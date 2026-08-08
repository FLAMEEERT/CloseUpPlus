import Testing

@testable import CloseUpKit

@Suite("PinLifecyclePolicy")
struct PinLifecyclePolicyTests {
    private let firstFrame = PinFrame(identifier: 1)
    private let secondFrame = PinFrame(identifier: 2)

    @Test("starts with a neutral placeholder")
    func initialState() {
        let lifecycle = PinLifecycle()

        #expect(lifecycle.state == .starting)
        #expect(lifecycle.content == .placeholder)
        #expect(lifecycle.lastFrame == nil)
    }

    @Test("a complete frame enters live and becomes the retained frame")
    func completeFrame() {
        let lifecycle = PinLifecyclePolicy.reduce(
            PinLifecycle(),
            event: .completeFrame(firstFrame)
        )

        #expect(lifecycle.state == .live)
        #expect(lifecycle.content == .live(firstFrame))
        #expect(lifecycle.lastFrame == firstFrame)
    }

    @Test("idle preserves the exact state, content, and last frame")
    func idlePreservesState() {
        let live = PinLifecyclePolicy.reduce(
            PinLifecycle(),
            event: .completeFrame(firstFrame)
        )
        let unavailable = PinLifecyclePolicy.reduce(live, event: .suspended)

        #expect(PinLifecyclePolicy.reduce(live, event: .idle) == live)
        #expect(PinLifecyclePolicy.reduce(unavailable, event: .idle) == unavailable)
    }

    @Test("blank and suspended output are temporary and keep the last frame")
    func temporaryUnavailability() {
        let live = PinLifecyclePolicy.reduce(
            PinLifecycle(),
            event: .completeFrame(firstFrame)
        )
        let blank = PinLifecyclePolicy.reduce(live, event: .blank)
        let suspended = PinLifecyclePolicy.reduce(live, event: .suspended)

        #expect(blank.state == .temporarilyUnavailable)
        #expect(blank.content == .temporarilyUnavailable(lastFrame: firstFrame, reason: .blank))
        #expect(blank.lastFrame == firstFrame)
        #expect(suspended.state == .temporarilyUnavailable)
        #expect(suspended.content == .temporarilyUnavailable(lastFrame: firstFrame, reason: .suspended))
        #expect(suspended.lastFrame == firstFrame)
    }

    @Test("temporary unavailability without a frame still exposes its reason")
    func temporaryUnavailabilityWithoutFrame() {
        let lifecycle = PinLifecyclePolicy.reduce(PinLifecycle(), event: .blank)

        #expect(lifecycle.state == .temporarilyUnavailable)
        #expect(lifecycle.content == .temporarilyUnavailable(lastFrame: nil, reason: .blank))
        #expect(lifecycle.lastFrame == nil)
    }

    @Test("a complete frame resumes a temporarily unavailable lifecycle")
    func resumesAfterTemporaryLoss() {
        let unavailable = PinLifecyclePolicy.reduce(
            PinLifecyclePolicy.reduce(PinLifecycle(), event: .completeFrame(firstFrame)),
            event: .suspended
        )
        let resumed = PinLifecyclePolicy.reduce(unavailable, event: .completeFrame(secondFrame))

        #expect(resumed.state == .live)
        #expect(resumed.content == .live(secondFrame))
        #expect(resumed.lastFrame == secondFrame)
    }

    @Test("unpin, source loss, permission failure, and permanent failure stop")
    func terminalEvents() {
        let events: [PinLifecycleEvent] = [
            .unpinRequested,
            .sourceEnded,
            .processEnded,
            .permissionFailure,
            .permissionRevoked,
            .permanentStreamFailure,
        ]

        for event in events {
            let lifecycle = PinLifecyclePolicy.reduce(
                PinLifecyclePolicy.reduce(PinLifecycle(), event: .completeFrame(firstFrame)),
                event: event
            )
            #expect(lifecycle.state == .stopping)
            #expect(lifecycle.content == .stopping)
            #expect(lifecycle.lastFrame == firstFrame)
        }
    }

    @Test("a late complete frame cannot revive a stopping lifecycle")
    func stoppingIsTerminal() {
        let stopping = PinLifecyclePolicy.reduce(
            PinLifecyclePolicy.reduce(PinLifecycle(), event: .completeFrame(firstFrame)),
            event: .sourceEnded
        )

        #expect(PinLifecyclePolicy.reduce(stopping, event: .completeFrame(secondFrame)) == stopping)
    }

    @Test("terminal events have precedence over concurrent frame events")
    func terminalEventPrecedence() {
        let lifecycle = PinLifecyclePolicy.reduce(
            PinLifecycle(),
            events: [.completeFrame(firstFrame), .sourceEnded, .completeFrame(secondFrame)]
        )

        #expect(lifecycle.state == .stopping)
        #expect(lifecycle.content == .stopping)
        #expect(lifecycle.lastFrame == nil)
    }
}
