import CoreGraphics

/// Shared geometry for playable Artifact surfaces. Create previews and Home
/// cards use the same height budget so controls do not move or become clipped
/// after publication.
enum InteractiveSurfaceLayout {
    static let homeSummaryHeight: CGFloat = 110
    /// The floating tab bar begins 35pt above the bottom of the Feed viewport.
    /// Reserve enough room for that overlap plus a visible separation so the
    /// summary actions remain fully tappable instead of sitting behind it.
    static let homeTabBarClearance: CGFloat = 42
    static let minimumInteractionHeight: CGFloat = 360

    static func interactionHeight(in viewportHeight: CGFloat) -> CGFloat {
        max(minimumInteractionHeight, viewportHeight - homeSummaryHeight - homeTabBarClearance)
    }
}
