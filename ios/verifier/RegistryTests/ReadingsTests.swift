import Foundation
import XCTest

/// The rows' texts and tokens (Shared/Readings.swift). The tokens are what
/// a live test compares with the value it wrote, so they use the writers'
/// own words: simctl's appearance and content size names, simctl location's
/// `lat,lon`.
final class ReadingsTests: XCTestCase {
    func testAppearanceAndTogglesUseSimctlsWords() {
        XCTAssertEqual(Readings.appearance(dark: true), Reading("Dark", raw: "dark"))
        XCTAssertEqual(Readings.appearance(dark: false), Reading("Light", raw: "light"))
        XCTAssertEqual(Readings.toggle(true), Reading("On", raw: "on"))
        XCTAssertEqual(Readings.toggle(false), Reading("Off", raw: "off"))
        XCTAssertEqual(Readings.toggle(true, detail: "Button Shapes"), Reading("On · Button Shapes", raw: "on"))
    }

    func testTextSizesAreSimctlsTwelveInDynamicTypeOrder() {
        XCTAssertEqual(Readings.textSizes.count, 12)
        XCTAssertEqual(Readings.textSize(index: 0)?.raw, "extra-small")
        XCTAssertEqual(Readings.textSize(index: 3), Reading("Large (default) · 4 of 12", raw: "large"))
        XCTAssertEqual(Readings.textSize(index: 5)?.raw, "extra-extra-large")
        XCTAssertEqual(Readings.textSize(index: 11)?.raw, "accessibility-extra-extra-extra-large")
        XCTAssertNil(Readings.textSize(index: 12))
        XCTAssertNil(Readings.textSize(index: -1))
    }

    func testLocationKeepsFiveDecimalsLikeTheWrite() throws {
        let date = try XCTUnwrap(ReadingsDocument.date("2026-09-26T11:02:03.000Z"))
        let reading = Readings.location(latitude: 37.33, longitude: -122.03, accuracy: 4.6, at: date)
        XCTAssertEqual(reading.raw, "37.33000,-122.03000")
        XCTAssertTrue(reading.value.hasPrefix("37.33000, -122.03000 · ±5 m · "), reading.value)
    }

    func testLanguageNamesTheFirstPreferredLanguage() {
        XCTAssertEqual(
            Readings.language(preferred: ["tr-TR", "en-TR"], localeIdentifier: "tr_TR", rightToLeft: false),
            Reading("tr-TR (+1 more) · region tr_TR · LTR", raw: "tr-TR")
        )
        XCTAssertEqual(
            Readings.language(preferred: ["ar-EG"], localeIdentifier: "ar_EG", rightToLeft: true),
            Reading("ar-EG · region ar_EG · RTL", raw: "ar-EG")
        )
        XCTAssertEqual(Readings.language(preferred: [], localeIdentifier: "en_US", rightToLeft: false).raw, "none")
    }

    func testTimeZoneOffsets() {
        XCTAssertEqual(
            Readings.timeZone(identifier: "Europe/Istanbul", secondsFromGMT: 3 * 3600),
            Reading("Europe/Istanbul · GMT+03:00", raw: "Europe/Istanbul")
        )
        XCTAssertEqual(
            Readings.timeZone(identifier: "America/St_Johns", secondsFromGMT: -(2 * 3600 + 1800)).value,
            "America/St_Johns · GMT-02:30"
        )
    }

    func testTimeFormatReadsTheHourSymbolOutsideQuotes() {
        XCTAssertEqual(Readings.timeFormat(pattern: "HH").raw, "24")
        XCTAssertEqual(Readings.timeFormat(pattern: "h a").raw, "12")
        XCTAssertEqual(Readings.timeFormat(pattern: "a h").raw, "12")
        XCTAssertEqual(Readings.timeFormat(pattern: "k").raw, "24")
        XCTAssertEqual(Readings.timeFormat(pattern: "'h'HH").raw, "24")
        XCTAssertEqual(Readings.timeFormat(pattern: "?").raw, "unknown")
    }

