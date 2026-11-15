import Darwin
import XCTest

@testable import MacPerfMonitorCore

/// Workers have no label of their own (a `multiprocessing` pool starts them
/// with `python -c`), so they are named after the interpreter that started
/// them: "train.py (worker)".
final class CommandLabelWorkerTests: XCTestCase {
    private func state(
        _ argv: [String], name: String = "Python", path: String = "/opt/homebrew/bin/python3",
        parent: CommandLabel.State? = nil
    ) -> CommandLabel.State {
        var state = CommandLabel.State()
        state.update(
            name: name, executablePath: path, uid: getuid(), arguments: { argv },
            parent: { parent })
        return state
    }

    func testUnlabelledChildOfALabelledInterpreterIsItsWorker() {
        let parent = state(["python3", "parity_probe.py"])
        XCTAssertEqual(parent.label, "parity_probe.py")
        // A multiprocessing pool worker and its resource tracker (seen live).
        let worker = state(
            [
                "Python", "-c",
                "from multiprocessing.spawn import spawn_main; spawn_main(tracker_fd=5, pipe_handle=7)",
                "--multiprocessing-fork",
            ], parent: parent)
        XCTAssertEqual(worker.label, "parity_probe.py (worker)")
        let tracker = state(
            ["Python", "-c", "from multiprocessing.resource_tracker import main;main(14)"],
            parent: parent)
        XCTAssertEqual(tracker.label, "parity_probe.py (worker)")
        // A worker's own worker keeps the one suffix.
        XCTAssertEqual(
            state(["Python", "-c", "pass"], parent: worker).label, "parity_probe.py (worker)")
        // A child with a label of its own keeps it.
        XCTAssertEqual(state(["python3", "other.py"], parent: parent).label, "other.py")
        // Node workers follow the same rule.
        let server = state(["node", "server.js"], name: "node", path: "/opt/homebrew/bin/node")
        XCTAssertEqual(
            state(
                ["node", "-e", "work()"], name: "node", path: "/opt/homebrew/bin/node",
                parent: server
            ).label,
            "server.js (worker)")
    }

    func testWorkersNeedALabelledParentOfTheSameInterpreter() {
        let inline = ["Python", "-c", "import time; time.sleep(9)"]
        XCTAssertNil(state(inline).label, "no parent found")
        XCTAssertNil(state(inline, parent: state(["python3"])).label, "parent is a bare REPL")
        let shell = state(["/bin/zsh", "deploy.sh"], name: "zsh", path: "/bin/zsh")
        XCTAssertEqual(shell.label, "deploy.sh")
        XCTAssertNil(state(inline, parent: shell).label, "a shell's child is not its worker")
        let node = state(["node", "server.js"], name: "node", path: "/opt/homebrew/bin/node")
        XCTAssertNil(state(inline, parent: node).label, "a different interpreter")
    }

    func testAWorkerWaitsAFewTicksForItsParent() {
        // Parent and worker first seen in the same scan, worker visited first.
        var worker = CommandLabel.State()
        let argv = ["Python", "-c", "pass"]
        func tick(_ parent: CommandLabel.State?) {
            worker.update(
                name: "Python", executablePath: "/usr/bin/python3", uid: getuid(),
                arguments: { argv }, parent: { parent })
        }
        tick(nil)
        XCTAssertNil(worker.label)
        tick(state(["python3", "train.py"]))
        XCTAssertEqual(worker.label, "train.py (worker)")
        // A parent that never turns up is given up on.
        var orphan = CommandLabel.State()
        var asked = 0
        for _ in 0..<6 {
            orphan.update(
                name: "Python", executablePath: "/usr/bin/python3", uid: getuid(),
                arguments: { argv },
                parent: {
                    asked += 1
                    return nil
                })
        }
        XCTAssertEqual(asked, 3)
        XCTAssertNil(orphan.label)
    }

    func testLongParentLabelsStillFitWithTheSuffix() {
        let long = String(repeating: "a", count: 70)
        let worker = CommandLabel.workerLabel(parent: long)
        XCTAssertEqual(worker.count, CommandLabel.maxLength)
        XCTAssertTrue(worker.hasSuffix(" (worker)"))
    }
}
