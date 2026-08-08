import AppKit
import CloseUpKit
import Foundation

/// Full-frame pinned mirror content. Pointer entry is the only interaction the
/// mirror owns; after that event the controller replaces it with the real AX
/// source window, so the first click, scroll, key, and native control all reach
/// the source directly.
@MainActor
public final class PinnedWindowContentView: NSView {
    public static let cornerRadius: CGFloat = 10

    public let rendererView: PinnedWindowRenderView
    public private(set) var lifecycle: PinLifecycle
    public private(set) var rendererContentSize: CGSize = .zero

    public var onPointerEntered: (() -> Void)?
    public var onContentSizeChanged: ((CGSize) -> Void)?

    private let statusLabel = NSTextField(labelWithString: "")
    private var trackingArea: NSTrackingArea?
    private var panelLanguage: SupportedLanguage
    private var activationStatusVisible = false
    private var activationStatusTask: Task<Void, Never>?

    public init(
        frame frameRect: NSRect,
        rendererView: PinnedWindowRenderView,
        lifecycle: PinLifecycle = PinLifecycle()
    ) {
        self.rendererView = rendererView
        self.lifecycle = lifecycle
        self.panelLanguage = SupportedLanguage.resolve(
            preferredLanguages: Locale.preferredLanguages
        )
        super.init(frame: frameRect)

        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.65)
            .cgColor

        rendererView.frame = bounds
        rendererView.autoresizingMask = [.width, .height]
        addSubview(rendererView)

        statusLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.alignment = .center
        statusLabel.isSelectable = false
        statusLabel.isEditable = false
        addSubview(statusLabel)

        applyPresentation()
        layoutSubtreeIfNeeded()
    }

    public required init?(coder: NSCoder) {
        nil
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        self.trackingArea = trackingArea
    }

    public override func mouseEntered(with event: NSEvent) {
        onPointerEntered?()
    }

    public override func layout() {
        super.layout()
        rendererView.frame = bounds
        statusLabel.frame = bounds.insetBy(dx: 20, dy: 20)

        let size = bounds.size
        if size != rendererContentSize, size.width > 0, size.height > 0 {
            rendererContentSize = size
            onContentSizeChanged?(size)
        }
    }

    public func update(lifecycle: PinLifecycle) {
        self.lifecycle = lifecycle
        applyPresentation()
    }

    func updateLanguage(_ language: SupportedLanguage) {
        guard panelLanguage != language else { return }
        panelLanguage = language
        applyStatus()
    }

    public func showActivationFailure() {
        activationStatusTask?.cancel()
        activationStatusVisible = true
        applyStatus()

        activationStatusTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))
            } catch {
                return
            }
            guard let self else { return }
            activationStatusVisible = false
            activationStatusTask = nil
            applyStatus()
        }
    }

    public func clearActivationStatus() {
        guard activationStatusVisible || activationStatusTask != nil else { return }
        activationStatusTask?.cancel()
        activationStatusTask = nil
        activationStatusVisible = false
        applyStatus()
    }

    public func prepareForRemoval() {
        activationStatusTask?.cancel()
        activationStatusTask = nil
        onPointerEntered = nil
        onContentSizeChanged = nil
    }

    private func applyPresentation() {
        switch lifecycle.state {
        case .starting:
            rendererView.isHidden = true
            rendererView.alphaValue = 1
        case .live:
            rendererView.isHidden = false
            rendererView.alphaValue = 1
        case .temporarilyUnavailable, .stopping:
            rendererView.isHidden = false
            rendererView.alphaValue = 0.52
        }
        applyStatus()
        needsLayout = true
    }

    private func applyStatus() {
        let status: String?
        if activationStatusVisible {
            status = PinnedWindowPanelCopy.activationFailed(language: panelLanguage)
        } else {
            switch lifecycle.state {
            case .starting:
                status = PinnedWindowPanelCopy.starting(language: panelLanguage)
            case .live:
                status = nil
            case .temporarilyUnavailable:
                status = temporaryStatus(for: lifecycle.content)
            case .stopping:
                status = PinnedWindowPanelCopy.stopping(language: panelLanguage)
            }
        }
        statusLabel.stringValue = status ?? ""
        statusLabel.isHidden = status == nil
        needsLayout = true
    }

    private func temporaryStatus(for content: PinLifecycleContent) -> String {
        guard case let .temporarilyUnavailable(_, reason) = content else {
            return PinnedWindowPanelCopy.unavailable(language: panelLanguage)
        }
        switch reason {
        case .blank:
            return PinnedWindowPanelCopy.unavailable(language: panelLanguage)
        case .suspended:
            return PinnedWindowPanelCopy.suspended(language: panelLanguage)
        }
    }

    deinit {
        activationStatusTask?.cancel()
    }
}

@MainActor
private enum PinnedWindowPanelCopy {
    static func starting(language: SupportedLanguage) -> String {
        AppKitStrings.string("Starting capture…", language: language)
    }

    static func unavailable(language: SupportedLanguage) -> String {
        AppKitStrings.string("Temporarily unavailable", language: language)
    }

    static func suspended(language: SupportedLanguage) -> String {
        AppKitStrings.string("Capture suspended", language: language)
    }

    static func stopping(language: SupportedLanguage) -> String {
        AppKitStrings.string("Stopping capture…", language: language)
    }

    static func activationFailed(language: SupportedLanguage) -> String {
        AppKitStrings.string("Unable to activate source window", language: language)
    }
}
