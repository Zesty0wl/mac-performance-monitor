import Darwin
import GRDB
import XCTest

@testable import MacPerfMonitorCore

final class NetworkTests: XCTestCase {
    private var tempURL: URL!
    private var store: SampleStore!

    override func setUpWithError() throws {
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("macperfmonitor-network-test-\(UUID().uuidString).sqlite")
        store = try SampleStore(url: tempURL)
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: tempURL)
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: tempURL.appendingPathExtension("shm"))
    }

    // MARK: - NetworkReader

    /// The reader must never crash and must report non-negative rates. The first
    /// read seeds the counters, so its rate is zero (nothing to difference).
    func testNetworkReaderIsSafeAndConsistent() {
        let reader = NetworkReader()
        let now = Date()
        if let first = reader.read(now: now) {
            XCTAssertEqual(first.inBytesPerSec, 0, accuracy: 0.001)
            XCTAssertEqual(first.outBytesPerSec, 0, accuracy: 0.001)
        }
        if let second = reader.read(now: now.addingTimeInterval(1)) {
            XCTAssertGreaterThanOrEqual(second.inBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(second.outBytesPerSec, 0)
            XCTAssertGreaterThanOrEqual(second.sessionInBytes, 0)
        }
    }

    // MARK: - Network scanner

    func testNetworkScanConfigurationBuildsInclusiveRange() throws {
        let configuration = NetworkScanConfiguration(
            interfaceName: "en0", localIPv4Address: "192.168.68.158",
            fromIPv4Address: "192.168.68.1", toIPv4Address: "192.168.68.3")
        XCTAssertEqual(
            try configuration.addresses(),
            ["192.168.68.1", "192.168.68.2", "192.168.68.3"])
    }

    func testNetworkScanConfigurationRejectsInvalidAndOversizedRanges() {
        let invalid = NetworkScanConfiguration(
            interfaceName: "en0", localIPv4Address: "192.168.1.2",
            fromIPv4Address: "192.168.1.300", toIPv4Address: "192.168.1.5")
        XCTAssertThrowsError(try invalid.addresses())

        let oversized = NetworkScanConfiguration(
            interfaceName: "en0", localIPv4Address: "10.0.0.2",
            fromIPv4Address: "10.0.0.1", toIPv4Address: "10.0.16.1")
        XCTAssertThrowsError(try oversized.addresses())
    }

    func testNetworkScanSuggestedRangeUsesUsableSubnetAddresses() {
        let range = NetworkIPv4Address.suggestedRange(address: "192.168.68.158", prefixLength: 24)
        XCTAssertEqual(range?.from, "192.168.68.1")
        XCTAssertEqual(range?.to, "192.168.68.254")

        let clamped = NetworkIPv4Address.suggestedRange(address: "10.42.7.8", prefixLength: 8)
        XCTAssertEqual(clamped?.from, "10.42.0.1")
        XCTAssertEqual(clamped?.to, "10.42.15.254")
    }

    func testNetworkScannerParsesARPForSelectedInterface() {
        let output = """
            ? (192.168.68.1) at b4:b0:24:e9:e6:45 on en0 ifscope [ethernet]
            ? (192.168.68.2) at (incomplete) on en0 ifscope [ethernet]
            ? (192.168.68.3) at 0:11:32:98:c7:b2 on en5 ifscope [ethernet]
            """
        let entries = NetworkScanner.parseARPTable(output, interfaceName: "en0")
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.ipv4Address, "192.168.68.1")
        XCTAssertEqual(entries.first?.macAddress, "B4:B0:24:E9:E6:45")
    }

    func testNetworkScannerCorrelatesNDPByNormalizedMAC() {
        let output = """
            Neighbor Linklayer Address Netif Expire St Flgs Prbs
            fe80::211:32ff:fe98:c7b2%en0 0:11:32:98:c7:b2 en0 23h S
            fd12::42 00:11:32:98:c7:b2 en0 23h S
            fe80::1%en5 0:11:32:98:c7:b2 en5 23h S
            """
        let entries = NetworkScanner.parseNDPTable(output, interfaceName: "en0")
        XCTAssertEqual(entries["00:11:32:98:C7:B2"]?.local, ["fe80::211:32ff:fe98:c7b2"])
        XCTAssertEqual(entries["00:11:32:98:C7:B2"]?.global, ["fd12::42"])
    }

    func testNetworkScannerParsesSMBIdentity() {
        let output = """
            NetBIOS Name Number Type Description
            DISKSTATION 0x00 UNIQUE [Workstation Service]
            DISKSTATION 0x20 UNIQUE [File/Print Server Service]
            WORKGROUP 0x00 GROUP [Domain Name]
            """
        let identity = NetworkScanner.parseSMBStatus(output)
        XCTAssertEqual(identity?.name, "DISKSTATION")
        XCTAssertEqual(identity?.domain, "WORKGROUP")
    }

    func testNetworkVendorRegistryParsesQuotedOrganization() {
        let csv = """
            Registry,Assignment,Organization Name,Organization Address
            MA-L,001122,"Example Devices, Inc.",Somewhere
            """
        XCTAssertEqual(NetworkVendorRegistry.parse(csv: csv)["001122"], "Example Devices, Inc.")
    }

    func testNetworkVendorCacheReturnsResolvedPrefixImmediately() {
        let names = NetworkVendorCache.names(
            for: ["00:11:22:33:44:55"], entries: ["001122": "Example Devices"])
        XCTAssertEqual(names["00:11:22:33:44:55"], "Example Devices")
    }

    func testNetworkVendorCacheTreatsEmptyEntryAsCachedNotFound() {
        let names = NetworkVendorCache.names(
            for: ["00:BB:CC:DD:EE:FF"], entries: ["00BBCC": ""])
        XCTAssertTrue(names.isEmpty)
    }

    func testNetworkMACAddressKinds() {
        XCTAssertEqual(
            NetworkMACAddress.kind("00:11:22:33:44:55"), .universallyAdministered)
        XCTAssertEqual(
            NetworkMACAddress.kind("02:11:22:33:44:55"), .locallyAdministered)
        XCTAssertEqual(NetworkMACAddress.kind("01:00:5E:00:00:FB"), .multicast)
    }

    func testNetworkVendorCacheIgnoresLocallyAdministeredMAC() {
        let names = NetworkVendorCache.names(
            for: ["02:11:22:33:44:55"], entries: ["021122": "Not a real vendor"])
        XCTAssertTrue(names.isEmpty)
    }

    func testNetworkPortScannerFindsOpenLoopbackPort() async throws {
        let listener = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(Darwin.listen(listener, 1), 0)

        var selectedAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let readAddress = withUnsafeMutablePointer(to: &selectedAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        XCTAssertEqual(readAddress, 0)
        let port = UInt16(bigEndian: selectedAddress.sin_port)

        let open = await NetworkScanner().scanPorts(
            host: "127.0.0.1", interfaceName: "lo0", ports: [port])
        XCTAssertEqual(open.map(\.port), [port])
    }

    // MARK: - nettop parsing

    func testNettopParsesStreamingRow() {
        let row = NetworkProcessReader.parse(line: "09:18:46.271725,apsd.644,5160036,3174755,")
        XCTAssertEqual(row?.pid, 644)
        XCTAssertEqual(row?.counters.inBytes, 5_160_036)
        XCTAssertEqual(row?.counters.outBytes, 3_174_755)
    }

    func testNettopParsesPlainRow() {
        let row = NetworkProcessReader.parse(line: "remoted.621,20849,5985,")
        XCTAssertEqual(row?.pid, 621)
        XCTAssertEqual(row?.counters.inBytes, 20_849)
        XCTAssertEqual(row?.counters.outBytes, 5_985)
    }

    func testNettopSkipsHeaderAndBlankLines() {
        XCTAssertNil(NetworkProcessReader.parse(line: ",bytes_in,bytes_out,"))
        XCTAssertNil(NetworkProcessReader.parse(line: "time,,bytes_in,bytes_out,"))
        XCTAssertNil(NetworkProcessReader.parse(line: ""))
    }

    /// Process names can contain dots (IP-like labels) and even commas; the PID is
    /// always the integer after the last dot, and the bytes are the last two
    /// fields, so the position-independent parser copes with both.
    func testNettopHandlesAwkwardNames() {
        let dotted = NetworkProcessReader.parse(line: "2.1.179.13221,229203,202444021,")
        XCTAssertEqual(dotted?.pid, 13221)
        XCTAssertEqual(dotted?.counters.inBytes, 229_203)
        XCTAssertEqual(dotted?.counters.outBytes, 202_444_021)

        let commad = NetworkProcessReader.parse(line: "Weird, Name.42,1,2,")
        XCTAssertEqual(commad?.pid, 42)
        XCTAssertEqual(commad?.counters.inBytes, 1)
        XCTAssertEqual(commad?.counters.outBytes, 2)
    }

    /// The one-shot reader parses a full nettop output block (header + rows) into
    /// cumulative per-PID counters. (Sampled one-shot to a pipe rather than streamed
    /// under a pty, so there is no partial-line buffering to test.)
    func testParsesOneShotOutputBlock() {
        let output = """
            time,bytes_in,bytes_out,
            09:00:00.0,Foo.111,100,200,
            09:00:00.0,Bar.222,300,400,
            2.1.179.13221,229203,202444021,
            """
        let counters = NetworkProcessReader.parse(output: output)
        XCTAssertEqual(counters[111]?.inBytes, 100)
        XCTAssertEqual(counters[111]?.outBytes, 200)
        XCTAssertEqual(counters[222]?.outBytes, 400)
        // A dotted process name resolves to the trailing pid.
        XCTAssertEqual(counters[13221]?.inBytes, 229203)
        // The header row is skipped (non-numeric byte fields).
        XCTAssertNil(counters[0])
    }

    // MARK: - nettop pacing

    /// The refresh loop must never respawn nettop back-to-back: fast runs sleep
    /// out to the fixed floor, and slow runs (5–17 s observed on some machines,
    /// docs/fd-count-1620-diagnosis.md) pause twice their own duration so nettop
    /// occupies at most ~1/3 of wall time.
    func testPaceSleepFloorsFastRunsAndStretchesSlowOnes() {
        // Fast machine: a 20 ms run sleeps out to the 2 s floor.
        XCTAssertEqual(
            NetworkProcessReader.paceSleep(afterRunTaking: 0.02), 1.98, accuracy: 0.001)
        // Degenerate elapsed still pauses the full floor.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 0), 2, accuracy: 0.001)
        // At the floor the pause is already dominated by the adaptive term.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 2), 4, accuracy: 0.001)
        // The diagnosed machine: a 5.1 s run gives a ~15.3 s total cycle instead
        // of an immediate respawn.
        XCTAssertEqual(NetworkProcessReader.paceSleep(afterRunTaking: 5.1), 10.2, accuracy: 0.001)
    }

    // MARK: - Rate formatting

    func testRateFormatting() {
        XCTAssertEqual(ByteFormat.rate(0), "0 B/s")
        XCTAssertEqual(ByteFormat.rate(512), "512 B/s")
        XCTAssertEqual(ByteFormat.rate(1024), "1.0 KB/s")
        XCTAssertEqual(ByteFormat.rate(1024 * 1024 * 3 / 2), "1.5 MB/s")
    }

    func testRateCompactFormatting() {
        XCTAssertEqual(ByteFormat.rateCompact(0), "0")
        XCTAssertEqual(ByteFormat.rateCompact(1024), "1.0K")
        XCTAssertEqual(ByteFormat.rateCompact(1024 * 1024 * 3 / 2), "1.5M")
        XCTAssertEqual(ByteFormat.rateCompact(15 * 1024 * 1024), "15M")
    }

    // MARK: - v6 persistence round-trip

    func testNetworkFieldsRoundTripThroughSystemSamples() throws {
        let now = Date()
        var system = Make.system(timestamp: now)
        system.networkInBytesPerSec = 1_500_000
        system.networkOutBytesPerSec = 250_000

        try store.insert(systemSample: system)

        let read = try XCTUnwrap(try store.latestSystemSample())
        XCTAssertEqual(read.networkInBytesPerSec, 1_500_000, accuracy: 0.001)
        XCTAssertEqual(read.networkOutBytesPerSec, 250_000, accuracy: 0.001)

        let history = try store.systemHistory(.oneHour, now: now.addingTimeInterval(1))
        let point = try XCTUnwrap(history.last)
        XCTAssertEqual(point.networkInBytesPerSec, 1_500_000, accuracy: 0.001)
        XCTAssertEqual(point.networkOutBytesPerSec, 250_000, accuracy: 0.001)
    }

    func testPerProcessNetworkRoundTripThroughProcessHistory() throws {
        let now = Date()
        let system = Make.system(timestamp: now)
        var p = Make.process(timestamp: now, pid: 321, name: "Net")
        p.networkBytesPerSec = 42_000

        try store.insert(system, processes: [p])

        let points = try store.processHistory(
            for: p.id, window: .oneHour, now: now.addingTimeInterval(1))
        let point = try XCTUnwrap(points.last)
        XCTAssertEqual(point.networkBytesPerSec, 42_000, accuracy: 0.001)
    }

    func testTopConsumersRankByNetwork() throws {
        let now = Date()
        let system = Make.system(timestamp: now)

        var chatty = Make.process(timestamp: now, pid: 100, name: "Chatty")
        chatty.networkBytesPerSec = 5_000_000
        var quiet = Make.process(timestamp: now, pid: 200, name: "Quiet")
        quiet.networkBytesPerSec = 1_000

        try store.insert(system, processes: [quiet, chatty])

        let ranked = try store.topConsumers(
            window: .oneHour, metric: .averageNetwork, limit: 10, now: now.addingTimeInterval(1))
        XCTAssertEqual(ranked.first?.name, "Chatty")
        XCTAssertEqual(ranked.first?.averageNetwork ?? 0, 5_000_000, accuracy: 0.001)
        XCTAssertEqual(ranked.last?.name, "Quiet")
    }

    // MARK: - Insights

    func testSustainedNetworkProducesInsight() {
        let now = Date()
        // ~12 minutes of 3 MB/s total throughput (2.5 down + 0.5 up), one point
        // every 12 s, ending at `now`.
        let history = (0..<60).map { i in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(-i) * 12),
                pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0,
                networkInBytesPerSec: 2_500_000, networkOutBytesPerSec: 500_000)
        }.reversed()

        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now,
                totalRAM: 16_000_000_000,
                currentPressure: .normal,
                systemHistory: Array(history),
                leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0)))
        XCTAssertTrue(
            insights.contains { $0.kind == .network },
            "sustained multi-MB/s throughput should produce a network insight")
    }

    func testIdleNetworkProducesNoInsight() {
        let now = Date()
        let history = (0..<60).map { i in
            SystemHistoryPoint(
                date: now.addingTimeInterval(Double(-i) * 12),
                pressurePercent: 0, appMemory: 0, wired: 0, compressed: 0,
                cachedFiles: 0, swapUsed: 0,
                networkInBytesPerSec: 2_000, networkOutBytesPerSec: 500)
        }.reversed()

        let insights = InsightEngine.insights(
            InsightEngine.Inputs(
                now: now,
                totalRAM: 16_000_000_000,
                currentPressure: .normal,
                systemHistory: Array(history),
                leaks: [], events: [], consumers: [], consumerSeries: [:],
                rosetta: RosettaCost(processCount: 0, totalFootprint: 0)))
        XCTAssertFalse(insights.contains { $0.kind == .network })
    }
}
