// SPDX-License-Identifier: MIT

import Foundation
import MacPerfMonitorCore
import UniformTypeIdentifiers

/// The content type for the shareable `.mpmtrace` container. Resolved from the
/// file extension so no Info.plist declaration is strictly required, though one
/// is registered so Finder shows a proper type and icon.
enum TraceFileType {
    static let utType =
        UTType(filenameExtension: ProcessTraceCodec.fileExtension, conformingTo: .data) ?? .data
}

/// A decoded trace the Analytics tab is currently displaying, plus the file name
/// it came from (for the viewer's banner).
struct ImportedTrace: Identifiable, Sendable {
    let id = UUID()
    let document: ProcessTraceDocument
    let fileName: String
    let preparation: TraceViewerPreparation
}

struct TracePreparedSeries: Sendable {
    let identity: ProcessIdentity
    let name: String
    let points: [PerfPoint]
}

struct TracePreparedStat: Sendable {
    let identity: ProcessIdentity
    let name: String
    let statistics: SeriesStatistics
}

struct TraceProjectionResult: Sendable {
    let gridSeries: [PerfMetric: [TracePreparedSeries]]
    let focusedSeries: [TracePreparedSeries]
    let focusedStats: [TracePreparedStat]
}

/// Serial, cancellable derivation for imported-trace interactions. New requests
/// invalidate the current generation; long point scans notice every 1,024 rows
/// and stop, so zoom and process-selection changes never queue a backlog.
final class TraceProjectionWorker: @unchecked Sendable {
    private let queue = DispatchQueue(
        label: "com.macperformancemonitor.trace-projection",
        qos: .userInitiated)
    private let lock = NSLock()
    private var generation = 0

    func cancel() {
        lock.lock()
        generation &+= 1
        lock.unlock()
    }

    func submit(
        document: ProcessTraceDocument,
        activeIdentities: [ProcessIdentity],
        domain: ClosedRange<Date>,
        focusedMetric: PerfMetric?,
        showStats: Bool,
        gridPointBudget: Int,
        focusedPointBudget: Int,
        completion: @escaping (TraceProjectionResult) -> Void
    ) {
        lock.lock()
        generation &+= 1
        let token = generation
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            let cancelled = { !self.isCurrent(token) }
            let seriesByIdentity = Dictionary(
                uniqueKeysWithValues: document.processes.map { ($0.identity, $0) })

            var grid: [PerfMetric: [TracePreparedSeries]] = Dictionary(
                uniqueKeysWithValues: PerfMetric.allCases.map { ($0, []) })
            var focused: [TracePreparedSeries] = []
            var stats: [TracePreparedStat] = []
            let visibleSpan = domain.upperBound.timeIntervalSince(domain.lowerBound)

            if let focusedMetric {
                let width = visibleSpan / Double(focusedPointBudget)
                for identity in activeIdentities {
                    guard !cancelled(), let series = seriesByIdentity[identity] else { return }
                    let slice = PerfSeriesBuilder.traceSlice(series.points, domain: domain)
                    guard
                        let points = PerfSeriesBuilder.traceDownsampled(
                            slice, metric: focusedMetric, bucketWidth: width,
                            isCancelled: cancelled)
                    else { return }
                    if !points.isEmpty {
                        focused.append(
                            TracePreparedSeries(
                                identity: identity, name: series.name, points: points))
                    }
                    if showStats,
                        let summary = PerfSeriesBuilder.traceStatistics(
                            slice, metric: focusedMetric, domain: domain,
                            isCancelled: cancelled)
                    {
                        stats.append(
                            TracePreparedStat(
                                identity: identity, name: series.name, statistics: summary))
                    }
                }
            } else {
                let width = visibleSpan / Double(gridPointBudget)
                for identity in activeIdentities {
                    guard !cancelled(), let series = seriesByIdentity[identity] else { return }
                    let slice = PerfSeriesBuilder.traceSlice(series.points, domain: domain)
                    guard
                        let projected = PerfSeriesBuilder.traceDownsampled(
                            slice, bucketWidth: width, isCancelled: cancelled)
                    else { return }
                    for metric in PerfMetric.allCases {
                        guard let points = projected[metric], !points.isEmpty else { continue }
                        grid[metric, default: []].append(
                            TracePreparedSeries(
                                identity: identity, name: series.name, points: points))
                    }
                }
            }

            guard self.isCurrent(token) else { return }
            let result = TraceProjectionResult(
                gridSeries: grid, focusedSeries: focused, focusedStats: stats)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(token) else { return }
                completion(result)
            }
        }
    }

    private func isCurrent(_ token: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == token
    }
}

struct TraceViewerPreparation: Sendable {
    static let maximumActiveProcesses = 8
    static let maximumGridPoints = 300

    let fullDomain: ClosedRange<Date>
    let hasNetworkData: Bool
    let peakFootprints: [ProcessIdentity: UInt64]
    let activeIdentities: [ProcessIdentity]
    let gridSeries: [PerfMetric: [TracePreparedSeries]]

