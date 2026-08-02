import XCTest

@testable import MacPerfMonitorCore

final class NotchDisplayModesTests: XCTestCase {
    private func mode(
        _ width: Int, _ height: Int, scale: Int = 2, refresh: Double = 120
    ) -> DisplayModeDescriptor {
        DisplayModeDescriptor(
            width: width, height: height,
            pixelWidth: width * scale, pixelHeight: height * scale, refreshRate: refresh)
    }

    /// The real scaled sizes a 14-inch MacBook Pro publishes, each notched mode
    /// beside the notch-free twin that excludes the camera band.
    private var fourteenInch: [DisplayModeDescriptor] {
        [
            mode(1512, 982), mode(1512, 945),
            mode(1800, 1169), mode(1800, 1125),
            mode(1352, 878), mode(1352, 845),
            mode(1147, 745), mode(1147, 716),
            mode(1024, 665), mode(1024, 640),
        ]
    }

    func testFindsTheNotchFreeTwinOfTheDefaultMode() throws {
        let twin = try XCTUnwrap(
            NotchDisplayModes.notchFreeTwin(of: mode(1512, 982), in: fourteenInch))
        XCTAssertEqual(twin, mode(1512, 945))
    }

    func testFindsTheNotchedTwinComingBack() throws {
        let twin = try XCTUnwrap(
            NotchDisplayModes.notchedTwin(of: mode(1512, 945), in: fourteenInch))
        XCTAssertEqual(twin, mode(1512, 982))
    }

    /// Each scaled size pairs with its own twin, so changing resolution in System
    /// Settings while the notch is hidden keeps the size the user chose.
    func testEveryScaledSizePairsWithItsOwnTwin() throws {
        let expected: [(Int, Int, Int)] = [
            (1512, 982, 945), (1800, 1169, 1125), (1352, 878, 845),
            (1147, 745, 716), (1024, 665, 640),
        ]
        for (width, notched, free) in expected {
            let twin = try XCTUnwrap(
                NotchDisplayModes.notchFreeTwin(of: mode(width, notched), in: fourteenInch),
                "no twin for \(width)x\(notched)")
            XCTAssertEqual(twin, mode(width, free))
        }
    }

    func testReportsWhichHalfOfThePairIsCurrent() {
        XCTAssertFalse(
            NotchDisplayModes.isNotchHidden(current: mode(1512, 982), in: fourteenInch))
        XCTAssertTrue(
            NotchDisplayModes.isNotchHidden(current: mode(1512, 945), in: fourteenInch))
    }

    func testDetectsANotchedDisplayFromItsModeList() {
        XCTAssertTrue(NotchDisplayModes.hasNotchPair(in: fourteenInch))
    }

    /// A display with no notch has nothing to pair, so the menu never offers the
    /// toggle. These are the modes an ordinary 16:10 external panel publishes.
    func testDisplayWithoutANotchHasNoPair() {
        let external = [mode(2560, 1600, scale: 1), mode(1920, 1200, scale: 1)]
        XCTAssertFalse(NotchDisplayModes.hasNotchPair(in: external))
        XCTAssertNil(
            NotchDisplayModes.notchFreeTwin(of: mode(2560, 1600, scale: 1), in: external))
        XCTAssertFalse(
            NotchDisplayModes.isNotchHidden(current: mode(2560, 1600, scale: 1), in: external))
    }

    /// The trap the height-ratio window exists to avoid: a panel offering both
    /// 16:9 and 16:10 at one width is two aspect ratios, not a notch pair, and
    /// switching between them would silently letterbox the user.
    func testWidthMatchAloneDoesNotPair() {
        let external = [mode(1920, 1080, scale: 1), mode(1920, 1200, scale: 1)]
        XCTAssertFalse(NotchDisplayModes.hasNotchPair(in: external))
        XCTAssertNil(
            NotchDisplayModes.notchFreeTwin(of: mode(1920, 1200, scale: 1), in: external))
    }

    /// A HiDPI mode must never pair with the same-sized low-resolution one, which
    /// shares its logical width but is a different backing scale.
    func testDoesNotPairAcrossBackingScales() {
        let modes = [
            mode(1512, 982, scale: 2),
            DisplayModeDescriptor(
                width: 1512, height: 945, pixelWidth: 1512, pixelHeight: 945, refreshRate: 120),
        ]
        XCTAssertNil(NotchDisplayModes.notchFreeTwin(of: mode(1512, 982, scale: 2), in: modes))
    }

    /// ProMotion publishes every size at many refresh rates. The twin must be the
    /// one at the current rate, or toggling the notch would also drop the display
    /// to 47 Hz.
    func testPairsWithinTheCurrentRefreshRate() throws {
        let modes = [
            mode(1512, 982, refresh: 120), mode(1512, 945, refresh: 120),
            mode(1512, 982, refresh: 47), mode(1512, 945, refresh: 47),
        ]
        let twin = try XCTUnwrap(
            NotchDisplayModes.notchFreeTwin(of: mode(1512, 982, refresh: 120), in: modes))
        XCTAssertEqual(twin.refreshRate, 120)
    }

    /// With more than one candidate, the switch should give up as little height as
    /// the panel allows.
    func testPrefersTheTallestNotchFreeCandidate() throws {
        let modes = [
            mode(1512, 982), mode(1512, 945), mode(1512, 930),
        ]
        let twin = try XCTUnwrap(
            NotchDisplayModes.notchFreeTwin(of: mode(1512, 982), in: modes))
        XCTAssertEqual(twin.height, 945)
    }

    func testEmptyModeListIsHandled() {
        XCTAssertFalse(NotchDisplayModes.hasNotchPair(in: []))
        XCTAssertNil(NotchDisplayModes.notchFreeTwin(of: mode(1512, 982), in: []))
        XCTAssertFalse(NotchDisplayModes.isNotchHidden(current: mode(1512, 982), in: []))
    }
}
