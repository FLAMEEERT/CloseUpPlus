import Foundation

/// A value-only identity for a successfully delivered mirror frame.
///
/// CloseUpKit deliberately does not carry a framework sample buffer through
/// this policy. Platform code can use its own frame object and publish a
/// monotonically increasing token here, while the reducer remains Sendable and
/// deterministic.
public struct PinFrame: Equatable, Hashable, Sendable {
    public let identifier: UInt64

    public init(identifier: UInt64) {
        self.identifier = identifier
    }
}

/// The four presentation states owned by one pinned-window session.
public enum PinLifecycleState: Equatable, Hashable, Sendable {
    case starting
    case live
    case temporarilyUnavailable
    case stopping
}

/// Why the capture is temporarily unavailable. These values are semantic
/// reasons; the app target is responsible for mapping them to localized copy.
public enum PinTemporaryUnavailableReason: Equatable, Hashable, Sendable {
    case blank
    case suspended
}

/// Pure content guidance for the renderer/panel layer.
public enum PinLifecycleContent: Equatable, Hashable, Sendable {
    case placeholder
    case live(PinFrame)
    case temporarilyUnavailable(lastFrame: PinFrame?, reason: PinTemporaryUnavailableReason)
    case stopping
}

/// Events accepted by the lifecycle reducer.
public enum PinLifecycleEvent: Equatable, Hashable, Sendable {
    case completeFrame(PinFrame)
    case idle
    case blank
    case suspended
    case sourceEnded
    case processEnded
    case permissionFailure
    case permissionRevoked
    case permanentStreamFailure
    case unpinRequested

    fileprivate var isTerminal: Bool {
        switch self {
        case .sourceEnded, .processEnded, .permissionFailure, .permissionRevoked,
             .permanentStreamFailure, .unpinRequested:
            true
        case .completeFrame, .idle, .blank, .suspended:
            false
        }
    }
}

/// The complete, value-based state consumed by the platform/session layer.
/// `lastFrame` remains available while a session is temporarily unavailable so
/// the panel can dim the previous image; stopping keeps that value only long
/// enough for teardown and can then be removed by the owner.
public struct PinLifecycle: Equatable, Hashable, Sendable {
    public let state: PinLifecycleState
    public let content: PinLifecycleContent
    public let lastFrame: PinFrame?

    public init() {
        self.state = .starting
        self.content = .placeholder
        self.lastFrame = nil
    }

    fileprivate init(
        state: PinLifecycleState,
        content: PinLifecycleContent,
        lastFrame: PinFrame?
    ) {
        self.state = state
        self.content = content
        self.lastFrame = lastFrame
    }
}

/// Pure Pin lifecycle reducer.
public enum PinLifecyclePolicy {
    /// Apply one event. Stopping is terminal: callbacks that arrive after an
    /// authoritative teardown, including a late complete frame, are ignored.
    public static func reduce(
        _ lifecycle: PinLifecycle,
        event: PinLifecycleEvent
    ) -> PinLifecycle {
        guard lifecycle.state != .stopping else { return lifecycle }

        switch event {
        case .completeFrame(let frame):
            return PinLifecycle(
                state: .live,
                content: .live(frame),
                lastFrame: frame
            )
        case .idle:
            // A static source is not a failed source. Preserve every field,
            // including temporary presentation content and its last frame.
            return lifecycle
        case .blank:
            return temporarilyUnavailable(
                from: lifecycle,
                reason: .blank
            )
        case .suspended:
            return temporarilyUnavailable(
                from: lifecycle,
                reason: .suspended
            )
        case .sourceEnded, .processEnded, .permissionFailure, .permissionRevoked,
             .permanentStreamFailure, .unpinRequested:
            return PinLifecycle(
                state: .stopping,
                content: .stopping,
                lastFrame: lifecycle.lastFrame
            )
        }
    }

    /// Reduce a batch of observations with explicit precedence. An
    /// authoritative terminal event wins over any complete/blank/idle event in
    /// the same delivery window, regardless of callback order. This models the
    /// source-loss-versus-late-frame race without relying on elapsed time.
    public static func reduce(
        _ lifecycle: PinLifecycle,
        events: [PinLifecycleEvent]
    ) -> PinLifecycle {
        if let terminal = events.first(where: { $0.isTerminal }) {
            return reduce(lifecycle, event: terminal)
        }

        return events.reduce(lifecycle) { current, event in
            reduce(current, event: event)
        }
    }

    private static func temporarilyUnavailable(
        from lifecycle: PinLifecycle,
        reason: PinTemporaryUnavailableReason
    ) -> PinLifecycle {
        PinLifecycle(
            state: .temporarilyUnavailable,
            content: .temporarilyUnavailable(lastFrame: lifecycle.lastFrame, reason: reason),
            lastFrame: lifecycle.lastFrame
        )
    }
}
