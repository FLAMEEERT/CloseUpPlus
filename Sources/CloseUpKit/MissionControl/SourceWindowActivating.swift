import Foundation

/// The result of trying to focus the exact source window represented by a
/// Mission Control `CGWindowID`.
///
/// This is deliberately separate from `WindowAction`: activating a source is
/// a focus operation, not an AX title-bar button action or an app-wide raise.
public enum SourceWindowActivationResult: Equatable, Sendable {
    case activated
    case accessibilityUnavailable
    case sourceUnavailable
    case applicationActivationFailed
    case windowMoveFailed
    case windowResizeFailed
    case windowRaiseFailed
}

/// Focuses one exact source window without forwarding the mirror's input.
///
/// The production implementation resolves the `CGWindowID` to its AX window
/// element and performs `AXRaise`. Implementations are isolated behind this
/// protocol so panel presentation remains testable without a live Accessibility
/// target.
@MainActor
public protocol SourceWindowActivating {
    /// Move and size the exact source to the mirror, activate its application,
    /// then raise that exact AX window. `targetFrame` is in CG global space.
    func activate(
        source: WindowInfo,
        positionedAt targetFrame: CGRect
    ) -> SourceWindowActivationResult

    /// Latest real source geometry in CG global coordinates.
    func currentFrame(source: WindowInfo) -> CGRect?
}
