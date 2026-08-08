import AppKit
import CloseUpKit
import CoreGraphics
import Foundation

/// Owns the complete lifetime of every pinned-window mirror.
///
/// Pinning is deliberately separate from Mission Control's transient session:
/// Mission Control only changes presentation, while this manager owns the
/// resolver, permission controller, renderer, panel, stream session, and all
/// source-liveness work. All public methods and snapshots are main-actor
/// synchronous so a future Mission Control integration can read state without
/// subscribing to an asynchronous stream.
@MainActor
final class PinManager {

    // MARK: - Public state and hooks

    /// The manager-owned platform seams. They live for the manager's lifetime
    /// and are never constructed as part of a Mission Control session.
    let windowResolver: ScreenCaptureWindowResolver
    let permissionController: ScreenCapturePermissionController

    /// Called synchronously after a state or mirror-window-ID snapshot changes.
    /// U6 can use this to refresh the currently visible Mission Control cluster.
    var onStateChanged: (() -> Void)?

    /// Called synchronously when Mission Control presentation visibility changes.
    /// The hook is presentation-only; it never tears down a capture session.
    var onMissionControlVisibilityChanged: ((Bool) -> Void)?

    private(set) var missionControlVisible = false
    private(set) var masterEnabled = true
    private(set) var lastPermissionOutcome: ScreenCapturePermissionOutcome?
    private(set) var language = SupportedLanguage.resolve(preferredLanguages: Locale.preferredLanguages)

    /// Snapshot of the panel window IDs that U6 must exclude from Mission
    /// Control candidates. Hidden panels remain in this set until unpinned.
    var pinnedPanelWindowIDs: Set<CGWindowID> {
        Set(records.values.compactMap { record in
            guard let windowNumber = record.panel?.panel.windowNumber,
                  windowNumber > 0
            else { return nil }
            return CGWindowID(windowNumber)
        })
    }

    var sessionCount: Int {
        records.values.reduce(into: 0) { count, record in
            if record.session != nil { count += 1 }
        }
    }

    func pinState(for key: ScreenCaptureSourceKey) -> OverlayPinState {
        records[key]?.state ?? .unpinned
    }

    func pinState(for windowID: CGWindowID, ownerPID: pid_t) -> OverlayPinState {
        pinState(for: ScreenCaptureSourceKey(windowID: windowID, ownerPID: ownerPID))
    }

    /// Keep already-created AppKit panels in the selected in-app language.
    func setLanguage(_ language: SupportedLanguage) {
        guard self.language != language else { return }
        self.language = language
        for panel in records.values.compactMap(\.panel) {
            panel.updateLanguage(language)
        }
    }

    // MARK: - Lifecycle

    private var records: [ScreenCaptureSourceKey: ManagedPin] = [:]
    private var isStarted = false
    private var workspaceTerminationObserver: NSObjectProtocol?
    private var livenessTask: Task<Void, Never>?
    private var permissionTask: Task<Void, Never>?
    private var pinTasks: [ScreenCaptureSourceKey: Task<Void, Never>] = [:]
    private var nextGeneration: UInt64 = 0
    private var permissionWasAuthorized: Bool?

    private let livenessInterval: UInt64 = 2_000_000_000
    private let livenessMissThreshold = 3
    private let authoritativeLossThreshold = 2

    init(
        windowResolver: ScreenCaptureWindowResolver = ScreenCaptureWindowResolver(),
        permissionController: ScreenCapturePermissionController = ScreenCapturePermissionController()
    ) {
        self.windowResolver = windowResolver
        self.permissionController = permissionController
    }

    /// Starts only non-prompting observers. No Screen Recording permission
    /// request or source discovery occurs at launch.
    func start() {
        guard !isStarted else { return }
        isStarted = true
        installWorkspaceTerminationObserver()
        Log.pinning.notice("pin manager start")
    }

    /// Application-termination shutdown. It invalidates pending work before
    /// stopping streams, so a late permission, stream, or liveness callback
    /// cannot recreate ownership after the app is going away.
    func stop() {
        guard isStarted || !records.isEmpty else { return }

        isStarted = false
        masterEnabled = false
        cancelPinTasks()
        removeWorkspaceTerminationObserver()
        shutdownAll(reason: .applicationTerminated)
        missionControlVisible = false
        onMissionControlVisibilityChanged = nil
        onStateChanged = nil
        Log.pinning.notice("pin manager stopped")
    }

