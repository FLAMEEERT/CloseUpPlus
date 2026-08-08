import AVFoundation
import AppKit
import CoreMedia

/// Background-safe bridge to AVSampleBufferVideoRenderer. ScreenCaptureKit
/// delivers IOSurface-backed sample buffers on a supplied serial queue, and
/// Apple's macOS 14 renderer explicitly supports enqueueing from that queue.
public final class PinnedWindowFrameRenderer: @unchecked Sendable {
    private let renderer: AVSampleBufferVideoRenderer

    public init(renderer: AVSampleBufferVideoRenderer) {
        self.renderer = renderer
    }

    /// Enqueue only transient video data; no media is written or retained by
    /// CloseUp beyond the renderer's current display state.
    @discardableResult
    public func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard renderer.status != .failed else { return false }
        renderer.enqueue(sampleBuffer)
        return renderer.status != .failed
    }

    /// Flush pending media. Keeping the displayed image by default lets a
    /// temporary unavailable state dim the last complete frame later.
    public func reset(removeDisplayedImage: Bool = false) {
        if #available(macOS 14.0, *) {
            renderer.flush(
                removingDisplayedImage: removeDisplayedImage,
                completionHandler: nil
            )
        } else {
            renderer.flush()
        }
    }
}

/// Minimal aspect-fit view for U4 to mount in its eventual panel.
@MainActor
public final class PinnedWindowRenderView: NSView {
    public let displayLayer: AVSampleBufferDisplayLayer
    public let frameRenderer: PinnedWindowFrameRenderer

    public override init(frame frameRect: NSRect) {
        let displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer = displayLayer
        self.frameRenderer = PinnedWindowFrameRenderer(
            renderer: displayLayer.sampleBufferRenderer
        )
        super.init(frame: frameRect)
        configureLayer()
    }

    public required init?(coder: NSCoder) {
        let displayLayer = AVSampleBufferDisplayLayer()
        self.displayLayer = displayLayer
        self.frameRenderer = PinnedWindowFrameRenderer(
            renderer: displayLayer.sampleBufferRenderer
        )
        super.init(coder: coder)
        configureLayer()
    }

    public override func layout() {
        super.layout()
        displayLayer.frame = bounds
    }

    private func configureLayer() {
        wantsLayer = true
        displayLayer.videoGravity = .resizeAspect
        displayLayer.frame = bounds
        displayLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(displayLayer)
    }
}
