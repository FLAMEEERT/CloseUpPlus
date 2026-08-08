import Foundation

/// Semantic pixel dimensions for a capture output. No ScreenCaptureKit type is
/// exposed from CloseUpKit.
public struct CapturePixelSize: Equatable, Hashable, Sendable {
    public let width: Int
    public let height: Int

    public init(width: Int, height: Int) {
        self.width = max(1, width)
        self.height = max(1, height)
    }
}

/// Independent lower and upper bounds for output dimensions.
public struct CapturePixelBounds: Equatable, Hashable, Sendable {
    public let minimum: CapturePixelSize
    public let maximum: CapturePixelSize

    public init(
        minimum: CapturePixelSize = CapturePixelSize(width: 1, height: 1),
        maximum: CapturePixelSize = CapturePixelSize(width: 8_192, height: 8_192)
    ) {
        self.minimum = CapturePixelSize(
            width: min(minimum.width, maximum.width),
            height: min(minimum.height, maximum.height)
        )
        self.maximum = CapturePixelSize(
            width: max(minimum.width, maximum.width),
            height: max(minimum.height, maximum.height)
        )
    }

    public static let standard = CapturePixelBounds()
}

public enum CapturePixelFormat: String, Equatable, Hashable, Sendable {
    case bgra
}

/// Visibility is the only input needed to choose how much capture work should
/// remain active. `.stopped` is used when the panel/session is being removed.
public enum CaptureVisibility: String, Equatable, Hashable, Sendable {
    case visible
    case hidden
    case stopped
}

public enum CaptureWork: String, Equatable, Hashable, Sendable {
    case active
    case reduced
    case stopped
}

/// A resize or display-scale change before it is turned into a framework
/// configuration. Keeping this value semantic lets platform code debounce it
/// without passing AppKit or ScreenCaptureKit objects into CloseUpKit.
public struct CaptureResizeRequest: Equatable, Hashable, Sendable {
    public let contentSize: CGSize
    public let backingScale: CGFloat
    public let visibility: CaptureVisibility

    public init(
        contentSize: CGSize,
        backingScale: CGFloat,
        visibility: CaptureVisibility = .visible
    ) {
        self.contentSize = contentSize
        self.backingScale = backingScale
        self.visibility = visibility
    }
}

/// A queued request gets a policy-owned revision so an older async completion
/// cannot finish a newer update.
public struct CaptureConfigurationRequest: Equatable, Hashable, Sendable {
    public let revision: UInt64
    public let contentSize: CGSize
    public let backingScale: CGFloat
    public let visibility: CaptureVisibility

    fileprivate init(revision: UInt64, resize: CaptureResizeRequest) {
        self.revision = revision
        self.contentSize = resize.contentSize
        self.backingScale = resize.backingScale
        self.visibility = resize.visibility
    }
}

/// The framework-free configuration passed to a platform adapter.
public struct CaptureConfiguration: Equatable, Hashable, Sendable {
    public let outputSize: CapturePixelSize
    public let pixelFormat: CapturePixelFormat
    public let capturesCursor: Bool
    public let capturesAudio: Bool
    public let maximumFramesPerSecond: Int
    public let preservesAspectRatio: Bool
    public let queueDepth: Int
    public let work: CaptureWork

    fileprivate init(
        outputSize: CapturePixelSize,
        queueDepth: Int,
        work: CaptureWork
    ) {
        self.outputSize = outputSize
        self.pixelFormat = .bgra
        self.capturesCursor = false
        self.capturesAudio = false
        self.maximumFramesPerSecond = CaptureConfigurationPolicy.maximumFramesPerSecond(for: work)
        self.preservesAspectRatio = true
        self.queueDepth = queueDepth
        self.work = work
    }
}

public enum CaptureConfigurationAction: Equatable, Hashable, Sendable {
    case none
    case apply(CaptureConfigurationRequest)

    public var request: CaptureConfigurationRequest? {
        guard case .apply(let request) = self else { return nil }
        return request
    }
}

public enum CaptureConfigurationEvent: Equatable, Hashable, Sendable {
    case resize(CaptureResizeRequest)
    case debounceElapsed
    case updateFinished(revision: UInt64, configuration: CaptureConfiguration)
}

/// Value state for the resize debounce/serialization policy.
public struct CaptureConfigurationState: Equatable, Hashable, Sendable {
    public let applied: CaptureConfiguration?
    public let pending: CaptureConfigurationRequest?
    public let inFlight: CaptureConfigurationRequest?
    public let isDebounceReady: Bool

    fileprivate let nextRevision: UInt64

    public init(applied: CaptureConfiguration? = nil) {
        self.applied = applied
        self.pending = nil
        self.inFlight = nil
        self.isDebounceReady = false
        self.nextRevision = 0
    }

    fileprivate init(
        applied: CaptureConfiguration?,
        pending: CaptureConfigurationRequest?,
        inFlight: CaptureConfigurationRequest?,
        isDebounceReady: Bool,
        nextRevision: UInt64
    ) {
        self.applied = applied
        self.pending = pending
        self.inFlight = inFlight
        self.isDebounceReady = isDebounceReady
        self.nextRevision = nextRevision
    }
}

public struct CaptureConfigurationDecision: Equatable, Hashable, Sendable {
    public let state: CaptureConfigurationState
    public let action: CaptureConfigurationAction

    fileprivate init(state: CaptureConfigurationState, action: CaptureConfigurationAction = .none) {
        self.state = state
        self.action = action
    }
}

