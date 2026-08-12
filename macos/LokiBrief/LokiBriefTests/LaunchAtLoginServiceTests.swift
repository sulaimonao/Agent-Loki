import XCTest
@testable import LokiBrief

private actor LaunchAtLoginTestClient: LaunchAtLoginSystemClient {
    var state: LaunchAtLoginSystemState
    var registerFailure: LaunchAtLoginClientFailure?
    var unregisterFailure: LaunchAtLoginClientFailure?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0
    private(set) var openSettingsCalls = 0

    init(state: LaunchAtLoginSystemState) { self.state = state }

    func currentState() async -> LaunchAtLoginSystemState { state }

    func register() async throws {
        registerCalls += 1
        if let registerFailure { throw registerFailure }
        state = .enabled
    }

    func unregister() async throws {
        unregisterCalls += 1
        if let unregisterFailure { throw unregisterFailure }
        state = .notRegistered
    }

    func openLoginItemsSettings() async { openSettingsCalls += 1 }
    func setRegisterFailure(_ failure: LaunchAtLoginClientFailure?) { registerFailure = failure }
    func setUnregisterFailure(_ failure: LaunchAtLoginClientFailure?) { unregisterFailure = failure }
}

final class LaunchAtLoginServiceTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_768_406_400)

    func testActualSystemStatusMappingsRemainTruthful() async {
        for (system, expected) in [
            (LaunchAtLoginSystemState.notRegistered, LaunchAtLoginState.notRegistered),
            (.enabled, .enabled),
            (.requiresApproval, .requiresApproval),
            (.notFound, .notFound),
        ] {
            let client = LaunchAtLoginTestClient(state: system)
            let service = LaunchAtLoginService(client: client, desiredEnabled: false, now: { self.anchor })
            let snapshot = await service.refresh()
            XCTAssertEqual(snapshot.state, expected)
        }
    }

    func testRegistrationSuccessRefreshesActualStatus() async {
        let client = LaunchAtLoginTestClient(state: .notRegistered)
        let service = LaunchAtLoginService(client: client, desiredEnabled: false, now: { self.anchor })

        let snapshot = await service.registerExplicitly()
        let registerCalls = await client.registerCalls
        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertTrue(snapshot.desiredEnabled)
        XCTAssertEqual(registerCalls, 1)
    }

    func testAlreadyRegisteredIsReconciledFromSystemState() async {
        let client = LaunchAtLoginTestClient(state: .enabled)
        await client.setRegisterFailure(.alreadyRegistered)
        let service = LaunchAtLoginService(client: client, desiredEnabled: false, now: { self.anchor })

        let snapshot = await service.registerExplicitly()

        XCTAssertEqual(snapshot.state, .enabled)
        XCTAssertEqual(snapshot.reasonCode, "launch_already_registered")
    }

    func testDeniedRegistrationRequiresApprovalWithoutRepeatedPrompt() async {
        let client = LaunchAtLoginTestClient(state: .requiresApproval)
        await client.setRegisterFailure(.launchDeniedByUser)
        let service = LaunchAtLoginService(client: client, desiredEnabled: false, now: { self.anchor })

        let snapshot = await service.registerExplicitly()
        let registerCalls = await client.registerCalls

        XCTAssertEqual(snapshot.state, .requiresApproval)
        XCTAssertEqual(snapshot.reasonCode, "launch_approval_required")
        XCTAssertEqual(registerCalls, 1)
    }

    func testUnregisterDoesNotDisableSchedulePreferenceOutsideService() async {
        let client = LaunchAtLoginTestClient(state: .enabled)
        let service = LaunchAtLoginService(client: client, desiredEnabled: true, now: { self.anchor })

        let snapshot = await service.unregisterExplicitly()
        let unregisterCalls = await client.unregisterCalls

        XCTAssertEqual(snapshot.state, .notRegistered)
        XCTAssertFalse(snapshot.desiredEnabled)
        XCTAssertEqual(unregisterCalls, 1)
    }

    func testRegistrationAndSystemSettingsAreDisabledDuringTests() async {
        let client = LaunchAtLoginTestClient(state: .notRegistered)
        let service = LaunchAtLoginService(
            client: client,
            desiredEnabled: true,
            registrationAllowed: false,
            now: { self.anchor }
        )

        let snapshot = await service.registerExplicitly()
        await service.openLoginItemsSettingsExplicitly()
        let registerCalls = await client.registerCalls
        let openSettingsCalls = await client.openSettingsCalls
        XCTAssertEqual(snapshot.reasonCode, "launch_registration_disabled_in_tests")
        XCTAssertEqual(registerCalls, 0)
        XCTAssertEqual(openSettingsCalls, 0)
    }

    func testStoredPreferenceDoesNotOverrideActualSystemState() async {
        let client = LaunchAtLoginTestClient(state: .requiresApproval)
        let service = LaunchAtLoginService(client: client, desiredEnabled: true, now: { self.anchor })

        let snapshot = await service.refresh()

        XCTAssertTrue(snapshot.desiredEnabled)
        XCTAssertEqual(snapshot.state, .requiresApproval)
    }
}
