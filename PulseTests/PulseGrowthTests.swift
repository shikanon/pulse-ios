import XCTest
@testable import Pulse

final class PulseGrowthTests: XCTestCase {
    func testChallengeLinkKeepsIdentifierAndRejectsAmbiguousIDs() throws {
        let id = "11111111-1111-4111-8111-111111111111"
        let good = try XCTUnwrap(URL(string: "https://play.pulse.test/a/abcdef?challenge=\(id)"))
        XCTAssertEqual(PulseDeepLink.parse(good, universalLinkHost: "play.pulse.test"), .challenge(slug: "abcdef", id: id))
        XCTAssertNil(PulseDeepLink.parse(URL(string: "https://play.pulse.test/a/abcdef?challenge=bad")!, universalLinkHost: "play.pulse.test"))
        XCTAssertNil(PulseDeepLink.parse(URL(string: "https://play.pulse.test/a/abcdef?challenge=\(id)&challenge=\(id)")!, universalLinkHost: "play.pulse.test"))
        XCTAssertNil(PulseDeepLink.parse(good, universalLinkHost: "other.pulse.test"))
    }
    func testResultBridgeAcceptsOnlyBoundedNumericScoresAndKnownEvents() {
        XCTAssertEqual(PulsePlayMessage(body: ["type": "pulse:play-v1", "name": "complete", "score": 42])?.score, 42)
        for score: Any in [true, -1, 1.5, Double.infinity, 1_000_000_001, "42"] {
            XCTAssertNil(PulsePlayMessage(body: ["type": "pulse:play-v1", "name": "complete", "score": score]))
        }
        XCTAssertNil(PulsePlayMessage(body: ["type": "other", "name": "interaction"]))
        XCTAssertNil(PulsePlayMessage(body: ["type": "pulse:play-v1", "name": "network"]))
        XCTAssertEqual(PulsePlayMessage(body: ["type": "pulse:play-v1", "name": "interaction"])?.name, "interaction")
    }
}
