import Foundation

public enum AskTopic: String, CaseIterable, Sendable, Codable, Identifiable {
    case overview, cpu, memory, disk, network

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .overview: return t("System overview")
        case .cpu: return t("CPU")
        case .memory: return t("Memory")
        case .disk: return t("Disk space")
        case .network: return t("Network")
        }
    }

    public var question: String {
        switch self {
        case .overview: return t("Why is my Mac slow?")
        case .cpu: return t("What is using my CPU?")
        case .memory: return t("What is taking my RAM?")
        case .disk: return t("Why is my disk full?")
        case .network: return t("Why is my network slow?")
        }
    }
}

public struct AskEvidence: Identifiable, Sendable, Equatable {
    public var id: String
    public var title: String
    public var value: String
    public var detail: String
    public var processIdentity: ProcessIdentity?

    public init(
        id: String, title: String, value: String, detail: String,
        processIdentity: ProcessIdentity? = nil
    ) {
        self.id = id
        self.title = title
        self.value = value
        self.detail = detail
        self.processIdentity = processIdentity
    }
}

public struct AskReport: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let topic: AskTopic
    public let capturedAt: Date
    public let sampledAt: Date?
    public var summary: String
    public var evidence: [AskEvidence]
    public var limits: [String]
    public var resourceConstrained = false

    public static func make(
        topic: AskTopic, snapshot: Sampler.Snapshot?, now: Date = Date(),
        freshness: TimeInterval = 10, networkTrackingEnabled: Bool = false
    ) -> AskReport {
        var report = AskReport(
            id: UUID(), topic: topic, capturedAt: now, sampledAt: snapshot?.system.timestamp,
            summary: t("Waiting for a current reading."), evidence: [], limits: [])
        guard let snapshot else {
            report.limits = [
                t("No current sample is available. Try again after monitoring starts.")
            ]
            return report
        }
        let system = snapshot.system
        let age = now.timeIntervalSince(system.timestamp)
        guard age >= -1, age <= max(1, freshness) else {
            report.summary = t("The last reading is too old to describe your Mac now.")
            report.limits = [t("Refresh the report to collect current evidence.")]
            return report
        }
        report.summary = t(
            "These readings show current activity, not a confirmed cause of a slowdown.")
        report.limits = [t("Preview reports cover current readings, not earlier events.")]
        report.resourceConstrained =
            system.pressureSampleValid != true || system.pressureLevel == .critical
            || system.thermalPressure?.isThrottling == true

        func add(_ id: String, _ title: String, _ value: String, _ detail: String) {
            report.evidence.append(
                AskEvidence(id: id, title: title, value: value, detail: detail))
        }

        if topic == .overview || topic == .cpu {
            if system.cpuLoad.isFinite, (0...1).contains(system.cpuLoad) {
                add(
                    "cpu", t("Whole-machine CPU"), percent(system.cpuLoad * 100),
                    t(
                        "Whole-machine CPU uses a 0 to 100 percent scale. A single reading does not show sustained load."
                    ))
            }
            if let thermal = system.thermalPressure {
                add(
                    "thermal", t("Thermal pressure"), thermal.label,
                    t(
                        "macOS thermal pressure. Serious or critical pressure can reduce performance."
                    ))
                if thermal.isThrottling {
                    report.summary = t(
                        "macOS is reporting thermal pressure that can reduce performance. Compare responsiveness when the current workload finishes and the Mac cools down."
                    )
                }
            }
        }
        if topic == .overview || topic == .memory {
            if system.pressureSampleValid == true {
                add(
                    "pressure", t("Memory pressure"), pressureName(system.pressureLevel),
                    t(
                        "Memory pressure is more useful than used RAM alone when checking for memory strain."
                    ))
                if system.pressureLevel != .normal {
                    report.summary = t(
                        "macOS is reporting memory strain. Check which apps use the most memory and whether responsiveness improves when pressure falls."
                    )
                }
            } else {
                report.limits.append(t("A valid memory pressure reading is not available."))
            }
            if system.swapSampleValid == true {
                add(
                    "swap", t("Swap used"), bytes(system.swapUsed),
                    t("Existing swap alone does not prove that your Mac is short of memory now."))
            }
            for (id, title, reading) in [
                ("swap-in", t("Swap read rate"), system.swapInBytesPerSecond),
                ("swap-out", t("Swap write rate"), system.swapOutBytesPerSecond),
            ] {
                if let reading, reading.isFinite, reading >= 0 {
                    add(
                        id, title, rate(reading),
                        t(
                            "Current swap traffic. Interpret it alongside memory pressure, not stored swap alone."
                        ))
                }
            }
        }
        if topic == .overview || topic == .disk {
            if let total = system.bootVolumeTotalBytes, total > 0,
                let free = system.bootVolumeFreeBytes, free <= total
            {
                add(
                    "disk-space", t("Startup disk free space"), bytes(free),
                    t(
                        "Capacity refreshes at most once a minute. APFS volumes can share the same free space."
                    ))
                add(
                    "disk-free-percent", t("Startup disk free percentage"),
                    percent(Double(free) / Double(total) * 100),
                    t(
                        "Free space as a share of reported capacity. Low space is a storage concern, not evidence of slow disk I/O."
                    ))
            } else {
                report.limits.append(t("Startup disk capacity is not available."))
            }
            if let busy = system.diskUtilizationPercent, busy.isFinite, (0...100).contains(busy) {
                add(
                    "disk-busy", t("Busiest disk activity"), percent(busy),
                    t(
                        "Busy share of the most active physical disk. It may be an external disk, and this does not identify the app responsible."
                    ))
            }
            for (id, title, latency) in [
                ("disk-read-latency", t("Disk read service time"), system.diskReadLatencyMs),
                ("disk-write-latency", t("Disk write service time"), system.diskWriteLatencyMs),
            ] {
                if let latency, latency.isFinite, latency >= 0 {
                    add(
                        id, title, latency.formatted(.number.precision(.fractionLength(1))) + " ms",
                        t(
                            "Average device service time across measured disks, not an app's wait time. Compare it during and after the symptom."
                        ))
                }
            }
            if system.diskUtilizationPercent == nil && system.diskReadLatencyMs == nil
                && system.diskWriteLatencyMs == nil
            {
                report.limits.append(
                    t(
                        "Disk busy time and latency are unavailable. Free space alone cannot establish a disk bottleneck."
                    ))
            }
            if topic == .disk {
                report.summary = t(
                    "Disk capacity shows how much space remains. A Disk Map scan shows where files use it."
                )
                report.limits.append(
                    t("Open Disk Map to review a scan. This report does not scan or delete files."))
            }
        }
        if topic == .overview || topic == .network {
            if snapshot.network != nil,
                system.networkInBytesPerSec.isFinite, system.networkInBytesPerSec >= 0,
                system.networkOutBytesPerSec.isFinite, system.networkOutBytesPerSec >= 0
            {
                add(
                    "network-in", t("Download traffic"), rate(system.networkInBytesPerSec),
                    t("Traffic is current use, not the maximum speed of your connection."))
                add(
                    "network-out", t("Upload traffic"), rate(system.networkOutBytesPerSec),
                    t("Low traffic alone does not show that a network is slow."))
            } else {
                report.limits.append(t("Network traffic readings are not available."))
            }
            if !networkTrackingEnabled {
                report.limits.append(
                    t("Per-app network tracking is off, so app traffic is unknown."))
            }
            if topic == .network {
                report.summary = t(
                    "Traffic readings alone cannot diagnose a slow connection. No active network test was run."
                )
            }
        }

        let readable = snapshot.processes.filter {
            let processAge = now.timeIntervalSince($0.timestamp)
            return processAge >= -1 && processAge <= max(1, freshness)
        }
        let ranked: [ProcessSample]
        switch topic {
        case .overview, .cpu:
            ranked = readable.filter { $0.cpuPercent.isFinite && $0.cpuPercent > 0 }
                .sorted {
                    $0.cpuPercent == $1.cpuPercent ? $0.pid < $1.pid : $0.cpuPercent > $1.cpuPercent
                }
        case .memory:
            ranked = readable.filter { $0.footprintReadable }
                .sorted {
                    $0.physFootprint == $1.physFootprint
                        ? $0.pid < $1.pid : $0.physFootprint > $1.physFootprint
                }
        case .network where networkTrackingEnabled:
            ranked = readable.filter { $0.networkBytesPerSec.isFinite && $0.networkBytesPerSec > 0 }
                .sorted {
                    $0.networkBytesPerSec == $1.networkBytesPerSec
                        ? $0.pid < $1.pid : $0.networkBytesPerSec > $1.networkBytesPerSec
                }
        case .disk:
            ranked = readable.filter {
                $0.diskReadBytesPerSec >= 0 && $0.diskWriteBytesPerSec >= 0
                    && ($0.diskReadBytesPerSec + $0.diskWriteBytesPerSec).isFinite
                    && $0.diskReadBytesPerSec + $0.diskWriteBytesPerSec > 0
            }.sorted {
                let left = $0.diskReadBytesPerSec + $0.diskWriteBytesPerSec
                let right = $1.diskReadBytesPerSec + $1.diskWriteBytesPerSec
                return left == right ? $0.pid < $1.pid : left > right
            }
        default:
            ranked = []
        }
        for (index, process) in ranked.prefix(5).enumerated() {
            let value: String
            let detail: String
            switch topic {
            case .memory:
                value = bytes(process.physFootprint)
                detail = t("Physical footprint. Large memory use alone is not a memory leak.")
            case .network:
                value = rate(process.networkBytesPerSec)
                detail = t("Combined upload and download. Only readable processes are included.")
            case .disk:
                value = rate(process.diskReadBytesPerSec + process.diskWriteBytesPerSec)
                detail = t(
                    "Process disk reads and writes. This may not match physical disk activity because of caching and shared work."
                )
            default:
                value = percent(process.cpuPercent)
                detail = t(
                    "CPU as a share of one core, so a process can exceed 100 percent. This is not proof of a fault."
                )
            }
            report.evidence.append(
                AskEvidence(
                    id: "process-\(index)", title: process.displayName, value: value,
                    detail: detail, processIdentity: process.id))
        }
        if let first = ranked.first {
            if topic == .cpu {
                report.summary = t(
                    "%@ has the highest current CPU use among readable processes.",
                    first.displayName)
            } else if topic == .memory {
                report.summary = t(
                    "%@ has the largest current physical footprint among readable processes.",
                    first.displayName)
            }
        }
        if topic != .disk || !ranked.isEmpty {
            if readable.count < snapshot.processes.count {
                report.limits.append(t("Some process readings are stale and are not included."))
            }
            if snapshot.unreadableProcessCount > 0
                || readable.contains(where: { !$0.footprintReadable })
            {
                report.limits.append(
                    t("Some processes could not be read. Rankings may be incomplete."))
            }
        }
        return report
    }

    public mutating func includeDiskMap(_ snapshot: DiskMapSnapshot, analysis: DiskMapAnalysis) {
        guard topic == .disk, snapshot.scope == .startupDisk, !snapshot.partial,
            snapshot.revision == analysis.revision
        else { return }
        let scanDate = snapshot.scannedAt.formatted(date: .abbreviated, time: .shortened)
        for item in analysis.kinds.sorted(by: { $0.bytes > $1.bytes }).prefix(5) {
            evidence.append(
                AskEvidence(
                    id: "scan-\(item.kind.rawValue)", title: t(item.kind.label),
                    value: Self.bytes(item.bytes),
                    detail: t(
                        "Startup-disk scan from %@. Scanned categories are not a measure of space safe to delete.",
                        scanDate)))
        }
        limits.append(
            t(
                "The scan does not account for %@ of used space.",
                Self.bytes(snapshot.reconciliation.unaccountedBytes)))
        if snapshot.reconciliation.counts.unlistedDirectories > 0 {
            limits.append(t("Some folders were not readable during the scan."))
        }
        if snapshot.reconciliation.sharedBytes > 0 || snapshot.reconciliation.overshootBytes > 0 {
            limits.append(t("Shared APFS blocks can make scanned sizes exceed physical usage."))
        }
        if snapshot.reconciliation.volumeChangedDuringScan {
            limits.append(t("Disk usage changed while the scan was running."))
        }
    }

    public mutating func includeRecentHistory(_ points: [SystemHistoryPoint]) {
        let recent = points.filter {
            $0.date >= capturedAt.addingTimeInterval(-300) && $0.date <= capturedAt
                && $0.bucketDuration == 0
        }.sorted { $0.date < $1.date }
        guard let first = recent.first, let last = recent.last, recent.count >= 3,
            last.date.timeIntervalSince(first.date) >= 60,
            capturedAt.timeIntervalSince(last.date) <= 15,
            zip(recent, recent.dropFirst()).allSatisfy({
                let interval = $1.date.timeIntervalSince($0.date)
                return interval > 0 && interval <= 30
            })
        else {
            limits.append(t("There is not enough recent continuous history to establish a trend."))
            return
        }
        let span = last.date.timeIntervalSince(first.date)
        let window = t(
            "Recent observed interval: %@ to %@.",
            first.date.formatted(date: .omitted, time: .standard),
            last.date.formatted(date: .omitted, time: .standard))
        if topic == .cpu || topic == .overview {
            if recent.allSatisfy({ $0.cpuLoad.isFinite && (0...1).contains($0.cpuLoad) }) {
                let weighted =
                    zip(recent, recent.dropFirst()).reduce(0.0) { total, pair in
                        total + pair.1.cpuLoad * pair.1.date.timeIntervalSince(pair.0.date)
                    } / span
                evidence.insert(
                    AskEvidence(
                        id: "cpu-trend", title: t("Recent mean CPU"),
                        value: Self.percent(weighted * 100),
                        detail: window + " "
                            + t(
                                "Time-weighted whole-machine CPU. This describes the observed interval, not a cause by itself."
                            )), at: 0)
            }
        }
        if topic == .memory || topic == .overview {
            let difference = Int64(clamping: last.compressed) - Int64(clamping: first.compressed)
            let value =
                (difference > 0 ? "+" : difference < 0 ? "-" : "")
                + Self.bytes(difference.magnitude)
            evidence.insert(
                AskEvidence(
                    id: "compression-trend", title: t("Change in compressed memory"), value: value,
                    detail: window + " "
                        + t(
                            "A change in compression is not proof of a memory leak or active paging."
                        )), at: 0)
        }
    }

    private static func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1))) + "%"
    }

    private static func bytes(_ value: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(clamping: value), countStyle: .memory)
    }

    private static func rate(_ value: Double) -> String {
        let bounded = min(max(0, value), Double(Int64.max / 2))
        return ByteCountFormatter.string(fromByteCount: Int64(bounded), countStyle: .memory) + "/s"
    }

    private static func pressureName(_ pressure: PressureLevel) -> String {
        switch pressure {
        case .normal: return t("Normal")
        case .warning: return t("Warning")
        case .critical: return t("Critical")
        }
    }
}

