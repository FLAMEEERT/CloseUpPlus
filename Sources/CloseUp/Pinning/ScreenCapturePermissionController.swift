import CoreGraphics
import CloseUpKit

/// The non-prompting state observed by a caller before it attempts capture.
public enum ScreenCapturePermissionStatus: String, Equatable, Sendable {
    case authorized
    case notGranted
}

/// The result of an explicit screen-capture permission request.
public enum ScreenCapturePermissionOutcome: String, Equatable, Sendable {
    case alreadyAuthorized
    case authorized
    case denied
    case needsRetry
}

/// Owns screen-capture TCC checks without coupling them to Accessibility.
///
/// Construction and preflight never prompt. The request API is asynchronous so
/// callers can coalesce an already-pending explicit request, while the actual
/// CoreGraphics request remains isolated to that user-invoked method.
@MainActor
public final class ScreenCapturePermissionController {
    private var pendingRequest: Task<ScreenCapturePermissionOutcome, Never>?

    public init() {}

    /// Observe the current grant without prompting or changing state.
    public func preflight() -> ScreenCapturePermissionStatus {
        CGPreflightScreenCaptureAccess() ? .authorized : .notGranted
    }

    /// Request access after an explicit user action. This method never
    /// relaunches the app and stores no pending source selection.
    public func requestAccess() async -> ScreenCapturePermissionOutcome {
        if let pendingRequest {
            return await pendingRequest.value
        }

        if CGPreflightScreenCaptureAccess() {
            return .alreadyAuthorized
        }

        let request = Task { @MainActor [weak self] in
            self?.performExplicitRequest() ?? .needsRetry
        }
        pendingRequest = request
        let outcome = await request.value
        pendingRequest = nil
        return outcome
    }

    private func performExplicitRequest() -> ScreenCapturePermissionOutcome {
        let requestReturnedAccess = CGRequestScreenCaptureAccess()

        // A request can be accepted by the privacy service while the current
        // process still cannot use capture until it retries after a restart.
        let usableImmediately = CGPreflightScreenCaptureAccess()
        let outcome: ScreenCapturePermissionOutcome
        if usableImmediately {
            outcome = .authorized
        } else if requestReturnedAccess {
            outcome = .needsRetry
        } else {
            outcome = .denied
        }

        Log.pinning.notice(
            "screen capture permission outcome=\(outcome.rawValue, privacy: .public)"
        )
        return outcome
    }
}
