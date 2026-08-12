import Foundation
import SwiftData

@MainActor
extension LocalStore {
    private var p5Context: ModelContext { container.mainContext }

    func primaryBriefSchedule() throws -> BriefSchedule {
        if let stored = try p5Context.fetch(FetchDescriptor<StoredBriefSchedule>()).first(where: { $0.id == BriefSchedule.primaryID }) {
            return try stored.domainSchedule()
        }
        let schedule = BriefSchedule()
        p5Context.insert(try StoredBriefSchedule(schedule: schedule))
        try p5Context.save()
        return schedule
    }

    func savePrimaryBriefSchedule(_ schedule: BriefSchedule, at date: Date = .now) throws {
        if let stored = try p5Context.fetch(FetchDescriptor<StoredBriefSchedule>()).first(where: { $0.id == schedule.id }) {
            try stored.update(from: schedule, updatedAt: date)
        } else {
            p5Context.insert(try StoredBriefSchedule(schedule: schedule, updatedAt: date))
        }
        try p5Context.save()
    }

    func notificationDeliverySettings() throws -> StoredNotificationDeliverySettings {
        if let stored = try p5Context.fetch(FetchDescriptor<StoredNotificationDeliverySettings>()).first(where: { $0.id == "primary" }) {
            return stored
        }
        let settings = StoredNotificationDeliverySettings()
        p5Context.insert(settings)
        try p5Context.save()
        return settings
    }

    func reserveNotificationDelivery(
        input: NotificationDeliveryInput,
        authorization: NotificationAuthorizationState,
        at date: Date = .now
    ) throws -> (NotificationDeliveryReservation, StoredDeliveryRecord) {
        let notificationID = LokiNotificationContract.stableIdentifier(occurrenceKey: input.occurrenceKey)
        if let stored = try p5Context.fetch(FetchDescriptor<StoredDeliveryRecord>()).first(where: { $0.notificationIdentifier == notificationID }) {
            if stored.outcome == .submitted { return (.alreadySubmitted, stored) }
            stored.authorization = authorization
            stored.privacyMode = input.privacyMode
            stored.itemCount = input.itemCount
            stored.sourceCount = input.sourceCount
            stored.briefID = input.briefID
            try persistLocalCalendarDay(
                ownerType: .delivery,
                ownerIdentifier: stored.id,
                day: input.briefingDay,
                resolutionSource: .linkedBrief,
                recordedAt: date
            )
            try p5Context.save()
            return (.reserved, stored)
        }
        let stored = StoredDeliveryRecord(
            id: "delivery-\(notificationID)",
            notificationIdentifier: notificationID,
            occurrenceIdentifierHash: SchedulePrivacy.hashIdentifier(input.occurrenceKey),
            briefID: input.briefID,
            authorization: authorization,
            privacyMode: input.privacyMode,
            itemCount: input.itemCount,
            sourceCount: input.sourceCount,
            reservedAt: date,
            reasonCode: "delivery_reserved"
        )
        p5Context.insert(stored)
        try persistLocalCalendarDay(
            ownerType: .delivery,
            ownerIdentifier: stored.id,
            day: input.briefingDay,
            resolutionSource: .linkedBrief,
            recordedAt: date
        )
        try p5Context.save()
        return (.reserved, stored)
    }

    func recordNotificationDelivery(
        identifier: String,
        outcome: NotificationDeliveryOutcome,
        authorization: NotificationAuthorizationState,
        reasonCode: String,
        at date: Date = .now
    ) throws {
        guard let stored = try p5Context.fetch(FetchDescriptor<StoredDeliveryRecord>()).first(where: { $0.notificationIdentifier == identifier }) else { return }
        stored.record(outcome: outcome, authorization: authorization, at: date, reasonCode: reasonCode)
        try p5Context.save()
    }

    @discardableResult
    func recordValidatedNotificationResponse(
        identifier: String,
        briefID: String,
        at date: Date = .now
    ) throws -> Bool {
        guard let stored = try p5Context.fetch(FetchDescriptor<StoredDeliveryRecord>()).first(where: { $0.notificationIdentifier == identifier }),
              stored.briefID == briefID,
              try brief(id: briefID) != nil
        else { return false }
        stored.recordResponse(at: date)
        try p5Context.save()
        return true
    }