public struct AskContextBudget: Sendable, Equatable {
    public static let maximumContext = 4096
    public static let answerReserve = 800
    public static let safetyReserve = 496

    public let contextSize: Int

    public init(reportedSize: Int, maximumContext: Int = Self.maximumContext) {
        contextSize = max(0, min(maximumContext, reportedSize))
    }

    public var inputLimit: Int {
        max(0, contextSize - Self.answerReserve - Self.safetyReserve)
    }

    public func admits(inputTokens: Int) -> Bool {
        contextSize > Self.answerReserve + Self.safetyReserve
            && inputTokens >= 0 && inputTokens <= inputLimit
    }
}

public enum AskLocalModelPolicy {
    public static let minimumPhysicalMemoryBytes: UInt64 = 16 * 1024 * 1024 * 1024
    public static let maximumContextTokens = 8192

    public static func isEligible(physicalMemoryBytes: UInt64, isAppleSilicon: Bool) -> Bool {
        isAppleSilicon && physicalMemoryBytes >= minimumPhysicalMemoryBytes
    }

    public static func permitsInference(
        physicalMemoryBytes: UInt64, isAppleSilicon: Bool,
        pressure: PressureLevel?, thermalIsConstrained: Bool
    ) -> Bool {
        isEligible(physicalMemoryBytes: physicalMemoryBytes, isAppleSilicon: isAppleSilicon)
            && pressure == .normal && !thermalIsConstrained
    }
}
