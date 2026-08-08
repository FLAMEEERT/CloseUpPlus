import AppKit
import ApplicationServices
import CloseUpKit
import CoreGraphics
import PermissionFlow
import SwiftUI

/// Catalog-backed status families for the Screen Recording row. The enum keeps
/// framework outcomes out of the view while the view resolves the final copy
/// through `AppState.loc(...)` in the selected in-app language.
enum ScreenCapturePermissionMessage: Equatable {
    case authorized
    case setup
    case denied
    case needsRetry
    case revoked
}

/// The single shared, observable source of truth for the app shell: the chosen
/// language (and everything derived from it) plus the master on/off state of the
/// Mission Control overlay engine.
@MainActor
@Observable
final class AppState {

    // MARK: - Language

    /// The user's language choice. Persisted and re-applied on every change so
    /// switching takes effect live (no restart).
    var languagePreference: LanguagePreference {
        didSet {
            languagePreference.save()
            pinManager.setLanguage(language)
            applyLanguage()
        }
    }

    /// The concrete language currently rendered.
    var language: SupportedLanguage { languagePreference.effectiveLanguage }

    /// The locale injected into every SwiftUI scene root.
    var locale: Locale { Locale(identifier: language.localeIdentifier) }

    /// Identity used to force a SwiftUI subtree rebuild on language change.
    var localeIdentifier: String { language.localeIdentifier }

    /// Resolve a catalog key to a finished string in the *chosen* language, for
    /// AppKit/bridged surfaces (status-bar menu, window titles, `.help`) that
    /// don't follow SwiftUI's injected `\.locale`.
    func loc(_ key: String) -> String {
        AppKitStrings.string(key, language: language)
    }

    // MARK: - Engine state

