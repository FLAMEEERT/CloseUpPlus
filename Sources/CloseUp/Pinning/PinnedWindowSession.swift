import AVFoundation
import CloseUpKit
import CoreMedia
import Foundation
import ScreenCaptureKit

public enum PinnedWindowStopReason: String, Equatable, Sendable {
    case userRequested
    case sourceEnded
    case processEnded
    case permissionDenied
    case permissionRevoked
    case systemStopped
    case internalFailure
}

public enum PinnedWindowSampleStatus: String, Equatable, Sendable {
    case complete
    case idle
    case blank
    case suspended
}

/// Main-actor semantic signals consumed by the future multi-session manager.
/// Sample buffers themselves never appear here. Status/frame signals are
/// semantic-edge notifications; the renderer still receives every complete
/// sample buffer.
public enum PinnedWindowSessionSignal: Equatable, Sendable {
    case lifecycleChanged(PinLifecycleState)
    case sampleStatus(PinnedWindowSampleStatus)
    case frameDelivered(PinFrame)
    case temporarilyUnavailable(PinTemporaryUnavailableReason)
    case streamActivityChanged(active: Bool)
    case configurationApplied(revision: UInt64, outputSize: CapturePixelSize)
    case configurationFailed(revision: UInt64, domain: String, code: Int)
    case stopped(PinnedWindowStopReason)
}

private struct StreamErrorDetails: Sendable {
    let domain: String
    let code: Int

    init(_ error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
    }
}

private enum StreamOutputEvent: Sendable {
    case complete
    case idle
    case blank
    case suspended
    case invalidFrame
    case rendererFailed
}

private enum StreamDelegateEvent: Sendable {
    case stopped(StreamErrorDetails)
    case active
    case inactive
}

/// One exact source, one stream, one serial output queue, and one renderer.
/// The object is deliberately independent from any eventual NSPanel or
/// Mission Control lifecycle.
@MainActor
public final class PinnedWindowSession {
    public let sourceKey: ScreenCaptureSourceKey
    public let outputQueue: DispatchQueue
    public let frameRenderer: PinnedWindowFrameRenderer

    public private(set) var generation: UInt64 = 0
    public private(set) var lifecycle = PinLifecycle()
    public private(set) var lastConfiguration: CaptureConfiguration?

    public var onSignal: ((PinnedWindowSessionSignal) -> Void)?

    private let source: ScreenCaptureWindowSource
    private var stream: SCStream?
    private var streamOutput: StreamOutput?
    private var streamDelegate: StreamDelegate?
    private var configurationState = CaptureConfigurationState()
    private var configurationDebounce: DispatchWorkItem?
    private var nextFrameIdentifier: UInt64 = 0

    public init(
        source: ScreenCaptureWindowSource,
        frameRenderer: PinnedWindowFrameRenderer,
        outputQueue: DispatchQueue = DispatchQueue(
            label: "com.oomol.CloseUp.pinned-window-output",
            qos: .userInitiated
        ),
        onSignal: ((PinnedWindowSessionSignal) -> Void)? = nil
    ) {
        self.source = source
        self.sourceKey = source.key
        self.frameRenderer = frameRenderer
        self.outputQueue = outputQueue
        self.onSignal = onSignal
    }

