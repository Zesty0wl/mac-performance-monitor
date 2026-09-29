import Combine
import Foundation
import MacPerfMonitorCore

@MainActor
final class AskLocalModelStore: ObservableObject {
    static let shared = AskLocalModelStore()
    private static weak var activeStore: AskLocalModelStore?

    @Published private(set) var isInstalled = false
    @Published private(set) var isDownloading = false
    @Published private(set) var progress = 0.0
    @Published private(set) var isVerifying = false
    @Published private(set) var message: String?
    @Published private(set) var isInUse = false

    let directory: URL
    let backend: AskInferenceBackend
    let definition: AskLocalModelDefinition
    private let physicalMemory: () -> UInt64
    private let memoryIsNormal: () -> Bool
    private var downloadTask: Task<Void, Never>?
    private var downloadID = UUID()

    init(
        backend: AskInferenceBackend = .qwen,
        directory: URL? = nil,
        physicalMemory: @escaping () -> UInt64 = { ProcessInfo.processInfo.physicalMemory },
        memoryIsNormal: @escaping () -> Bool = {
            SystemMemoryReader().pressureLevelReading() == .normal
        }
    ) {
        precondition(backend.isLocal)
        self.backend = backend
        let definition = AskLocalModels.definition(for: backend)!
        self.definition = definition
        self.directory =
            directory
            ?? MacPerfMonitorDatabase.defaultURL().deletingLastPathComponent()
            .appendingPathComponent("models", isDirectory: true)
            .appendingPathComponent(definition.directoryName, isDirectory: true)
        self.physicalMemory = physicalMemory
        self.memoryIsNormal = memoryIsNormal
        refresh()
    }

    var isEligible: Bool {
        #if arch(arm64)
        return AskLocalModelPolicy.isEligible(
            physicalMemoryBytes: physicalMemory(), isAppleSilicon: true)
        #else
        return false
        #endif
    }

    var unavailabilityReason: String? {
        if !isEligible {
            return t(
                "%@ needs an Apple silicon Mac with at least 16 GB of RAM.", backend.displayName)
        }
        if isDownloading { return t("The local model is still downloading.") }
        if !isInstalled { return t("Download %@ in preview settings first.", backend.displayName) }
        if !memoryIsNormal() {
            return t(
                "Memory pressure is high or could not be read. %@ needs normal memory pressure to run. Close unused apps, then try again.",
                backend.displayName
            )
        }
        return nil
    }

    func refresh() { isInstalled = definition.hasCompleteFiles(in: directory) }

    func prepareForExplanations(enabled: Bool, backend: AskInferenceBackend) {
        guard enabled, backend == self.backend else {
            cancelDownload()
            return
        }
        download()
    }

    func download() {
        guard isEligible else {
            message = unavailabilityReason
            return
        }
        guard !isDownloading, !isInstalled, !isInUse else { return }
        let identifier = UUID()
        downloadID = identifier
        isDownloading = true
        progress = 0
        message = nil
        let parent = directory.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(
            ".\(backend.rawValue)-\(identifier.uuidString)", isDirectory: true)
        downloadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                try? FileManager.default.removeItem(at: staging)
                if downloadID == identifier {
                    isDownloading = false
                    isVerifying = false
                    downloadTask = nil
                    refresh()
                }
            }
            do {
                try FileManager.default.createDirectory(
                    at: parent, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                let capacity = try parent.resourceValues(forKeys: [
                    .volumeAvailableCapacityForImportantUsageKey
                ])
                guard let free = capacity.volumeAvailableCapacityForImportantUsage,
                    free >= definition.requiredFreeDiskBytes
                else { throw LocalDownloadError.diskSpace(definition.requiredFreeDiskBytes) }
                try FileManager.default.createDirectory(
                    at: staging, withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700])
                var completedBytes: Int64 = 0
                for asset in definition.assets {
                    try Task.checkCancellation()
                    guard isEligible else { throw AskExplanationError.insufficientMemory }
                    let completed = completedBytes
                    let destination = staging.appendingPathComponent(asset.name)
                    let transfer = AskModelTransfer(
                        destination: destination, expectedBytes: asset.bytes
                    ) { [weak self] written in
                        Task { @MainActor in
                            guard let self, self.downloadID == identifier else { return }
                            self.progress =
                                Double(completed + written) / Double(self.definition.downloadBytes)
                        }
                    }
                    _ = try await transfer.download(asset.url)
                    isVerifying = true
                    let verification = Task.detached(priority: .utility) {
                        try asset.verify(at: destination)
                    }
                    try await withTaskCancellationHandler {
                        try await verification.value
                    } onCancel: {
                        verification.cancel()
                    }
                    isVerifying = false
                    completedBytes += asset.bytes
                }
                try Task.checkCancellation()
                guard downloadID == identifier, isEligible else { throw CancellationError() }
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                try FileManager.default.moveItem(at: staging, to: directory)
                progress = 1
            } catch is CancellationError {
            } catch {
                guard downloadID == identifier, !Task.isCancelled else { return }
                message =
                    (error as? LocalDownloadError)?.localizedDescription
                    ?? t("The model download or integrity check failed. Please try again.")
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    func remove() {
        guard !isInUse, !isDownloading else { return }
        do {
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
            refresh()
            message = nil
        } catch {
            message = t("The local model could not be removed.")
        }
    }

    func beginUse() throws {
        guard isEligible else { throw AskExplanationError.insufficientMemory }
        guard !isInUse, Self.activeStore == nil else { throw AskPreviewError.busy }
        refresh()
        guard isInstalled, !isDownloading else { throw AskExplanationError.modelNotInstalled }
        Self.activeStore = self
        isInUse = true
    }

    func endUse() {
        if Self.activeStore === self { Self.activeStore = nil }
        isInUse = false
    }
}

@MainActor
final class AskLocalModelLibrary: ObservableObject {
    static let shared = AskLocalModelLibrary()
    let stores: [AskInferenceBackend: AskLocalModelStore]
    private var subscriptions: [AnyCancellable] = []

