import CryptoKit
import Foundation

public struct AskModelAsset: Sendable {
    public let name: String
    public let bytes: Int64
    public let sha256: String
    public let url: URL

    public init(name: String, bytes: Int64, sha256: String, url: URL) {
        self.name = name
        self.bytes = bytes
        self.sha256 = sha256
        self.url = url
    }

    public func verify(at url: URL) throws {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
        ])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
            values.fileSize.map(Int64.init) == bytes
        else { throw AskExplanationError.modelNotInstalled }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while try autoreleasepool(invoking: {
            try Task.checkCancellation()
            guard let chunk = try handle.read(upToCount: 1024 * 1024), !chunk.isEmpty else {
                return false
            }
            hasher.update(data: chunk)
            return true
        }) {}
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        guard digest == sha256 else { throw AskExplanationError.modelNotInstalled }
    }
}

public struct AskLocalModelDefinition: Sendable {
    public enum Format: Sendable { case mlx, gguf }

    public let identifier: String
    public let revision: String
    public let directoryName: String
    public let requiredFreeDiskBytes: Int64
    public let assets: [AskModelAsset]
    public var format: Format = .mlx

    public var downloadBytes: Int64 { assets.reduce(0) { $0 + $1.bytes } }

    public func hasCompleteFiles(in directory: URL) -> Bool {
        guard
            let values = try? directory.resourceValues(forKeys: [
                .isDirectoryKey, .isSymbolicLinkKey,
            ]),
            values.isDirectory == true, values.isSymbolicLink != true,
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
            Set(names) == Set(assets.map(\.name))
        else { return false }
        return assets.allSatisfy { asset in
            guard
                let value = try? directory.appendingPathComponent(asset.name).resourceValues(
                    forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            else { return false }
            return value.isRegularFile == true && value.isSymbolicLink != true
                && value.fileSize.map(Int64.init) == asset.bytes
        }
    }

    public func verify(in directory: URL) throws {
        guard hasCompleteFiles(in: directory) else { throw AskExplanationError.modelNotInstalled }
        for asset in assets { try asset.verify(at: directory.appendingPathComponent(asset.name)) }
    }
}

public enum AskQwenModel {
    public static let identifier = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
    public static let revision = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
    public static let directoryName = "qwen3-4b-instruct-2507-4bit"
    public static let requiredFreeDiskBytes: Int64 = 5 * 1024 * 1024 * 1024

    private static func asset(_ name: String, _ bytes: Int64, _ sha256: String) -> AskModelAsset {
        AskModelAsset(
            name: name, bytes: bytes, sha256: sha256,
            url: URL(string: "https://huggingface.co/\(identifier)/resolve/\(revision)/\(name)")!)
    }

    public static let assets: [AskModelAsset] = [
        asset(
            "config.json", 938, "574349e5a343236546fda55e4744a76e181f534182d7dc60ff1bad7e7a502849"),
        asset(
            "generation_config.json", 238,
            "835fffe355c9438e7a25be099b3fccaa98350b83451f9fd2d99512e74f1ade48"),
        asset(
            "tokenizer_config.json", 5440,
            "4397cc477eb6d79715ccd2000accd6b3531928f30029665832fa1b255f24d2b9"),
        asset(
            "chat_template.jinja", 4040,
            "40c21f34cf67d8c760ef72f8ad3ae5afad514299d4b06e91dd9a8d705af7b541"),
        asset(
            "tokenizer.json", 11_422_654,
            "aeb13307a71acd8fe81861d94ad54ab689df773318809eed3cbe794b4492dae4"),
        asset(
            "model.safetensors", 2_263_022_417,
            "2a73c6c248601ab904e035548abd8e6abb65ea27dcb5f342fb0a8910eb44173f"),
        AskModelAsset(
            name: "LICENSE", bytes: 11343,
            sha256: "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
            url: URL(string: "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507/raw/main/LICENSE")!
        ),
    ]

    public static let definition = AskLocalModelDefinition(
        identifier: identifier, revision: revision, directoryName: directoryName,
        requiredFreeDiskBytes: requiredFreeDiskBytes, assets: assets)

    public static var downloadBytes: Int64 { definition.downloadBytes }

    public static func hasCompleteFiles(in directory: URL) -> Bool {
        definition.hasCompleteFiles(in: directory)
    }

    public static func verify(in directory: URL) throws {
        try definition.verify(in: directory)
    }
}

public enum AskLocalModels {
    public static func definition(for backend: AskInferenceBackend) -> AskLocalModelDefinition? {
        switch backend {
        case .apple: return nil
        case .qwen: return AskQwenModel.definition
        case .qwen35: return qwen35
        case .deepAnalyze: return deepAnalyze
        }
    }