    /// Start is idempotent for the lifetime of this session.
    public func start() {
        guard stream == nil, lifecycle.state != .stopping else { return }

        generation &+= 1
        let activeGeneration = generation
        emit(.lifecycleChanged(.starting))
        Log.pinning.notice(
            "session start window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) generation=\(activeGeneration, privacy: .public)"
        )

        let initialRequest = CaptureResizeRequest(
            contentSize: source.contentSize,
            backingScale: source.backingScale,
            visibility: .visible
        )
        let queued = CaptureConfigurationPolicy.reduce(
            configurationState,
            event: .resize(initialRequest)
        )
        let initial = CaptureConfigurationPolicy.reduce(
            queued.state,
            event: .debounceElapsed
        )
        configurationState = initial.state

        guard let request = initial.action.request else {
            terminate(reason: .internalFailure, requestCaptureStop: false)
            return
        }

        let semanticConfiguration = CaptureConfigurationPolicy.configuration(for: request)
        let streamConfiguration = makeStreamConfiguration(semanticConfiguration)
        let output = StreamOutput(
            renderer: frameRenderer,
            deliver: { [weak self] event in
                Task { @MainActor [weak self] in
                    self?.receive(event, generation: activeGeneration)
                }
            }
        )
        let delegate = StreamDelegate { [weak self] event in
            Task { @MainActor [weak self] in
                self?.receive(event, generation: activeGeneration)
            }
        }
        let stream = SCStream(
            filter: source.contentFilter,
            configuration: streamConfiguration,
            delegate: delegate
        )

        self.stream = stream
        self.streamOutput = output
        self.streamDelegate = delegate

        do {
            try stream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
        } catch {
            let details = StreamErrorDetails(error)
            Log.pinning.error(
                "stream output setup failed window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) domain=\(details.domain, privacy: .public) code=\(details.code, privacy: .public)"
            )
            terminate(reason: .internalFailure, requestCaptureStop: false)
            return
        }

        stream.startCapture { [weak self] error in
            let details = error.map(StreamErrorDetails.init)
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(generation: activeGeneration) else { return }
                if let details {
                    self.receive(.stopped(details), generation: activeGeneration)
                    return
                }

                self.finishConfiguration(
                    revision: request.revision,
                    configuration: semanticConfiguration,
                    generation: activeGeneration
                )
                Log.pinning.notice(
                    "session live window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) generation=\(activeGeneration, privacy: .public) output=\(semanticConfiguration.outputSize.width, privacy: .public)x\(semanticConfiguration.outputSize.height, privacy: .public) revision=\(request.revision, privacy: .public)"
                )
            }
        }
    }

    /// Stop is idempotent and invalidates the current generation before any
    /// asynchronous stream teardown can deliver late callbacks.
    public func stop() {
        terminate(reason: .userRequested, requestCaptureStop: true)
    }

    /// U5 supplies authoritative lifecycle observations from NSWorkspace and
    /// periodic exact source checks.
    public func sourceEnded() {
        terminate(reason: .sourceEnded, requestCaptureStop: true)
    }

    public func processEnded() {
        terminate(reason: .processEnded, requestCaptureStop: true)
    }

    public func permissionRevoked() {
        terminate(reason: .permissionRevoked, requestCaptureStop: true)
    }

    /// Feed the U2 newest-wins resize policy. The stream receives at most one
    /// serialized update per debounce completion, not one update per resize.
    public func requestResize(
        contentSize: CGSize,
        backingScale: CGFloat,
        visibility: CaptureVisibility = .visible
    ) {
        guard lifecycle.state != .stopping else { return }
        let decision = CaptureConfigurationPolicy.reduce(
            configurationState,
            event: .resize(CaptureResizeRequest(
                contentSize: contentSize,
                backingScale: backingScale,
                visibility: visibility
            ))
        )
        configurationState = decision.state
        scheduleConfigurationDebounce()
    }

    /// Force the next complete sample to cross the semantic signal boundary.
    /// Normal complete frames are coalesced, but mirror restoration must wait
    /// for one frame captured after foreground cadence is requested.
    public func requestFreshFrameSignal() {
        guard lifecycle.state != .stopping else { return }
        streamOutput?.requestNextCompleteDelivery()
    }

    private func receive(_ event: StreamOutputEvent, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }

        switch event {
        case .complete:
            nextFrameIdentifier &+= 1
            let frame = PinFrame(identifier: nextFrameIdentifier)
            apply(.completeFrame(frame))
            emit(.sampleStatus(.complete))
            emit(.frameDelivered(frame))
        case .idle:
            // No lifecycle event: a static source keeps the existing image.
            emit(.sampleStatus(.idle))
        case .blank:
            apply(.blank)
            emit(.sampleStatus(.blank))
            emit(.temporarilyUnavailable(.blank))
        case .suspended:
            apply(.suspended)
            emit(.sampleStatus(.suspended))
            emit(.temporarilyUnavailable(.suspended))
        case .invalidFrame, .rendererFailed:
            terminate(reason: .internalFailure, requestCaptureStop: true)
        }
    }

    private func receive(_ event: StreamDelegateEvent, generation: UInt64) {
        guard isCurrent(generation: generation) else { return }

        switch event {
        case .stopped(let details):
            let reason = stopReason(for: details)
            Log.pinning.error(
                "stream stopped window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) reason=\(reason.rawValue, privacy: .public) domain=\(details.domain, privacy: .public) code=\(details.code, privacy: .public)"
            )
            terminate(reason: reason, requestCaptureStop: false)
        case .active:
            emit(.streamActivityChanged(active: true))
        case .inactive:
            // On macOS 14 this signal does not exist; U5 combines the newer
            // callback with process/source checks before deciding to unpin.
            emit(.streamActivityChanged(active: false))
        }
    }

    private func apply(_ event: PinLifecycleEvent) {
        let previous = lifecycle
        let next = PinLifecyclePolicy.reduce(previous, event: event)
        guard next != previous else { return }
        lifecycle = next

        // The renderer displays every complete sample, but a live panel does
        // not need a main-actor presentation update for every new frame token.
        // Temporary-reason changes remain semantic even when the broad state is
        // still `.temporarilyUnavailable`.
        let shouldNotify: Bool
        switch event {
        case .completeFrame:
            shouldNotify = previous.state != next.state
        case .idle:
            shouldNotify = false
        case .blank, .suspended:
            shouldNotify = previous.state != next.state
                || previous.content != next.content
        case .sourceEnded, .processEnded, .permissionFailure,
             .permissionRevoked, .permanentStreamFailure, .unpinRequested:
            shouldNotify = previous.state != next.state
        }
        guard shouldNotify else { return }
        emit(.lifecycleChanged(next.state))
    }

    private func finishConfiguration(
        revision: UInt64,
        configuration: CaptureConfiguration,
        generation: UInt64
    ) {
        guard isCurrent(generation: generation) else { return }
        let decision = CaptureConfigurationPolicy.reduce(
            configurationState,
            event: .updateFinished(revision: revision, configuration: configuration)
        )
        configurationState = decision.state
        lastConfiguration = configuration
        emit(.configurationApplied(revision: revision, outputSize: configuration.outputSize))

        if let nextRequest = decision.action.request {
            applyConfiguration(nextRequest, generation: generation)
        }
    }

    private func scheduleConfigurationDebounce() {
        configurationDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycle.state != .stopping else { return }
                let decision = CaptureConfigurationPolicy.reduce(
                    self.configurationState,
                    event: .debounceElapsed
                )
                self.configurationState = decision.state
                if let request = decision.action.request {
                    self.applyConfiguration(request, generation: self.generation)
                }
            }
        }
        configurationDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: work)
    }

    private func applyConfiguration(
        _ request: CaptureConfigurationRequest,
        generation: UInt64
    ) {
        guard let stream, isCurrent(generation: generation) else { return }
        let configuration = CaptureConfigurationPolicy.configuration(for: request)
        let streamConfiguration = makeStreamConfiguration(configuration)
        Log.pinning.debug(
            "stream configuration window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) generation=\(generation, privacy: .public) revision=\(request.revision, privacy: .public) output=\(configuration.outputSize.width, privacy: .public)x\(configuration.outputSize.height, privacy: .public)"
        )
        stream.updateConfiguration(streamConfiguration) { [weak self] error in
            let details = error.map(StreamErrorDetails.init)
            Task { @MainActor [weak self] in
                guard let self, self.isCurrent(generation: generation) else { return }
                if let details {
                    self.emit(.configurationFailed(
                        revision: request.revision,
                        domain: details.domain,
                        code: details.code
                    ))
                    self.terminate(reason: .internalFailure, requestCaptureStop: true)
                    return
                }
                self.finishConfiguration(
                    revision: request.revision,
                    configuration: configuration,
                    generation: generation
                )
            }
        }
    }

    private func terminate(reason: PinnedWindowStopReason, requestCaptureStop: Bool) {
        guard lifecycle.state != .stopping else { return }

        generation &+= 1
        configurationDebounce?.cancel()
        configurationDebounce = nil

        let currentStream = stream
        let currentOutput = streamOutput
        stream = nil
        streamOutput = nil
        streamDelegate = nil

        switch reason {
        case .userRequested:
            apply(.unpinRequested)
        case .sourceEnded:
            apply(.sourceEnded)
        case .processEnded:
            apply(.processEnded)
        case .permissionDenied:
            apply(.permissionFailure)
        case .permissionRevoked:
            apply(.permissionRevoked)
        case .systemStopped, .internalFailure:
            apply(.permanentStreamFailure)
        }

        if let currentStream, let currentOutput {
            try? currentStream.removeStreamOutput(currentOutput, type: .screen)
        }
        if requestCaptureStop, let currentStream {
            currentStream.stopCapture { error in
                if let error {
                    let details = StreamErrorDetails(error)
                    Log.pinning.debug(
                        "stream stop completion window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) domain=\(details.domain, privacy: .public) code=\(details.code, privacy: .public)"
                    )
                }
            }
        }

        // Keep renderer operations ordered after any queued sample delivery.
        let renderer = frameRenderer
        outputQueue.async {
            renderer.reset(removeDisplayedImage: true)
        }

        Log.pinning.notice(
            "session stopped window=\(self.sourceKey.windowID, privacy: .public) pid=\(self.sourceKey.ownerPID, privacy: .public) reason=\(reason.rawValue, privacy: .public)"
        )
        emit(.stopped(reason))
    }

    private func isCurrent(generation: UInt64) -> Bool {
        stream != nil && self.generation == generation && lifecycle.state != .stopping
    }

    private func makeStreamConfiguration(
        _ configuration: CaptureConfiguration
    ) -> SCStreamConfiguration {
        let streamConfiguration = SCStreamConfiguration()
        streamConfiguration.width = configuration.outputSize.width
        streamConfiguration.height = configuration.outputSize.height
        streamConfiguration.pixelFormat = kCVPixelFormatType_32BGRA
        streamConfiguration.showsCursor = false
        streamConfiguration.capturesAudio = false
        // The pure policy maps Mission Control-hidden panels to a bounded 1 fps
        // refresh while retaining the stream and renderer's last frame. A
        // stopped semantic configuration is still non-zero here; teardown owns
        // `stopCapture`, so a resize/visibility update cannot silently kill the
        // session.
        let framesPerSecond = max(1, configuration.maximumFramesPerSecond)
        streamConfiguration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(framesPerSecond)
        )
        streamConfiguration.preservesAspectRatio = configuration.preservesAspectRatio
        streamConfiguration.queueDepth = configuration.queueDepth
        streamConfiguration.scalesToFit = true
        return streamConfiguration
    }

    private func stopReason(for details: StreamErrorDetails) -> PinnedWindowStopReason {
        switch details.code {
        case SCStreamError.userDeclined.rawValue,
             SCStreamError.missingEntitlements.rawValue:
            .permissionDenied
        case SCStreamError.failedApplicationConnectionInvalid.rawValue,
             SCStreamError.failedNoMatchingApplicationContext.rawValue,
             SCStreamError.noCaptureSource.rawValue:
            .sourceEnded
        case SCStreamError.failedApplicationConnectionInterrupted.rawValue,
             SCStreamError.userStopped.rawValue:
            .systemStopped
        default:
            .internalFailure
        }
    }

    private func emit(_ signal: PinnedWindowSessionSignal) {
        onSignal?(signal)
    }
}