    /// Master switch: whether the Mission Control overlay is active. Persisted.
    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.isEnabledKey)
            applyEnabledState()
        }
    }

    private static let isEnabledKey = "isEnabled"

    /// Which overlay controls are shown. Persisted as a single JSON blob.
    var overlaySettings: OverlaySettings {
        didSet {
            guard oldValue != overlaySettings else { return }
            Self.saveOverlaySettings(overlaySettings)
        }
    }

    private static let overlaySettingsKey = "overlaySettings"

    /// Whether the menu-bar status item is hidden. The item is the only route to
    /// Settings/Quit, so re-opening the app (Finder/Spotlight launch of the
    /// already-running instance) restores it — see `applicationShouldHandleReopen`.
    /// Persisted.
    var hideMenuBarIcon: Bool {
        didSet {
            guard oldValue != hideMenuBarIcon else { return }
            UserDefaults.standard.set(hideMenuBarIcon, forKey: Self.hideMenuBarIconKey)
        }
    }

    private static let hideMenuBarIconKey = "hideMenuBarIcon"

    /// The Mission Control overlay engine, alive only while enabled.
    private var engine: MissionControlEngine?

    /// Runtime-only multi-session Pin ownership. This manager is independent
    /// from Mission Control's transient session teardown; U6 reads its
    /// synchronous snapshots and calls its explicit visibility hook.
    @ObservationIgnored
    let pinManager = PinManager()

    /// Synchronous U6 snapshot of CloseUp-owned mirror panel window IDs.
    var pinnedMirrorWindowIDs: Set<CGWindowID> {
        pinManager.pinnedPanelWindowIDs
    }

    func pinState(for windowID: CGWindowID, ownerPID: pid_t) -> OverlayPinState {
        pinManager.pinState(for: windowID, ownerPID: ownerPID)
    }

    func togglePin(for source: WindowInfo) {
        pinManager.toggle(source: source)
    }

    /// Mission Control presentation is orthogonal to Pin ownership. Hiding
    /// panels here does not stop streams or invalidate their generations.
    func setMissionControlVisible(_ visible: Bool) {
        pinManager.setMissionControlVisible(visible)
    }

    // MARK: - Launch at login

    @ObservationIgnored
    private let loginItem = LoginItemController()
    @ObservationIgnored
    private var applyingLoginItem = false

    /// Whether CloseUp launches at login. Backed by `SMAppService`; reverts on
    /// failure (a re-entrancy guard stops the revert from recursing).
    var launchAtLogin: Bool {
        didSet {
            guard !applyingLoginItem, oldValue != launchAtLogin else { return }
            do {
                try loginItem.setEnabled(launchAtLogin)
            } catch {
                applyingLoginItem = true
                launchAtLogin = oldValue
                applyingLoginItem = false
            }
        }
    }

    // MARK: - Accessibility permission

    /// Whether CloseUp currently has Accessibility trust — the single gate for
    /// the whole overlay feature. Observed by polling, since macOS posts no
    /// notification on grant.
    private(set) var accessibilityGranted: Bool = AXIsProcessTrusted()

    /// Presents the system Accessibility list with a floating drag-helper panel.
    /// `promptForAccessibilityTrust: false` — we drive the grant ourselves and
    /// reconcile by polling, so the OS prompt never double-fires.
    @ObservationIgnored
    private lazy var permissionFlow = PermissionFlowController(
        configuration: .init(promptForAccessibilityTrust: false)
    )

    @ObservationIgnored
    private let accessibilityWatcher = AccessibilityGrantWatcher()

    /// Screen Recording is an independent Pin-only capability. Preflight is
    /// safe to call from status refreshes; only `requestScreenCaptureAccess()`
    /// can invoke the prompting Core Graphics API.
    private(set) var screenCapturePermissionStatus: ScreenCapturePermissionStatus = .notGranted
    private(set) var screenCapturePermissionOutcome: ScreenCapturePermissionOutcome?
    private(set) var screenCapturePermissionMessage: ScreenCapturePermissionMessage = .setup
    private(set) var screenCapturePermissionRequestInFlight = false

    @ObservationIgnored
    private var applicationActivationObserver: NSObjectProtocol?

    @ObservationIgnored
    private var lastObservedPinPermissionOutcome: ScreenCapturePermissionOutcome?

    // MARK: - Updates

    /// Sparkle-backed auto-update controller (inert in Debug builds).
    @ObservationIgnored
    let updateController = UpdateController()

    // MARK: - Shortcuts

    @ObservationIgnored
    private lazy var shortcuts = ShortcutController()

    /// Restore one in-Mission-Control shortcut to its default chord (per-row
    /// reset button in Settings).
    func restoreShortcutDefault(_ shortcut: MissionControlShortcut) {
        shortcuts.restoreDefault(shortcut)
    }

    /// Whether a shortcut currently holds its default chord — drives the enabled
    /// state of its per-row reset button.
    func isShortcutAtDefault(_ shortcut: MissionControlShortcut) -> Bool {
        shortcuts.isAtDefault(shortcut)
    }

    // MARK: - Settings window

    /// Presents the Settings window. Wired by `AppDelegate` at launch because the
    /// window is AppKit-managed (`SettingsWindowController`): SwiftUI's `Settings`
    /// scene cannot be opened from the reopen handler in an accessory
    /// (`LSUIElement`) app. Held as a closure so `AppState` never retains the
    /// window (whose SwiftUI content already retains `AppState`). Both the menu's
    /// "Settings…" item and reopening the app route through `openSettings()`.
    @ObservationIgnored
    var settingsPresenter: (() -> Void)?

    /// Show the Settings window (creating it on first use) and bring it forward.
    func openSettings() {
        refreshPermissionStatuses()
        settingsPresenter?()
    }

    // MARK: - Init

    init() {
        languagePreference = LanguagePreference.load()
        isEnabled = UserDefaults.standard.object(forKey: Self.isEnabledKey) as? Bool ?? true
        overlaySettings = Self.loadOverlaySettings()
        hideMenuBarIcon = UserDefaults.standard.bool(forKey: Self.hideMenuBarIconKey)
        launchAtLogin = loginItem.isEnabled
        pinManager.setLanguage(language)
        applyLanguage()
        refreshScreenCapturePermissionStatus()
    }

    // MARK: - Lifecycle

    /// Called once at launch. Idempotent.
    func start() {
        shortcuts.start()
        pinManager.start()
        installApplicationActivationObserver()
        refreshPermissionStatuses()
        applyEnabledState()
    }

    /// Called at termination.
    func stop() {
        pinManager.stop()
        engine?.stop()
        accessibilityWatcher.stop()
        removeApplicationActivationObserver()
    }

    // MARK: - Accessibility flow

    /// Open System Settings → Accessibility (with the floating drag helper) and
    /// begin polling for the grant.
    func requestAccessibilityAccess() {
        permissionFlow.setLocaleIdentifier(language.localeIdentifier)
        permissionFlow.authorize(
            pane: .accessibility,
            suggestedAppURLs: [Bundle.main.bundleURL],
            sourceFrameInScreen: nil
        )
        accessibilityWatcher.start { [weak self] in
            self?.refreshAccessibilityStatus()
        }
    }

    /// Reconcile the cached grant state against the live one. Handles both the
    /// grant (re-attach the engine, dismiss the helper) and a later revocation
    /// (the existing tap/observer go dead — recreate them). Safe to call
    /// repeatedly (on settings appear, on app activation, from the poller).
    func refreshAccessibilityStatus() {
        let trusted = AXIsProcessTrusted()
        guard trusted != accessibilityGranted else { return }
        accessibilityGranted = trusted
        if trusted {
            permissionFlow.closePanel(returnToPreviousApp: true)
            accessibilityWatcher.stop()
        }
        // Re-create the observer + event tap so they (re)attach with the new
        // trust state — they go permanently dead across a trust change otherwise.
        restartEngine()
    }

    /// Stop polling when the settings window closes (not on tab switch).
    func stopAccessibilityWatch() {
        accessibilityWatcher.stop()
    }

    /// Refresh both independent privacy permissions without prompting. This is
    /// used by Settings and app activation so revocation is explained before a
    /// user tries Pin again.
    func refreshPermissionStatuses() {
        reconcilePinPermissionOutcome()
        refreshAccessibilityStatus()
        refreshScreenCapturePermissionStatus()
    }

    /// Refresh Screen Recording state only. If an authorized grant disappears,
    /// use PinManager's existing revocation hook: it tears down Pin sessions but
    /// leaves the Mission Control engine and Accessibility state untouched.
    func refreshScreenCapturePermissionStatus() {
        let previousStatus = screenCapturePermissionStatus
        let currentStatus = pinManager.permissionController.preflight()
        screenCapturePermissionStatus = currentStatus

        switch currentStatus {
        case .authorized:
            screenCapturePermissionMessage = .authorized
        case .notGranted:
            if previousStatus == .authorized {
                screenCapturePermissionMessage = .revoked
                pinManager.handlePermissionRevoked()
            } else if !screenCapturePermissionRequestInFlight {
                screenCapturePermissionMessage = message(for: screenCapturePermissionOutcome)
            }
        }
    }

    /// Explicit Settings/Pin recovery action. This is the only AppState route
    /// that can request Screen Recording access; passive status refreshes never
    /// call the prompting API.
    func requestScreenCaptureAccess() async {
        guard !screenCapturePermissionRequestInFlight else { return }
        screenCapturePermissionRequestInFlight = true

        let outcome = await pinManager.permissionController.requestAccess()
        screenCapturePermissionOutcome = outcome
        screenCapturePermissionRequestInFlight = false
        refreshScreenCapturePermissionStatus()
    }

    // MARK: - Private

    private func applyLanguage() {
        // Third-party packages that draw their own text (KeyboardShortcuts) are
        // redirected to the chosen language here in the i18n phase.
        ThirdPartyBundleLocalization.apply(language: language)
    }

    /// Surface an outcome produced by an explicit Mission Control Pin request
    /// without making PinManager's internal state part of the Settings view.
    /// Tracking the manager's last value prevents an older Pin denial from
    /// overwriting a newer Settings setup result.
    private func reconcilePinPermissionOutcome() {
        let managerOutcome = pinManager.lastPermissionOutcome
        guard managerOutcome != lastObservedPinPermissionOutcome else { return }
        lastObservedPinPermissionOutcome = managerOutcome
        guard let managerOutcome else { return }
        screenCapturePermissionOutcome = managerOutcome
        refreshScreenCapturePermissionStatus()
    }

    private func message(
        for outcome: ScreenCapturePermissionOutcome?
    ) -> ScreenCapturePermissionMessage {
        switch outcome {
        case .denied:
            .denied
        case .needsRetry:
            .needsRetry
        case .alreadyAuthorized, .authorized, nil:
            .setup
        }
    }

    private func installApplicationActivationObserver() {
        guard applicationActivationObserver == nil else { return }
        applicationActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshPermissionStatuses()
            }
        }
    }

    private func removeApplicationActivationObserver() {
        guard let observer = applicationActivationObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        applicationActivationObserver = nil
    }

    private func applyEnabledState() {
        pinManager.setMasterEnabled(isEnabled)
        if isEnabled {
            let engine = engine ?? MissionControlEngine(
                actionsProvider: { [weak self] in self?.overlaySettings.enabledActions ?? [] },
                pinStateProvider: { [weak self] windowID, ownerPID in
                    self?.pinState(for: windowID, ownerPID: ownerPID) ?? .unpinned
                },
                togglePinHandler: { [weak self] source in
                    self?.togglePin(for: source)
                },
                excludedWindowIDsProvider: { [weak self] in
                    self?.pinnedMirrorWindowIDs ?? []
                },
                missionControlVisibilityHandler: { [weak self] visible in
                    self?.setMissionControlVisible(visible)
                },
                chordProvider: { [weak self] shortcut in self?.shortcuts.chord(for: shortcut) },
                localeProvider: { [weak self] in self?.locale ?? .current }
            )
            self.engine = engine
            pinManager.onStateChanged = { [weak self, weak engine] in
                self?.reconcilePinPermissionOutcome()
                engine?.pinStateDidChange()
            }
            engine.start()
        } else {
            engine?.stop()
            engine = nil
            pinManager.onStateChanged = nil
        }
    }

    /// Restart the engine (e.g. after the Accessibility grant lands, so the
    /// observer and event tap re-attach now that they're permitted).
    private func restartEngine() {
        guard isEnabled else { return }
        engine?.stop()
        engine = nil
        applyEnabledState()
    }

    private static func loadOverlaySettings() -> OverlaySettings {
        guard let data = UserDefaults.standard.data(forKey: overlaySettingsKey),
              let settings = try? JSONDecoder().decode(OverlaySettings.self, from: data)
        else { return OverlaySettings() }
        return settings
    }

    private static func saveOverlaySettings(_ settings: OverlaySettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: overlaySettingsKey)
    }
}