    public static let qwen35: AskLocalModelDefinition = {
        let identifier = "mlx-community/Qwen3.5-4B-4bit"
        let revision = "0e7ffd5c629ef7719d4cbc04069232580bfa9d9c"
        func asset(_ name: String, _ bytes: Int64, _ hash: String) -> AskModelAsset {
            AskModelAsset(
                name: name, bytes: bytes, sha256: hash,
                url: URL(
                    string: "https://huggingface.co/\(identifier)/resolve/\(revision)/\(name)")!)
        }
        return AskLocalModelDefinition(
            identifier: identifier, revision: revision, directoryName: "qwen3.5-4b-4bit",
            requiredFreeDiskBytes: 7 * 1024 * 1024 * 1024,
            assets: [
                asset(
                    "config.json", 3366,
                    "f3efc81b2ea8d96a45301037d3ccccbcccdef44a961845c87f286aaddbc6eaaa"),
                asset(
                    "tokenizer_config.json", 1139,
                    "e98f1901ac6f0adff67b1d540bfa0c36ac1a0cf59eb72ed78146ef89aafa1182"),
                asset(
                    "chat_template.jinja", 7756,
                    "a4aee8afcf2e0711942cf848899be66016f8d14a889ff9ede07bca099c28f715"),
                asset(
                    "tokenizer.json", 19_989_343,
                    "87a7830d63fcf43bf241c3c5242e96e62dd3fdc29224ca26fed8ea333db72de4"),
                asset(
                    "model.safetensors", 3_034_300_695,
                    "5fb9acd0246866381cf8c5c354c6db1019f6498eec4ccb4f5edcc71ffeacb2db"),
                asset(
                    "model.safetensors.index.json", 101944,
                    "52e534c41f7b97708329c85f762e5882bf48bd5955a422c6ae74eba321e6048a"),
                AskModelAsset(
                    name: "LICENSE", bytes: 11544,
                    sha256: "bbedc3fda3305820b977265f01b8619d87570a6739de3a5582c3464840f1e57a",
                    url: URL(
                        string:
                            "https://huggingface.co/Qwen/Qwen3.5-4B/resolve/851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a/LICENSE"
                    )!),
            ])
    }()

    public static let deepAnalyze = AskLocalModelDefinition(
        identifier: "mattritchey/DeepAnalyze-8B-Q4_K_M-GGUF",
        revision: "abe1b56f63a98bb86dcb42aa6abfdcc560797a88",
        directoryName: "deepanalyze-8b-q4-k-m", requiredFreeDiskBytes: 11 * 1024 * 1024 * 1024,
        assets: [
            AskModelAsset(
                name: "deepanalyze-8b-q4_k_m.gguf", bytes: 5_027_783_424,
                sha256: "8b00b7c74e008ffb113baa3f3938ce5a77e8a8432978b32fcf1727a95be3497e",
                url: URL(
                    string:
                        "https://huggingface.co/mattritchey/DeepAnalyze-8B-Q4_K_M-GGUF/resolve/abe1b56f63a98bb86dcb42aa6abfdcc560797a88/deepanalyze-8b-q4_k_m.gguf"
                )!),
            AskModelAsset(
                name: "LICENSE", bytes: 1068,
                sha256: "f531202cd3d1e674c5d3cb3a66a00441901044bb27a6b394c88fe22ff84445be",
                url: URL(
                    string:
                        "https://raw.githubusercontent.com/ruc-datalab/DeepAnalyze/007389cb2a51c58e0fb80a3c88243573a84c5365/LICENSE"
                )!),
            AskModelAsset(
                name: "DEEPSEEK-LICENSE", bytes: 1084,
                sha256: "f2c6c602815669d292889e5be8c802f2ed950653b77999b1584e8e6aed25d040",
                url: URL(
                    string:
                        "https://huggingface.co/deepseek-ai/DeepSeek-R1-0528-Qwen3-8B/resolve/6e8885a6ff5c1dc5201574c8fd700323f23c25fa/LICENSE"
                )!),
            AskModelAsset(
                name: "QWEN-LICENSE", bytes: 11343,
                sha256: "832dd9e00a68dd83b3c3fb9f5588dad7dcf337a0db50f7d9483f310cd292e92e",
                url: URL(
                    string:
                        "https://huggingface.co/Qwen/Qwen3-8B/resolve/b968826d9c46dd6066d109eabc6255188de91218/LICENSE"
                )!),
            AskModelAsset(
                name: "MODEL-CARD.md", bytes: 2969,
                sha256: "3b4b52828fa7b525f73e5151b6037dc87cd222633947a5c61c108dfc8cad6964",
                url: URL(
                    string:
                        "https://huggingface.co/RUC-DataLab/DeepAnalyze-8B/resolve/214c302cebc61ed92f9c856a3dd47a7fdc588d5f/README.md"
                )!),
        ], format: .gguf)
}
