import Foundation
import Testing

@testable import CloseUpKit

@Suite("CaptureConfigurationPolicy")
struct CaptureConfigurationPolicyTests {
    private let request = CaptureResizeRequest(
        contentSize: CGSize(width: 320, height: 180),
        backingScale: 2,
        visibility: .visible
    )

    @Test("output pixels are content size multiplied by backing scale")
    func outputPixelSize() {
        let pixels = CaptureConfigurationPolicy.outputPixelSize(
            contentSize: CGSize(width: 320, height: 180),
            backingScale: 2
        )

        #expect(pixels == CapturePixelSize(width: 640, height: 360))
    }

    @Test("output pixels are clamped to explicit safe bounds")
    func outputPixelBounds() {
        let bounds = CapturePixelBounds(
            minimum: CapturePixelSize(width: 16, height: 16),
            maximum: CapturePixelSize(width: 512, height: 256)
        )

        #expect(CaptureConfigurationPolicy.outputPixelSize(
            contentSize: CGSize(width: 1, height: 2),
            backingScale: 1,
            bounds: bounds
        ) == CapturePixelSize(width: 16, height: 16))
        #expect(CaptureConfigurationPolicy.outputPixelSize(
            contentSize: CGSize(width: 1_000, height: 1_000),
            backingScale: 2,
            bounds: bounds
        ) == CapturePixelSize(width: 512, height: 256))
        #expect(CaptureConfigurationPolicy.outputPixelSize(
            contentSize: .zero,
            backingScale: .nan,
            bounds: bounds
        ) == CapturePixelSize(width: 16, height: 16))
    }

    @Test("active configuration is local BGRA video at 30 fps with no cursor or audio")
    func activeConfiguration() {
        let configuration = CaptureConfigurationPolicy.configuration(for: request)

        #expect(configuration.outputSize == CapturePixelSize(width: 640, height: 360))
        #expect(configuration.pixelFormat == .bgra)
        #expect(!configuration.capturesCursor)
        #expect(!configuration.capturesAudio)
        #expect(configuration.maximumFramesPerSecond == 30)
        #expect(configuration.preservesAspectRatio)
        #expect(configuration.queueDepth == 3)
        #expect(configuration.work == .active)
    }

    @Test("visibility maps to active, reduced, and stopped work")
    func visibilityPolicy() {
        for (visibility, work) in [
            (CaptureVisibility.visible, CaptureWork.active),
            (.hidden, .reduced),
            (.stopped, .stopped),
        ] {
            let configuration = CaptureConfigurationPolicy.configuration(for: CaptureResizeRequest(
                contentSize: request.contentSize,
                backingScale: request.backingScale,
                visibility: visibility
            ))
            #expect(configuration.work == work)
        }
    }

    @Test("capture frame rate follows work without stopping the session")
    func frameRatePolicy() {
        let configurations = [
            CaptureVisibility.visible,
            .hidden,
            .stopped,
        ].reduce(into: [CaptureVisibility: CaptureConfiguration]()) {
            result, visibility in
            result[visibility] = CaptureConfigurationPolicy.configuration(for: CaptureResizeRequest(
                contentSize: request.contentSize,
                backingScale: request.backingScale,
                visibility: visibility
            ))
        }

        #expect(configurations[.visible]?.maximumFramesPerSecond == 30)
        #expect(configurations[.hidden]?.maximumFramesPerSecond == 1)
        #expect(configurations[.stopped]?.maximumFramesPerSecond == 1)
    }

    @Test("queue depth starts at three and is limited to five")
    func queueDepthPolicy() {
        #expect(CaptureConfigurationPolicy.queueDepth() == 3)
        #expect(CaptureConfigurationPolicy.queueDepth(requested: 2) == 3)
        #expect(CaptureConfigurationPolicy.queueDepth(requested: 4) == 4)
        #expect(CaptureConfigurationPolicy.queueDepth(requested: 99) == 5)
    }

    @Test("resize debounce keeps only the newest request")
    func resizeDebounce() throws {
        let first = CaptureConfigurationPolicy.reduce(
            CaptureConfigurationState(),
            event: .resize(request)
        )
        let secondRequest = CaptureResizeRequest(
            contentSize: CGSize(width: 640, height: 360),
            backingScale: 2,
            visibility: .visible
        )
        let second = CaptureConfigurationPolicy.reduce(
            first.state,
            event: .resize(secondRequest)
        )
        let decision = CaptureConfigurationPolicy.reduce(
            second.state,
            event: .debounceElapsed
        )

        let applied = try #require(decision.action.request)
        #expect(applied.contentSize == secondRequest.contentSize)
        #expect(applied.revision > (first.state.pending?.revision ?? 0))
        #expect(decision.state.pending == nil)
        #expect(decision.state.inFlight?.revision == applied.revision)
    }

    @Test("resize during an update is serialized and applies newest-wins after completion")
    func serializedResize() throws {
        let started = CaptureConfigurationPolicy.reduce(
            CaptureConfigurationPolicy.reduce(
                CaptureConfigurationPolicy.reduce(
                    CaptureConfigurationState(),
                    event: .resize(request)
                ).state,
                event: .debounceElapsed
            ).state,
            event: .resize(CaptureResizeRequest(
                contentSize: CGSize(width: 800, height: 450),
                backingScale: 1,
                visibility: .hidden
            ))
        )
        let waiting = CaptureConfigurationPolicy.reduce(started.state, event: .debounceElapsed)
        let inFlightRevision = try #require(started.state.inFlight?.revision)
        let finished = CaptureConfigurationPolicy.reduce(
            waiting.state,
            event: .updateFinished(
                revision: inFlightRevision,
                configuration: CaptureConfigurationPolicy.configuration(for: request)
            )
        )

        let next = try #require(finished.action.request)
        #expect(next.contentSize == CGSize(width: 800, height: 450))
        #expect(next.visibility == .hidden)
        #expect(finished.state.inFlight?.revision == next.revision)
        #expect(finished.state.pending == nil)
    }

    @Test("stale update completion cannot finish a newer serialized update")
    func staleCompletion() throws {
        let started = CaptureConfigurationPolicy.reduce(
            CaptureConfigurationPolicy.reduce(
                CaptureConfigurationState(),
                event: .resize(request)
            ).state,
            event: .debounceElapsed
        )
        let state = started.state
        let revision = try #require(state.inFlight?.revision)
        let stale = CaptureConfigurationPolicy.reduce(
            state,
            event: .updateFinished(
                revision: revision + 1,
                configuration: CaptureConfigurationPolicy.configuration(for: request)
            )
        )

        #expect(stale.action == .none)
        #expect(stale.state == state)
    }
}
