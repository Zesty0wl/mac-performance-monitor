import XCTest

@testable import MacPerfMonitorCore

final class ProcessDetailFieldsTests: XCTestCase {
    // MARK: Working directory

    func testWorkingDirectoryOfOwnProcess() throws {
        let reported = try XCTUnwrap(ProcessReader().workingDirectory(getpid()))
        let expected = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .resolvingSymlinksInPath().path
        XCTAssertEqual(URL(fileURLWithPath: reported).resolvingSymlinksInPath().path, expected)
    }

    func testWorkingDirectoryOfUnreadableProcessIsNil() {
        XCTAssertNil(ProcessReader().workingDirectory(-1))
        if geteuid() != 0 { XCTAssertNil(ProcessReader().workingDirectory(1)) }
    }

    // MARK: Remote address

    private func socket(_ detail: String) -> OpenFileDescriptor {
        OpenFileDescriptor(fd: 3, kind: .socket, detail: detail)
    }

    func testRemoteAddressIsReadFromConnectedSockets() {
        XCTAssertEqual(
            socket("tcp 10.0.0.2:51234 -> 17.253.144.10:443").remoteAddress, "17.253.144.10")
        XCTAssertEqual(
            socket("tcp [fe80::1]:51234 -> [2620:149:af0::10]:443").remoteAddress,
            "2620:149:af0::10")
        XCTAssertEqual(socket("udp 10.0.0.2:5353 -> 224.0.0.251:5353").remoteAddress, "224.0.0.251")
    }

    func testRemoteAddressIsNilWhereThereIsNoRemoteEnd() {
        XCTAssertNil(socket("tcp 0.0.0.0:8080 (listening)").remoteAddress)
        XCTAssertNil(socket("unix /var/run/thing.sock").remoteAddress)
        XCTAssertNil(socket("socket").remoteAddress)
        XCTAssertNil(socket("tcp 10.0.0.2:1 -> [broken").remoteAddress)
        XCTAssertNil(
            OpenFileDescriptor(fd: 4, kind: .file, detail: "/tmp/a -> b:1").remoteAddress,
            "A file path that happens to contain an arrow is not a socket")
    }

    // MARK: TCP state

    func testListsTheStateOfRealTCPSockets() throws {
        // A listener on loopback, a client connected to it, and the accepted end.
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(listener, 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer -> Int32 in
                guard Darwin.bind(listener, pointer, length) == 0, Darwin.listen(listener, 1) == 0
                else {
                    return -1
                }
                return getsockname(listener, pointer, &length)
            }
        }
        XCTAssertEqual(bound, 0)

        let client = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        defer { close(client) }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(client, $0, length)
            }
        }
        XCTAssertEqual(connected, 0)
        let accepted = Darwin.accept(listener, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { close(accepted) }

        let descriptors = try XCTUnwrap(ProcessReader().openFileDescriptors(getpid()))
        let byFD = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.fd, $0) })
        XCTAssertEqual(byFD[listener]?.tcpState, .listening)
        XCTAssertEqual(byFD[client]?.tcpState, .established)
        XCTAssertEqual(byFD[accepted]?.tcpState, .established)
        XCTAssertEqual(byFD[client]?.remoteAddress, "127.0.0.1")
        // A file is not a TCP socket.
        XCTAssertNil(descriptors.first { $0.kind == .file }?.tcpState)
    }

    func testStateLabelsMatchNetstat() {
        XCTAssertEqual(OpenFileDescriptor.TCPState.established.label, "ESTABLISHED")
        XCTAssertEqual(OpenFileDescriptor.TCPState(rawValue: 10)?.label, "TIME_WAIT")
        XCTAssertNil(OpenFileDescriptor.TCPState(rawValue: -1))
        XCTAssertNil(OpenFileDescriptor.TCPState(rawValue: 11))
    }

    /// A helper built before the field existed sends descriptors without it.
    func testDescriptorFromAnOlderHelperStillDecodes() throws {
        let old = try JSONEncoder().encode([OldDescriptor(fd: 7, kind: .socket, detail: "socket")])
        let decoded = try JSONDecoder().decode([OpenFileDescriptor].self, from: old)
        XCTAssertEqual(decoded.first?.fd, 7)
        XCTAssertNil(decoded.first?.tcpState)
    }

    private struct OldDescriptor: Codable {
        var fd: Int32
        var kind: OpenFileDescriptor.Kind
        var detail: String
    }

    // MARK: Reverse DNS

    func testLoopbackResolvesWithoutTheNetwork() {
        XCTAssertEqual(ReverseDNS.hostName(for: "127.0.0.1"), "localhost")
    }

    func testTextThatIsNotAnAddressIsNeverLookedUp() {
        XCTAssertNil(ReverseDNS.hostName(for: "example.com"))
        XCTAssertNil(ReverseDNS.hostName(for: ""))
        XCTAssertNil(ReverseDNS.hostName(for: "999.1.1.1"))
    }

    func testLocalAddressesAreNotWorthAQuery() {
        for address in ["127.0.0.1", "::1", "0.0.0.0", "::", "169.254.10.2", "fe80::1", ""] {
            XCTAssertFalse(ReverseDNS.isWorthLookingUp(address), address)
        }
        for address in ["17.253.144.10", "192.168.1.20", "2620:149:af0::10"] {
            XCTAssertTrue(ReverseDNS.isWorthLookingUp(address), address)
        }
    }
}
