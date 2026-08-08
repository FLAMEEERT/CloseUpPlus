import CoreGraphics
import Foundation
import ScreenCaptureKit

import CloseUpKit

/// Stable source identity. A window number by itself is not sufficient because
/// WindowServer can reuse it for a different process.
public struct ScreenCaptureSourceKey: Equatable, Hashable, Sendable {
    public let windowID: CGWindowID
    public let ownerPID: pid_t

    public init(windowID: CGWindowID, ownerPID: pid_t) {
        self.windowID = windowID
        self.ownerPID = ownerPID
    }
}

/// Semantic failures from the ScreenCaptureKit discovery seam.
public enum ScreenCaptureWindowResolutionFailure: Equatable, Sendable {
    case notFound(source: ScreenCaptureSourceKey)
    case ownerMismatch(source: ScreenCaptureSourceKey, observedPIDs: [pid_t])
    case permissionDenied
    case discoveryFailed(domain: String, code: Int)
}

private enum ScreenCaptureDiscoveryResult {
    case success(SCShareableContent)
    case failure(ScreenCaptureWindowResolutionFailure)
}

public enum ScreenCaptureWindowResolution {
    case matched(ScreenCaptureWindowSource)
    case failed(ScreenCaptureWindowResolutionFailure)
}

/// The exact SCWindow/filter pair plus semantic sizing information needed to
/// configure a single-window stream. The platform objects stay main-actor
/// isolated and are never sent through the frame pipeline.
@MainActor
public final class ScreenCaptureWindowSource {
    public let key: ScreenCaptureSourceKey
    public let window: SCWindow
    public let contentFilter: SCContentFilter
    public let contentSize: CGSize
    public let backingScale: CGFloat

    public var aspectRatio: CGFloat {
        guard contentSize.width > 0, contentSize.height > 0 else { return 1 }
        return contentSize.width / contentSize.height
    }

    fileprivate init(
        key: ScreenCaptureSourceKey,
        window: SCWindow,
        contentFilter: SCContentFilter,
        contentSize: CGSize,
        backingScale: CGFloat
    ) {
        self.key = key
        self.window = window
        self.contentFilter = contentFilter
        self.contentSize = contentSize
        self.backingScale = backingScale
    }
}

/// Discovers one exact window from ScreenCaptureKit, including off-screen
/// windows so an existing Pin can recover after a Space or visibility change.
@MainActor
public final class ScreenCaptureWindowResolver {
    private let preflight: @Sendable () -> Bool

    public init(
        preflight: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() }
    ) {
        self.preflight = preflight
    }

    /// Resolve by both CGWindowID and owner PID. No display crop, app-wide
    /// filter, or fallback source is constructed on a failed match.
    public func resolve(
        source key: ScreenCaptureSourceKey
    ) async -> ScreenCaptureWindowResolution {
        switch await discoverContent() {
        case .success(let content):
            return resolve(key: key, in: content)
        case .failure(let failure):
            return failed(failure, for: key)
        }
    }

    /// Resolve several exact sources against one ScreenCaptureKit snapshot.
    /// This is used by the liveness monitor; startup intentionally continues to
    /// call the single-source API above so its behavior and call shape remain
    /// unchanged.
    public func resolve(
        sources keys: [ScreenCaptureSourceKey]
    ) async -> [ScreenCaptureSourceKey: ScreenCaptureWindowResolution] {
        let uniqueKeys = Array(Set(keys))
        guard !uniqueKeys.isEmpty else { return [:] }

        switch await discoverContent() {
        case .success(let content):
            return Dictionary(uniqueKeysWithValues: uniqueKeys.map { key in
                (key, resolve(key: key, in: content))
            })
        case .failure(let failure):
            return Dictionary(uniqueKeysWithValues: uniqueKeys.map { key in
                (key, failed(failure, for: key))
            })
        }
    }

    private func discoverContent() async -> ScreenCaptureDiscoveryResult {
        guard preflight() else {
            return .failure(.permissionDenied)
        }

        do {
            // Keep onScreenWindowsOnly false: an off-screen source can return
            // when a pinned window is restored or a Space becomes visible.
            return .success(try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            ))
        } catch {
            let details = NSErrorDetails(error)
            if details.isPermissionDenied {
                return .failure(.permissionDenied)
            }
            return .failure(.discoveryFailed(domain: details.domain, code: details.code))
        }
    }

    private func resolve(
        key: ScreenCaptureSourceKey,
        in content: SCShareableContent
    ) -> ScreenCaptureWindowResolution {
        let sameID = content.windows.filter { $0.windowID == key.windowID }
        guard !sameID.isEmpty else {
            Log.pinning.notice(
                "source not found window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public)"
            )
            return .failed(.notFound(source: key))
        }

        guard let matchedWindow = sameID.first(where: {
            $0.owningApplication?.processID == key.ownerPID
        }) else {
            let observedPIDs = Array(
                Set(sameID.compactMap { $0.owningApplication?.processID })
            ).sorted()
            Log.pinning.notice(
                "source owner mismatch window=\(key.windowID, privacy: .public) expectedPID=\(key.ownerPID, privacy: .public) observedPIDs=\(observedPIDs, privacy: .public)"
            )
            return .failed(.ownerMismatch(source: key, observedPIDs: observedPIDs))
        }

        // Construct the exact-window filter only after both identity parts
        // match. This intentionally does not fall back to a display crop.
        let contentFilter = SCContentFilter(desktopIndependentWindow: matchedWindow)
        let info = SCShareableContent.info(for: contentFilter)
        let contentSize = validContentSize(info.contentRect.size, fallback: matchedWindow.frame.size)
        let backingScale = validBackingScale(CGFloat(info.pointPixelScale))

        Log.pinning.notice(
            "source matched window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public) content=\(Int(contentSize.width), privacy: .public)x\(Int(contentSize.height), privacy: .public) scale=\(backingScale, privacy: .public)"
        )
        return .matched(
            ScreenCaptureWindowSource(
                key: key,
                window: matchedWindow,
                contentFilter: contentFilter,
                contentSize: contentSize,
                backingScale: backingScale
            )
        )
    }

    private func failed(
        _ failure: ScreenCaptureWindowResolutionFailure,
        for key: ScreenCaptureSourceKey
    ) -> ScreenCaptureWindowResolution {
        switch failure {
        case .permissionDenied:
            Log.pinning.notice(
                "source resolve denied window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public)"
            )
        case .discoveryFailed(let domain, let code):
            Log.pinning.error(
                "source discovery failed window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public) domain=\(domain, privacy: .public) code=\(code, privacy: .public)"
            )
        case .notFound, .ownerMismatch:
            break
        }
        return .failed(failure)
    }

    private func validContentSize(_ size: CGSize, fallback: CGSize) -> CGSize {
        let candidate = size.width > 0 && size.height > 0 ? size : fallback
        guard candidate.width > 0, candidate.height > 0,
              candidate.width.isFinite, candidate.height.isFinite
        else {
            return CGSize(width: 1, height: 1)
        }
        return candidate
    }

    private func validBackingScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite, scale > 0 else { return 1 }
        return scale
    }
}

private struct NSErrorDetails: Sendable {
    let domain: String
    let code: Int
    let isPermissionDenied: Bool

    init(_ error: Error) {
        let nsError = error as NSError
        domain = nsError.domain
        code = nsError.code
        isPermissionDenied = nsError.domain == SCStreamErrorDomain
            && nsError.code == SCStreamError.userDeclined.rawValue
    }
}
