import XCTest

@testable import MacPerfMonitorCore

final class GPUAttributionTests: XCTestCase {
    // MARK: - GPUProcessReader parsing

    func testCreatorStringYieldsPID() {
        XCTAssertEqual(GPUProcessReader.pid(fromCreator: "pid 413, WindowServer"), 413)
        XCTAssertEqual(GPUProcessReader.pid(fromCreator: "pid 96180, Screen Sharing"), 96180)
        XCTAssertNil(GPUProcessReader.pid(fromCreator: "WindowServer"))
        XCTAssertNil(GPUProcessReader.pid(fromCreator: "pid , x"))
    }

    func testAppUsageSumsContextsAndKeepsNewestSubmission() {
        let usage = GPUProcessReader.usage(
            pid: 413,
            appUsage: [
                [
                    "API": "Metal", "accumulatedGPUTime": 20_828_301_005_375,
                    "lastSubmittedTime": 170_032_797_844_625,
                ],
                [
                    "API": "Metal", "accumulatedGPUTime": 103_470_833,
                    "lastSubmittedTime": 169_600_337_130_166,
                ],
                ["API": "Metal", "accumulatedGPUTime": 0, "lastSubmittedTime": 0],
            ])
        XCTAssertEqual(usage.pid, 413)
        XCTAssertEqual(usage.gpuTimeNanos, 20_828_301_005_375 + 103_470_833)
        XCTAssertEqual(usage.lastSubmittedNanos, 170_032_797_844_625)
        XCTAssertEqual(usage.contextCount, 3)
    }

    func testEmptyAppUsageIsOneIdleContext() {
        let usage = GPUProcessReader.usage(pid: 7, appUsage: [])
        XCTAssertEqual(usage.gpuTimeNanos, 0)
        XCTAssertEqual(usage.lastSubmittedNanos, 0)
        XCTAssertEqual(usage.contextCount, 1)
    }

    func testMachNanosConvertToWallClock() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let machNow: UInt64 = 170_036_000_000_000
        // Ten seconds before "now".
        let date = GPUProcessReader.date(
            fromMachNanos: machNow - 10_000_000_000, now: now, machNow: machNow)
        XCTAssertEqual(date?.timeIntervalSince1970 ?? 0, 1_999_999_990, accuracy: 0.001)
        XCTAssertNil(GPUProcessReader.date(fromMachNanos: 0, now: now, machNow: machNow))
        XCTAssertNil(GPUProcessReader.date(fromMachNanos: machNow + 1, now: now, machNow: machNow))
    }

    // MARK: - Workload classification

    func testKnownAIRuntimesAreRecognised() {
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "ollama", bundleID: nil, executablePath: "/usr/local/bin/ollama"),
            "Ollama")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "ollama runner", bundleID: nil,
                executablePath: "/Applications/Ollama.app/Contents/Resources/ollama"),
            "Ollama")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(name: "llama-server", bundleID: nil, executablePath: nil),
            "llama.cpp")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "LM Studio Helper", bundleID: "ai.elementlabs.lmstudio.helper",
                executablePath: nil),
            "LM Studio")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(name: "aned", bundleID: nil, executablePath: "/usr/libexec/aned"),
            "Core ML")
        XCTAssertEqual(
            GPUWorkload.category(name: "mediaanalysisd", bundleID: nil, executablePath: nil), .aiML)
    }

    func testInterpretersNeedTheCommandLine() {
        XCTAssertNil(
            GPUWorkload.aiRuntime(
                name: "python3.12", bundleID: nil, executablePath: "/usr/bin/python3"))
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "python3.12", bundleID: nil, executablePath: "/opt/homebrew/bin/python3",
                arguments: [
                    "python3", "-m", "mlx_lm.server", "--model", "mlx-community/Llama-3.2-3B",
                ]),
            "MLX")
        XCTAssertEqual(
            GPUWorkload.aiRuntime(
                name: "python", bundleID: nil, executablePath: nil,
                arguments: ["python", "train.py", "--backend", "torch"]),
            "PyTorch")
        XCTAssertEqual(
            GPUWorkload.category(
                name: "python", bundleID: nil, executablePath: nil,
                arguments: ["python", "serve.py"]),
            .other)
    }

    func testDisplayAndMediaCategories() {
        XCTAssertEqual(
            GPUWorkload.category(name: "WindowServer", bundleID: nil, executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(
                name: "Google Chrome Helper (GPU)", bundleID: "com.google.Chrome.helper",
                executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(
                name: "com.apple.WebKit.GPU", bundleID: "com.apple.WebKit.GPU", executablePath: nil),
            .displayUI)
        XCTAssertEqual(
            GPUWorkload.category(name: "VTDecoderXPCService", bundleID: nil, executablePath: nil),
            .media)
        XCTAssertEqual(
            GPUWorkload.category(name: "Screen Sharing", bundleID: nil, executablePath: nil), .media
        )
        XCTAssertEqual(
            GPUWorkload.category(
                name: "Blender", bundleID: "org.blenderfoundation.blender", executablePath: nil),
            .other)
    }

    func testModelHintFromArguments() {
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "llama-server", "-m", "/models/Qwen2.5-7B-Q4_K_M.gguf",
            ]),
            "Qwen2.5-7B-Q4_K_M.gguf")
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "python", "-m", "mlx_lm.server", "--model=mlx-community/gemma-2-9b",
            ]),
            "gemma-2-9b")
        XCTAssertEqual(
            GPUWorkload.modelHint(arguments: [
                "python", "-m", "mlx_lm.server", "--model", "mistral",
            ]),
            "mistral")
        XCTAssertNil(GPUWorkload.modelHint(arguments: ["ollama", "serve"]))
        XCTAssertNil(GPUWorkload.modelHint(arguments: nil))
    }
}
