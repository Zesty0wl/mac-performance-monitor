import Foundation

/// What kind of work a GPU consumer is doing, from what the process is.
public enum GPUWorkloadCategory: String, Sendable, Codable, CaseIterable, Equatable {
    /// Model inference and training: Ollama, llama.cpp, MLX, LM Studio, PyTorch,
    /// Core ML hosts, Apple Intelligence, the system's media analysis daemons.
    case aiML
    /// Compositing and app UI: WindowServer, the Dock, browser and Electron GPU
    /// helpers, wallpaper.
    case displayUI
    /// Video decode and encode, calls, screen capture and sharing.
    case media
    /// Everything else: games, creative apps, anything with a Metal context.
    case other

    public var label: String {
        switch self {
        case .aiML: return "AI and ML"
        case .displayUI: return "Display and UI"
        case .media: return "Media"
        case .other: return "Other"
        }
    }
}

/// Heuristics that name the GPU consumers a person recognises. Names, bundle
/// identifiers and executable paths are matched case-insensitively; the
/// command line, when available, is the tie-breaker for a bare `python` or
/// `node` that is running a model.
public enum GPUWorkload {
    /// The category for a process, from its identity alone.
    public static func category(
        name: String, bundleID: String?, executablePath: String?, arguments: [String]? = nil
    ) -> GPUWorkloadCategory {
        if aiRuntime(
            name: name, bundleID: bundleID, executablePath: executablePath, arguments: arguments)
            != nil
        {
            return .aiML
        }
        let key = haystack(name: name, bundleID: bundleID, executablePath: executablePath)
        if Self.mediaMarkers.contains(where: { key.contains($0) }) { return .media }
        if Self.displayMarkers.contains(where: { key.contains($0) }) { return .displayUI }
        return .other
    }

    /// The AI runtime a process is, when it is one ("Ollama", "MLX", "Core ML",
    /// ...), else nil. Checked before the other categories because a runtime's
    /// helper process can otherwise look like a generic GPU helper.
    public static func aiRuntime(
        name: String, bundleID: String?, executablePath: String?, arguments: [String]? = nil
    ) -> String? {
        let key = haystack(name: name, bundleID: bundleID, executablePath: executablePath)
        for (marker, runtime) in Self.aiMarkers where key.contains(marker) {
            return runtime
        }
        // A bare interpreter running a model shows its hand on the command line.
        if let arguments, !arguments.isEmpty {
            let line = arguments.joined(separator: " ").lowercased()
            for (marker, runtime) in Self.argumentMarkers where line.contains(marker) {
                return runtime
            }
        }
        return nil
    }

    /// A hint at the model a runtime is serving, from its command line
    /// (`--model llama3.2`, `serve mistral`, a `.gguf` or `.safetensors` path).
    public static func modelHint(arguments: [String]?) -> String? {
        guard let arguments, !arguments.isEmpty else { return nil }
        // Explicit model flags and model files first; `-m` is Python's module
        // flag as often as it is llama.cpp's model flag, so it only counts
        // when what follows looks like a file.
        for (index, argument) in arguments.enumerated() {
            let lower = argument.lowercased()
            if lower == "--model" || lower == "--model-path" || lower == "--model_path",
                index + 1 < arguments.count
            {
                return trimmedModel(arguments[index + 1])
            }
            if lower.hasPrefix("--model=") {
                return trimmedModel(String(argument.dropFirst("--model=".count)))
            }
            if isModelFile(lower) { return trimmedModel(argument) }
        }
        for (index, argument) in arguments.enumerated()
        where argument.lowercased() == "-m" && index + 1 < arguments.count {
            let next = arguments[index + 1]
            if next.contains("/") || isModelFile(next.lowercased()) { return trimmedModel(next) }
        }
        return nil
    }

    private static func isModelFile(_ lower: String) -> Bool {
        lower.hasSuffix(".gguf") || lower.hasSuffix(".safetensors") || lower.hasSuffix(".mlmodelc")
            || lower.hasSuffix(".mlpackage") || lower.hasSuffix(".bin") && lower.contains("model")
    }

