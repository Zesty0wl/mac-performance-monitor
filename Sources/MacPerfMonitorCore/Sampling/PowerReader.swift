import Foundation

/// Per-domain power (watts) read from Apple silicon's `IOReport` "Energy Model"
/// counters — the same source `powermetrics` uses. Energy is a monotonic counter
/// per channel; differencing it between ticks and dividing by elapsed time gives
/// power. The GPU and ANE (Neural Engine) draws come from one subscription, so the
/// GPU menubar panel gets both for the cost of a single cheap sample.
///
/// The IOReport functions are Apple SPI (not in the IOKit link stub), so they are
/// resolved at runtime with `dlsym`; if any are missing the reader simply yields
/// nil and the panel hides power/ANE.
struct PowerSample: Sendable, Equatable {
    var gpuWatts: Double?
    var aneWatts: Double?
    var cpuWatts: Double?
    /// From the "GPU Stats" state channels, when subscribed (see `GPUSample`).
    var gpuStates: [GPUPerformanceState]?
    var gpuActiveResidency: Double?
    var gpuThrottled: Bool?
    var gpuPowerCapPercent: Double?
    var gpuBandwidth: GPUBandwidthSample? = nil
    var gpuDiagnostics: GPUDiagnostics? = nil
    var gpuHealth: GPUHealthCounters? = nil
}

final class PowerReader {
    private let io = IOReportBindings()
    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTime: Date?
    private var health: GPUHealthCounters?
    private var healthReadAt: Date?

    /// Power averaged over the interval since the last call. nil on the very first
    /// call (no interval yet) or when IOReport is unavailable.
    func read(now: Date) -> PowerSample? {
        guard io.isAvailable else { return nil }
        if subscription == nil { setUpSubscription() }
        guard let subscription, let subscribedChannels else { return nil }

        guard let current = io.createSamples(subscription, subscribedChannels) else { return nil }
        defer {
            previousSample = current
            previousTime = now
        }
        guard let previousSample, let previousTime else { return nil }

        let dt = now.timeIntervalSince(previousTime)
        guard dt > 0 else { return nil }
        guard let delta = io.createSamplesDelta(previousSample, current) else { return nil }

        var gpu = 0.0
        var ane = 0.0
        var cpu = 0.0
        var sawGPU = false
        var sawANE = false
        var sawCPU = false
        var states: [GPUPerformanceState]?
        var active: Double?
        var throttled: Bool?
        var powerCap: Double?
        var bandwidthRead: GPUBandwidthHistogram?
        var bandwidthWrite: GPUBandwidthHistogram?
        var bandwidthCombined: GPUBandwidthHistogram?
        var diagnostics = GPUDiagnostics()
        var sawDiagnostics = false
        var submissions: [GPUEngine: Int64] = [:]
        var switchBuckets: [GPUEngine: [GPUContextSwitches.Bucket]] = [:]
        io.iterate(delta) { channel in
            let subgroup = self.io.subGroupName(channel)
            // Since-boot counters: read from the absolute sample below.
            if Self.healthSubgroups.contains(subgroup) { return }
            if Self.diagnosticSubgroups.contains(subgroup) || subgroup.hasSuffix(" vChannel Usage")
            {
                sawDiagnostics = true
                Self.accumulate(
                    channel: channel, subgroup: subgroup, io: self.io, into: &diagnostics,
                    submissions: &submissions, switches: &switchBuckets)
                return
            }
            if subgroup == Self.bandwidthSubgroup {
                let histogram = self.io.bandwidthHistogram(channel)
                switch self.io.channelName(channel) {
                case "AGX RD": bandwidthRead = histogram
                case "AGX WR": bandwidthWrite = histogram
                case "AGX RD+WR": bandwidthCombined = histogram
                default: break
                }
                return
            }
            if self.io.isStateChannel(channel) {
                let residency = self.io.stateResidencies(channel)
                guard !residency.isEmpty else { return }
                switch self.io.subGroupName(channel) {
                case Self.performanceStatesSubgroup:
                    active = Self.activeResidency(in: residency)
                    states = residency.filter { $0.name.uppercased() != "OFF" }
                case Self.throttleSubgroup:
                    // Any residency outside NO_CLTM means thermal management
                    // held the clock down for part of the interval.
                    let limited = residency.filter { !$0.name.uppercased().hasPrefix("NO_") }
                        .reduce(0.0) { $0 + $1.residency }
                    throttled = limited > 1
                case Self.powerCapSubgroup:
                    // State names are the cap ("100%", "75%"); weight by residency.
                    var weighted = 0.0
                    var total = 0.0
                    for state in residency {
                        guard let percent = Double(state.name.filter { $0.isNumber }) else {
                            continue
                        }
                        weighted += percent * state.residency
                        total += state.residency
                    }
                    if total > 0 { powerCap = weighted / total }
                default:
                    break
                }
                return
            }
            let name = self.io.channelName(channel)
            let joules = self.io.energyJoules(channel)
            switch name {
            case "GPU Energy":
                gpu += joules
                sawGPU = true
            case "CPU Energy":
                cpu += joules
                sawCPU = true
            default:
                if name.hasPrefix("ANE") {
                    ane += joules
                    sawANE = true
                }
            }
        }
        if sawDiagnostics {
            Self.finish(
                &diagnostics, submissions: submissions, switches: switchBuckets, interval: dt)
        }
        if healthReadAt.map({ now.timeIntervalSince($0) >= Self.healthInterval || $0 > now })
            ?? true
        {
            health = Self.health(in: current, io: io)
            healthReadAt = now
        }
        return PowerSample(
            gpuWatts: sawGPU ? gpu / dt : nil,
            aneWatts: sawANE ? ane / dt : nil,
            cpuWatts: sawCPU ? cpu / dt : nil,
            gpuStates: states,
            gpuActiveResidency: active,
            gpuThrottled: throttled,
            gpuPowerCapPercent: powerCap,
            gpuBandwidth: GPUBandwidthSample(
                timestamp: now, interval: dt, read: bandwidthRead, write: bandwidthWrite,
                combined: bandwidthCombined),
            gpuDiagnostics: sawDiagnostics ? diagnostics : nil,
            gpuHealth: health)
    }

