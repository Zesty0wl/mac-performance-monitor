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
}

final class PowerReader {
    private let io = IOReportBindings()
    private var subscription: UnsafeMutableRawPointer?
    private var subscribedChannels: CFMutableDictionary?
    private var previousSample: CFDictionary?
    private var previousTime: Date?

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
        io.iterate(delta) { channel in
            if self.io.isStateChannel(channel) {
                let residency = self.io.stateResidencies(channel)
                guard !residency.isEmpty else { return }
                switch self.io.subGroupName(channel) {
                case Self.performanceStatesSubgroup:
                    let off = residency.first { $0.name.uppercased() == "OFF" }?.residency ?? 0
                    active = max(0, 100 - off)
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
        return PowerSample(
            gpuWatts: sawGPU ? gpu / dt : nil,
            aneWatts: sawANE ? ane / dt : nil,
            cpuWatts: sawCPU ? cpu / dt : nil,
            gpuStates: states,
            gpuActiveResidency: active,
            gpuThrottled: throttled,
            gpuPowerCapPercent: powerCap)
    }

    /// "GPU Stats" subgroups worth a subscription: the clock-state residency,
    /// the thermal-throttle state and the power cap. The names are the
    /// driver's; the reader degrades to energy only when they are absent.
    static let performanceStatesSubgroup = "GPU Performance States"
    static let throttleSubgroup = "CLTM-induced GPU Performance States"
    static let powerCapSubgroup = "PPM Target as % of Max GPU Power"

    private func setUpSubscription() {
        guard let channels = io.copyChannelsInGroup("Energy Model") else { return }
        // Subscribe to only the GPU / ANE / CPU energy channels (3, not ~180)
        // plus three GPU state channels, so each per-tick sample is cheap.
        var kept = io.filteredEnergyChannelList(channels)
        for subgroup in [
            Self.performanceStatesSubgroup, Self.throttleSubgroup, Self.powerCapSubgroup,
        ] {
            if let group = io.copyChannelsInGroup("GPU Stats", subgroup: subgroup) {
                kept += io.channelList(group)
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
private final class IOReportBindings {
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