private final class StreamOutput: NSObject, SCStreamOutput {
    private let renderer: PinnedWindowFrameRenderer
    private let deliver: @Sendable (StreamOutputEvent) -> Void
    private let semanticStatusLock = NSLock()
    private var lastDeliveredSemanticStatus: PinnedWindowSampleStatus?
    private var failureEventDelivered = false

    init(
        renderer: PinnedWindowFrameRenderer,
        deliver: @escaping @Sendable (StreamOutputEvent) -> Void
    ) {
        self.renderer = renderer
        self.deliver = deliver
    }

    func requestNextCompleteDelivery() {
        semanticStatusLock.lock()
        lastDeliveredSemanticStatus = nil
        semanticStatusLock.unlock()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen else { return }
        guard let status = Self.status(in: sampleBuffer) else {
            deliverFailureIfNeeded(.invalidFrame)
            return
        }

        switch status {
        case .complete:
            guard renderer.enqueue(sampleBuffer) else {
                deliverFailureIfNeeded(.rendererFailed)
                return
            }
            deliverIfSemanticStatusChanged(.complete, event: .complete)
        case .idle:
            deliverIfSemanticStatusChanged(.idle, event: .idle)
        case .blank:
            deliverIfSemanticStatusChanged(.blank, event: .blank)
        case .suspended:
            deliverIfSemanticStatusChanged(.suspended, event: .suspended)
        case .started, .stopped:
            break
        @unknown default:
            deliverFailureIfNeeded(.invalidFrame)
        }
    }

