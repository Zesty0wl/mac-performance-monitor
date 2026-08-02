import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class GroupHistoryTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    private let startTime = Date(timeIntervalSince1970: 1_000_000)
    private let mb: UInt64 = 1024 * 1024

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-grouphist-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    private struct P {
        var pid: Int32
        var footprint: UInt64
        var cpu: Double
        var bundleID: String?
        var teamID: String?
    }

    private func insertTick(_ timestamp: Date, _ procs: [P]) throws {
        let samples = procs.map {
            Make.process(
                timestamp: timestamp, pid: $0.pid, startTime: startTime, name: "P\($0.pid)",
                bundleID: $0.bundleID, teamID: $0.teamID, footprint: $0.footprint, cpu: $0.cpu)
        }
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp), processes: samples,
                unreadableProcessCount: 0))
    }

    /// team_id is captured on the process row, and the upsert backfills it.
    func testTeamIDPersisted() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base, [P(pid: 1000, footprint: 100 * mb, cpu: 0, bundleID: nil, teamID: "AAA")])
        let teamID = try store.databasePool.read { db in
            try String.fetchOne(db, sql: "SELECT team_id FROM processes WHERE pid = 1000")
        }
        XCTAssertEqual(teamID, "AAA")
    }

    func testGroupMemberIDsResolvesByTeamID() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 0, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 0, bundleID: nil, teamID: "BBB"),
                P(pid: 3000, footprint: 30 * mb, cpu: 0, bundleID: nil, teamID: "AAA"),
            ])
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: base)
        XCTAssertEqual(ids.count, 2)
        // The matched rows should be P1 and P3 (both team AAA).
        let pids = try store.databasePool.read { db -> Set<Int32> in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            return Set(
                try Int32.fetchAll(
                    db, sql: "SELECT pid FROM processes WHERE id IN (\(placeholders))",
                    arguments: StatementArguments(ids)))
        }
        XCTAssertEqual(pids, [1000, 3000])
    }

    func testGroupSeriesSumsMembersPerTick() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        // Two members, two ticks. Tick0: 100 + 50 = 150 MB, cpu 10 + 5 = 15.
        // Tick1: 200 + 60 = 260 MB, cpu 30 + 5 = 35.
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        try insertTick(
            base.addingTimeInterval(2),
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 30, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 60 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        let now = base.addingTimeInterval(2)
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let series = try store.groupSeries(processIDs: ids, window: .oneHour, now: now)
        XCTAssertEqual(series.count, 2)
        XCTAssertEqual(series.first?.footprint, 150 * mb)
        XCTAssertEqual(series.first?.cpuPercent ?? 0, 15, accuracy: 0.001)
        XCTAssertEqual(series.last?.footprint, 260 * mb)
        XCTAssertEqual(series.last?.cpuPercent ?? 0, 35, accuracy: 0.001)
    }

    /// The minute tier carries both the bucket mean and the bucket peak through
    /// to the group series, so the "Peak" lens has data on the longer windows.
    func testGroupSeriesCarriesPeakFromMinuteTier() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)  // minute-aligned
        // One complete minute, two members of team AAA.
        // P1 footprint 100/200/300 MB (avg 200, peak 300), cpu 10/20/30 (avg 20,
        // peak 30); P2 flat 50 MB and 5% cpu (avg == peak).
        let p1fp: [UInt64] = [100 * mb, 200 * mb, 300 * mb]
        let p1cpu: [Double] = [10, 20, 30]
        let offsets: [Double] = [0, 20, 40]
        for i in 0..<3 {
            try insertTick(
                base.addingTimeInterval(offsets[i]),
                [
                    P(pid: 1000, footprint: p1fp[i], cpu: p1cpu[i], bundleID: nil, teamID: "AAA"),
                    P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
                ])
        }
        let now = base.addingTimeInterval(120)  // minute m0 is complete
        try Retention.run(store.databasePool, now: now)

        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")),
            window: .oneDay, glossary: nil, now: now)
        let series = try store.groupSeries(processIDs: ids, window: .oneDay, now: now)
        XCTAssertEqual(series.count, 1)
        let point = try XCTUnwrap(series.first)
        // Average concurrent footprint/CPU: 200 + 50 = 250 MB, 20 + 5 = 25%.
        XCTAssertEqual(point.footprint, 250 * mb)
        XCTAssertEqual(point.cpuPercent, 25, accuracy: 0.001)
        // Peak concurrent (summed per-member bucket maxima): 300 + 50 = 350 MB,
        // 30 + 5 = 35%.
        XCTAssertEqual(point.footprintPeak, 350 * mb)
        XCTAssertEqual(point.cpuPeakPercent, 35, accuracy: 0.001)
    }

    func testGroupMemberConsumersAggregatePerMember() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        // 1 s apart — the real logging cadence, where each raw row's held
        // duration is one interval so the time-weighted mean equals the simple
        // mean. (Wider spacing would weight by held duration; see the dedicated
        // weighting test.)
        try insertTick(
            base.addingTimeInterval(1),
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 30, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 50 * mb, cpu: 5, bundleID: nil, teamID: "AAA"),
            ])
        let now = base.addingTimeInterval(1)
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let members = try store.groupMemberConsumers(
            processIDs: ids, window: .oneHour, metric: .averageFootprint, now: now)
        XCTAssertEqual(members.count, 2)
        // P1 avg footprint (100+200)/2 = 150 MB, ranked first.
        XCTAssertEqual(members.first?.identity.pid, 1000)
        XCTAssertEqual(members.first?.averageFootprint, 150 * mb)
        XCTAssertEqual(members.last?.identity.pid, 2000)
        XCTAssertEqual(members.last?.averageFootprint, 50 * mb)
    }

    // MARK: - Merged program members

    /// A process instance with its own name and start time, so a test can model
    /// the same program being quit and relaunched (a new PID and a new start
    /// time, hence a new `processes` row) or running several instances at once.
    private struct Instance {
        var pid: Int32
        var startTime: Date
        var name: String
        var footprint: UInt64
        var cpu: Double = 0
        var teamID: String? = "AAA"
    }

    private func insertInstances(_ timestamp: Date, _ instances: [Instance]) throws {
        let samples = instances.map {
            Make.process(
                timestamp: timestamp, pid: $0.pid, startTime: $0.startTime, name: $0.name,
                teamID: $0.teamID, footprint: $0.footprint, cpu: $0.cpu)
        }
        try store.insert(
            Sampler.Snapshot(
                system: Make.system(timestamp: timestamp), processes: samples,
                unreadableProcessCount: 0))
    }

    private func teamMemberIDs(_ now: Date, team: String = "AAA") throws -> [Int64] {
        try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: team)), window: .oneHour,
            glossary: nil, now: now)
    }

    /// Quitting and relaunching a program gives it a fresh PID and therefore a
    /// fresh `processes` row. Those used to list as separate members; they now
    /// merge into one, and its footprint is the time-weighted mean of what the
    /// program held *while it was running*: the idle stretch between the runs is
    /// not averaged in.
    func testRestartsMergeIntoOneProgram() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let mb = self.mb
        // Run one: pid 100 at 200 MB, ticks at +0 and +1, then it exits.
        for offset in [0.0, 1.0] {
            try insertInstances(
                base.addingTimeInterval(offset),
                [Instance(pid: 100, startTime: base, name: "App", footprint: 200 * mb)])
        }
        // Run two: a new PID for the same executable at 400 MB, ticks at +10, +11.
        for offset in [10.0, 11.0] {
            try insertInstances(
                base.addingTimeInterval(offset),
                [
                    Instance(
                        pid: 200, startTime: base.addingTimeInterval(9), name: "App",
                        footprint: 400 * mb)
                ])
        }

        let now = base.addingTimeInterval(11)
        let breakdown = try store.groupBreakdown(
            processIDs: try teamMemberIDs(now), window: .oneHour, bucketSeconds: 2, now: now)

        XCTAssertEqual(breakdown.programs.count, 1, "restarts of one executable are one member")
        let program = try XCTUnwrap(breakdown.programs.first)
        XCTAssertEqual(program.instanceCount, 2)
        // The newest instance represents the program, so a row's actions target it.
        XCTAssertEqual(program.representative.pid, 200)
        // Run one held 200 MB for 3 s (2 s of ticks plus the one-heartbeat grace
        // before it is declared gone), run two 400 MB for 2 s: 1400/5 = 280 MB.
        XCTAssertEqual(program.averageFootprint, 280 * mb)
        XCTAssertEqual(program.peakFootprint, 400 * mb)
        // Resident for those 5 s only, not the 11 s the window spans.
        XCTAssertEqual(program.residentSeconds, 5, accuracy: 0.001)
    }

    /// Instances of one program running side by side are summed, not averaged: a
    /// browser with twenty renderers really does cost twenty renderers.
    func testConcurrentInstancesOfOneProgramSum() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let mb = self.mb
        for offset in [0.0, 1.0] {
            try insertInstances(
                base.addingTimeInterval(offset),
                [
                    Instance(pid: 100, startTime: base, name: "Helper", footprint: 100 * mb, cpu: 3),
                    Instance(pid: 101, startTime: base, name: "Helper", footprint: 150 * mb, cpu: 4),
                    Instance(pid: 102, startTime: base, name: "Helper", footprint: 50 * mb, cpu: 1),
                ])
        }
        let now = base.addingTimeInterval(1)
        let breakdown = try store.groupBreakdown(
            processIDs: try teamMemberIDs(now), window: .oneHour, bucketSeconds: 2, now: now)

        XCTAssertEqual(breakdown.programs.count, 1)
        let program = try XCTUnwrap(breakdown.programs.first)
        XCTAssertEqual(program.instanceCount, 3)
        XCTAssertEqual(program.averageFootprint, 300 * mb)
        XCTAssertEqual(program.averageCPU, 8, accuracy: 0.001)
        // A program that never left is resident for the whole observed span.
        XCTAssertEqual(program.residentSeconds, 2, accuracy: 0.001)
    }

    /// Different executables stay separate members even when they run together.
    func testDistinctProgramsStaySeparate() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let mb = self.mb
        try insertInstances(
            base,
            [
                Instance(pid: 100, startTime: base, name: "Alpha", footprint: 300 * mb),
                Instance(pid: 200, startTime: base, name: "Beta", footprint: 100 * mb),
            ])
        let breakdown = try store.groupBreakdown(
            processIDs: try teamMemberIDs(base), window: .oneHour, bucketSeconds: 2, now: base)
        XCTAssertEqual(breakdown.programs.map(\.displayName), ["Alpha", "Beta"])
    }

    /// A member that exits must stop contributing to the group's combined
    /// timeline once it is a heartbeat overdue. Carrying its last footprint
    /// forward for the rest of the window made every group with restart-happy
    /// members read far heavier than it ever was.
    func testExitedMemberIsNotCarriedForward() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        let mb = self.mb
        // Both members present at +0; only the survivor reports afterwards.
        try insertInstances(
            base,
            [
                Instance(pid: 100, startTime: base, name: "Gone", footprint: 500 * mb),
                Instance(pid: 200, startTime: base, name: "Survivor", footprint: 100 * mb),
            ])
        for offset in [1.0, 6.0] {
            try insertInstances(
                base.addingTimeInterval(offset),
                [Instance(pid: 200, startTime: base, name: "Survivor", footprint: 100 * mb)])
        }

        let now = base.addingTimeInterval(6)
        let series = try store.groupSeries(
            processIDs: try teamMemberIDs(now), window: .oneHour, bucketSeconds: 2, now: now)

        XCTAssertEqual(series.map(\.footprint), [600 * mb, 600 * mb, 100 * mb])
        XCTAssertEqual(series.last?.date, now)
    }

    /// The merged rows and the group's own timeline come out of one walk, so the
    /// dense minute tier must agree with the sparse raw tier on what a program's
    /// instances weighed together.
    func testProgramsMergeOnTheMinuteTier() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)  // minute-aligned
        let mb = self.mb
        for offset in [0.0, 20.0, 40.0] {
            try insertInstances(
                base.addingTimeInterval(offset),
                [
                    Instance(pid: 100, startTime: base, name: "Helper", footprint: 100 * mb),
                    Instance(pid: 101, startTime: base, name: "Helper", footprint: 200 * mb),
                    Instance(pid: 300, startTime: base, name: "Other", footprint: 60 * mb),
                ])
        }
        let now = base.addingTimeInterval(120)  // the first minute bucket is complete
        try Retention.run(store.databasePool, now: now)

        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")),
            window: .oneDay, glossary: nil, now: now)
        let breakdown = try store.groupBreakdown(processIDs: ids, window: .oneDay, now: now)

        XCTAssertEqual(breakdown.programs.count, 2)
        let helper = try XCTUnwrap(breakdown.programs.first { $0.displayName == "Helper" })
        XCTAssertEqual(helper.instanceCount, 2)
        XCTAssertEqual(helper.averageFootprint, 300 * mb)
        // The group's own timeline still sums every member in the bucket.
        XCTAssertEqual(breakdown.series.count, 1)
        XCTAssertEqual(breakdown.series.first?.footprint, 360 * mb)
    }

    func testGroupSeriesEmptyWithoutMembers() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        XCTAssertTrue(try store.groupSeries(processIDs: [], window: .oneHour, now: base).isEmpty)
    }

    /// End-to-end additivity against real device constants: the group score from
    /// the summed series equals the sum of per-member contributions.
    func testDecompositionAdditiveAgainstMemberConsumers() throws {
        let base = Date(timeIntervalSince1970: 1_700_000_400)
        try insertTick(
            base,
            [
                P(pid: 1000, footprint: 200 * mb, cpu: 40, bundleID: nil, teamID: "AAA"),
                P(pid: 2000, footprint: 100 * mb, cpu: 10, bundleID: nil, teamID: "AAA"),
            ])
        let now = base
        let ids = try store.groupMemberIDs(
            rule: .condition(GroupCondition(field: .teamID, value: "AAA")), window: .oneHour,
            glossary: nil, now: now)
        let members = try store.groupMemberConsumers(processIDs: ids, window: .oneHour, now: now)
        let device = GroupFootprint.Device(cores: 8, totalRAM: 16 * 1024 * mb)
        let d = GroupFootprint.decompose(consumers: members, device: device)
        let sum = d.contributions.reduce(0) { $0 + $1.score }
        XCTAssertEqual(sum, d.groupScore, accuracy: 1e-9)
        XCTAssertEqual(d.contributions.count, 2)
    }
}
