import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class ExplorerHistoryTests: XCTestCase {
    func testChangedRecordingPolicyDoesNotHideAnOlderWideBucket() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-width-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let process = Make.process(timestamp: start, cpu: 20)
        try store.insert(Make.system(timestamp: start), processes: [process])
        try Retention.run(
            store.databasePool, now: start.addingTimeInterval(600),
            policy: RetentionPolicy(standardResBucket: 300))
        try store.databasePool.write { db in try Retention.setMeta(db, "minute_bucket_seconds", 60)
        }
        let time = start.addingTimeInterval(180)
        let machine = try store.systemHistory(
            from: time, to: time.addingTimeInterval(20), granularity: .minute)
        XCTAssertEqual(machine.first?.bucketDuration, 300)
        XCTAssertNotNil(try store.explorerMachineRecordAt(time, granularity: .minute))
        let processes = try store.explorerProcessHistories(
            identities: [process.id], from: time,
            to: time.addingTimeInterval(20), granularity: .minute)
        XCTAssertEqual(processes.first?.points.first?.duration, 300)
        XCTAssertEqual(
            try store.explorerProcessesAt(time, granularity: .minute).first?.point.duration, 300)
    }

    func testExistingHistoryReadOnlyWhenRequested() throws {
        guard let path = ProcessInfo.processInfo.environment["MACPERF_EXPLORER_DATABASE"] else {
            return
        }
        var configuration = Configuration()
        configuration.readonly = true
        let pool = try DatabasePool(path: path, configuration: configuration)
        let store = SampleStore(pool: pool)
        let timestamp = try XCTUnwrap(
            pool.read { db in
                try Double.fetchOne(db, sql: "SELECT MAX(timestamp) FROM system_samples")
            })
        let end = Date(timeIntervalSince1970: timestamp)
        for span in [300.0, 3600, 21600, 86400, 604800] {
            let started = Date()
            let from = end.addingTimeInterval(-span)
            var tier = try store.finestGranularityCovering(from: from, to: end)
            if span > 172800 { tier = .hour } else if span > 7200, tier == .raw { tier = .minute }
            let machine = try store.systemHistory(from: from, to: end, granularity: tier)
            let candidates = try store.explorerProcesses(from: from, to: end, limit: 8)
            let process = try store.explorerProcessHistories(
                identities: Array(candidates.prefix(2)).map(\.id),
                from: from, to: end, granularity: tier)
            XCTAssertTrue(machine.allSatisfy { $0.date <= end })
            XCTAssertTrue(process.flatMap(\.points).allSatisfy { $0.date <= end })
            let readSeconds = Date().timeIntervalSince(started)
            print(
                String(
                    format:
                        "Explorer read-only %.0f s window: %d machine rows, %d process rows, %.3f s",
                    span, machine.count, process.flatMap(\.points).count, readSeconds))
        }
        let record = try store.explorerMachineRecordAt(end, granularity: .raw)
        XCTAssertNotNil(record)
        _ = try store.explorerProcessesAt(end, granularity: .raw)
    }

    func testMachineRecordExposesStoredFieldsWithoutFutureOrStaleFallback() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        var sample = Make.system(timestamp: start, pressurePercent: 20)
        sample.pageInsDelta = 42
        sample.gpuDieC = nil
        try store.insert(systemSample: sample)
        let record = try XCTUnwrap(store.explorerMachineRecordAt(start, granularity: .raw))
        XCTAssertEqual(record.source, "system_samples")
        XCTAssertEqual(record.fields.first(where: { $0.name == "page_ins_delta" })?.value, "42")
        XCTAssertNil(record.fields.first(where: { $0.name == "gpu_die" })?.value)
        XCTAssertNil(
            try store.explorerMachineRecordAt(start.addingTimeInterval(-1), granularity: .raw))
        XCTAssertNil(
            try store.explorerMachineRecordAt(start.addingTimeInterval(60), granularity: .raw))
    }

    func testAsOfSnapshotNeverUsesFutureOrStaleProcessSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-at-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        for (offset, cpu) in [(0.0, 10.0), (30, 20), (90, 99)] {
            let date = start.addingTimeInterval(offset)
            try store.insert(
                Make.system(timestamp: date), processes: [Make.process(timestamp: date, cpu: cpu)])
        }
        let rows = try store.explorerProcessesAt(start.addingTimeInterval(45), granularity: .raw)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.point.values[.cpu], 20)
        XCTAssertEqual(rows.first?.point.date, start.addingTimeInterval(30))
        XCTAssertTrue(
            try store.explorerProcessesAt(start.addingTimeInterval(200), granularity: .raw).isEmpty)
        XCTAssertTrue(
            try store.explorerProcessesAt(start.addingTimeInterval(-1), granularity: .raw).isEmpty)
    }

    func testProcessExplorerSearchAndRawDetailsRespectIdentityAndWindow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-process-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let process = Make.process(
            timestamp: start, pid: 500, name: "BuildWorker", footprint: 1234, cpu: 42)
        try store.insert(Make.system(timestamp: start), processes: [process])
        let reused = Make.process(
            timestamp: start.addingTimeInterval(100), pid: 500,
            startTime: start.addingTimeInterval(99), name: "OtherWorker", footprint: 9876)
        try store.insert(Make.system(timestamp: reused.timestamp), processes: [reused])
        let matches = try store.explorerProcesses(
            from: start, to: start.addingTimeInterval(10), search: "build")
        XCTAssertEqual(matches.map(\.id), [process.id])
        let histories = try store.explorerProcessHistories(
            identities: [process.id, reused.id],
            from: start, to: start.addingTimeInterval(10), granularity: .raw)
        let point = try XCTUnwrap(
            histories.first(where: { $0.process.id == process.id })?.points.first)
        XCTAssertEqual(point.values[.footprint], 1234)
        XCTAssertEqual(point.values[.cpu], 42)
        XCTAssertEqual(point.values[.threads], 4)
        XCTAssertEqual(point.values[.sockets], 3)
        XCTAssertEqual(histories.first(where: { $0.process.id == reused.id })?.points.count, 0)
        XCTAssertThrowsError(
            try store.explorerProcessHistories(
                identities: [process.id], from: start,
                to: start.addingTimeInterval(10), granularity: .raw, maximumPointCount: 0))
    }

    func testProcessExplorerStitchesSequentialInstancesWithoutMergingConcurrentOnes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-lineage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let oldStart = start.addingTimeInterval(-30)
        let currentStart = start.addingTimeInterval(9)

        for (offset, footprint) in [(0.0, 100.0), (2.0, 110.0)] {
            let date = start.addingTimeInterval(offset)
            try store.insert(
                Make.system(timestamp: date),
                processes: [
                    Make.process(
                        timestamp: date, pid: 100, startTime: oldStart, name: "Agent",
                        footprint: UInt64(footprint))
                ])
        }
        for (offset, footprint) in [(10.0, 200.0), (12.0, 210.0)] {
            let date = start.addingTimeInterval(offset)
            try store.insert(
                Make.system(timestamp: date),
                processes: [
                    Make.process(
                        timestamp: date, pid: 200, startTime: currentStart, name: "Agent",
                        footprint: UInt64(footprint)),
                    Make.process(
                        timestamp: date, pid: 201, startTime: currentStart, name: "Agent",
                        footprint: 900),
                ])
        }

        let selected = ProcessIdentity(pid: 200, startTime: currentStart)
        let histories = try store.explorerProcessHistories(
            identities: [selected], from: start,
            to: start.addingTimeInterval(12), granularity: .raw)
        let history = try XCTUnwrap(histories.first)

        XCTAssertEqual(history.process.id, selected)
        XCTAssertEqual(history.points.compactMap { $0.values[.footprint] }, [100, 110, 200, 210])
        XCTAssertEqual(history.points.map(\.startsNewRun), [false, false, true, false])
    }

    func testProcessAggregatesLeaveRawOnlyFieldsUnavailable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-process-tier-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        let process = Make.process(timestamp: start, footprint: 1234, cpu: 10)
        try store.insert(Make.system(timestamp: start), processes: [process])
        try Retention.run(store.databasePool, now: start.addingTimeInterval(300))
        let history = try store.explorerProcessHistories(
            identities: [process.id], from: start,
            to: start.addingTimeInterval(59), granularity: .minute)
        let point = try XCTUnwrap(history.first?.points.first)
        XCTAssertEqual(point.duration, 60)
        XCTAssertEqual(point.values[.footprint], 1234)
        XCTAssertEqual(point.minima[.footprint], 1234)
        XCTAssertNil(point.values[.threads])
        XCTAssertNil(point.values[.resident])
        let zoomed = try store.explorerProcessHistories(
            identities: [process.id],
            from: start.addingTimeInterval(10), to: start.addingTimeInterval(20),
            granularity: .minute)
        XCTAssertEqual(zoomed.first?.points.first?.date, start)
        XCTAssertEqual(zoomed.first?.points.first?.duration, 60)
        try store.databasePool.write { db in
            try db.execute(sql: "UPDATE process_minute SET cpu_max = 0")
        }
        let legacy = try store.explorerProcessHistories(
            identities: [process.id], from: start,
            to: start.addingTimeInterval(59), granularity: .minute)
        XCTAssertEqual(legacy.first?.points.first?.values[.cpu], 10)
        XCTAssertNil(legacy.first?.points.first?.maxima[.cpu])
    }

    func testHistoricalMachineSliceExcludesNewerSamples() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-history-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        for offset in [0.0, 10, 20, 30, 3600] {
            var sample = Make.system(
                timestamp: start.addingTimeInterval(offset), pressurePercent: offset / 100)
            sample.cpuDieC = 60 + offset / 1000
            sample.gpuDieC = offset == 20 ? nil : 45
            try store.insert(systemSample: sample)
        }
        for granularity in [HistoryWindow.Granularity.raw, .minute, .hour] {
            let points = try store.systemHistory(
                from: start.addingTimeInterval(10), to: start.addingTimeInterval(20),
                granularity: granularity)
            XCTAssertEqual(points.map { $0.date.timeIntervalSince(start) }, [10, 20])
            XCTAssertEqual(points[0].cpuDieC, 60.01)
            XCTAssertNil(points[1].gpuDieC)
        }
        XCTAssertTrue(
            try store.systemHistory(
                from: start.addingTimeInterval(20), to: start, granularity: .hour
            ).isEmpty)
    }

    func testHistoricalMachineSliceKeepsStoredStatisticsAndBounds() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("explorer-tiers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try SampleStore(url: directory.appendingPathComponent("history.sqlite"))
        let start = Date(timeIntervalSince1970: 1_700_000_400)
        for offset in [0.0, 10, 20, 60, 70, 120] {
            try store.insert(
                systemSample: Make.system(
                    timestamp: start.addingTimeInterval(offset), pressurePercent: offset))
        }
        try Retention.run(store.databasePool, now: start.addingTimeInterval(300))
        let points = try store.systemHistory(
            from: start, to: start.addingTimeInterval(59), granularity: .minute)
        XCTAssertEqual(points.count, 1)
        let point = try XCTUnwrap(points.first)
        XCTAssertEqual(point.date, start)
        XCTAssertEqual(point.sampleCount, 3)
        XCTAssertEqual(point.bucketDuration, 60)
        XCTAssertEqual(point.pressurePercent, 10)
        XCTAssertEqual(point.minima?.pressurePercent, 0)
        XCTAssertEqual(point.peaks?.pressurePercent, 20)
        let zoomed = try store.systemHistory(
            from: start.addingTimeInterval(10),
            to: start.addingTimeInterval(20), granularity: .minute)
        XCTAssertEqual(zoomed.map(\.date), [start])
        XCTAssertEqual(zoomed.first?.bucketDuration, 60)
    }
}