    /// "GPU Stats" subgroups worth a subscription: the clock-state residency,
    /// the thermal-throttle state and the power cap. The names are the
    /// driver's; the reader degrades to energy only when they are absent.
    static let performanceStatesSubgroup = "GPU Performance States"
    static let throttleSubgroup = "CLTM-induced GPU Performance States"
    static let powerCapSubgroup = "PPM Target as % of Max GPU Power"
    static let bandwidthSubgroup = "DCS BW"

    /// Extra "GPU Stats" subgroups behind the GPU tab's Clock, Limits and Work
    /// pages (about 70 channels; the subscription's sample went from 0.62 to
    /// 0.82 ms median on an M3 Pro). The three `vChannel Usage` subgroups are
    /// matched by suffix.
    static let controllerSubgroup = "GPU Power Controller States"
    static let lostPerformanceSubgroup = "PMU Loop Lost Performance Reason Code States"
    static let activeHistogramSubgroup = "Active Time Histogram"
    static let idleHistogramSubgroup = "Idle Time Histogram"
    static let contextSwitchSubgroup = "Context Switch Latencies"
    static let diagnosticSubgroups: Set<String> = [
        controllerSubgroup, lostPerformanceSubgroup, activeHistogramSubgroup,
        idleHistogramSubgroup, contextSwitchSubgroup,
    ]
    /// Cumulative since-boot counters, read from the absolute sample rather
    /// than the delta, every `healthInterval` seconds.
    static let healthSubgroups: Set<String> = ["Issue Counts", "UV Warn State", "THM Counters"]
    static let healthInterval: TimeInterval = 5

