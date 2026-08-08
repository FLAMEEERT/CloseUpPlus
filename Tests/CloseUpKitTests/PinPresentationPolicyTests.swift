import Testing

@testable import CloseUpKit

@Suite("PinPresentationPolicy")
struct PinPresentationPolicyTests {
    @Test("a pin established during Mission Control binds its Space while hidden")
    func missionControlEstablishmentBindsThenStaysHidden() {
        #expect(
            PinPresentationPolicy.establishmentActions(
                missionControlVisible: true
            ) == [.bindToCurrentSpaceWhileHidden]
        )
    }

    @Test("Mission Control hides an already-presented panel")
    func missionControlEntryHidesPanel() {
        #expect(
            PinPresentationPolicy.missionControlActions(
                visible: true,
                panelIsOnActiveSpace: true
            ) == [.hide]
        )
    }

    @Test("Mission Control exit presents a panel only on its active Space")
    func missionControlExitPreservesOneSpaceConstraint() {
        #expect(
            PinPresentationPolicy.missionControlActions(
                visible: false,
                panelIsOnActiveSpace: true
            ) == [.show]
        )
        #expect(
            PinPresentationPolicy.missionControlActions(
                visible: false,
                panelIsOnActiveSpace: false
            ) == [.remainHidden]
        )
    }

    @Test("a pin established outside Mission Control presents immediately")
    func nonMissionControlEstablishmentPresents() {
        #expect(
            PinPresentationPolicy.establishmentActions(
                missionControlVisible: false
            ) == [.show]
        )
    }
}