    init(stores: [AskInferenceBackend: AskLocalModelStore]? = nil) {
        self.stores =
            stores ?? [
                .qwen: .shared,
                .qwen35: AskLocalModelStore(backend: .qwen35),
                .deepAnalyze: AskLocalModelStore(backend: .deepAnalyze),
            ]
        subscriptions = self.stores.values.map { store in
            store.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    var isInUse: Bool { stores.values.contains(where: \.isInUse) }

    func prepare(enabled: Bool, backend: AskInferenceBackend) {
        for (choice, store) in stores {
            if !enabled || choice != backend { store.cancelDownload() }
        }
        if enabled, backend == .qwen {
            stores[backend]?.prepareForExplanations(enabled: true, backend: backend)
        }
    }
}

private enum LocalDownloadError: LocalizedError {
    case diskSpace(Int64), transfer

    var errorDescription: String? {
        switch self {
        case .diskSpace(let bytes):
            return t(
                "At least %@ of free disk space is needed to download and verify this model.",
                ByteFormat.string(UInt64(bytes)))
        case .transfer: return t("The model download or integrity check failed. Please try again.")
        }
    }
}

private final class AskModelTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let destination: URL
    private let expectedBytes: Int64
    private let progress: @Sendable (Int64) -> Void
    private let lock = NSLock()
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDownloadTask?
    private var session: URLSession?
    private var cancelled = false
    private var lastProgress = 0.0

    init(destination: URL, expectedBytes: Int64, progress: @escaping @Sendable (Int64) -> Void) {
        self.destination = destination
        self.expectedBytes = expectedBytes
        self.progress = progress
    }

    func download(_ url: URL) async throws -> URL {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                guard !cancelled else {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                let config = URLSessionConfiguration.ephemeral
                config.httpCookieStorage = nil
                config.urlCredentialStorage = nil
                config.urlCache = nil
                config.timeoutIntervalForRequest = 60
                config.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
                self.session = session
                let task = session.downloadTask(with: url)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            self.lock.lock()
            self.cancelled = true
            let task = self.task
            self.lock.unlock()
            task?.cancel()
        }
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesWritten <= expectedBytes else {
            finish(.failure(LocalDownloadError.transfer))
            return
        }
        let fraction = Double(totalBytesWritten) / Double(max(1, expectedBytes))
        if fraction - lastProgress >= 0.005 || totalBytesWritten == expectedBytes {
            lastProgress = fraction
            progress(totalBytesWritten)
        }
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let host = request.url?.host ?? ""
        let allowed =
            request.url?.scheme == "https"
            && (host == "huggingface.co" || host.hasSuffix(".huggingface.co")
                || host.hasSuffix(".hf.co"))
        completionHandler(allowed ? request : nil)
    }

    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
                throw LocalDownloadError.transfer
            }
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(destination))
        } catch { finish(.failure(error)) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?)
    {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<URL, Error>) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let session = self.session
        self.session = nil
        self.task = nil
        lock.unlock()
        session?.invalidateAndCancel()
        continuation?.resume(with: result)
    }
}