    /// Master Enable is independent from the Mission Control engine. Disabling
    /// it destroys every runtime-only Pin and re-enabling it restores none.
    func setMasterEnabled(_ enabled: Bool) {
        guard masterEnabled != enabled else { return }
        masterEnabled = enabled
        guard !enabled else {
            Log.pinning.notice("pin master enabled")
            return
        }

        shutdownAll(reason: .masterDisabled)
    }

    /// Explicit U6/UI recovery hook for Screen Recording revocation. It stops
    /// all Pin sessions and never touches MissionControlEngine or Accessibility.
    func handlePermissionRevoked() {
        permissionWasAuthorized = false
        shutdownAll(reason: .permissionRevoked)
    }

    // MARK: - Pin and Unpin API

    /// Toggle one exact source. `.pinning` and `.unpinning` are intentionally
    /// no-ops: duplicate requests cannot create a second session or attach a
    /// reused window ID to an older process.
    func toggle(source: WindowInfo) {
        let key = ScreenCaptureSourceKey(
            windowID: source.windowID,
            ownerPID: source.ownerPID
        )
        switch pinState(for: key) {
        case .unpinned:
            pin(source: source)
        case .pinned:
            unpin(for: key)
        case .pinning, .unpinning:
            let stateDescription = String(describing: pinState(for: key))
            Log.pinning.debug(
                "pin toggle ignored window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public) state=\(stateDescription, privacy: .public)"
            )
        }
    }

    /// Pin one exact source. The permission request is reachable only through
    /// this explicit Pin entry point; construction, start, and preflight do
    /// not prompt.
    func pin(source: WindowInfo) {
        guard isStarted, masterEnabled else { return }

        let key = ScreenCaptureSourceKey(
            windowID: source.windowID,
            ownerPID: source.ownerPID
        )
        guard records[key] == nil else {
            Log.pinning.debug(
                "duplicate pin ignored window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public) count=\(self.records.count, privacy: .public)"
            )
            return
        }

        nextGeneration &+= 1
        let record = ManagedPin(
            key: key,
            requestedSource: source,
            generation: nextGeneration
        )
        records[key] = record
        lastPermissionOutcome = nil
        notifyStateChanged()
        Log.pinning.notice(
            "pin requested window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public) count=\(self.records.count, privacy: .public)"
        )

        let task = Task { @MainActor [weak self, weak record] in
            guard let self, let record else { return }
            await self.resolveAndStart(record)
        }
        pinTasks[key] = task
    }