    init(document: ProcessTraceDocument) {
        var minimum: Double?
        var maximum: Double?
        var hasNetworkData = false
        var peakFootprints: [ProcessIdentity: UInt64] = [:]

        for series in document.processes {
            if let first = series.points.first?.t, let last = series.points.last?.t {
                minimum = min(minimum ?? first, first)
                maximum = max(maximum ?? last, last)
            }
            var peak: UInt64 = 0
            for point in series.points {
                peak = max(peak, point.footprint)
                hasNetworkData = hasNetworkData || point.net > 0
            }
            peakFootprints[series.identity] = peak
        }

        let declared = document.timeRange
        if let minimum, let maximum, maximum > minimum {
            fullDomain =
                Date(timeIntervalSince1970: minimum)...Date(timeIntervalSince1970: maximum)
        } else if declared.lowerBound == declared.upperBound {
            fullDomain = declared.lowerBound...declared.lowerBound.addingTimeInterval(1)
        } else {
            fullDomain = declared
        }
        self.hasNetworkData = hasNetworkData
        self.peakFootprints = peakFootprints

        let active = Array(
            document.processes.prefix(Self.maximumActiveProcesses).map(\.identity))
        activeIdentities = active
        let activeSet = Set(active)
        let width =
            fullDomain.upperBound.timeIntervalSince(fullDomain.lowerBound)
            / Double(Self.maximumGridPoints)
        var prepared: [PerfMetric: [TracePreparedSeries]] = Dictionary(
            uniqueKeysWithValues: PerfMetric.allCases.map { ($0, []) })
        for series in document.processes where activeSet.contains(series.identity) {
            let projected = PerfSeriesBuilder.traceDownsampled(
                series.points[...], bucketWidth: width)
            for metric in PerfMetric.allCases {
                guard let points = projected[metric], !points.isEmpty else { continue }
                prepared[metric, default: []].append(
                    TracePreparedSeries(
                        identity: series.identity, name: series.name, points: points))
            }
        }
        gridSeries = prepared
    }
}

/// Bounded trace file loading shared by the open panel and Finder routing. File
/// I/O, decompression, JSON decoding, and semantic validation all stay off the
/// main thread; only the final state handoff returns to it.
enum TraceFileLoader {
    private static let queue = DispatchQueue(
        label: "com.macperformancemonitor.trace-import",
        qos: .userInitiated)

    static func load(
        _ url: URL,
        completion: @escaping (Result<ImportedTrace, Error>) -> Void
    ) {
        let fileName = url.lastPathComponent
        queue.async {
            let result = Result {
                let document = try ProcessTraceCodec.decode(contentsOf: url)
                return ImportedTrace(
                    document: document,
                    fileName: fileName,
                    preparation: TraceViewerPreparation(document: document))
            }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

enum TraceExportError: LocalizedError {
    case noHistory

    var errorDescription: String? {
        switch self {
        case .noHistory:
            return
                "There is no recorded history for the selected processes in this window. Try a longer timeframe or a coarser resolution."
        }
    }
}

final class TraceExportOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func commitIfActive(_ commit: () throws -> Void) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        try commit()
        return true
    }
}

/// CPU and allocation-heavy export work. History loading remains on the data
/// layer's reader queue; conversion, validation, compression, and the atomic
/// write run here so neither queue blocks the app's UI or interactive reads.
enum TraceFileExporter {
    private static let queue = DispatchQueue(
        label: "com.macperformancemonitor.trace-export",
        qos: .userInitiated)

    static func write(
        histories: [ProcessIdentity: [ProcessHistoryPoint]],
        orderedIdentities: [ProcessIdentity],
        samples: [ProcessIdentity: ProcessSample],
        window: ClosedRange<Date>,
        resolutionSeconds: Double,
        exportedAt: Date,
        destination: URL,
        operation: TraceExportOperation,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        queue.async {
            guard !operation.isCancelled else { return }
            let result = Result<Void, Error> {
                var series: [ProcessTraceSeries] = []
                series.reserveCapacity(orderedIdentities.count)
                for identity in orderedIdentities {
                    guard !operation.isCancelled else { return }
                    guard let sample = samples[identity],
                        let points = histories[identity], !points.isEmpty
                    else { continue }
                    series.append(TraceExportBuilder.makeSeries(from: sample, points: points))
                }

                guard !series.isEmpty else { throw TraceExportError.noHistory }
                let document = TraceExportBuilder.makeDocument(
                    window: window,
                    resolutionSeconds: resolutionSeconds,
                    processes: series,
                    now: exportedAt)
                guard !operation.isCancelled else { return }
                let data = try ProcessTraceCodec.encode(document)
                guard !operation.isCancelled else { return }
                let fileManager = FileManager.default
                let temporary = destination.deletingLastPathComponent().appendingPathComponent(
                    ".\(destination.lastPathComponent).\(UUID().uuidString).tmp")
                defer { try? fileManager.removeItem(at: temporary) }
                try data.write(to: temporary)
                guard !operation.isCancelled else { return }
                _ = try operation.commitIfActive {
                    if fileManager.fileExists(atPath: destination.path) {
                        _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
                    } else {
                        try fileManager.moveItem(at: temporary, to: destination)
                    }
                }
            }
            guard !operation.isCancelled else { return }
            DispatchQueue.main.async { completion(result) }
        }
    }
}

/// The window of history an export covers.
enum ExportTimeframe: String, CaseIterable, Identifiable {
    case currentView
    case lastHour
    case last6Hours
    case last24Hours
    case last7Days

