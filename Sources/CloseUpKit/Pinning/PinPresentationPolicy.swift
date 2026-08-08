/// Pure presentation decisions for one pinned mirror panel.
///
/// A panel created while Mission Control is visible has not necessarily been
/// ordered into a Space yet. The app target must therefore perform the
/// `bindToCurrentSpaceWhileHidden` action before the Mission Control session
/// can end; checking `isOnActiveSpace` alone cannot create that association.
public enum PinPresentationPolicy {
    public enum Action: Equatable, Hashable, Sendable {
        /// Order the panel into the current Space invisibly, then order it out.
        /// The AppKit seam owns the alpha/orderFront/orderOut details.
        case bindToCurrentSpaceWhileHidden
        /// Remove a panel from the screen list while Mission Control is open.
        case hide
        /// Order a panel in because it is already associated with the active
        /// Space. This action must not move the panel between Spaces.
        case show
        /// Keep a panel hidden because presenting it would cross its Space.
        case remainHidden
    }

    /// The ordered actions needed when capture finishes and the panel becomes
    /// owned by the manager.
    public static func establishmentActions(
        missionControlVisible: Bool
    ) -> [Action] {
        missionControlVisible
            ? [.bindToCurrentSpaceWhileHidden]
            : [.show]
    }

    /// The ordered actions for one Mission Control visibility transition.
    /// `panelIsOnActiveSpace` is consulted only on exit, after the panel has
    /// either already been shown or been hidden-bound during establishment.
    public static func missionControlActions(
        visible: Bool,
        panelIsOnActiveSpace: Bool
    ) -> [Action] {
        if visible {
            return [.hide]
        }

        return panelIsOnActiveSpace ? [.show] : [.remainHidden]
    }
}
