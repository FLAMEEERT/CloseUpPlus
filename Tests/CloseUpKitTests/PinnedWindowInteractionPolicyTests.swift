import Foundation
import Testing

@testable import CloseUpKit

@Suite("PinnedWindowInteractionPolicy")
struct PinnedWindowInteractionPolicyTests {
    @Test("pointer entry starts one source handoff")
    func pointerEntryStartsHandoff() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .mirroring,
            event: .pointerEntered
        )

        #expect(decision.state == .handingOff)
        #expect(decision.actions == [.beginHandoff])
        #expect(PinnedWindowInteractionPolicy.reduce(
            decision.state,
            event: .pointerEntered
        ).actions.isEmpty)
    }

    @Test("successful handoff hides the mirror and capture")
    func successfulHandoff() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .handingOff,
            event: .handoffSucceeded
        )

        #expect(decision.state == .interacting(outsideStableTicks: 0))
        #expect(decision.actions == [.hideMirror, .suspendCapture])
    }

    @Test("failed handoff returns to the existing mirror")
    func failedHandoff() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .handingOff,
            event: .handoffFailed
        )

        #expect(decision.state == .mirroring)
        #expect(decision.actions.isEmpty)
    }

    @Test("pressed mouse keeps source interaction alive outside its frame")
    func pressedMousePreventsRestore() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .interacting(outsideStableTicks: 1),
            event: .observation(pointerInsideSource: false, mouseButtonsPressed: true)
        )

        #expect(decision.state == .interacting(outsideStableTicks: 0))
        #expect(decision.actions == [.adoptSourceFrame])
    }

    @Test("two settled outside observations begin a fresh-frame restore")
    func settledExitBeginsRestore() {
        let first = PinnedWindowInteractionPolicy.reduce(
            .interacting(outsideStableTicks: 0),
            event: .observation(pointerInsideSource: false, mouseButtonsPressed: false)
        )
        let second = PinnedWindowInteractionPolicy.reduce(
            first.state,
            event: .observation(pointerInsideSource: false, mouseButtonsPressed: false)
        )

        #expect(first.state == .interacting(outsideStableTicks: 1))
        #expect(first.actions == [.adoptSourceFrame])
        #expect(second.state == .restoring)
        #expect(second.actions == [
            .adoptSourceFrame,
            .resumeCapture,
            .scheduleRestoreFallback,
        ])
    }

    @Test("returning inside resets the outside settle count")
    func returningInsideResetsSettle() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .interacting(outsideStableTicks: 1),
            event: .observation(pointerInsideSource: true, mouseButtonsPressed: false)
        )

        #expect(decision.state == .interacting(outsideStableTicks: 0))
        #expect(decision.actions == [.adoptSourceFrame])
    }

    @Test("a fresh captured frame reveals the mirror after the source handoff")
    func freshFrameCompletesRestore() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .restoring,
            event: .freshFrameDelivered
        )

        #expect(decision.state == .mirroring)
        #expect(decision.actions == [.cancelRestoreFallback, .showMirror])
    }

    @Test("restore has a bounded fallback when a static source emits no frame")
    func restoreTimeoutShowsMirror() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .restoring,
            event: .restoreTimedOut
        )

        #expect(decision.state == .mirroring)
        #expect(decision.actions == [.showMirror])
    }

    @Test("re-entering during restore keeps the real source interactive")
    func reenterDuringRestore() {
        let decision = PinnedWindowInteractionPolicy.reduce(
            .restoring,
            event: .observation(pointerInsideSource: true, mouseButtonsPressed: false)
        )

        #expect(decision.state == .interacting(outsideStableTicks: 0))
        #expect(decision.actions == [.cancelRestoreFallback, .suspendCapture])
    }
}