/// Pure capture-resource and resize policy.
public enum CaptureConfigurationPolicy {
    public static let initialQueueDepth = 3
    public static let maximumQueueDepth = 5
    public static let maximumFramesPerSecond = 30
    /// Hidden panels keep their last rendered frame and a live session, but do
    /// not need foreground capture cadence. A non-zero interval is deliberate:
    /// ScreenCaptureKit remains safely restorable when the panel becomes visible.
    public static let reducedFramesPerSecond = 1

    /// Map semantic work to a bounded framework cadence. `.stopped` is kept at
    /// the reduced cadence if a caller constructs a stopped configuration; only
    /// the session teardown path is allowed to stop capture.
    public static func maximumFramesPerSecond(for work: CaptureWork) -> Int {
        switch work {
        case .active:
            maximumFramesPerSecond
        case .reduced, .stopped:
            reducedFramesPerSecond
        }
    }

    /// Convert points to pixels, rounding up so the output does not undershoot
    /// the useful mirror size, then clamp each axis independently.
    public static func outputPixelSize(
        contentSize: CGSize,
        backingScale: CGFloat,
        bounds: CapturePixelBounds = .standard
    ) -> CapturePixelSize {
        let width = boundedPixel(
            contentSize.width * backingScale,
            minimum: bounds.minimum.width,
            maximum: bounds.maximum.width
        )
        let height = boundedPixel(
            contentSize.height * backingScale,
            minimum: bounds.minimum.height,
            maximum: bounds.maximum.height
        )
        return CapturePixelSize(width: width, height: height)
    }

    public static func queueDepth(requested: Int = initialQueueDepth) -> Int {
        min(max(initialQueueDepth, requested), maximumQueueDepth)
    }

    public static func work(for visibility: CaptureVisibility) -> CaptureWork {
        switch visibility {
        case .visible:
            .active
        case .hidden:
            .reduced
        case .stopped:
            .stopped
        }
    }

    public static func configuration(
        for request: CaptureResizeRequest,
        queueDepth requestedQueueDepth: Int = initialQueueDepth,
        bounds: CapturePixelBounds = .standard
    ) -> CaptureConfiguration {
        CaptureConfiguration(
            outputSize: outputPixelSize(
                contentSize: request.contentSize,
                backingScale: request.backingScale,
                bounds: bounds
            ),
            queueDepth: queueDepth(requested: requestedQueueDepth),
            work: work(for: request.visibility)
        )
    }

    public static func configuration(
        for request: CaptureConfigurationRequest,
        queueDepth requestedQueueDepth: Int = initialQueueDepth,
        bounds: CapturePixelBounds = .standard
    ) -> CaptureConfiguration {
        configuration(
            for: CaptureResizeRequest(
                contentSize: request.contentSize,
                backingScale: request.backingScale,
                visibility: request.visibility
            ),
            queueDepth: requestedQueueDepth,
            bounds: bounds
        )
    }

    /// Reduce resize/debounce/completion events. The caller starts its timer
    /// when a `.resize` decision has a pending request, sends
    /// `.debounceElapsed` when that timer fires, and applies only the returned
    /// `.apply` action. A resize arriving during an update remains pending and
    /// is applied after the in-flight revision completes.
    public static func reduce(
        _ state: CaptureConfigurationState,
        event: CaptureConfigurationEvent
    ) -> CaptureConfigurationDecision {
        switch event {
        case .resize(let resize):
            let request = CaptureConfigurationRequest(
                revision: state.nextRevision,
                resize: resize
            )
            let next = CaptureConfigurationState(
                applied: state.applied,
                pending: request,
                inFlight: state.inFlight,
                isDebounceReady: false,
                nextRevision: state.nextRevision &+ 1
            )
            return CaptureConfigurationDecision(state: next)

        case .debounceElapsed:
            guard let pending = state.pending else {
                return CaptureConfigurationDecision(state: state)
            }

            if state.inFlight != nil {
                let next = CaptureConfigurationState(
                    applied: state.applied,
                    pending: pending,
                    inFlight: state.inFlight,
                    isDebounceReady: true,
                    nextRevision: state.nextRevision
                )
                return CaptureConfigurationDecision(state: next)
            }

            let next = CaptureConfigurationState(
                applied: state.applied,
                pending: nil,
                inFlight: pending,
                isDebounceReady: false,
                nextRevision: state.nextRevision
            )
            return CaptureConfigurationDecision(
                state: next,
                action: .apply(pending)
            )

        case .updateFinished(let revision, let configuration):
            guard let inFlight = state.inFlight, inFlight.revision == revision else {
                return CaptureConfigurationDecision(state: state)
            }

            if state.isDebounceReady, let pending = state.pending {
                let next = CaptureConfigurationState(
                    applied: configuration,
                    pending: nil,
                    inFlight: pending,
                    isDebounceReady: false,
                    nextRevision: state.nextRevision
                )
                return CaptureConfigurationDecision(
                    state: next,
                    action: .apply(pending)
                )
            }

            let next = CaptureConfigurationState(
                applied: configuration,
                pending: state.pending,
                inFlight: nil,
                isDebounceReady: false,
                nextRevision: state.nextRevision
            )
            return CaptureConfigurationDecision(state: next)
        }
    }

    private static func boundedPixel(_ rawValue: CGFloat, minimum: Int, maximum: Int) -> Int {
        guard rawValue.isFinite, rawValue > 0 else { return minimum }
        guard rawValue < CGFloat(maximum) else { return maximum }
        let rounded = Int(ceil(rawValue))
        return min(max(rounded, minimum), maximum)
    }
}