    /// Convenience entry point for callers that have only the exact identity.
    /// ScreenCaptureKit revalidates both key parts and supplies the real source
    /// geometry; a Mission Control thumbnail frame is never used for the panel.
    func pin(
        windowID: CGWindowID,
        ownerPID: pid_t,
        ownerName: String = "",
        sourceFrame: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)
    ) {
        pin(
            source: WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                ownerName: ownerName,
                frame: sourceFrame
            )
        )
    }

    func unpin(for key: ScreenCaptureSourceKey) {
        guard let record = records[key] else {
            Log.pinning.debug(
                "duplicate unpin ignored window=\(key.windowID, privacy: .public) pid=\(key.ownerPID, privacy: .public)"
            )
            return
        }
        stop(record, reason: .userRequested)
    }

    func unpin(windowID: CGWindowID, ownerPID: pid_t) {
        unpin(for: ScreenCaptureSourceKey(windowID: windowID, ownerPID: ownerPID))
    }

    // MARK: - Mission Control presentation

    /// Hide panels and reduce their configured capture work while Mission
    /// Control is visible. Sessions, renderers, and generations remain alive.
    /// On exit, only panels still on their creation Space are restored.
    func setMissionControlVisible(_ visible: Bool) {
        guard missionControlVisible != visible else { return }
        missionControlVisible = visible

        for record in records.values {
            guard let panel = record.panel, let session = record.session else { continue }
            for action in PinPresentationPolicy.missionControlActions(
                visible: visible,
                panelIsOnActiveSpace: panel.panel.isOnActiveSpace
            ) {
                switch action {
                case .hide:
                    panel.setPresented(false)
                    requestVisibility(.hidden, for: record, session: session, panel: panel)
                case .show:
                    panel.setPresented(true)
                    requestVisibility(.visible, for: record, session: session, panel: panel)
                case .remainHidden:
                    // The panel remains owned and its capture remains
                    // recoverable, but it must not be forced onto another
                    // Space.
                    requestVisibility(.hidden, for: record, session: session, panel: panel)
                case .bindToCurrentSpaceWhileHidden:
                    panel.bindToCurrentSpaceWhileHidden()
                }
            }
        }

        onMissionControlVisibilityChanged?(visible)
        notifyStateChanged()
        Log.pinning.notice(
            "mission control visibility=\(visible ? "visible" : "hidden", privacy: .public) sessions=\(self.sessionCount, privacy: .public)"
        )
    }

    // MARK: - Permission and source startup

    private func resolveAndStart(_ record: ManagedPin) async {
        defer {
            if records[record.key] === record {
                pinTasks[record.key] = nil
            }
        }

        guard isCurrent(record) else { return }

        let permissionOutcome: ScreenCapturePermissionOutcome
        switch permissionController.preflight() {
        case .authorized:
            permissionOutcome = .alreadyAuthorized
        case .notGranted:
            // This is the only call site that can request Screen Recording.
            permissionOutcome = await permissionController.requestAccess()
        }

        guard isCurrent(record) else { return }
        lastPermissionOutcome = permissionOutcome
        notifyStateChanged()

        switch permissionOutcome {
        case .alreadyAuthorized, .authorized:
            break
        case .denied, .needsRetry:
            fail(record, reason: permissionOutcome.rawValue)
            return
        }

        let resolution = await windowResolver.resolve(source: record.key)
        guard isCurrent(record) else { return }

        switch resolution {
        case .matched(let source):
            establishSession(record, source: source)
        case .failed(let failure):
            if case .permissionDenied = failure,
               permissionController.preflight() == .notGranted {
                handlePermissionRevoked()
            } else {
                fail(record, reason: resolutionFailureReason(failure))
            }
        }
    }

    private func establishSession(
        _ record: ManagedPin,
        source: ScreenCaptureWindowSource
    ) {
        guard isCurrent(record) else { return }

        let panelSource = resolvedPanelSource(
            requested: record.requestedSource,
            resolved: source
        )
        guard let initialFrame = PinnedWindowLayout.appKitFrame(
            forCoreGraphicsFrame: panelSource.frame,
            pivotHeight: Self.menuBarScreenHeight()
        ) else {
            fail(record, reason: "invalid-source-frame")
            return
        }

        let rendererView = PinnedWindowRenderView(frame: .zero)
        let session = PinnedWindowSession(
            source: source,
            frameRenderer: rendererView.frameRenderer,
            onSignal: { [weak self, weak record] signal in
                guard let self, let record else { return }
                self.receive(signal, for: record)
            }
        )
        let panel = PinnedWindowPanelController(
            source: panelSource,
            initialFrame: initialFrame,
            rendererView: rendererView
        )
        panel.updateLanguage(language)

        record.rendererView = rendererView
        record.session = session
        record.panel = panel

        panel.onContentSizeChanged = { [weak self, weak record, weak panel] size, scale in
            guard let self, let record, let panel, self.isCurrent(record),
                  let session = record.session
            else { return }
            let visibility: CaptureVisibility = self.missionControlVisible
                ? .hidden
                : panel.captureVisibility
            session.requestResize(
                contentSize: size,
                backingScale: scale,
                visibility: visibility
            )
        }
        panel.onCaptureVisibilityChanged = { [weak self, weak record, weak panel] requested in
            guard let self, let record, let panel, self.isCurrent(record),
                  let session = record.session
            else { return }
            if requested == .visible {
                session.requestFreshFrameSignal()
            }
            self.requestVisibility(
                self.missionControlVisible ? .hidden : requested,
                for: record,
                session: session,
                panel: panel
            )
        }

        panel.update(lifecycle: session.lifecycle)
        for action in PinPresentationPolicy.establishmentActions(
            missionControlVisible: missionControlVisible
        ) {
            switch action {
            case .bindToCurrentSpaceWhileHidden:
                panel.bindToCurrentSpaceWhileHidden()
            case .show:
                panel.setPresented(true)
            case .hide, .remainHidden:
                panel.setPresented(false)
            }
        }
        notifyStateChanged()
        ensureLivenessMonitoring()
        ensurePermissionMonitoring()

        Log.pinning.notice(
            "session owned window=\(record.key.windowID, privacy: .public) pid=\(record.key.ownerPID, privacy: .public) count=\(self.sessionCount, privacy: .public)"
        )
        session.start()

        // PinnedWindowSession starts with a visible configuration. A panel
        // established during Mission Control was already hidden-bound above;
        // enqueue the reduced hidden presentation without destroying the
        // stream or its generation.
        if missionControlVisible {
            requestVisibility(.hidden, for: record, session: session, panel: panel)
        }
    }

    private func resolvedPanelSource(
        requested: WindowInfo,
        resolved: ScreenCaptureWindowSource
    ) -> WindowInfo {
        let ownerName = requested.ownerName.isEmpty
            ? (resolved.window.owningApplication?.applicationName ?? "")
            : requested.ownerName
        return WindowInfo(
            windowID: resolved.key.windowID,
            ownerPID: resolved.key.ownerPID,
            ownerName: ownerName,
            frame: resolved.window.frame
        )
    }

    // MARK: - Session signals and teardown

    private func receive(_ signal: PinnedWindowSessionSignal, for record: ManagedPin) {
        guard isCurrent(record) else { return }

        switch signal {
        case .lifecycleChanged(let state):
            record.panel?.update(lifecycle: record.session?.lifecycle ?? PinLifecycle())
            switch state {
            case .live:
                setState(.pinned, for: record)
            case .stopping:
                setState(.unpinning, for: record)
            case .starting, .temporarilyUnavailable:
                break
            }
        case .sampleStatus, .temporarilyUnavailable, .frameDelivered:
            // The session coalesces these semantic signals while the renderer
            // continues to receive every complete sample. Lifecycle changes
            // above are the sole panel-presentation path, so a status/frame
            // notification cannot cause another redundant AppKit update.
            if case .frameDelivered = signal {
                record.panel?.captureFrameDelivered()
                setState(.pinned, for: record)
            }
        case .streamActivityChanged, .configurationApplied, .configurationFailed:
            // Inactive/blank delivery is not source closure. The session's
            // lifecycle signal owns the paused presentation and its retry path.
            break
        case .stopped(let reason):
            removeRecord(record, reason: reason.rawValue)
        }
    }

    private func unpin(record: ManagedPin) {
        guard isCurrent(record) else { return }
        stop(record, reason: .userRequested)
    }

    private func stop(_ record: ManagedPin, reason: StopReason) {
        guard isCurrent(record) else { return }
        setState(.unpinning, for: record)
        record.livenessResolutionInFlight = false

        if let session = record.session {
            switch reason {
            case .permissionRevoked:
                session.permissionRevoked()
            case .sourceEnded:
                session.sourceEnded()
            case .processEnded:
                session.processEnded()
            case .userRequested, .masterDisabled, .applicationTerminated:
                session.stop()
            }
        }

        // Session stop emits synchronously today, but keep this fallback so a
        // future session implementation cannot leave manager ownership behind.
        if isCurrent(record) {
            removeRecord(record, reason: reason.rawValue)
        }
    }

    private func fail(_ record: ManagedPin, reason: String) {
        guard isCurrent(record) else { return }
        Log.pinning.notice(
            "pin failed window=\(record.key.windowID, privacy: .public) pid=\(record.key.ownerPID, privacy: .public) reason=\(reason, privacy: .public)"
        )
        removeRecord(record, reason: reason)
    }

    private func removeRecord(_ record: ManagedPin, reason: String) {
        guard records[record.key] === record else { return }
        record.invalidated = true
        pinTasks[record.key]?.cancel()
        pinTasks[record.key] = nil
        record.session?.onSignal = nil
        record.panel?.close()
        record.panel = nil
        record.session = nil
        record.rendererView = nil
        records[record.key] = nil
        notifyStateChanged()
        Log.pinning.notice(
            "session removed window=\(record.key.windowID, privacy: .public) pid=\(record.key.ownerPID, privacy: .public) reason=\(reason, privacy: .public) count=\(self.records.count, privacy: .public)"
        )
        stopMonitoringIfIdle()
    }

    private func setState(_ state: OverlayPinState, for record: ManagedPin) {
        guard records[record.key] === record, record.state != state else { return }
        record.state = state
        notifyStateChanged()
    }

    private func isCurrent(_ record: ManagedPin) -> Bool {
        records[record.key] === record && !record.invalidated
    }

    private func notifyStateChanged() {
        onStateChanged?()
    }

    private static func menuBarScreenHeight() -> CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }

    private func requestVisibility(
        _ visibility: CaptureVisibility,
        for record: ManagedPin,
        session: PinnedWindowSession,
        panel: PinnedWindowPanelController
    ) {
        guard isCurrent(record), record.session === session, record.panel === panel else { return }
        let size = panel.contentView.rendererContentSize
        guard size.width > 0, size.height > 0 else { return }
        let scale = panel.panel.screen?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor
            ?? 1
        session.requestResize(
            contentSize: size,
            backingScale: scale,
            visibility: visibility
        )
    }

    // MARK: - Application termination and permission observation

    private func installWorkspaceTerminationObserver() {
        guard workspaceTerminationObserver == nil else { return }
        workspaceTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[
                NSWorkspace.applicationUserInfoKey
            ] as? NSRunningApplication else { return }

            let pid = application.processIdentifier
            MainActor.assumeIsolated { self?.handleApplicationTermination(pid: pid) }
        }
    }

    private func removeWorkspaceTerminationObserver() {
        guard let observer = workspaceTerminationObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(observer)
        workspaceTerminationObserver = nil
    }

    private func handleApplicationTermination(pid: pid_t) {
        let matching = records.values.filter { $0.key.ownerPID == pid }
        guard !matching.isEmpty else { return }

        Log.pinning.notice(
            "source application terminated pid=\(pid, privacy: .public) count=\(matching.count, privacy: .public)"
        )
        for record in matching {
            stop(record, reason: .processEnded)
        }
    }

    private func ensurePermissionMonitoring() {
        guard permissionTask == nil else { return }

        let authorized = permissionController.preflight() == .authorized
        if permissionWasAuthorized == true, !authorized {
            handlePermissionRevoked()
            return
        }
        permissionWasAuthorized = authorized

        permissionTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                let current = self.permissionController.preflight() == .authorized
                if self.permissionWasAuthorized == true, !current {
                    self.handlePermissionRevoked()
                    break
                }
                self.permissionWasAuthorized = current
            }
            self?.permissionTask = nil
        }
    }

    // MARK: - macOS 14 liveness fallback

    private func ensureLivenessMonitoring() {
        guard livenessTask == nil else { return }
        livenessTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: self?.livenessInterval ?? 2_000_000_000)
                } catch {
                    break
                }
                guard let self, !Task.isCancelled else { break }
                self.checkSourceLiveness()
            }
            self?.livenessTask = nil
        }
    }

    /// The all-window list is intentionally used instead of on-screen-only:
    /// minimized, hidden, and other-Space windows may be absent from the latter
    /// while their source ownership remains valid. A nil result means the
    /// system query itself failed, so the whole check is skipped conservatively.
    private func exactWindowKeys() -> Set<ScreenCaptureSourceKey>? {
        guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        return Set(raw.compactMap { entry in
            guard let windowID = entry[kCGWindowNumber as String] as? CGWindowID,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t
            else { return nil }
            return ScreenCaptureSourceKey(windowID: windowID, ownerPID: ownerPID)
        })
    }

    private func checkSourceLiveness() {
        guard let keys = exactWindowKeys() else { return }

        var pending: [ManagedPin] = []

        for record in records.values where record.session != nil {
            guard isCurrent(record) else { continue }
            if keys.contains(record.key) {
                record.livenessMisses = 0
                record.authoritativeMissingChecks = 0
                continue
            }

            record.livenessMisses += 1
            let process = NSRunningApplication(processIdentifier: record.key.ownerPID)
            if record.livenessMisses >= livenessMissThreshold,
               process == nil || process?.isTerminated == true {
                stop(record, reason: .processEnded)
                continue
            }

            guard record.livenessMisses >= livenessMissThreshold,
                  !record.livenessResolutionInFlight
            else { continue }

            record.livenessResolutionInFlight = true
            pending.append(record)
        }

        guard !pending.isEmpty else { return }

        // One ScreenCaptureKit snapshot is enough to revalidate every source
        // that missed the exact WindowServer list in this cycle. The records
        // are captured strongly only until the batch returns; every result is
        // still fenced by the manager's identity/current-record check below.
        Task { @MainActor [weak self, pending] in
            guard let self else { return }
            let resolutions = await self.windowResolver.resolve(
                sources: pending.map(\.key)
            )
            self.finishLivenessChecks(pending, resolutions: resolutions)
        }
    }

    private func finishLivenessChecks(
        _ pending: [ManagedPin],
        resolutions: [ScreenCaptureSourceKey: ScreenCaptureWindowResolution]
    ) {
        for record in pending {
            guard isCurrent(record) else { continue }
            guard let resolution = resolutions[record.key] else {
                // The resolver returns one result per requested key. If a
                // future seam violates that contract, treat it as a
                // discovery gap rather than source loss and permit retry.
                record.livenessResolutionInFlight = false
                record.livenessMisses = 0
                continue
            }
            finishLivenessCheck(record, resolution: resolution)
        }
    }

    private func finishLivenessCheck(
        _ record: ManagedPin,
        resolution: ScreenCaptureWindowResolution
    ) {
        guard isCurrent(record) else { return }
        record.livenessResolutionInFlight = false

        switch resolution {
        case .matched:
            record.livenessMisses = 0
            record.authoritativeMissingChecks = 0
        case .failed(.permissionDenied):
            if permissionController.preflight() == .notGranted {
                handlePermissionRevoked()
            }
        case .failed(.notFound), .failed(.ownerMismatch):
            // A missing exact source is debounced twice after the initial
            // exact-window misses. This avoids treating a transient discovery
            // gap as closure while still recovering a genuinely closed window.
            record.authoritativeMissingChecks += 1
            if record.authoritativeMissingChecks >= authoritativeLossThreshold {
                stop(record, reason: .sourceEnded)
            }
        case .failed(.discoveryFailed):
            // Discovery failure is not source closure. Keep ownership and let
            // the next exact miss schedule a later revalidation.
            record.livenessMisses = 0
        }
    }

    // MARK: - Shared shutdown helpers

    private func cancelPinTasks() {
        for task in pinTasks.values {
            task.cancel()
        }
        pinTasks.removeAll()
    }

    private func shutdownAll(reason: StopReason) {
        guard !records.isEmpty else {
            stopMonitoringIfIdle()
            return
        }

        Log.pinning.notice(
            "pin shutdown reason=\(reason.rawValue, privacy: .public) count=\(self.records.count, privacy: .public)"
        )
        cancelPinTasks()
        let current = Array(records.values)
        for record in current {
            stop(record, reason: reason)
        }
        // `stop` is synchronous today, but retain no manager ownership if a
        // future session implementation defers its stopped signal.
        for record in current where records[record.key] === record {
            removeRecord(record, reason: reason.rawValue)
        }
        stopMonitoringIfIdle()
    }

    private func stopMonitoringIfIdle() {
        guard records.values.allSatisfy({ $0.session == nil }) else { return }
        livenessTask?.cancel()
        livenessTask = nil
        permissionTask?.cancel()
        permissionTask = nil
        permissionWasAuthorized = nil
    }

    private func resolutionFailureReason(
        _ failure: ScreenCaptureWindowResolutionFailure
    ) -> String {
        switch failure {
        case .notFound:
            "source-not-found"
        case .ownerMismatch:
            "source-owner-mismatch"
        case .permissionDenied:
            "permission-denied"
        case .discoveryFailed:
            "source-discovery-failed"
        }
    }
}

private extension PinManager {
    enum StopReason: String {
        case userRequested
        case sourceEnded
        case processEnded
        case permissionRevoked
        case masterDisabled
        case applicationTerminated
    }

    final class ManagedPin {
        let key: ScreenCaptureSourceKey
        let requestedSource: WindowInfo
        let generation: UInt64

        var state: OverlayPinState = .pinning
        var session: PinnedWindowSession?
        var panel: PinnedWindowPanelController?
        var rendererView: PinnedWindowRenderView?
        var livenessMisses = 0
        var authoritativeMissingChecks = 0
        var livenessResolutionInFlight = false
        var invalidated = false

        init(
            key: ScreenCaptureSourceKey,
            requestedSource: WindowInfo,
            generation: UInt64
        ) {
            self.key = key
            self.requestedSource = requestedSource
            self.generation = generation
        }
    }
}