    private static func accumulate(
        channel: CFDictionary, subgroup: String, io: IOReportBindings,
        into diagnostics: inout GPUDiagnostics, submissions: inout [GPUEngine: Int64],
        switches: inout [GPUEngine: [GPUContextSwitches.Bucket]]
    ) {
        switch subgroup {
        case controllerSubgroup:
            diagnostics.controllerStates = io.stateResidencies(channel)
                .filter { $0.residency > 0 }
                .sorted { $0.residency > $1.residency }
        case lostPerformanceSubgroup:
            let states = io.stateResidencies(channel)
            guard !states.isEmpty else { return }
            diagnostics.lostPerformanceKnown = true
            diagnostics.lostPerformance = states.filter {
                let name = $0.name.uppercased()
                return name != "NONE" && name != "INVALID" && $0.residency > 0
            }
            .sorted { $0.residency > $1.residency }
        case activeHistogramSubgroup, idleHistogramSubgroup:
            guard let totals = io.histogramTotals(channel) else { return }
            let milliseconds = totals.hits > 0 ? totals.seconds / Double(totals.hits) * 1000 : nil
            if subgroup == activeHistogramSubgroup {
                // Hits are completed busy periods: wake-ups. The rate is set
                // in `finish` once the interval is known.
                diagnostics.wakeupsPerSecond = Double(totals.hits)
                diagnostics.meanBusyMilliseconds = milliseconds
            } else {
                diagnostics.meanIdleMilliseconds = milliseconds
            }
        case contextSwitchSubgroup:
            let name = io.channelName(channel)
            guard let parsed = GPUContextSwitches.parse(channel: name),
                let engine = GPUEngine.allCases.first(where: {
                    $0.contextSwitchPrefix == parsed.prefix
                })
            else { return }
            let count = io.simpleValue(channel)
            guard count >= 0 else { return }
            switches[engine, default: []].append(
                .init(upperBoundMicroseconds: parsed.upperBound, count: count))
        default:
            guard
                let engine = GPUEngine.allCases.first(where: {
                    subgroup == "\($0.submissionPrefix) vChannel Usage"
                })
            else { return }
            let count = io.simpleValue(channel)
            guard count >= 0 else { return }
            submissions[engine, default: 0] += count
        }
    }

    private static func finish(
        _ diagnostics: inout GPUDiagnostics, submissions: [GPUEngine: Int64],
        switches: [GPUEngine: [GPUContextSwitches.Bucket]], interval: TimeInterval
    ) {
        if let hits = diagnostics.wakeupsPerSecond {
            diagnostics.wakeupsPerSecond = hits / interval
        }
        for engine in GPUEngine.allCases {
            var activity = GPUEngineActivity()
            if let count = submissions[engine] {
                activity.submissionsPerSecond = Double(count) / interval
            }
            if let buckets = switches[engine], let histogram = GPUContextSwitches(buckets: buckets)
            {
                activity.contextSwitches = histogram
                activity.contextSwitchesPerSecond = Double(histogram.total) / interval
            }
            if activity != GPUEngineActivity() { diagnostics.engines[engine] = activity }
        }
    }

    private static func health(in sample: CFDictionary, io: IOReportBindings) -> GPUHealthCounters?
    {
        var counters = GPUHealthCounters()
        var saw = false
        io.iterate(sample) { channel in
            guard healthSubgroups.contains(io.subGroupName(channel)) else { return }
            let value = io.simpleValue(channel)
            guard value >= 0 else { return }
            saw = true
            switch io.channelName(channel) {
            case "Total Restarts": counters.restarts = value
            case "CDM Kill Count": counters.killedWork[.compute] = value
            case "FRG Kill Count": counters.killedWork[.fragment] = value
            case "GTP Kill Count": counters.killedWork[.geometry] = value
            case "Memless Render Failed": counters.memorylessRenderFailures = value
            case "UVWarn Instances": counters.undervoltageWarnings = value
            case "THM Activation Count": counters.thermalActivations = value
            default: break
            }
        }
        return saw ? counters : nil
    }

    static func activeResidency(in states: [GPUPerformanceState]) -> Double? {
        let offStates = states.filter { $0.name.uppercased() == "OFF" }
        guard offStates.count == 1, let off = offStates.first?.residency,
            off.isFinite, (0...100).contains(off)
        else { return nil }
        return 100 - off
    }

