import Foundation
import UserNotifications

protocol UserNotificationCenterClient: Sendable {
    func authorizationState() async -> NotificationAuthorizationState
    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState
    func submit(_ submission: NotificationSubmission) async throws
    func removePending(identifiers: [String]) async
    func removeDelivered(identifiers: [String]) async
    func removeAllPending() async
    func removeAllDelivered() async
}

struct SystemUserNotificationCenterClient: UserNotificationCenterClient, @unchecked Sendable {
    private let center: UNUserNotificationCenter

    init(center: UNUserNotificationCenter = .current()) {
        self.center = center
    }

    func authorizationState() async -> NotificationAuthorizationState {
        await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: Self.map(settings.authorizationStatus))
            }
        }
    }

    func requestExplicitAuthorization() async throws -> NotificationAuthorizationState {
        _ = try await center.requestAuthorization(options: [.alert])
        return await authorizationState()
    }

    func submit(_ submission: NotificationSubmission) async throws {
        let content = UNMutableNotificationContent()
        content.title = submission.title
        content.body = submission.body
        content.categoryIdentifier = submission.categoryIdentifier
        content.userInfo = submission.userInfo
        let request = UNNotificationRequest(identifier: submission.identifier, content: content, trigger: nil)
        try await center.add(request)
    }

    func removePending(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDelivered(identifiers: [String]) async {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func removeAllPending() async {
        center.removeAllPendingNotificationRequests()
    }

    func removeAllDelivered() async {
        center.removeAllDeliveredNotifications()
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationAuthorizationState {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        case .ephemeral: .ephemeral
        @unknown default: .unsupported
        }
    }
}

actor NotificationDeliveryService {
    private let center: any UserNotificationCenterClient
    private let traceSink: NotificationTraceSink
    private var epoch: UInt64 = 0
    private var activeIdentifiers: Set<String> = []

    init(
        center: any UserNotificationCenterClient = SystemUserNotificationCenterClient(),
        traceSink: @escaping NotificationTraceSink = { _ in }
    ) {
        self.center = center
        self.traceSink = traceSink
    }

    /// Reads system truth. This method never requests authorization.
    func refreshAuthorization() async -> NotificationAuthorizationState {
        let state = await center.authorizationState()
        traceSink(.init(
            event: "notification_authorization",
            traceID: UUID().uuidString.lowercased(),
            status: state == .error ? .failed : .success,
            reasonCode: "authorization_\(state.rawValue)"
        ))
        return state
    }

    /// This is the only authorization-requesting entry point. Its reason type has
    /// no startup, migration, or scheduled-run case.
    func requestAuthorization(
        reason: NotificationAuthorizationRequestReason
    ) async -> NotificationAuthorizationState {
        let traceID = UUID().uuidString.lowercased()
        traceSink(.init(
            event: "notification_authorization",
            traceID: traceID,
            status: .started,
            reasonCode: reason.rawValue
        ))
        do {
            let state = try await center.requestExplicitAuthorization()
            traceSink(.init(
                event: "notification_authorization",
                traceID: traceID,
                status: state.permitsDelivery ? .success : .degraded,
                reasonCode: "authorization_\(state.rawValue)"
            ))
            return state
        } catch {
            traceSink(.init(
                event: "notification_authorization",
                traceID: traceID,
                status: .failed,
                reasonCode: "authorization_request_failed"
            ))
            return .error
        }
    }

    /// The caller must create a durable, unique reservation for the occurrence
    /// before passing `.reserved`. This keeps the service from treating an
    /// in-memory set as the authoritative delivery ledger.
    func deliver(
        _ input: NotificationDeliveryInput,
        reservation: NotificationDeliveryReservation
    ) async -> NotificationDeliveryOutcome {
        let submission = LokiNotificationContract.content(for: input)
        let traceID = UUID().uuidString.lowercased()
        let operationEpoch = epoch

        guard reservation == .reserved else {
            traceSink(.init(
                event: "notification_delivery",
                traceID: traceID,
                status: .skipped,
                reasonCode: reservation == .alreadySubmitted ? "duplicate_persisted" : "delivery_suppressed",
                notificationIdentifier: submission.identifier
            ))
            return reservation == .alreadySubmitted ? .duplicateSuppressed : .notRequested
        }
        guard input.isEligible else {
            traceSink(.init(
                event: "notification_delivery",
                traceID: traceID,
                status: .skipped,
                reasonCode: "run_not_eligible",
                notificationIdentifier: submission.identifier
            ))
            return .ineligibleRun
        }
        guard LokiNotificationContract.validBriefIdentifier(input.briefID) else {
            traceSink(.init(
                event: "notification_delivery",
                traceID: traceID,
                status: .failed,
                reasonCode: "invalid_brief_identifier",
                notificationIdentifier: submission.identifier
            ))
            return .addFailed
        }
        guard !activeIdentifiers.contains(submission.identifier) else {
            return .duplicateSuppressed
        }

        let authorization = await center.authorizationState()
        guard operationEpoch == epoch else {
            await remove(identifier: submission.identifier)
            return tracedSkip(.removed, reason: "stale_before_submission_removed", submission: submission, traceID: traceID)
        }
        switch authorization {
        case .authorized, .provisional, .ephemeral:
            break
        case .notDetermined:
            return tracedSkip(.authorizationNotDetermined, reason: "authorization_not_determined", submission: submission, traceID: traceID)
        case .denied:
            return tracedSkip(.authorizationDenied, reason: "authorization_denied", submission: submission, traceID: traceID)
        case .unsupported:
            return tracedSkip(.unsupported, reason: "authorization_unsupported", submission: submission, traceID: traceID)
        case .error:
            return tracedSkip(.addFailed, reason: "authorization_error", submission: submission, traceID: traceID)
        }

        activeIdentifiers.insert(submission.identifier)
        traceSink(.init(
            event: "notification_delivery",
            traceID: traceID,
            status: .started,
            reasonCode: "submission_started",
            notificationIdentifier: submission.identifier,
            itemCount: input.itemCount,
            sourceCount: input.sourceCount
        ))

        do {
            try await center.submit(submission)
            activeIdentifiers.remove(submission.identifier)
            guard operationEpoch == epoch else {
                await remove(identifier: submission.identifier)
                traceSink(.init(
                    event: "notification_delivery",
                    traceID: traceID,
                    status: .skipped,
                    reasonCode: "late_submission_removed",
                    notificationIdentifier: submission.identifier
                ))
                return .removed
            }
            traceSink(.init(
                event: "notification_delivery",
                traceID: traceID,
                status: .success,
                reasonCode: "submitted_to_system",
                notificationIdentifier: submission.identifier,
                itemCount: input.itemCount,
                sourceCount: input.sourceCount
            ))
            return .submitted
        } catch {
            activeIdentifiers.remove(submission.identifier)
            let isStale = operationEpoch != epoch
            if isStale { await remove(identifier: submission.identifier) }
            traceSink(.init(
                event: "notification_delivery",
                traceID: traceID,
                status: isStale ? .skipped : .failed,
                reasonCode: isStale ? "late_submission_removed" : "notification_add_failed",
                notificationIdentifier: submission.identifier
            ))
            return isStale ? .removed : .addFailed
        }
    }

    /// Invalidates in-flight submissions before asking the system to remove both
    /// pending and already-delivered notifications.
    func removeAll() async {
        epoch &+= 1
        let active = Array(activeIdentifiers)
        activeIdentifiers.removeAll()
        if !active.isEmpty {
            await center.removePending(identifiers: active)
            await center.removeDelivered(identifiers: active)
        }
        await center.removeAllPending()
        await center.removeAllDelivered()
        traceSink(.init(
            event: "notification_delivery",
            traceID: UUID().uuidString.lowercased(),
            status: .success,
            reasonCode: "all_notification_artifacts_removed"
        ))
    }

    /// Cancels only submissions that are currently crossing the system boundary.
    /// Already-delivered notifications from prior completed runs remain intact.
    func cancelActiveSubmissions(reasonCode: String) async {
        epoch &+= 1
        let active = Array(activeIdentifiers)
        activeIdentifiers.removeAll()
        for identifier in active {
            await remove(identifier: identifier)
        }
        traceSink(.init(
            event: "notification_delivery",
            traceID: UUID().uuidString.lowercased(),
            status: active.isEmpty ? .skipped : .success,
            reasonCode: active.isEmpty ? "active_notification_cancellation_not_required" : String(reasonCode.prefix(120)),
            itemCount: active.count
        ))
    }

    func remove(identifier: String) async {
        await center.removePending(identifiers: [identifier])
        await center.removeDelivered(identifiers: [identifier])
    }

    private func tracedSkip(
        _ outcome: NotificationDeliveryOutcome,
        reason: String,
        submission: NotificationSubmission,
        traceID: String
    ) -> NotificationDeliveryOutcome {
        traceSink(.init(
            event: "notification_delivery",
            traceID: traceID,
            status: .skipped,
            reasonCode: reason,
            notificationIdentifier: submission.identifier
        ))
        return outcome
    }
}
