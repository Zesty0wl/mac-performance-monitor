import Foundation
import XCTest

@testable import MacPerfMonitorCore

final class TemperatureFormatTests: XCTestCase {
    private let key = TemperatureFormat.defaultsKey
    private var saved: Any?

    override func setUp() {
        super.setUp()
        saved = UserDefaults.standard.object(forKey: key)
    }

    override func tearDown() {
        if let saved {
            UserDefaults.standard.set(saved, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
        super.tearDown()
    }

    func testConversionIsExactAtReferencePoints() {
        XCTAssertEqual(TemperatureFormat.display(0, fahrenheit: true), 32)
        XCTAssertEqual(TemperatureFormat.display(100, fahrenheit: true), 212)
        XCTAssertEqual(TemperatureFormat.display(-40, fahrenheit: true), -40)
        XCTAssertEqual(TemperatureFormat.display(62.5, fahrenheit: false), 62.5)
    }

    /// Match System follows the region default and the system Temperature
    /// setting (the `mu` locale keyword that System Settings writes).
    func testSystemChoiceFollowsTheLocale() {
        func fahrenheit(_ id: String) -> Bool {
            TemperatureFormat.usesFahrenheit(choice: .system, locale: Locale(identifier: id))
        }
        XCTAssertFalse(fahrenheit("en_GB"))
        XCTAssertTrue(fahrenheit("en_US"))
        XCTAssertTrue(fahrenheit("en_GB@mu=fahrenhe"))
        XCTAssertFalse(fahrenheit("en_US@mu=celsius"))
        XCTAssertFalse(fahrenheit("de_DE"))
    }

    func testExplicitChoiceOverridesTheLocale() {
        let us = Locale(identifier: "en_US")
        let uk = Locale(identifier: "en_GB")
        XCTAssertFalse(TemperatureFormat.usesFahrenheit(choice: .celsius, locale: us))
        XCTAssertTrue(TemperatureFormat.usesFahrenheit(choice: .fahrenheit, locale: uk))
    }

    func testStringsUseTheChosenUnit() {
        UserDefaults.standard.set(TemperatureUnitChoice.celsius.rawValue, forKey: key)
        XCTAssertEqual(TemperatureFormat.string(62.4), "62°C")
        XCTAssertEqual(TemperatureFormat.string(62.44, fractionDigits: 1), "62.4°C")
        XCTAssertEqual(TemperatureFormat.degrees(62.4), "62°")
        XCTAssertEqual(TemperatureFormat.letter, "C")

        UserDefaults.standard.set(TemperatureUnitChoice.fahrenheit.rawValue, forKey: key)
        XCTAssertEqual(TemperatureFormat.string(62.4), "144°F")
        XCTAssertEqual(TemperatureFormat.string(100, fractionDigits: 1), "212.0°F")
        XCTAssertEqual(TemperatureFormat.degrees(100), "212°")
        XCTAssertEqual(TemperatureFormat.letter, "F")
        // A value already in the display unit is labelled, not converted again.
        XCTAssertEqual(TemperatureFormat.label(144), "144°F")
        XCTAssertEqual(TemperatureFormat.converter()(100), 212)
    }

    func testUnknownStoredChoiceFallsBackToSystem() {
        UserDefaults.standard.set("kelvin", forKey: key)
        XCTAssertEqual(TemperatureFormat.choice, .system)
        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertEqual(TemperatureFormat.choice, .system)
    }

    func testNonFiniteReadingsDoNotCrash() {
        XCTAssertEqual(TemperatureFormat.label(.nan), "--" + TemperatureFormat.symbol)
        XCTAssertEqual(TemperatureFormat.degrees(.infinity), "--°")
    }
}

final class QuarterStepCeilingTests: XCTestCase {
    func testQuarterStepsAvoidTopsThatQuarterUnevenly() {
        // Fahrenheit die temperatures with headroom: 181 °F * 1.12 ≈ 203.
        XCTAssertEqual(LiveChartGeometry.niceCeiling(203), 250)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(203, quarterSteps: true), 300)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(140, quarterSteps: true), 200)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(160, quarterSteps: true), 200)
        // Values that already sit on a quarter-friendly top are unchanged.
        XCTAssertEqual(LiveChartGeometry.niceCeiling(93, quarterSteps: true), 100)
        XCTAssertEqual(LiveChartGeometry.niceCeiling(110, quarterSteps: true), 120)
    }
}
