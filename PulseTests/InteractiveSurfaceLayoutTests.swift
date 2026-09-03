import XCTest
@testable import Pulse

final class InteractiveSurfaceLayoutTests: XCTestCase {
    func testStandardPhoneViewportReservesSummaryAndFloatingNavigation() {
        let viewportHeight: CGFloat = 840
        let interactionHeight = InteractiveSurfaceLayout.interactionHeight(in: viewportHeight)

        XCTAssertEqual(
            interactionHeight + InteractiveSurfaceLayout.homeSummaryHeight + InteractiveSurfaceLayout.homeTabBarClearance,
            viewportHeight
        )
        XCTAssertGreaterThanOrEqual(interactionHeight, 620, "A standard phone must retain a useful embedded-game viewport")
    }

    func testCompactViewportNeverCollapsesTheInteractiveSurface() {
        XCTAssertEqual(
            InteractiveSurfaceLayout.interactionHeight(in: 420),
            InteractiveSurfaceLayout.minimumInteractionHeight
        )
    }
}
