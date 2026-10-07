import SwiftUI
import XCTest
@testable import DeviceHubProApp

/// Space/Return on the custom controls act once per press: a held key's
/// repeats are consumed, not re-run (the record button used to start and
/// stop recordings, switches flipped back and forth).
final class KeyActivationTests: XCTestCase {
    func testTheKeyDownActs() {
        var runs = 0
        let result = KeyActivation.handle(.down) {
            runs += 1
            return .handled
        }
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(result, .handled)
    }

    func testAHeldKeyDoesNotActAgain() {
        var runs = 0
        for phase: KeyPress.Phases in [.down, .repeat, .repeat, .repeat] {
            let result = KeyActivation.handle(phase) {
                runs += 1
                return .handled
            }
            XCTAssertEqual(result, .handled, "repeats are consumed, not passed on")
        }
        XCTAssertEqual(runs, 1)
    }

    func testAnIgnoredKeyDownTravelsOn() {
        XCTAssertEqual(KeyActivation.handle(.down) { .ignored }, .ignored)
    }

    func testTheHandlerSeesRepeatsToConsumeThem() {
        // SwiftUI's own default for `onKeyPress(keys:)`; without `.repeat`
        // the repeats of a held key would travel on up the responder chain.
        XCTAssertEqual(KeyActivation.phases, [.down, .repeat])
    }
}