    private func deliverFailureIfNeeded(_ event: StreamOutputEvent) {
        semanticStatusLock.lock()
        let shouldDeliver = !failureEventDelivered
        if shouldDeliver {
            failureEventDelivered = true
        }
        semanticStatusLock.unlock()

        guard shouldDeliver else { return }
        deliver(event)
    }

    /// ScreenCaptureKit can report many complete samples while the semantic
    /// presentation remains live. Keep enqueueing all of them, but cross the
    /// actor boundary only on a semantic status transition. The lock also
    /// keeps this safe if a caller supplies a concurrent sample-handler queue.
    private func deliverIfSemanticStatusChanged(
        _ status: PinnedWindowSampleStatus,
        event: StreamOutputEvent
    ) {
        semanticStatusLock.lock()
        let changed = lastDeliveredSemanticStatus != status
        if changed {
            lastDeliveredSemanticStatus = status
        }
        semanticStatusLock.unlock()

        guard changed else { return }
        deliver(event)
    }

    private static func status(in sampleBuffer: CMSampleBuffer) -> ScreenCaptureFrameStatus? {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
        let status = ScreenCaptureFrameStatus.decode(
            attachments.first?[SCStreamFrameInfo.status]
        )
        else {
            return nil
        }
        return status
    }
}

private final class StreamDelegate: NSObject, SCStreamDelegate {
    private let deliver: @Sendable (StreamDelegateEvent) -> Void

    init(deliver: @escaping @Sendable (StreamDelegateEvent) -> Void) {
        self.deliver = deliver
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        deliver(.stopped(StreamErrorDetails(error)))
    }

    @available(macOS 15.2, *)
    func streamDidBecomeActive(_ stream: SCStream) {
        deliver(.active)
    }

    @available(macOS 15.2, *)
    func streamDidBecomeInactive(_ stream: SCStream) {
        deliver(.inactive)
    }
}
