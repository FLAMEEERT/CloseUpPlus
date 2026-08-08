import Foundation

/// Semantic mirror of ScreenCaptureKit's `SCFrameStatus` raw values.
///
/// Sample-buffer attachments bridge the status as an `NSNumber`/`Int`, not as
/// an `SCFrameStatus` instance. Decoding at this boundary keeps that platform
/// representation detail out of the capture-session state machine.
public enum ScreenCaptureFrameStatus: Int, CaseIterable, Equatable, Sendable {
    case complete = 0
    case idle = 1
    case blank = 2
    case suspended = 3
    case started = 4
    case stopped = 5

    public static func decode(_ attachmentValue: Any?) -> Self? {
        guard let rawValue = attachmentValue as? Int else { return nil }
        return Self(rawValue: rawValue)
    }
}