    private func setUpSubscription() {
        guard let channels = io.copyChannelsInGroup("Energy Model") else { return }
        // Subscribe to only the GPU / ANE / CPU energy channels (3, not ~180)
        // plus three GPU state channels, so each per-tick sample is cheap.
        var kept = io.filteredEnergyChannelList(channels)
        let gpuSubgroups =
            [Self.performanceStatesSubgroup, Self.throttleSubgroup, Self.powerCapSubgroup]
            + Self.diagnosticSubgroups.sorted() + Self.healthSubgroups.sorted()
            + GPUEngine.allCases.map { "\($0.submissionPrefix) vChannel Usage" }
        for subgroup in gpuSubgroups {
            if let group = io.copyChannelsInGroup("GPU Stats", subgroup: subgroup) {
                kept += io.channelList(group)
            }
        }
        if let group = io.copyChannelsInGroup("PMP", subgroup: Self.bandwidthSubgroup) {
            kept += io.channelList(group).filter { entry in
                guard let channel = entry as? NSDictionary else { return false }
                return ["AGX RD", "AGX WR", "AGX RD+WR"].contains(
                    io.channelName(channel as CFDictionary))
            }
        }
        let filtered = io.channels(channels, replacingListWith: kept)
        var subbed: Unmanaged<CFMutableDictionary>?
        guard let sub = io.createSubscription(filtered, &subbed),
            let subbedChannels = subbed?.takeRetainedValue()
        else { return }
        subscription = sub
        subscribedChannels = subbedChannels
    }
}