    private static func trimmedModel(_ raw: String) -> String {
        let base = (raw as NSString).lastPathComponent
        return base.isEmpty ? raw : base
    }

    private static func haystack(name: String, bundleID: String?, executablePath: String?) -> String
    {
        [name, bundleID ?? "", executablePath ?? ""].joined(separator: " ").lowercased()
    }

    /// Ordered so the most specific marker wins ("ollama runner" before a
    /// generic "python").
    static let aiMarkers: [(String, String)] = [
        ("ollama", "Ollama"),
        ("llama-server", "llama.cpp"),
        ("llama-cli", "llama.cpp"),
        ("llama.cpp", "llama.cpp"),
        ("llamafile", "llamafile"),
        ("lm studio", "LM Studio"),
        ("lmstudio", "LM Studio"),
        ("/lms", "LM Studio"),
        ("mlx_lm", "MLX"),
        ("mlx-lm", "MLX"),
        ("mlx.", "MLX"),
        ("/mlx", "MLX"),
        ("koboldcpp", "KoboldCpp"),
        ("gpt4all", "GPT4All"),
        ("jan.ai", "Jan"),
        ("text-generation-webui", "text-generation-webui"),
        ("vllm", "vLLM"),
        ("comfyui", "ComfyUI"),
        ("draw things", "Draw Things"),
        ("drawthings", "Draw Things"),
        ("diffusionbee", "DiffusionBee"),
        ("stable diffusion", "Stable Diffusion"),
        ("invokeai", "InvokeAI"),
        ("whisper", "Whisper"),
        ("anecompilerservice", "Core ML"),
        ("aned", "Core ML"),
        ("coremlservice", "Core ML"),
        ("com.apple.coreml", "Core ML"),
        ("mediaanalysisd", "Media Analysis"),
        ("photoanalysisd", "Photos Analysis"),
        ("intelligenceplatform", "Apple Intelligence"),
        ("generativeexperiences", "Apple Intelligence"),
        ("generativefunctions", "Apple Intelligence"),
        ("privatecloudcompute", "Apple Intelligence"),
        ("siriinference", "Siri"),
        ("modelmanager", "Apple Intelligence"),
    ]

    /// Command-line markers for interpreters (`python`, `node`) hosting a
    /// model, checked only when the process name gives nothing away.
    static let argumentMarkers: [(String, String)] = [
        ("mlx_lm", "MLX"),
        ("mlx.", "MLX"),
        ("torch", "PyTorch"),
        ("diffusers", "Diffusers"),
        ("transformers", "Transformers"),
        ("llama_cpp", "llama.cpp"),
        ("llama-cpp", "llama.cpp"),
        ("vllm", "vLLM"),
        ("whisper", "Whisper"),
        ("tensorflow", "TensorFlow"),
        ("jax", "JAX"),
        (".gguf", "llama.cpp"),
        ("ollama", "Ollama"),
    ]

    static let mediaMarkers: [String] = [
        "vtdecoderxpcservice", "vtencoderxpcservice", "videotoolbox", "avconferenced",
        "replayd", "screen sharing", "screensharing", "screencaptureui", "quicktime",
        "final cut", "compressor", "imovie", "handbrake", "obs", "zoom.us", "com.microsoft.teams",
        "facetime", "photos.app", "photolibraryd",
    ]

    static let displayMarkers: [String] = [
        "windowserver", "dock", "systemuiserver", "controlcenter", "notificationcenter",
        "wallpaper", "helper (gpu)", "helper (renderer)", "com.apple.webkit.gpu",
        "webkit.gpu", "gpu process", "finder", "spotlight", "loginwindow", "accessibilityui",
        "universalcontrol", "cursoruiviewservice", "texteditingui", "iconservicesagent",
        "quicklookuiservice", "screensaver", "coreautha", "localauthentication",
    ]
}
