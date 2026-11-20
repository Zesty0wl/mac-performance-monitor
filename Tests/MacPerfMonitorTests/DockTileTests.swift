import AppKit
import MacPerfMonitorCore
import SwiftUI
import XCTest

@testable import MacPerfMonitor

@MainActor
final class DockTileTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000.5)

    /// A throwaway defaults domain, removed when the test ends so runs do not
    /// leave plists behind in ~/Library/Preferences.
    private func scratchDefaults() -> UserDefaults {
        let name = "DockTileTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    // MARK: Buckets

    func testBucketCountFollowsTheSampleRateUpToTheCap() {
        XCTAssertEqual(DockTileBuckets.count(for: .two), 120)
        XCTAssertEqual(DockTileBuckets.count(for: .five), 256)
        XCTAssertEqual(DockTileBuckets.count(for: .fifteen), 256)
        XCTAssertEqual(DockTileBuckets.width(for: .two), 1)
        XCTAssertEqual(DockTileBuckets.width(for: .fifteen), 900.0 / 256, accuracy: 1e-9)
    }

    func testOnlyCompletedSlotsAreAveragedAndEmptySlotsAreGaps() {
        // Two-minute range: one-second slots. The slot holding `now` is still
        // filling, so it is left out.
        let samples: [(date: Date, values: [Double])] = [
            (now.addingTimeInterval(-1.2), [10]), (now.addingTimeInterval(-1.1), [30]),
            (now.addingTimeInterval(-3.2), [50]), (now, [99]),
            (now.addingTimeInterval(-500), [7]),
        ]
        let values = DockTileBuckets.average(samples, channels: 1, now: now, range: .two)[0]
        XCTAssertEqual(values.count, 120)
        XCTAssertEqual(values[119], 20)
        XCTAssertNil(values[118])
        XCTAssertEqual(values[117], 50)
        XCTAssertFalse(values.contains(99))
        XCTAssertFalse(values.contains(7))
    }

    func testAClosedSlotDoesNotChangeAsTimeMovesWithinTheNextOne() {
        let samples: [(date: Date, values: [Double])] = (0..<900).map {
            (now.addingTimeInterval(-Double($0)), [Double($0 % 17)])
        }
        let boundary = DockTileBuckets.nextBoundary(after: now, range: .fifteen)
        let early = DockTileBuckets.average(samples, channels: 1, now: now, range: .fifteen)
        let late = DockTileBuckets.average(
            samples, channels: 1, now: boundary.addingTimeInterval(-0.01), range: .fifteen)
        XCTAssertEqual(early, late)
        XCTAssertGreaterThan(boundary, now)
        XCTAssertLessThanOrEqual(boundary.timeIntervalSince(now), 900.0 / 256)
    }

    func testTheCaptionRowShrinksWithItsText() throws {
        let fixtures = Self.fixtures(variants: true)
        func header(_ name: String) throws -> CGFloat {
            let content = try XCTUnwrap(fixtures[name])
            return DockTileRenderer.captionLayout(content, size: .large)?.header
                ?? DockTileRenderer.bareHeader
        }
        // A label on its own is a shorter row than any row with a value; no
        // text leaves only the bare margin.
        XCTAssertLessThan(try header("cpu-label"), try header("cpu"))
        XCTAssertLessThan(try header("cpu-label"), try header("cpu-value"))
        XCTAssertEqual(try header("cpu-bare"), DockTileRenderer.bareHeader)
        // A centred label is centred on the plate.
        let label = try XCTUnwrap(
            DockTileRenderer.captionLayout(try XCTUnwrap(fixtures["cpu-label"]), size: .large))
        let mid = label.leading.origin.x + label.leading.text.size().width / 2
        XCTAssertEqual(mid, DockTileSize.large.plate.midX, accuracy: 0.5)
    }

    func testNonFiniteValuesAreLeftOutOfTheMean() {
        let samples: [(date: Date, values: [Double])] = [
            (now.addingTimeInterval(-1.2), [10, .nan]), (now.addingTimeInterval(-1.1), [30, 4]),
        ]
        let channels = DockTileBuckets.average(samples, channels: 2, now: now, range: .two)
        XCTAssertEqual(channels[0][119], 20)
        XCTAssertEqual(channels[1][119], 4)
    }

    func testRecentStopsAtTheStartOfTheRange() {
        let history = (0..<900).map { now.addingTimeInterval(-Double(899 - $0)) }
        let recent = DockTileContent.recent(history, now: now, range: .two) { $0 }
        XCTAssertEqual(recent.last, history.last)
        XCTAssertLessThanOrEqual(recent.count, 122)
        XCTAssertGreaterThanOrEqual(recent.count, 120)
        XCTAssertEqual(DockTileContent.recent(history, now: now, range: .fifteen) { $0 }.count, 900)
    }

    func testAShrunkCaptionRowFitsThePlate() throws {
        let wide = DockTileContent(
            leading: .init(text: "↓1023.9M", color: .green, size: DockTileContent.rateSize),
            trailing: .init(text: "↑1023.9M", color: .red, size: DockTileContent.rateSize),
            lines: [], top: 1)
        for size in DockTileSize.allCases {
            let layout = try XCTUnwrap(DockTileRenderer.captionLayout(wide, size: size))
            let trailing = try XCTUnwrap(layout.trailing)
            XCTAssertLessThanOrEqual(
                trailing.origin.x + trailing.text.size().width, size.plate.maxX - size.inset + 0.5)
            XCTAssertGreaterThanOrEqual(
                trailing.origin.x, layout.leading.origin.x + layout.leading.text.size().width)
        }
    }

    func testShortGapsAreJoinedAndLongOnesSplit() {
        let plot = CGRect(x: 0, y: 0, width: 100, height: 50)
        // Up to three empty slots are joined across; four or more are a gap.
        let runs = DockTileRenderer.runs(
            [nil, 1, 2, nil, 3, nil, nil, nil, 4, nil, nil, nil, nil, 5, 6], top: 10, in: plot)
        XCTAssertEqual(runs.map(\.count), [4, 2])
    }

    // MARK: Rate scale

    func testABriefBurstDoesNotSetTheRateScale() {
        // Steady 1 MB/s with a two-second 50 MB/s burst, on the 2 minute range.
        var steady: [Double?] = Array(repeating: 1_000_000, count: 120)
        steady[60] = 50_000_000
        steady[61] = 50_000_000
        let top = DockTileContent.rateTop([steady, Array(repeating: 0, count: 120)], range: .two)
        XCTAssertLessThan(top, 32_000_000)
        XCTAssertGreaterThanOrEqual(top, 1_000_000)
    }

    func testSustainedLoadStillSetsTheRateScale() {
        var busy: [Double?] = Array(repeating: 1_000_000, count: 120)
        for index in 40..<80 { busy[index] = 50_000_000 }
        XCTAssertGreaterThanOrEqual(DockTileContent.rateTop([busy], range: .two), 50_000_000)
    }

    func testTheAverageRestartsAfterAGap() {
        // The burst before the gap must not leak into the average after it.
        let values: [Double?] = [9, 9, 9, nil, nil, nil, nil, 1, 1]
        XCTAssertEqual(DockTileContent.smoothedPeak(values, window: 3), 9)
        XCTAssertEqual(DockTileContent.smoothedPeak(Array(values[3...]), window: 3), 1)
    }

    func testAnIdleLinkKeepsTheFloor() {
        XCTAssertEqual(
            DockTileContent.rateTop([Array(repeating: 100, count: 60)], range: .five),
            DockTileContent.rateFloor)
    }

    // MARK: Presence

    private func presenceDefaults(mode: DockPresenceMode?, pinned: Bool?) -> UserDefaults {
        let defaults = scratchDefaults()
        if let mode { defaults.set(mode.rawValue, forKey: DockPresenceMode.defaultsKey) }
        if let pinned { defaults.set(pinned, forKey: PresenceController.pinDefaultsKey) }
        return defaults
    }

    private func reconciled(mode: DockPresenceMode?, pinned: Bool?) -> (DockPresenceMode, Bool) {
        let defaults = presenceDefaults(mode: mode, pinned: pinned)
        DockPresenceMode.reconcile(defaults)
        return (
            DockPresenceMode.current(defaults),
            defaults.bool(forKey: PresenceController.pinDefaultsKey)
        )
    }

    func testTheOldSwitchSetsTheModeOnFirstLaunch() {
        XCTAssertTrue(reconciled(mode: nil, pinned: nil) == (.withWindows, false))
        XCTAssertTrue(reconciled(mode: nil, pinned: true) == (.always, true))
        XCTAssertTrue(reconciled(mode: nil, pinned: false) == (.withWindows, false))
    }

    func testTheOldSwitchWinsWhenChangedElsewhere() {
        // Turned on by an older version or an import: Always.
        XCTAssertTrue(reconciled(mode: .withWindows, pinned: true) == (.always, true))
        XCTAssertTrue(reconciled(mode: .whileShowingTrend, pinned: true) == (.always, true))
        // Turned off: Always ends, the trend mode an older version cannot see stays.
        XCTAssertTrue(reconciled(mode: .always, pinned: false) == (.withWindows, false))
        XCTAssertTrue(
            reconciled(mode: .whileShowingTrend, pinned: false) == (.whileShowingTrend, false))
        // In step: unchanged.
        XCTAssertTrue(reconciled(mode: .always, pinned: true) == (.always, true))
    }

    func testTheModeIsMirroredToTheOldSwitch() {
        let defaults = presenceDefaults(mode: .always, pinned: false)
        DockPresenceMode.mirror(defaults)
        XCTAssertTrue(defaults.bool(forKey: PresenceController.pinDefaultsKey))
        defaults.set(
            DockPresenceMode.whileShowingTrend.rawValue, forKey: DockPresenceMode.defaultsKey)
        DockPresenceMode.mirror(defaults)
        XCTAssertFalse(defaults.bool(forKey: PresenceController.pinDefaultsKey))
    }

    func testLabelAndValueAreOnUnlessTurnedOff() {
        let defaults = scratchDefaults()
        XCTAssertEqual(DockTileText.current(defaults), .all)
        defaults.set(false, forKey: DockTileText.valueKey)
        XCTAssertEqual(DockTileText.current(defaults), DockTileText(label: true, value: false))
    }

    func testCaptionsFollowTheLabelAndValueSwitches() {
        func texts(_ metric: DockTileMetric, _ latest: [Double?], _ text: DockTileText) -> [String?]
        {
            let captions = DockTileContent.captions(metric: metric, latest: latest, text: text)
            return [captions.leading?.text, captions.trailing?.text]
        }
        XCTAssertEqual(texts(.cpu, [41.4], .all), ["CPU", "41%"])
        XCTAssertEqual(
            texts(.load, [4.26], .all), ["LOAD", String(format: "%.1f", locale: .current, 4.3)])
        XCTAssertEqual(texts(.gpu, [70.6], .all), ["GPU", "71%"])
        XCTAssertEqual(texts(.energy, [16.6], .all), ["PWR", "17W"])
        XCTAssertEqual(texts(.cpu, [41.4], DockTileText(label: false, value: true)), [nil, "41%"])
        XCTAssertEqual(texts(.memory, [63], DockTileText(label: true, value: false)), ["RAM", nil])
        XCTAssertEqual(texts(.network, [2048, nil], .all), ["↓2.0K", "↑--"])
        XCTAssertEqual(
            texts(.network, [2048, 1024], DockTileText(label: true, value: false)), ["↓", "↑"])
        XCTAssertEqual(
            texts(.disk, [2048, 1024], DockTileText(label: true, value: false)), ["R", "W"])
        XCTAssertEqual(
            texts(.disk, [2048, 1024], DockTileText(label: false, value: true)), ["2.0K", "1.0K"])
        XCTAssertEqual(texts(.disk, [2048, 1024], .all), ["R\u{2009}2.0K", "W\u{2009}1.0K"])
        XCTAssertEqual(texts(.disk, [2048, 1024], .none), [nil, nil])
        // The numbers keep their direction's color with the marks off.
        let disk = DockTileContent.captions(
            metric: .disk, latest: [1, 1], text: DockTileText(label: false, value: true))
        XCTAssertEqual(disk.leading?.color, NSColor(DiskStyle.read))
        XCTAssertEqual(disk.trailing?.color, NSColor(DiskStyle.write))
    }

    func testSizeDefaultsToLargeAndStandardKeepsTheIconGrid() {
        let defaults = scratchDefaults()
        XCTAssertEqual(DockTileSize.current(defaults), .large)
        defaults.set("standard", forKey: DockTileSize.defaultsKey)
        XCTAssertEqual(DockTileSize.current(defaults), .standard)
        XCTAssertEqual(DockTileSize.standard.plate.width / 128, 824.0 / 1024, accuracy: 0.01)
        XCTAssertGreaterThan(DockTileSize.large.plate.width, DockTileSize.standard.plate.width)
    }

    func testTrendModeKeepsTheIconOnlyWhileATrendIsChosen() {
        XCTAssertTrue(DockPresenceMode.whileShowingTrend.keepsIcon(showing: .cpu))
        XCTAssertFalse(DockPresenceMode.whileShowingTrend.keepsIcon(showing: .appIcon))
        XCTAssertTrue(DockPresenceMode.always.keepsIcon(showing: .appIcon))
        XCTAssertFalse(DockPresenceMode.withWindows.keepsIcon(showing: .network))
    }

    // MARK: Dock menu

    func testDockMenuShowsAndChangesTheChoice() throws {
        let defaults = scratchDefaults()
        let controller = DockTileController(
            model: SamplerModel(persistenceEnabled: false), defaults: defaults)
        var submenu = try XCTUnwrap(controller.dockMenuItem().submenu)
        let titles = DockTileMetric.allCases.map(\.title)
        XCTAssertEqual(submenu.items.prefix(titles.count).map(\.title), titles)
        XCTAssertEqual(submenu.items[0].state, .on)
        // Ranges and the caption switch are off while the app icon shows.
        XCTAssertFalse(submenu.items.last?.isEnabled ?? true)

        let network = try XCTUnwrap(
            submenu.items.first { $0.title == DockTileMetric.network.title })
        _ = network.target?.perform(network.action, with: network)
        XCTAssertEqual(DockTileMetric.current(defaults), .network)

        submenu = try XCTUnwrap(controller.dockMenuItem().submenu)
        let fifteen = try XCTUnwrap(submenu.items.first { $0.title == DockTileRange.fifteen.title })
        XCTAssertTrue(fifteen.isEnabled)
        _ = fifteen.target?.perform(fifteen.action, with: fifteen)
        XCTAssertEqual(DockTileRange.current(defaults), .fifteen)

        let value = try XCTUnwrap(submenu.items.last)
        XCTAssertEqual(value.state, .on)
        _ = value.target?.perform(value.action, with: value)
        XCTAssertEqual(DockTileText.current(defaults), DockTileText(label: true, value: false))
    }

    // MARK: Rendering

    func testEveryMetricRendersAtTheDockScale() throws {
        for content in Self.fixtures().values {
            for size in DockTileSize.allCases {
                let image = try XCTUnwrap(DockTileRenderer.image(content, size: size))
                XCTAssertEqual(image.size, DockTileRenderer.canvas)
                let cgImage = try XCTUnwrap(
                    image.cgImage(forProposedRect: nil, context: nil, hints: nil))
                XCTAssertEqual(cgImage.width, 512)
            }
        }
    }

    /// Set MACPERF_DOCK_TILE_ARTIFACTS to a folder to write each fixture as a PNG.
    func testWritesArtifactsWhenAsked() throws {
        guard let folder = ProcessInfo.processInfo.environment["MACPERF_DOCK_TILE_ARTIFACTS"]
        else { throw XCTSkip("set MACPERF_DOCK_TILE_ARTIFACTS to write the tiles") }
        for (name, content) in Self.fixtures(variants: true) {
            for size in DockTileSize.allCases {
                try write(content, size: size, name: "\(name)-\(size.rawValue)", to: folder)
            }
        }
    }

    private func write(
        _ content: DockTileContent, size: DockTileSize, name: String, to folder: String
    ) throws {
        let image = try XCTUnwrap(DockTileRenderer.image(content, size: size))
        let cgImage = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(
            NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }

    /// One fixture's metric, lines and newest values.
    private struct Fixture {
        var name: String
        var metric: DockTileMetric
        var lines: [DockTileContent.Line]
        var top: Double
        var latest: [Double?]
    }

    private static func wave(_ count: Int, base: Double, swing: Double, seed: Double) -> [Double?] {
        (0..<count).map { index in
            let phase = Double(index) / Double(count)
            return base + swing * sin(phase * 9 + seed) * 0.6 + swing
                * sin(phase * 31 + seed * 2) * 0.4
        }
    }

    private static func line(_ values: [Double?], _ color: Color) -> [DockTileContent.Line] {
        [DockTileContent.Line(values: values, color: NSColor(color))]
    }

    private static func pair(
        _ first: [Double?], _ second: [Double?], _ metric: DockTileMetric
    ) -> [DockTileContent.Line] {
        let style = DockTileContent.pairStyle(metric)
        return [
            DockTileContent.Line(values: second, color: style.second.color),
            DockTileContent.Line(values: first, color: style.first.color),
        ]
    }

    private static func baseFixtures() -> [Fixture] {
        var cpu = wave(256, base: 28, swing: 14, seed: 1)
        // A real gap (longer than the bridged three slots) and a short one.
        cpu.replaceSubrange(60..<80, with: Array(repeating: nil, count: 20))
        cpu.replaceSubrange(150..<152, with: [nil, nil])
        return [
            Fixture(
                name: "load", metric: .load,
                lines: line(wave(256, base: 4, swing: 2, seed: 2.4), CPULevel.light.color),
                top: 12, latest: [4.3]),
            Fixture(
                name: "cpu", metric: .cpu, lines: line(cpu, CPULevel.light.color), top: 100,
                latest: [100]),
            Fixture(
                name: "memory", metric: .memory,
                lines: line(wave(120, base: 55, swing: 8, seed: 4), PressureLevel.warning.color),
                top: 100, latest: [63]),
            Fixture(
                name: "gpu", metric: .gpu,
                lines: line(wave(256, base: 62, swing: 20, seed: 0.7), CPULevel.busy.color),
                top: 100, latest: [71]),
            Fixture(
                name: "energy", metric: .energy,
                lines: line(wave(256, base: 14, swing: 6, seed: 3.1), BatteryStyle.consumer),
                top: 25, latest: [17]),
            Fixture(
                name: "network", metric: .network,
                lines: pair(
                    wave(256, base: 2_400_000, swing: 1_600_000, seed: 0.3),
                    wave(256, base: 300_000, swing: 220_000, seed: 2.1), .network),
                top: LiveChartGeometry.binaryNiceCeiling(5_000_000), latest: [4_300_000, 532_000]),
            Fixture(
                name: "disk", metric: .disk,
                lines: pair(
                    wave(256, base: 9_000_000, swing: 7_000_000, seed: 1.7),
                    wave(256, base: 14_000_000, swing: 9_000_000, seed: 0.9), .disk),
                top: LiveChartGeometry.binaryNiceCeiling(30_000_000),
                latest: [12_600_000, 31_000_000]),
        ]
    }

    /// One tile per metric, and with `variants` each metric again with only
    /// the label, only the value, and no text.
    static func fixtures(variants: Bool = false) -> [String: DockTileContent] {
        let texts: [(suffix: String, text: DockTileText)] =
            variants
            ? [
                ("", .all), ("-label", DockTileText(label: true, value: false)),
                ("-value", DockTileText(label: false, value: true)), ("-bare", .none),
            ] : [("", .all)]
        var fixtures: [String: DockTileContent] = [:]
        for fixture in baseFixtures() {
            for variant in texts {
                let captions = DockTileContent.captions(
                    metric: fixture.metric, latest: fixture.latest, text: variant.text)
                fixtures[fixture.name + variant.suffix] = DockTileContent(
                    leading: captions.leading, trailing: captions.trailing, lines: fixture.lines,
                    top: fixture.top, centersCaptions: variant.text.label && !variant.text.value)
            }
        }
        return fixtures
    }
}