/// Runtime (`dlsym`) bindings to the IOReport SPI. Kept tiny and self-contained so
/// the rest of the code never touches the raw C ABI.
final class IOReportBindings {
    private typealias CopyChannelsFn =
        @convention(c) (
            CFString?, CFString?, UInt64, UInt64, UInt64
        ) -> Unmanaged<CFMutableDictionary>?
    private typealias CreateSubFn =
        @convention(c) (
            UnsafeMutableRawPointer?, CFMutableDictionary,
            UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>, UInt64, CFTypeRef?
        ) -> UnsafeMutableRawPointer?
    private typealias CreateSamplesFn =
        @convention(c) (
            UnsafeMutableRawPointer, CFMutableDictionary, CFTypeRef?
        ) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn =
        @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) ->
        Unmanaged<CFDictionary>?
    private typealias ChannelStrFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias SimpleIntFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias FormatFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias HistogramCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias HistogramValueFn = @convention(c) (CFDictionary, Int32) -> Int64
    private typealias IterateFn =
        @convention(c) (
            CFDictionary, @convention(block) (CFDictionary) -> Int32
        ) -> Void

    private let copyChannelsFn: CopyChannelsFn?
    private let createSubFn: CreateSubFn?
    private let createSamplesFn: CreateSamplesFn?
    private let createDeltaFn: CreateDeltaFn?
    private let channelNameFn: ChannelStrFn?
    private let unitLabelFn: ChannelStrFn?
    private let simpleIntFn: SimpleIntFn?
    private let iterateFn: IterateFn?
    private let subGroupFn: ChannelStrFn?
    private let formatFn: FormatFn?
    private let stateCountFn: StateCountFn?
    private let stateNameFn: StateNameFn?
    private let stateResidencyFn: StateResidencyFn?
    private let histogramCountFn: HistogramCountFn?
    private let histogramHitsFn: HistogramValueFn?
    private let histogramSumFn: HistogramValueFn?

    var isAvailable: Bool {
        copyChannelsFn != nil && createSubFn != nil && createSamplesFn != nil
            && createDeltaFn != nil && channelNameFn != nil && simpleIntFn != nil
            && iterateFn != nil && unitLabelFn != nil
    }

    init() {
        func sym<T>(_ name: String, _ type: T.Type) -> T? {
            guard let p = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
            return unsafeBitCast(p, to: T.self)
        }
        copyChannelsFn = sym("IOReportCopyChannelsInGroup", CopyChannelsFn.self)
        createSubFn = sym("IOReportCreateSubscription", CreateSubFn.self)
        createSamplesFn = sym("IOReportCreateSamples", CreateSamplesFn.self)
        createDeltaFn = sym("IOReportCreateSamplesDelta", CreateDeltaFn.self)
        channelNameFn = sym("IOReportChannelGetChannelName", ChannelStrFn.self)
        unitLabelFn = sym("IOReportChannelGetUnitLabel", ChannelStrFn.self)
        simpleIntFn = sym("IOReportSimpleGetIntegerValue", SimpleIntFn.self)
        iterateFn = sym("IOReportIterate", IterateFn.self)
        subGroupFn = sym("IOReportChannelGetSubGroup", ChannelStrFn.self)
        formatFn = sym("IOReportChannelGetFormat", FormatFn.self)
        stateCountFn = sym("IOReportStateGetCount", StateCountFn.self)
        stateNameFn = sym("IOReportStateGetNameForIndex", StateNameFn.self)
        stateResidencyFn = sym("IOReportStateGetResidency", StateResidencyFn.self)
        histogramCountFn = sym("IOReportHistogramGetBucketCount", HistogramCountFn.self)
        histogramHitsFn = sym("IOReportHistogramGetBucketHits", HistogramValueFn.self)
        histogramSumFn = sym("IOReportHistogramGetBucketSum", HistogramValueFn.self)
    }

    /// A simple (integer) channel's value, or -1 when it is not one.
    func simpleValue(_ channel: CFDictionary) -> Int64 {
        guard formatFn?(channel) == 1, let simpleIntFn else { return -1 }
        return simpleIntFn(channel, 0)
    }

    /// A histogram channel's total hits and the summed duration of its
    /// entries in seconds. Only the GPU's `24Mticks` (24 MHz) unit is
    /// understood; anything else returns nil rather than a mis-scaled time.
    func histogramTotals(_ channel: CFDictionary) -> (hits: Int64, seconds: Double)? {
        guard formatFn?(channel) == 3, let histogramCountFn, let histogramHitsFn,
            let histogramSumFn,
            (unitLabelFn?(channel)?.takeUnretainedValue() as String?)?.lowercased() == "24mticks"
        else { return nil }
        let count = histogramCountFn(channel)
        guard count > 0, count <= 256 else { return nil }
        var hits: Int64 = 0
        var ticks: Int64 = 0
        for index in 0..<count {
            let bucketHits = histogramHitsFn(channel, index)
            // An empty bucket's sum in a delta is a sentinel (Int64.min, seen
            // on an M3 Pro), not zero: skip it rather than reject the channel.
            guard bucketHits != 0 else { continue }
            let bucketSum = histogramSumFn(channel, index)
            guard bucketHits > 0, bucketSum >= 0 else { return nil }
            hits += bucketHits
            ticks += bucketSum
        }
        return (hits, Double(ticks) / 24_000_000)
    }

    func copyChannelsInGroup(_ group: String, subgroup: String? = nil) -> CFMutableDictionary? {
        copyChannelsFn?(group as CFString, subgroup.map { $0 as CFString }, 0, 0, 0)?
            .takeRetainedValue()
    }

    /// The channel dictionaries inside a channels collection.
    func channelList(_ channels: CFMutableDictionary) -> [Any] {
        guard let dict = channels as NSDictionary as? [String: Any],
            let array = dict["IOReportChannels"] as? [Any]
        else { return [] }
        return array
    }

    /// Only the GPU / ANE / CPU energy channels, so the subscription samples a
    /// handful of counters instead of every power rail. Falls back to the full
    /// set if the names don't resolve (correctness over the optimization).
    func filteredEnergyChannelList(_ channels: CFMutableDictionary) -> [Any] {
        let array = channelList(channels)
        let kept = array.filter { element in
            guard let channel = element as? NSDictionary else { return false }
            let name = channelName(channel as CFDictionary)
            return name == "GPU Energy" || name == "CPU Energy" || name.hasPrefix("ANE")
        }
        return kept.isEmpty ? array : kept
    }

    /// `template` with its channel list replaced, for a merged subscription.
    func channels(
        _ template: CFMutableDictionary, replacingListWith list: [Any]
    )
        -> CFMutableDictionary
    {
        guard let dict = template as NSDictionary as? [String: Any] else { return template }
        let result = NSMutableDictionary(dictionary: dict)
        result["IOReportChannels"] = list
        return result as CFMutableDictionary
    }

    /// kIOReportFormatState: residency per named state rather than a counter.
    func isStateChannel(_ channel: CFDictionary) -> Bool {
        formatFn?(channel) == 2
    }

    func subGroupName(_ channel: CFDictionary) -> String {
        subGroupFn?(channel)?.takeUnretainedValue() as String? ?? ""
    }

    func bandwidthHistogram(_ channel: CFDictionary) -> GPUBandwidthHistogram? {
        guard isStateChannel(channel),
            (unitLabelFn?(channel)?.takeUnretainedValue() as String?)?.lowercased() == "events",
            let stateCountFn, let stateNameFn, let stateResidencyFn
        else { return nil }
        let count = stateCountFn(channel)
        guard count > 0, count <= 128 else { return nil }
        var names: [String] = []
        var counts: [Int64] = []
        for index in 0..<count {
            guard let name = stateNameFn(channel, index)?.takeUnretainedValue() as String? else {
                return nil
            }
            names.append(name)
            counts.append(stateResidencyFn(channel, index))
        }
        return GPUBandwidthHistogram(labels: names, counts: counts)
    }

    /// Each state's share of the sampled interval, 0...100, in state order.
    func stateResidencies(_ channel: CFDictionary) -> [GPUPerformanceState] {
        guard let stateCountFn, let stateNameFn, let stateResidencyFn else { return [] }
        let count = stateCountFn(channel)
        guard count > 0 else { return [] }
        var raw: [(String, Int64)] = []
        var total: Int64 = 0
        for i in 0..<count {
            let name = stateNameFn(channel, i)?.takeUnretainedValue() as String? ?? "\(i)"
            let ticks = max(0, stateResidencyFn(channel, i))
            raw.append((name, ticks))
            total += ticks
        }
        guard total > 0 else { return [] }
        return raw.map {
            GPUPerformanceState(name: $0.0, residency: Double($0.1) / Double(total) * 100)
        }
    }

    func createSubscription(
        _ channels: CFMutableDictionary,
        _ subbed: UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>
    ) -> UnsafeMutableRawPointer? {
        createSubFn?(nil, channels, subbed, 0, nil)
    }

    func createSamples(
        _ sub: UnsafeMutableRawPointer, _ channels: CFMutableDictionary
    ) -> CFDictionary? {
        createSamplesFn?(sub, channels, nil)?.takeRetainedValue()
    }

    func createSamplesDelta(_ previous: CFDictionary, _ current: CFDictionary) -> CFDictionary? {
        createDeltaFn?(previous, current, nil)?.takeRetainedValue()
    }

    func channelName(_ channel: CFDictionary) -> String {
        channelNameFn?(channel)?.takeUnretainedValue() as String? ?? ""
    }

    /// The channel's energy delta converted to joules from whatever unit it reports
    /// (channels mix nJ / µJ / mJ).
    func energyJoules(_ channel: CFDictionary) -> Double {
        let raw = Double(simpleIntFn?(channel, 0) ?? 0)
        let unit = (unitLabelFn?(channel)?.takeUnretainedValue() as String? ?? "").lowercased()
        switch unit {
        case "nj": return raw / 1_000_000_000
        case "uj", "µj": return raw / 1_000_000
        case "mj": return raw / 1_000
        case "j": return raw
        default: return raw / 1_000  // IOReport energy defaults to mJ
        }
    }

    func iterate(_ samples: CFDictionary, _ body: @escaping (CFDictionary) -> Void) {
        iterateFn?(samples) { channel in
            body(channel)
            return 0  // kIOReportIterOk — continue
        }
    }
}
