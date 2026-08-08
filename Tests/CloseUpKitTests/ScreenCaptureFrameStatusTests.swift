import Foundation
import Testing

@testable import CloseUpKit

@Suite("ScreenCaptureFrameStatus")
struct ScreenCaptureFrameStatusTests {
    @Test("decodes the NSNumber-backed raw values used by sample-buffer attachments")
    func decodesAttachmentValues() {
        for status in ScreenCaptureFrameStatus.allCases {
            let attachmentValue: Any = NSNumber(value: status.rawValue)
            #expect(ScreenCaptureFrameStatus.decode(attachmentValue) == status)
        }
    }

    @Test("rejects missing, non-integer, and unknown attachment values")
    func rejectsInvalidValues() {
        #expect(ScreenCaptureFrameStatus.decode(nil) == nil)
        #expect(ScreenCaptureFrameStatus.decode("0") == nil)
        #expect(ScreenCaptureFrameStatus.decode(NSNumber(value: 99)) == nil)
    }
}
