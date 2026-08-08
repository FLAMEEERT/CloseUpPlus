/// A control rendered in the Mission Control overlay.
///
/// Pinning is deliberately modeled outside `WindowAction`: the latter is the
/// AX-only action domain and remains the contract for Accessibility button
/// presses and keyboard shortcuts. `OverlayControl` is the display and hit-test
/// domain, so it can carry the pin toggle alongside the existing actions.
public enum OverlayControl: Equatable, Hashable, Identifiable, Sendable {
    case pin
    case unpin
    case pinning
    case unpinning
    case windowAction(WindowAction)

    /// The operation a click may execute. Progress controls have no executable
    /// operation while their manager transition is in flight.
    public enum ExecutionKind: Equatable, Hashable, Sendable {
        case pin
        case unpin
        case windowAction(WindowAction)
        case none
    }

    /// Stable identity for the overlay row. Every pin lifecycle state occupies
    /// the same hit-test slot, so replacing Pin with Unpin or a progress state
    /// cannot shift the existing AX controls.
    public var id: String {
        switch self {
        case .pin, .unpin, .pinning, .unpinning:
            "pin-toggle"
        case .windowAction(let action):
            "window-action.\(action.rawValue)"
        }
    }

    /// SF Symbol used by the display layer.
    public var symbolName: String {
        switch self {
        case .pin, .pinning:
            "pin"
        case .unpin, .unpinning:
            "pin.slash"
        case .windowAction(let action):
            action.symbolName
        }
    }

    /// Localization catalog key for the display layer's accessibility label and
    /// tooltip. The strings are keys, not user-facing interpolation.
    public var titleKey: String {
        switch self {
        case .pin:
            "Pin Window"
        case .unpin:
            "Unpin Window"
        case .pinning:
            "Pinning Window"
        case .unpinning:
            "Unpinning Window"
        case .windowAction(let action):
            action.titleKey
        }
    }

    public var executionKind: ExecutionKind {
        switch self {
        case .pin:
            .pin
        case .unpin:
            .unpin
        case .pinning, .unpinning:
            .none
        case .windowAction(let action):
            .windowAction(action)
        }
    }

    /// Whether a hit on this control is allowed to reach the execution layer.
    /// Pinning and Unpinning remain visible but disabled until the manager
    /// settles the corresponding transition.
    public var isEnabled: Bool {
        switch self {
        case .pin, .unpin, .windowAction:
            true
        case .pinning, .unpinning:
            false
        }
    }

    /// Whether Mission Control must begin exiting before this control starts
    /// its operation. A newly pinned mirror is deliberately hidden while
    /// Mission Control is visible, so Pin is the only control that needs this
    /// transition; Unpin and the existing window-management flow stay in place.
    public var exitsMissionControlBeforeExecution: Bool {
        self == .pin
    }

    public var action: WindowAction? {
        guard case .windowAction(let action) = self else { return nil }
        return action
    }
}

/// Runtime ownership state for one source window's pin session. A stopping
/// session still belongs to the manager, so it keeps the same stable first
/// control slot while showing disabled Unpinning progress.
public enum OverlayPinState: Equatable, Hashable, Sendable {
    case unpinned
    case pinning
    case pinned
    case unpinning

    public var control: OverlayControl {
        switch self {
        case .unpinned:
            .pin
        case .pinning:
            .pinning
        case .pinned:
            .unpin
        case .unpinning:
            .unpinning
        }
    }

    /// Whether the manager has established ownership or is still tearing it
    /// down. Unpin is only active after the state reaches `.pinned`.
    public var hasEstablishedOwnership: Bool {
        switch self {
        case .pinned, .unpinning:
            true
        case .unpinned, .pinning:
            false
        }
    }

    public func applying(_ event: OverlayPinEvent) -> Self {
        switch (self, event) {
        case (.unpinned, .startPinning):
            .pinning
        case (.pinning, .pinSucceeded):
            .pinned
        case (.pinning, .pinFailed):
            .unpinned
        case (.pinned, .startUnpinning):
            .unpinning
        case (.unpinning, .unpinSucceeded):
            .unpinned
        case (.unpinning, .unpinFailed):
            .pinned
        default:
            self
        }
    }
}

/// Events that advance the pure pin lifecycle model. Invalid or stale events
/// leave the current state unchanged, which keeps retries and duplicate manager
/// callbacks from changing ownership accidentally.
public enum OverlayPinEvent: Equatable, Hashable, Sendable {
    case startPinning
    case pinSucceeded
    case pinFailed
    case startUnpinning
    case unpinSucceeded
    case unpinFailed
}

/// Pure composition policy for the Mission Control display/hit-test model.
/// Existing AX eligibility is evaluated first through `OverlayCapabilityPolicy`:
/// authoritative `.resolved(.none)` stays dark for popups, auxiliary surfaces,
/// and native-full-screen windows; `.unavailable` preserves the legacy show-all
/// fallback; `.indeterminate` exposes no cluster while remaining retryable.
public enum OverlayControlPolicy {
    public static func controls(
        pinState: OverlayPinState,
        enabledActions: [WindowAction],
        capability: CapabilityResolution
    ) -> [OverlayControl] {
        let outcome = OverlayCapabilityPolicy.outcome(for: capability)

        let actions: [WindowAction]
        if let display = outcome.display {
            // `.none` is the existing authoritative rejection path. Do not add
            // Pin to an ineligible or native-full-screen thumbnail.
            guard display != .none else { return [] }
            actions = display.supported(from: enabledActions)
        } else {
            // AX-unavailable is intentionally the old fallback: all settings-
            // enabled actions remain visible, with Pin added independently.
            actions = enabledActions
        }

        return [pinState.control] + actions.map(OverlayControl.windowAction)
    }
}
