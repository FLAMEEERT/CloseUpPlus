import Foundation

/// Pure lifecycle for switching a pinned window between its passive mirror and
/// the exact, interactive source window underneath it.
public enum PinnedWindowInteractionState: Equatable, Sendable {
    case mirroring
    case handingOff
    case interacting(outsideStableTicks: Int)
    case restoring
}

public enum PinnedWindowInteractionEvent: Equatable, Sendable {
    case pointerEntered
    case handoffSucceeded
    case handoffFailed
    case observation(pointerInsideSource: Bool, mouseButtonsPressed: Bool)
    case freshFrameDelivered
    case restoreTimedOut
}

public enum PinnedWindowInteractionAction: Equatable, Sendable {
    case beginHandoff
    case hideMirror
    case suspendCapture
    case adoptSourceFrame
    case resumeCapture
    case showMirror
    case scheduleRestoreFallback
    case cancelRestoreFallback
}

public struct PinnedWindowInteractionDecision: Equatable, Sendable {
    public let state: PinnedWindowInteractionState
    public let actions: [PinnedWindowInteractionAction]

    public init(
        state: PinnedWindowInteractionState,
        actions: [PinnedWindowInteractionAction]
    ) {
        self.state = state
        self.actions = actions
    }
}

public enum PinnedWindowInteractionPolicy {
    /// Two observations avoid restoring the mirror on a single noisy geometry
    /// sample while the source is being dragged or resized.
    public static let requiredOutsideStableTicks = 2

    public static func reduce(
        _ state: PinnedWindowInteractionState,
        event: PinnedWindowInteractionEvent
    ) -> PinnedWindowInteractionDecision {
        switch (state, event) {
        case (.mirroring, .pointerEntered):
            return .init(state: .handingOff, actions: [.beginHandoff])

        case (.handingOff, .handoffSucceeded):
            return .init(
                state: .interacting(outsideStableTicks: 0),
                actions: [.hideMirror, .suspendCapture]
            )

        case (.handingOff, .handoffFailed):
            return .init(state: .mirroring, actions: [])

        case (.interacting, .observation(let pointerInside, let buttonsPressed)):
            guard !pointerInside, !buttonsPressed else {
                return .init(
                    state: .interacting(outsideStableTicks: 0),
                    actions: [.adoptSourceFrame]
                )
            }

            let currentTicks: Int
            if case .interacting(let ticks) = state {
                currentTicks = ticks
            } else {
                currentTicks = 0
            }
            let nextTicks = currentTicks + 1
            if nextTicks >= requiredOutsideStableTicks {
                return .init(
                    state: .restoring,
                    actions: [
                        .adoptSourceFrame,
                        .resumeCapture,
                        .scheduleRestoreFallback,
                    ]
                )
            }
            return .init(
                state: .interacting(outsideStableTicks: nextTicks),
                actions: [.adoptSourceFrame]
            )

        case (.restoring, .freshFrameDelivered):
            return .init(
                state: .mirroring,
                actions: [.cancelRestoreFallback, .showMirror]
            )

        case (.restoring, .restoreTimedOut):
            return .init(state: .mirroring, actions: [.showMirror])

        case (.restoring, .observation(let pointerInside, let buttonsPressed))
            where pointerInside || buttonsPressed:
            return .init(
                state: .interacting(outsideStableTicks: 0),
                actions: [.cancelRestoreFallback, .suspendCapture]
            )

        default:
            return .init(state: state, actions: [])
        }
    }
}
