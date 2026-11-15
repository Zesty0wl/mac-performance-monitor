// SPDX-License-Identifier: MIT
import XCTest

@testable import MacPerfMonitor

/// The Details panel's Command line row: what it shows, and that a copied line
/// splits back into the same arguments in a shell.
final class ProcessCommandLineTests: XCTestCase {
    func testAProcessStartedWithNoArgumentsShowsNone() {
        // An XPC service's argv is only its program, which Path already shows.
        XCTAssertNil(
            ProcessCommandLine.displayed([
                "/System/Library/Frameworks/Metal.framework/Versions/A/XPCServices/"
                    + "MTLCompilerService.xpc/Contents/MacOS/MTLCompilerService"
            ]))
        XCTAssertNil(ProcessCommandLine.displayed(["-zsh"]))
        XCTAssertNil(ProcessCommandLine.displayed([]))
    }

    func testArgumentsShowWithTheProgramAsStarted() {
        XCTAssertEqual(
            ProcessCommandLine.displayed(["python3", "-u", "/srv/job/run_job.py"]),
            "python3 -u /srv/job/run_job.py")
        XCTAssertEqual(
            ProcessCommandLine.displayed(["/bin/zsh", "-c", "echo 'hi' && ls"]),
            #"/bin/zsh -c 'echo '\''hi'\'' && ls'"#)
        XCTAssertEqual(ProcessCommandLine.displayed(["node", ""]), "node ''")
    }

    func testQuotedLineSplitsBackIntoTheSameArguments() throws {
        let arguments = ["/bin/echo", "plain", "two words", "it's", "$HOME", "a\"b", ""]
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "printf '%s\\n' " + ProcessCommandLine.quoted(arguments)]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try shell.run()
        shell.waitUntilExit()
        let output = String(
            decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        XCTAssertEqual(
            output.split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(
                String.init), arguments)
    }
}
