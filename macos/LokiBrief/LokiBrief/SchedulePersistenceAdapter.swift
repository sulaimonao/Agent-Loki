import Foundation
import SwiftData

protocol SchedulePersisting: Sendable {
    func loadPrimarySchedule() async throws -> BriefSchedule
    func save(_ schedule: BriefSchedule, at date: Date) async throws
    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState?
    func claim(
        _ occurrence: ScheduleOccurrence,
        trigger: ScheduleActivationTrigger,
        at date: Date
    ) async throws -> ScheduleClaimDisposition
    func mark(
        _ occurrence: ScheduleOccurrence,
        state: ScheduleOccurrenceState,
        reasonCode: String,
        at date: Date
    ) async throws
    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int
}

@MainActor
final class SchedulePersistenceAdapter: SchedulePersisting {
    private let store: LocalStore
    private var context: ModelContext { store.container.mainContext }

    init(store: LocalStore) {
        self.store = store
    }

    func loadPrimarySchedule() async throws -> BriefSchedule {
        if let stored = try context.fetch(FetchDescriptor<StoredBriefSchedule>()).first(where: {
            $0.id == BriefSchedule.primaryID
        }) {
            return try stored.domainSchedule()
        }
        let schedule = BriefSchedule()
        context.insert(try StoredBriefSchedule(schedule: schedule))
        try context.save()
        return schedule
    }

    func save(_ schedule: BriefSchedule, at date: Date) async throws {
        let schedules = try context.fetch(FetchDescriptor<StoredBriefSchedule>())
        if let stored = schedules.first(where: { $0.id == schedule.id }) {
            try stored.update(from: schedule, updatedAt: date)
        } else {
            context.insert(try StoredBriefSchedule(schedule: schedule, updatedAt: date))
        }
        try context.save()
    }

    func state(for occurrence: ScheduleOccurrence) async throws -> ScheduleOccurrenceState? {
        try matchingOccurrence(occurrence)?.state
    }

    func claim(
        _ occurrence: ScheduleOccurrence,
        trigger: ScheduleActivationTrigger,
        at date: Date
    ) async throws -> ScheduleClaimDisposition {
        if let stored = try matchingOccurrence(occurrence) {
            switch stored.state {
            case .succeeded:
                return .alreadySucceeded
            case .skipped, .canceled:
                return .terminal
            case .claimed, .pending:
                return .alreadyClaimed
            case .failed, .interrupted:
                let priorIdentifier = stored.id
                stored.id = occurrence.key.rawValue
                stored.resolvedTimeZoneIdentifier = occurrence.resolvedTimeZoneIdentifier
                stored.resolvedExecutionDate = occurrence.resolvedExecutionDate
                stored.stateRaw = ScheduleOccurrenceState.claimed.rawValue
                stored.activationTriggerRaw = trigger.rawValue
                stored.claimedAt = date
                stored.completedAt = nil
                stored.reasonCode = "occurrence_reclaimed"
                stored.updatedAt = date
                if priorIdentifier != stored.id {
                    try store.deleteLocalCalendarDay(ownerType: .occurrence, ownerIdentifier: priorIdentifier)
                }
                try persistBriefingDay(for: occurrence, at: date)
                try context.save()
                return .claimed
            }
        }
        context.insert(StoredScheduleOccurrence(
            occurrence: occurrence,
            state: .claimed,
            trigger: trigger,
            claimedAt: date,
            reasonCode: "occurrence_claimed",
            updatedAt: date
        ))
        try persistBriefingDay(for: occurrence, at: date)
        try context.save()
        return .claimed
    }

    func mark(
        _ occurrence: ScheduleOccurrence,
        state: ScheduleOccurrenceState,
        reasonCode: String,
        at date: Date
    ) async throws {
        if let stored = try matchingOccurrence(occurrence) {
            if stored.state == .succeeded, state != .succeeded { return }
            stored.stateRaw = state.rawValue
            stored.reasonCode = String(reasonCode.prefix(120))
            stored.updatedAt = date
            if state.isTerminal { stored.completedAt = date }
        } else {
            context.insert(StoredScheduleOccurrence(
                occurrence: occurrence,
                state: state,
                trigger: .scheduled,
                claimedAt: state == .claimed ? date : nil,
                completedAt: state.isTerminal ? date : nil,
                reasonCode: reasonCode,
                updatedAt: date
            ))
        }
        try persistBriefingDay(for: occurrence, at: date)
        try context.save()
    }

    func markNonterminalOccurrencesInterrupted(at date: Date) async throws -> Int {
        let stored = try context.fetch(FetchDescriptor<StoredScheduleOccurrence>())
        var count = 0
        for occurrence in stored where [.pending, .claimed].contains(occurrence.state) {
            occurrence.stateRaw = ScheduleOccurrenceState.interrupted.rawValue
            occurrence.reasonCode = "interrupted_by_termination"
            occurrence.updatedAt = date
            count += 1
        }
        if count > 0 { try context.save() }
        return count
    }

    private func matchingOccurrence(_ occurrence: ScheduleOccurrence) throws -> StoredScheduleOccurrence? {
        try context.fetch(FetchDescriptor<StoredScheduleOccurrence>()).first {
            $0.id == occurrence.key.rawValue || $0.slotKey == occurrence.slotKey.rawValue
        }
    }

    private func persistBriefingDay(for occurrence: ScheduleOccurrence, at date: Date) throws {
        try store.persistLocalCalendarDay(
            ownerType: .occurrence,
            ownerIdentifier: occurrence.key.rawValue,
            day: occurrence.briefingDay,
            resolutionSource: .storedOccurrence,
            calendar: store.userCalendarProvider(),
            timeZone: TimeZone(identifier: occurrence.resolvedTimeZoneIdentifier)
                ?? store.userTimeZoneProvider(),
            recordedAt: date
        )
    }
}