    func testBatteryReadingsSayTheOverrideIsNotSeen() {
        XCTAssertEqual(Readings.batteryLevel(-1).raw, "-1")
        XCTAssertTrue(Readings.batteryLevel(-1).value.contains("apps do not see the override"))
        XCTAssertEqual(Readings.batteryLevel(0.42), Reading("42 %", raw: "42"))
        XCTAssertEqual(Readings.batteryState(0).raw, "unknown")
        XCTAssertEqual(Readings.batteryState(2), Reading("Charging", raw: "charging"))
    }

    func testBiometrics() throws {
        XCTAssertEqual(
            Readings.biometrics(type: "faceID", enrolled: true, lastMatch: nil),
            Reading("Face ID · enrolled", raw: "faceID:enrolled")
        )
        XCTAssertEqual(Readings.biometrics(type: "touchID", enrolled: false, lastMatch: nil).raw, "touchID:notEnrolled")
        XCTAssertEqual(Readings.biometrics(type: "none", enrolled: false, lastMatch: nil), Reading("No biometry", raw: "none"))
        let date = try XCTUnwrap(ReadingsDocument.date("2026-09-26T11:02:03.000Z"))
        let matched = Readings.biometrics(type: "faceID", enrolled: true, lastMatch: ("Succeeded", date))
        XCTAssertTrue(matched.value.hasPrefix("Face ID · enrolled · last match Succeeded at "), matched.value)
        XCTAssertEqual(matched.raw, "faceID:enrolled")
    }

    func testPermissionsListEveryServiceInOrder() {
        let reading = Readings.permissions(["location": "authorizedWhenInUse", "photos": "denied"])
        XCTAssertEqual(
            reading.raw,
            "location=authorizedWhenInUse,photos=denied,contacts=unknown,calendar=unknown,reminders=unknown,"
                + "microphone=unknown,camera=unknown,motion=unknown,mediaLibrary=unknown"
        )
        XCTAssertEqual(reading.value.split(separator: "\n").count, Readings.permissionServices.count)
    }

    func testPasteboardAndCountersAndLinks() throws {
        XCTAssertEqual(
            Readings.pasteboard(changeCount: 7, hasStrings: true, hasURLs: false, hasImages: true),
            Reading("Change 7 · text, image", raw: "7")
        )
        XCTAssertEqual(Readings.pasteboard(changeCount: 0, hasStrings: false, hasURLs: false, hasImages: false).value, "Change 0 · empty")
        XCTAssertEqual(Readings.memoryWarnings(count: 0, last: nil), Reading("None since launch", raw: "0"))
        let date = try XCTUnwrap(ReadingsDocument.date("2026-09-26T11:02:03.000Z"))
        XCTAssertEqual(Readings.memoryWarnings(count: 2, last: date).raw, "2")
        let link = Readings.link("devicehubpro-verifier://link/check?q=a%20b", at: date)
        XCTAssertEqual(link.raw, "devicehubpro-verifier://link/check?q=a%20b")
        XCTAssertEqual(Readings.volume(0.5), Reading("50 %", raw: "50"))
        let push = Readings.push(title: "Device Hub Pro", body: "Verifier push check", at: date)
        XCTAssertEqual(push.raw, "Device Hub Pro — Verifier push check")
        XCTAssertTrue(push.value.hasPrefix("Device Hub Pro — Verifier push check · "), push.value)
        XCTAssertEqual(Readings.push(title: "", body: "", at: date).raw, "")
        XCTAssertEqual(Readings.noPush.raw, "none")
        XCTAssertEqual(Readings.grayscale(true).raw, "grayscale")
    }

    /// The orientation tokens are devicectl's pose names, so a test compares
    /// what `orientation set` sent with what the app saw.
    func testOrientationAndLiquidGlass() {
        XCTAssertEqual(Readings.orientation(1), Reading("Portrait", raw: "portrait"))
        XCTAssertEqual(Readings.orientation(2).raw, "portraitUpsideDown")
        XCTAssertEqual(Readings.orientation(3).raw, "landscapeLeft")
        XCTAssertEqual(Readings.orientation(4).raw, "landscapeRight")
        XCTAssertEqual(Readings.orientation(5), Reading("Face up", raw: "faceUp"))
        XCTAssertEqual(Readings.orientation(6).raw, "faceDown")
        XCTAssertEqual(Readings.orientation(0).raw, "unknown")
        XCTAssertEqual(Readings.orientation(9).raw, "unknown")
        XCTAssertEqual(Readings.liquidGlass.raw, "unreadable")
    }
}
