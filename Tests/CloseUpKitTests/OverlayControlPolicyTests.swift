import Testing

@testable import CloseUpKit

@Suite("OverlayControl")
struct OverlayControlTests {
    private let enabledActions: [WindowAction] = [.close, .minimize, .zoom]
    private let allCapabilities = WindowCapabilities(canClose: true, canMinimize: true, canZoom: true)

    @Test("pin controls expose stable metadata and progress controls are disabled")
    func metadata() {
        #expect(OverlayControl.pin.id == "pin-toggle")
        #expect(OverlayControl.unpin.id == OverlayControl.pin.id)
        #expect(OverlayControl.pinning.id == OverlayControl.pin.id)
        #expect(OverlayControl.unpinning.id == OverlayControl.pin.id)
        #expect(OverlayControl.windowAction(.close).id == "window-action.close")

        #expect(OverlayControl.pin.symbolName == "pin")
        #expect(OverlayControl.unpin.symbolName == "pin.slash")
        #expect(OverlayControl.pinning.symbolName == OverlayControl.pin.symbolName)
        #expect(OverlayControl.unpinning.symbolName == OverlayControl.unpin.symbolName)
        #expect(OverlayControl.windowAction(.close).symbolName == "xmark")
        #expect(OverlayControl.pin.titleKey == "Pin Window")
        #expect(OverlayControl.unpin.titleKey == "Unpin Window")
        #expect(OverlayControl.pinning.titleKey == "Pinning Window")
        #expect(OverlayControl.unpinning.titleKey == "Unpinning Window")
        #expect(OverlayControl.windowAction(.close).titleKey == "Close Window")

        #expect(OverlayControl.pin.executionKind == .pin)
        #expect(OverlayControl.unpin.executionKind == .unpin)
        #expect(OverlayControl.windowAction(.close).executionKind == .windowAction(.close))
        #expect(OverlayControl.pinning.executionKind == .none)
        #expect(OverlayControl.unpinning.executionKind == .none)
        #expect(OverlayControl.pin.isEnabled)
        #expect(OverlayControl.unpin.isEnabled)
        #expect(!OverlayControl.pinning.isEnabled)
        #expect(!OverlayControl.unpinning.isEnabled)
    }

    @Test("only Pin exits Mission Control before execution")
    func missionControlExitPolicy() {
        #expect(OverlayControl.pin.exitsMissionControlBeforeExecution)
        #expect(!OverlayControl.unpin.exitsMissionControlBeforeExecution)
        #expect(!OverlayControl.pinning.exitsMissionControlBeforeExecution)
        #expect(!OverlayControl.unpinning.exitsMissionControlBeforeExecution)
        #expect(!OverlayControl.windowAction(.close).exitsMissionControlBeforeExecution)
    }

    @Test("an eligible unpinned window puts Pin before supported AX controls")
    func unpinnedOrderAndIntersection() {
        let controls = OverlayControlPolicy.controls(
            pinState: .unpinned,
            enabledActions: enabledActions,
            capability: .resolved(WindowCapabilities(canClose: true, canMinimize: false, canZoom: true))
        )

        #expect(controls == [.pin, .windowAction(.close), .windowAction(.zoom)])
    }

    @Test("an eligible pinned window replaces Pin with Unpin in the same position")
    func pinnedOrder() {
        let controls = OverlayControlPolicy.controls(
            pinState: .pinned,
            enabledActions: enabledActions,
            capability: .resolved(allCapabilities)
        )

        #expect(controls == [.unpin, .windowAction(.close), .windowAction(.minimize), .windowAction(.zoom)])
        #expect(controls.first?.id == OverlayControl.pin.id)
    }

    @Test("AX unavailable preserves enabled-action fallback and adds Pin")
    func unavailableFallback() {
        let controls = OverlayControlPolicy.controls(
            pinState: .unpinned,
            enabledActions: enabledActions,
            capability: .unavailable
        )

        #expect(controls == [.pin, .windowAction(.close), .windowAction(.minimize), .windowAction(.zoom)])
    }

    @Test("authoritative ineligible or native-full-screen resolution stays dark")
    func authoritativeRejection() {
        for state in [OverlayPinState.unpinned, .pinned, .pinning, .unpinning] {
            let controls = OverlayControlPolicy.controls(
                pinState: state,
                enabledActions: enabledActions,
                capability: .resolved(.none)
            )
            #expect(controls.isEmpty)
        }
    }

    @Test("indeterminate capability exposes no unsafe control cluster")
    func indeterminateIsDarkAndRetryable() {
        let controls = OverlayControlPolicy.controls(
            pinState: .unpinned,
            enabledActions: enabledActions,
            capability: .indeterminate
        )

        #expect(controls.isEmpty)
        #expect(OverlayCapabilityPolicy.outcome(for: .indeterminate).retry)
    }

    @Test("pin lifecycle keeps the toggle in the first hit-test position")
    func lifecycleOrder() {
        let states: [OverlayPinState] = [.unpinned, .pinning, .pinned, .unpinning]
        let firstIDs = states.map { state in
            OverlayControlPolicy.controls(
                pinState: state,
                enabledActions: enabledActions,
                capability: .resolved(allCapabilities)
            ).first?.id
        }

        #expect(firstIDs == Array(repeating: OverlayControl.pin.id, count: states.count))
        #expect(OverlayControlPolicy.controls(
            pinState: .pinning,
            enabledActions: enabledActions,
            capability: .resolved(allCapabilities)
        ).first?.isEnabled == false)
        #expect(OverlayControlPolicy.controls(
            pinState: .unpinning,
            enabledActions: enabledActions,
            capability: .resolved(allCapabilities)
        ).first?.isEnabled == false)
    }

    @Test("pin and unpin failures restore the safe ownership state")
    func lifecycleFailures() {
        #expect(OverlayPinState.unpinned.applying(.startPinning) == .pinning)
        #expect(OverlayPinState.pinning.applying(.pinFailed) == .unpinned)
        #expect(OverlayPinState.pinning.applying(.pinSucceeded) == .pinned)
        #expect(OverlayPinState.pinned.applying(.startUnpinning) == .unpinning)
        #expect(OverlayPinState.unpinning.applying(.unpinFailed) == .pinned)
        #expect(OverlayPinState.unpinning.applying(.unpinSucceeded) == .unpinned)
    }
}