    func deliveryRecords() throws -> [StoredDeliveryRecord] {
        try p5Context.fetch(FetchDescriptor<StoredDeliveryRecord>()).sorted { $0.reservedAt > $1.reservedAt }
    }

    func scheduledBriefingRuns() throws -> [StoredScheduledBriefingRun] {
        try p5Context.fetch(FetchDescriptor<StoredScheduledBriefingRun>()).sorted { $0.startedAt > $1.startedAt }
    }

    func markScheduledBriefingRunsInterrupted(at date: Date = .now) throws -> Int {
        let runs = try p5Context.fetch(FetchDescriptor<StoredScheduledBriefingRun>())
        var count = 0
        for run in runs where ![ScheduledBriefingRunState.complete.rawValue, ScheduledBriefingRunState.partial.rawValue, ScheduledBriefingRunState.cancelled.rawValue, ScheduledBriefingRunState.failed.rawValue, ScheduledBriefingRunState.interrupted.rawValue, ScheduledBriefingRunState.skipped.rawValue].contains(run.coordinatorStateRaw) {
            run.stateRaw = ScheduledRunState.waiting.rawValue
            run.coordinatorStateRaw = ScheduledBriefingRunState.interrupted.rawValue
            run.reasonCode = "interrupted_by_termination"
            run.updatedAt = date
            run.completedAt = date
            count += 1
        }
        if count > 0 { try p5Context.save() }
        return count
    }

    func recordNextScheduledOccurrence(runID: String, next: Date?) throws {
        guard let run = try p5Context.fetch(FetchDescriptor<StoredScheduledBriefingRun>()).first(where: { $0.id == runID }) else { return }
        run.nextScheduledOccurrence = next
        try p5Context.save()
    }
}

@MainActor
final class ScheduledBriefingPersistenceAdapter: ScheduledBriefingRunPersisting {
    private let store: LocalStore
    private var context: ModelContext { store.container.mainContext }

    init(store: LocalStore) { self.store = store }

    func recordTransition(_ snapshot: ScheduledBriefingRunSnapshot) throws {
        if let stored = try context.fetch(FetchDescriptor<StoredScheduledBriefingRun>()).first(where: { $0.id == snapshot.plan.id }) {
            stored.update(with: snapshot)
        } else {
            context.insert(StoredScheduledBriefingRun(snapshot: snapshot))
        }
        try store.persistLocalCalendarDay(
            ownerType: .run,
            ownerIdentifier: snapshot.plan.id,
            day: snapshot.plan.briefingDay,
            resolutionSource: .linkedOccurrence,
            recordedAt: snapshot.updatedAt
        )
        try context.save()
    }

    func commit(_ commit: ScheduledBriefingCommit) throws {
        let result = commit.result
        let stored: StoredScheduledBriefingRun
        if let existing = try context.fetch(FetchDescriptor<StoredScheduledBriefingRun>()).first(where: { $0.id == result.plan.id }) {
            existing.update(with: result)
            stored = existing
        } else {
            let snapshot = ScheduledBriefingRunSnapshot(
                plan: result.plan,
                state: result.state,
                reasonCode: result.reasonCode,
                traceID: UUID().uuidString.lowercased(),
                startedAt: result.startedAt,
                updatedAt: result.completedAt,
                completedAt: result.completedAt,
                sourceOutcomes: result.sourceOutcomes,
                vaultOutcome: result.vaultOutcome,
                briefID: result.brief?.id,
                fallbackReasonCode: result.fallbackReasonCode,
                failureReasonCodes: result.failureReasonCodes
            )
            stored = StoredScheduledBriefingRun(snapshot: snapshot)
            context.insert(stored)
        }
        for prior in try context.fetch(FetchDescriptor<StoredScheduledBriefingSourceResult>()).filter({ $0.runID == result.plan.id }) {
            context.delete(prior)
        }
        for outcome in result.sourceOutcomes {
            context.insert(StoredScheduledBriefingSourceResult(runID: result.plan.id, outcome: outcome, startedAt: result.startedAt, completedAt: result.completedAt))
        }
        if let brief = result.brief { try store.record(brief) }
        if let provenance = result.generationProvenance { try store.persistGenerationProvenance(provenance) }
        try store.persistLocalCalendarDay(
            ownerType: .run,
            ownerIdentifier: result.plan.id,
            day: result.plan.briefingDay,
            resolutionSource: .linkedOccurrence,
            recordedAt: result.completedAt
        )
        _ = stored
        try context.save()
    }
}