    var id: String { rawValue }

    var label: String {
        switch self {
        case .currentView: return "Current view"
        case .lastHour: return "Last 1 hr"
        case .last6Hours: return "Last 6 hr"
        case .last24Hours: return "Last 24 hr"
        case .last7Days: return "Last 7 day"
        }
    }

    /// The absolute window this timeframe maps to. `currentView` echoes the
    /// window the chart is showing; the rest are anchored to `now`.
    func window(now: Date, currentView: ClosedRange<Date>) -> ClosedRange<Date> {
        switch self {
        case .currentView: return currentView
        case .lastHour: return now.addingTimeInterval(-3600)...now
        case .last6Hours: return now.addingTimeInterval(-6 * 3600)...now
        case .last24Hours: return now.addingTimeInterval(-24 * 3600)...now
        case .last7Days: return now.addingTimeInterval(-7 * 86_400)...now
        }
    }
}

/// The stored resolution an export is sampled at. Higher resolution means more
/// points and a larger file; availability is bounded by what retention still
/// holds for the chosen window.
enum ExportResolution: String, CaseIterable, Identifiable {
    case full
    case standard
    case coarse

    var id: String { rawValue }

    var label: String {
        switch self {
        case .full: return "Full"
        case .standard: return "Standard"
        case .coarse: return "Coarse"
        }
    }

    /// The stored tier this resolution reads from.
    var granularity: HistoryWindow.Granularity {
        switch self {
        case .full: return .raw
        case .standard: return .minute
        case .coarse: return .hour
        }
    }

    /// Nominal spacing between points, in seconds, honouring the user's
    /// configured sampling intervals for the finer tiers.
    var nominalSeconds: Double {
        switch self {
        case .full: return SamplerModel.configuredHighResInterval()
        case .standard: return SamplerModel.configuredStandardResInterval()
        case .coarse: return 3600
        }
    }

    /// A short "~2s raw" style descriptor for the picker.
    var detail: String {
        switch self {
        case .full:
            return "~\(Int(SamplerModel.configuredHighResInterval().rounded()))s raw samples"
        case .standard:
            let s = Int(SamplerModel.configuredStandardResInterval().rounded())
            return s < 60 ? "\(s)s buckets" : "\(s / 60)-min buckets"
        case .coarse:
            return "1-hr buckets"
        }
    }
}

/// Minimal, non-identifying provenance for an exported trace, and the assembly
/// of the document itself. Kept out of the views so the mapping from live
/// samples and stored history to the shareable `ProcessTraceDocument` lives in
/// one place.
enum TraceExportBuilder {
    /// "Mac Performance Monitor 1.2.0 (127)".
    static func generator() -> String {
        "\(AppInfo.displayName) \(AppInfo.version) (\(AppInfo.build))"
    }

    /// OS + hardware model, with nothing that identifies a person or account.
    static func currentSource() -> ProcessTraceDocument.Source {
        ProcessTraceDocument.Source(
            osVersion: osVersionString(),
            machineModel: sysctlString("hw.model"))
    }

    static func osVersionString() -> String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var s = "macOS \(v.majorVersion).\(v.minorVersion)"
        if v.patchVersion > 0 { s += ".\(v.patchVersion)" }
        return s
    }

    /// One process's exported series, taking metadata from its live sample and
    /// points from the loaded history.
    static func makeSeries(
        from sample: ProcessSample, points: [ProcessHistoryPoint]
    ) -> ProcessTraceSeries {
        ProcessTraceSeries(
            pid: sample.pid,
            startTime: sample.startTime,
            name: sample.displayName,
            executablePath: sample.executablePath,
            bundleID: sample.bundleID,
            teamID: sample.teamID,
            architecture: sample.architecture == .unknown ? nil : sample.architecture.label,
            isTranslated: sample.isTranslated,
            points: points.map(ProcessTracePoint.init)
        )
    }

    /// Assemble the full document from the covered window, resolution, and the
    /// per-process series.
    static func makeDocument(
        window: ClosedRange<Date>,
        resolutionSeconds: Double,
        processes: [ProcessTraceSeries],
        now: Date = Date()
    ) -> ProcessTraceDocument {
        ProcessTraceDocument(
            generator: generator(),
            exportedAt: now,
            source: currentSource(),
            startDate: window.lowerBound,
            endDate: window.upperBound,
            resolutionSeconds: resolutionSeconds,
            processes: processes)
    }

    /// Read a null-terminated `sysctl` string value, or nil when unavailable.
    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer)
        return value.isEmpty ? nil : value
    }
}
