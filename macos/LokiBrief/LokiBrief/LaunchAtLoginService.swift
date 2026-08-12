import Foundation
import ServiceManagement

enum LaunchAtLoginState: String, Codable, CaseIterable, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
    case unsupported
    case error
}

struct LaunchAtLoginSnapshot: Codable, Equatable, Sendable {
    let state: LaunchAtLoginState
    let desiredEnabled: Bool
    let reasonCode: String
    let checkedAt: Date
}

enum LaunchAtLoginSystemState: String, Sendable {
    case notRegistered
    case enabled
    case requiresApproval
    case notFound
}

enum LaunchAtLoginClientFailure: Error, Equatable, Sendable {
    case alreadyRegistered
    case launchDeniedByUser
    case unavailable
    case other(reasonCode: String)
}

protocol LaunchAtLoginSystemClient: Sendable {
    func currentState() async -> LaunchAtLoginSystemState
    func register() async throws
    func unregister() async throws
    func openLoginItemsSettings() async
}

struct SMAppServiceLaunchAtLoginClient: LaunchAtLoginSystemClient {
    func currentState() async -> LaunchAtLoginSystemState {
        switch SMAppService.mainApp.status {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        @unknown default: .notFound
        }
    }

    func register() async throws {
        do { try SMAppService.mainApp.register() }
        catch { throw Self.map(error) }
    }

    func unregister() async throws {
        do { try await SMAppService.mainApp.unregister() }
        catch { throw Self.map(error) }
    }

    func openLoginItemsSettings() async {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func map(_ error: Error) -> LaunchAtLoginClientFailure {
        let nsError = error as NSError
        let isServiceManagementError: Bool
        if #available(macOS 15.0, *) {
            isServiceManagementError = nsError.domain == SMAppServiceErrorDomain
        } else {
            // SMAppServiceErrorDomain was not public until macOS 15. The stable
            // Service Management error codes remain the only bounded signal.
            isServiceManagementError = true
        }
        if isServiceManagementError {
            if nsError.code == Int(kSMErrorAlreadyRegistered) { return .alreadyRegistered }
            if nsError.code == Int(kSMErrorLaunchDeniedByUser) { return .launchDeniedByUser }
            if nsError.code == Int(kSMErrorServiceUnavailable) { return .unavailable }
        }
        return .other(reasonCode: "launch_service_error_\(nsError.code)")
    }
}

actor LaunchAtLoginService {
    private let client: any LaunchAtLoginSystemClient
    private let registrationAllowed: Bool
    private let now: @Sendable () -> Date
    private let traceSink: ScheduleTraceSink
    private var desiredEnabled: Bool

    init(
        client: any LaunchAtLoginSystemClient,
        desiredEnabled: Bool,
        registrationAllowed: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: @escaping ScheduleTraceSink = { _ in }
    ) {
        self.client = client
        self.desiredEnabled = desiredEnabled
        self.registrationAllowed = registrationAllowed
        self.now = now
        self.traceSink = traceSink
    }

    static func live(
        desiredEnabled: Bool,
        isTesting: Bool = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil,
        traceSink: @escaping ScheduleTraceSink = { _ in }
    ) -> LaunchAtLoginService {
        LaunchAtLoginService(
            client: SMAppServiceLaunchAtLoginClient(),
            desiredEnabled: desiredEnabled,
            registrationAllowed: !isTesting,
            traceSink: traceSink
        )
    }

    func refresh() async -> LaunchAtLoginSnapshot {
        let state = await client.currentState()
        return snapshot(for: state, reasonCode: "launch_status_refreshed")
    }

    func registerExplicitly() async -> LaunchAtLoginSnapshot {
        guard registrationAllowed else {
            return snapshot(state: .unsupported, reasonCode: "launch_registration_disabled_in_tests")
        }
        desiredEnabled = true
        do {
            try await client.register()
            let actual = await client.currentState()
            let snapshot = snapshot(for: actual, reasonCode: "launch_registration_completed")
            trace(snapshot, status: actual == .enabled ? .success : .degraded)
            return snapshot
        } catch LaunchAtLoginClientFailure.alreadyRegistered {
            let actual = await client.currentState()
            let snapshot = snapshot(for: actual, reasonCode: "launch_already_registered")
            trace(snapshot, status: .success)
            return snapshot
        } catch LaunchAtLoginClientFailure.launchDeniedByUser {
            let snapshot = snapshot(state: .requiresApproval, reasonCode: "launch_approval_required")
            trace(snapshot, status: .degraded)
            return snapshot
        } catch LaunchAtLoginClientFailure.unavailable {
            let snapshot = snapshot(state: .error, reasonCode: "launch_service_unavailable")
            trace(snapshot, status: .failed)
            return snapshot
        } catch {
            let snapshot = snapshot(state: .error, reasonCode: "launch_registration_failed")
            trace(snapshot, status: .failed)
            return snapshot
        }
    }

    func unregisterExplicitly() async -> LaunchAtLoginSnapshot {
        guard registrationAllowed else {
            return snapshot(state: .unsupported, reasonCode: "launch_unregistration_disabled_in_tests")
        }
        do {
            try await client.unregister()
            desiredEnabled = false
            let actual = await client.currentState()
            let snapshot = snapshot(for: actual, reasonCode: "launch_unregistration_completed")
            trace(snapshot, status: actual == .notRegistered ? .success : .degraded)
            return snapshot
        } catch {
            let actual = await client.currentState()
            let snapshot = snapshot(for: actual, reasonCode: "launch_unregistration_failed")
            trace(snapshot, status: .failed)
            return snapshot
        }
    }

    func openLoginItemsSettingsExplicitly() async {
        guard registrationAllowed else { return }
        await client.openLoginItemsSettings()
    }

    func setDesiredEnabledForReconciliation(_ enabled: Bool) {
        desiredEnabled = enabled
    }

    private func snapshot(for systemState: LaunchAtLoginSystemState, reasonCode: String) -> LaunchAtLoginSnapshot {
        let state: LaunchAtLoginState = switch systemState {
        case .notRegistered: .notRegistered
        case .enabled: .enabled
        case .requiresApproval: .requiresApproval
        case .notFound: .notFound
        }
        return snapshot(state: state, reasonCode: reasonCode)
    }

    private func snapshot(state: LaunchAtLoginState, reasonCode: String) -> LaunchAtLoginSnapshot {
        .init(state: state, desiredEnabled: desiredEnabled, reasonCode: reasonCode, checkedAt: now())
    }

    private func trace(_ snapshot: LaunchAtLoginSnapshot, status: ScheduleTraceStatus) {
        traceSink(.init(
            timestamp: snapshot.checkedAt,
            event: .launchAtLogin,
            traceID: UUID().uuidString.lowercased(),
            spanID: UUID().uuidString.lowercased(),
            parentSpanID: nil,
            component: "launch-at-login",
            status: status,
            reasonCode: snapshot.reasonCode,
            occurrenceHash: nil,
            boundedCount: nil
        ))
    }
}
