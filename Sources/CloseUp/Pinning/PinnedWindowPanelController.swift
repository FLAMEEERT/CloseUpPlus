import AppKit
import CloseUpKit
import Foundation
import QuartzCore

/// Owns the Topit-style handoff for one pinned window: a passive floating
/// mirror while idle, and the exact real source window while the pointer is in
/// it. The mirror itself never proxies input.
@MainActor
public final class PinnedWindowPanelController: NSObject, NSWindowDelegate {
    public let panel: NSPanel
    public let source: WindowInfo
    public let contentView: PinnedWindowContentView

    public var onContentSizeChanged: ((CGSize, CGFloat) -> Void)?
    public var onCaptureVisibilityChanged: ((CaptureVisibility) -> Void)?

    public private(set) var interactionState: PinnedWindowInteractionState = .mirroring

    public var captureVisibility: CaptureVisibility {
        guard presentationAllowed else { return .hidden }
        switch interactionState {
        case .mirroring, .restoring: return .visible
        case .handingOff, .interacting: return .hidden
        }
    }

    private let activator: any SourceWindowActivating
    private var sourcePollTimer: Timer?
    private var interactionPollTimer: Timer?
    private var restoreFallbackTask: Task<Void, Never>?
    private var latestSourceFrameCG: CGRect?
    private var presentationAllowed = false
    private var isClosed = false
    private var previousMouseButtonsPressed = false
    private var transitionGeneration: UInt64 = 0

    private static let fadeDuration: TimeInterval = 0.1

    public init(
        source: WindowInfo,
        initialFrame: CGRect,
        rendererView: PinnedWindowRenderView,
        activator: any SourceWindowActivating = AccessibilitySourceWindowActivator()
    ) {
        self.source = source
        self.activator = activator

        let panelFrame = Self.validPanelFrame(initialFrame)
        self.contentView = PinnedWindowContentView(
            frame: NSRect(origin: .zero, size: panelFrame.size),
            rendererView: rendererView
        )
        self.panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        panel.contentView = contentView
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.ignoresCycle, .fullScreenAuxiliary]
        panel.delegate = self

        contentView.onPointerEntered = { [weak self] in
            self?.handlePointerEntry()
        }
        contentView.onContentSizeChanged = { [weak self] size in
            self?.reportContentSize(size)
        }
        contentView.layoutSubtreeIfNeeded()
        reportContentSize(contentView.rendererContentSize)
        startSourcePolling()
    }

    public func show() {
        guard !isClosed else { return }
        cancelRestoreFallback()
        transitionGeneration &+= 1
        presentationAllowed = true
        if let frame = activator.currentFrame(source: source) {
            latestSourceFrameCG = frame
        }
        adoptLatestSourceFrame()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
    }

    public func hide() {
        cancelRestoreFallback()
        transitionGeneration &+= 1
        presentationAllowed = false
        interactionState = .mirroring
        updateInteractionPolling()
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.orderOut(nil)
    }

    public func bindToCurrentSpaceWhileHidden() {
        guard !isClosed else { return }
        let originalAlpha = panel.alphaValue
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        panel.orderOut(nil)
        panel.alphaValue = originalAlpha
    }

    public func setPresented(_ presented: Bool) {
        presented ? show() : hide()
    }

    public func update(lifecycle: PinLifecycle) {
        guard !isClosed else { return }
        contentView.update(lifecycle: lifecycle)
    }

    func updateLanguage(_ language: SupportedLanguage) {
        guard !isClosed else { return }
        contentView.updateLanguage(language)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        sourcePollTimer?.invalidate()
        sourcePollTimer = nil
        interactionPollTimer?.invalidate()
        interactionPollTimer = nil
        cancelRestoreFallback()
        contentView.prepareForRemoval()
        panel.delegate = nil
        panel.orderOut(nil)
        panel.close()
    }

    public func windowShouldClose(_ sender: NSWindow) -> Bool {
        false
    }

    public func windowDidChangeBackingProperties(_ notification: Notification) {
        reportContentSize(contentView.rendererContentSize)
    }

    private func handlePointerEntry() {
        guard presentationAllowed, !isClosed else { return }
        apply(PinnedWindowInteractionPolicy.reduce(
            interactionState,
            event: .pointerEntered
        ))
    }

    private func beginHandoff() {
        guard presentationAllowed,
              let targetFrame = PinnedWindowLayout.coreGraphicsFrame(
                  forAppKitFrame: panel.frame,
                  pivotHeight: Self.menuBarScreenHeight()
              )
        else {
            apply(PinnedWindowInteractionPolicy.reduce(
                interactionState,
                event: .handoffFailed
            ))
            return
        }

        switch activator.activate(source: source, positionedAt: targetFrame) {
        case .activated:
            Log.pinning.notice(
                "source handoff active window=\(self.source.windowID, privacy: .public) pid=\(self.source.ownerPID, privacy: .public)"
            )
            contentView.clearActivationStatus()
            latestSourceFrameCG = targetFrame
            apply(PinnedWindowInteractionPolicy.reduce(
                interactionState,
                event: .handoffSucceeded
            ))
        case .accessibilityUnavailable,
             .sourceUnavailable,
             .applicationActivationFailed,
             .windowMoveFailed,
             .windowResizeFailed,
             .windowRaiseFailed:
            contentView.showActivationFailure()
            apply(PinnedWindowInteractionPolicy.reduce(
                interactionState,
                event: .handoffFailed
            ))
        }
    }

    private func startSourcePolling() {
        sourcePollTimer = Timer.scheduledTimer(
            timeInterval: 0.2,
            target: self,
            selector: #selector(pollSource),
            userInfo: nil,
            repeats: true
        )
        sourcePollTimer?.tolerance = 0.04
    }

    private func startInteractionPolling() {
        guard interactionPollTimer == nil else { return }
        interactionPollTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(pollInteraction),
            userInfo: nil,
            repeats: true
        )
        interactionPollTimer?.tolerance = 0.004
    }

    private func updateInteractionPolling() {
        switch interactionState {
        case .interacting, .restoring:
            startInteractionPolling()
        case .mirroring, .handingOff:
            interactionPollTimer?.invalidate()
            interactionPollTimer = nil
            previousMouseButtonsPressed = false
        }
    }

    @objc private func pollSource() {
        guard !isClosed, presentationAllowed else { return }
        if let frame = activator.currentFrame(source: source) {
            latestSourceFrameCG = frame
        }

        switch interactionState {
        case .mirroring:
            adoptLatestSourceFrame()
        case .handingOff:
            break
        case .interacting, .restoring:
            adoptLatestSourceFrame()
        }
    }

    @objc private func pollInteraction() {
        guard !isClosed, presentationAllowed else { return }
        switch interactionState {
        case .interacting, .restoring:
            break
        case .mirroring, .handingOff:
            return
        }

        let mouseButtonsPressed = NSEvent.pressedMouseButtons != 0
        if previousMouseButtonsPressed, !mouseButtonsPressed,
           let frame = activator.currentFrame(source: source) {
            latestSourceFrameCG = frame
        }
        previousMouseButtonsPressed = mouseButtonsPressed

        guard let sourceFrame = latestSourceFrameCG,
              let appKitFrame = PinnedWindowLayout.appKitFrame(
                  forCoreGraphicsFrame: sourceFrame,
                  pivotHeight: Self.menuBarScreenHeight()
              )
        else { return }

        apply(PinnedWindowInteractionPolicy.reduce(
            interactionState,
            event: .observation(
                pointerInsideSource: appKitFrame.contains(NSEvent.mouseLocation),
                mouseButtonsPressed: mouseButtonsPressed
            )
        ))
    }

    public func captureFrameDelivered() {
        guard !isClosed else { return }
        apply(PinnedWindowInteractionPolicy.reduce(
            interactionState,
            event: .freshFrameDelivered
        ))
    }

    private func apply(_ decision: PinnedWindowInteractionDecision) {
        interactionState = decision.state
        updateInteractionPolling()
        for action in decision.actions {
            switch action {
            case .beginHandoff:
                beginHandoff()
            case .hideMirror:
                fadeMirrorOut()
            case .suspendCapture:
                onCaptureVisibilityChanged?(.hidden)
            case .adoptSourceFrame:
                adoptLatestSourceFrame()
            case .resumeCapture:
                onCaptureVisibilityChanged?(.visible)
            case .showMirror:
                guard presentationAllowed else { continue }
                fadeMirrorIn()
            case .scheduleRestoreFallback:
                scheduleRestoreFallback()
            case .cancelRestoreFallback:
                cancelRestoreFallback()
            }
        }
    }

    private func fadeMirrorOut() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        panel.ignoresMouseEvents = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.transitionGeneration == generation,
                      self.interactionState != .mirroring
                else { return }
                self.panel.orderOut(nil)
            }
        }
    }

    private func fadeMirrorIn() {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        panel.alphaValue = 0
        panel.ignoresMouseEvents = false
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.transitionGeneration == generation else { return }
                Log.pinning.notice(
                    "source handoff restored window=\(self.source.windowID, privacy: .public) pid=\(self.source.ownerPID, privacy: .public)"
                )
            }
        }
    }

    private func scheduleRestoreFallback() {
        cancelRestoreFallback()
        restoreFallbackTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(350))
            } catch {
                return
            }
            guard let self else { return }
            restoreFallbackTask = nil
            Log.pinning.notice(
                "source handoff restore timeout window=\(self.source.windowID, privacy: .public) pid=\(self.source.ownerPID, privacy: .public)"
            )
            apply(PinnedWindowInteractionPolicy.reduce(
                interactionState,
                event: .restoreTimedOut
            ))
        }
    }

    private func cancelRestoreFallback() {
        restoreFallbackTask?.cancel()
        restoreFallbackTask = nil
    }

    private func adoptLatestSourceFrame() {
        guard let sourceFrame = latestSourceFrameCG
                ?? activator.currentFrame(source: source),
              let appKitFrame = PinnedWindowLayout.appKitFrame(
                  forCoreGraphicsFrame: sourceFrame,
                  pivotHeight: Self.menuBarScreenHeight()
              )
        else { return }

        latestSourceFrameCG = sourceFrame
        guard panel.frame != appKitFrame else { return }
        panel.setFrame(appKitFrame, display: false)
        contentView.layoutSubtreeIfNeeded()
        reportContentSize(contentView.rendererContentSize)
    }

    private func reportContentSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0, !isClosed else { return }
        onContentSizeChanged?(size, backingScaleFactor)
    }

    private var backingScaleFactor: CGFloat {
        panel.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
    }

    private static func validPanelFrame(_ frame: CGRect) -> CGRect {
        guard frame.origin.x.isFinite,
              frame.origin.y.isFinite,
              frame.width.isFinite,
              frame.height.isFinite,
              frame.width > 1,
              frame.height > 1
        else {
            return CGRect(x: 0, y: 0, width: 360, height: 240)
        }
        return frame
    }

    private static func menuBarScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }
}
