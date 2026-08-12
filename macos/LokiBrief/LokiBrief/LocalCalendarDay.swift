import CryptoKit
import Foundation
import SwiftData

/// A civil calendar day. This is the authoritative representation for
/// user-facing briefing dates; `Date` remains the representation for instants.
struct LocalCalendarDay: Codable, Hashable, Identifiable, Sendable, Comparable {
    enum DisplayStyle: Sendable {
        case complete
        case abbreviated
        case medium
        case short

        fileprivate var formatterStyle: DateFormatter.Style {
            switch self {
            case .complete: .full
            case .abbreviated: .medium
            case .medium: .long
            case .short: .short
            }
        }
    }

    let year: Int
    let month: Int
    let day: Int

    var id: String { storageValue }

    /// Stable persistence and identity material. It is deliberately independent
    /// of UTC and never derives from epoch-day truncation.
    var storageValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    var compactValue: String {
        String(format: "%04d%02d%02d", year, month, day)
    }

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(storageValue: String) {
        let parts = storageValue.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count >= 4,
              parts[1].count == 2,
              parts[2].count == 2,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              year > 0,
              (1...13).contains(month),
              (1...31).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    static func resolve(
        containing instant: Date,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> LocalCalendarDay {
        // This overload applies the supplied zone without mutating the
        // autoupdating calendar, so each production call observes current user
        // settings while tests can inject a deterministic calendar and zone.
        let components = calendar.dateComponents(in: timeZone, from: instant)
        return LocalCalendarDay(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    /// Compatibility anchor for legacy `Date` fields. User-facing code must
    /// format `LocalCalendarDay` directly instead of treating this as day truth.
    func referenceDate(
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> Date? {
        var components = DateComponents()
        components.calendar = calendar
        components.timeZone = timeZone
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return calendar.date(from: components)
    }

    func formatted(
        _ style: DisplayStyle,
        locale: Locale = .autoupdatingCurrent,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> String {
        guard let referenceDate = referenceDate(calendar: calendar, timeZone: timeZone) else {
            return storageValue
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = timeZone
        formatter.dateStyle = style.formatterStyle
        formatter.timeStyle = .none
        return formatter.string(from: referenceDate)
    }

    static func < (lhs: LocalCalendarDay, rhs: LocalCalendarDay) -> Bool {
        if lhs.year != rhs.year { return lhs.year < rhs.year }
        if lhs.month != rhs.month { return lhs.month < rhs.month }
        return lhs.day < rhs.day
    }
}

struct LocalCalendarTimestamp: Hashable, Sendable {
    let day: LocalCalendarDay
    let hour: Int
    let minute: Int
    let second: Int
    let millisecond: Int
    let timeZoneIdentifier: String

    var filenameValue: String {
        String(
            format: "%@-%02d%02d%02d%03d",
            day.compactValue,
            hour,
            minute,
            second,
            millisecond
        )
    }

    static func resolve(
        _ instant: Date,
        calendar: Calendar = .autoupdatingCurrent,
        timeZone: TimeZone = .autoupdatingCurrent
    ) -> LocalCalendarTimestamp {
        let components = calendar.dateComponents(in: timeZone, from: instant)
        return .init(
            day: .init(
                year: components.year ?? 1970,
                month: components.month ?? 1,
                day: components.day ?? 1
            ),
            hour: components.hour ?? 0,
            minute: components.minute ?? 0,
            second: components.second ?? 0,
            millisecond: (components.nanosecond ?? 0) / 1_000_000,
            timeZoneIdentifier: timeZone.identifier
        )
    }
}

enum LocalCalendarExportFilename {
    static func make(
        timestamp: LocalCalendarTimestamp,
        uniqueIdentifier: UUID = UUID()
    ) -> String {
        // The readable prefix remains local-calendar based. The identifier
        // prevents two exports from replacing one another even when they are
        // created from the same timestamp or different app processes.
        "loki-vault-\(timestamp.filenameValue)-\(uniqueIdentifier.uuidString.lowercased()).lokivault"
    }
}

struct BriefHistoryDayGroup: Identifiable, Hashable, Sendable {
    let day: LocalCalendarDay
    let entries: [BriefHistoryEntry]

    var id: String { day.storageValue }
}

enum BriefHistoryGrouping {
    static func group(_ entries: [BriefHistoryEntry]) -> [BriefHistoryDayGroup] {
        var orderedDays: [LocalCalendarDay] = []
        var entriesByDay: [LocalCalendarDay: [BriefHistoryEntry]] = [:]
        for entry in entries {
            if entriesByDay[entry.briefingDay] == nil { orderedDays.append(entry.briefingDay) }
            entriesByDay[entry.briefingDay, default: []].append(entry)
        }
        return orderedDays.map { .init(day: $0, entries: entriesByDay[$0, default: []]) }
    }
}

enum LocalCalendarDayOwnerType: String, Codable, CaseIterable, Sendable {
    case brief
    case occurrence
    case run
    case delivery
}

enum LocalCalendarDayResolutionSource: String, Codable, Sendable {
    case createdFromCurrentUserContext = "created_current_user_context"
    case storedOccurrence = "stored_occurrence"
    case linkedOccurrence = "linked_occurrence"
    case linkedBrief = "linked_brief"
    case generatedAtMigration = "generated_at_migration"
    case scheduledForMigration = "scheduled_for_migration"
    case reservedAtMigration = "reserved_at_migration"
}

@Model final class StoredLocalCalendarDay {
    @Attribute(.unique) var id: String
    var ownerTypeRaw: String
    var ownerIdentifierHash: String
    var year: Int
    var month: Int
    var day: Int
    var calendarIdentifier: String
    var timeZoneIdentifier: String
    var canonicalKey: String
    var resolutionSourceRaw: String
    var recordedAt: Date

    init(
        ownerType: LocalCalendarDayOwnerType,
        ownerIdentifier: String,
        day: LocalCalendarDay,
        calendar: Calendar,
        timeZone: TimeZone,
        resolutionSource: LocalCalendarDayResolutionSource,
        recordedAt: Date = .now
    ) {
        let ownerHash = Self.hash(ownerIdentifier)
        self.id = "\(ownerType.rawValue).\(ownerHash)"
        self.ownerTypeRaw = ownerType.rawValue
        self.ownerIdentifierHash = ownerHash
        self.year = day.year
        self.month = day.month
        self.day = day.day
        self.calendarIdentifier = String(describing: calendar.identifier)
        self.timeZoneIdentifier = timeZone.identifier
        self.canonicalKey = day.storageValue
        self.resolutionSourceRaw = resolutionSource.rawValue
        self.recordedAt = recordedAt
    }

    var localDay: LocalCalendarDay {
        LocalCalendarDay(year: year, month: month, day: day)
    }

    var ownerType: LocalCalendarDayOwnerType? {
        LocalCalendarDayOwnerType(rawValue: ownerTypeRaw)
    }

    static func identifier(ownerType: LocalCalendarDayOwnerType, ownerIdentifier: String) -> String {
        "\(ownerType.rawValue).\(hash(ownerIdentifier))"
    }

    private static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct LocalCalendarDayMigrationReport: Equatable, Sendable {
    var occurrencesBackfilled = 0
    var briefsBackfilled = 0
    var runsBackfilled = 0
    var deliveriesBackfilled = 0
    var encodedBriefsRewritten = 0
    var runMetadataRewritten = 0

    var totalSidecars: Int {
        occurrencesBackfilled + briefsBackfilled + runsBackfilled + deliveriesBackfilled
    }

    static let none = LocalCalendarDayMigrationReport()
}

@MainActor
extension LocalStore {
    func localCalendarDay(
        ownerType: LocalCalendarDayOwnerType,
        ownerIdentifier: String
    ) -> LocalCalendarDay? {
        let identifier = StoredLocalCalendarDay.identifier(
            ownerType: ownerType,
            ownerIdentifier: ownerIdentifier
        )
        return try? container.mainContext.fetch(FetchDescriptor<StoredLocalCalendarDay>())
            .first(where: { $0.id == identifier })?
            .localDay
    }

    @discardableResult
    func persistLocalCalendarDay(
        ownerType: LocalCalendarDayOwnerType,
        ownerIdentifier: String,
        day: LocalCalendarDay,
        resolutionSource: LocalCalendarDayResolutionSource,
        calendar: Calendar? = nil,
        timeZone: TimeZone? = nil,
        recordedAt: Date = .now
    ) throws -> Bool {
        let context = container.mainContext
        let identifier = StoredLocalCalendarDay.identifier(
            ownerType: ownerType,
            ownerIdentifier: ownerIdentifier
        )
        if try context.fetch(FetchDescriptor<StoredLocalCalendarDay>()).contains(where: { $0.id == identifier }) {
            return false
        }
        context.insert(StoredLocalCalendarDay(
            ownerType: ownerType,
            ownerIdentifier: ownerIdentifier,
            day: day,
            calendar: calendar ?? userCalendarProvider(),
            timeZone: timeZone ?? userTimeZoneProvider(),
            resolutionSource: resolutionSource,
            recordedAt: recordedAt
        ))
        return true
    }

    func deleteLocalCalendarDay(
        ownerType: LocalCalendarDayOwnerType,
        ownerIdentifier: String
    ) throws {
        let identifier = StoredLocalCalendarDay.identifier(
            ownerType: ownerType,
            ownerIdentifier: ownerIdentifier
        )
        for stored in try container.mainContext.fetch(FetchDescriptor<StoredLocalCalendarDay>()) where stored.id == identifier {
            container.mainContext.delete(stored)
        }
    }

    func localCalendarDaySidecars() throws -> [StoredLocalCalendarDay] {
        try container.mainContext.fetch(FetchDescriptor<StoredLocalCalendarDay>()).sorted { $0.id < $1.id }
    }

    @discardableResult
    func backfillLocalCalendarDays() throws -> LocalCalendarDayMigrationReport {
        typealias Evidence = (
            day: LocalCalendarDay,
            calendar: Calendar,
            timeZone: TimeZone,
            source: LocalCalendarDayResolutionSource
        )

        let context = container.mainContext
        let userCalendar = userCalendarProvider()
        let userTimeZone = userTimeZoneProvider()
        var report = LocalCalendarDayMigrationReport.none

        let occurrences = try context.fetch(FetchDescriptor<StoredScheduleOccurrence>())
        var occurrenceEvidenceByHash: [String: Evidence] = [:]
        for occurrence in occurrences {
            let timeZone = TimeZone(identifier: occurrence.resolvedTimeZoneIdentifier) ?? userTimeZone
            let historicalCalendar = Calendar(identifier: .gregorian)
            let day = localCalendarDay(ownerType: .occurrence, ownerIdentifier: occurrence.id)
                ?? LocalCalendarDay(storageValue: occurrence.intendedLocalDate)
                ?? LocalCalendarDay.resolve(
                    containing: occurrence.resolvedExecutionDate,
                    calendar: historicalCalendar,
                    timeZone: timeZone
                )
            let evidence: Evidence = (day, historicalCalendar, timeZone, .storedOccurrence)
            occurrenceEvidenceByHash[ScheduledBriefingPrivacy.hashIdentifier(occurrence.id)] = evidence
            if try persistLocalCalendarDay(
                ownerType: .occurrence,
                ownerIdentifier: occurrence.id,
                day: day,
                resolutionSource: .storedOccurrence,
                calendar: historicalCalendar,
                timeZone: timeZone,
                recordedAt: occurrence.updatedAt
            ) {
                report.occurrencesBackfilled += 1
            }
        }

        let runs = try context.fetch(FetchDescriptor<StoredScheduledBriefingRun>())
        let runsByBriefID = Dictionary(grouping: runs.compactMap { run in
            run.briefID.map { ($0, run) }
        }, by: { $0.0 })

        let storedBriefs = try context.fetch(FetchDescriptor<StoredBrief>())
        var briefEvidenceByID: [String: Evidence] = [:]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for stored in storedBriefs {
            let decoded = try? stored.decodedBrief()
            let linkedOccurrence = runsByBriefID[stored.id]?
                .compactMap { occurrenceEvidenceByHash[$0.1.occurrenceHash] }
                .first
            let existingDay = localCalendarDay(ownerType: .brief, ownerIdentifier: stored.id)
            let evidence: Evidence
            if let existingDay {
                evidence = (existingDay, userCalendar, userTimeZone, .linkedBrief)
            } else if let explicit = decoded?.briefingDay {
                evidence = (explicit, userCalendar, userTimeZone, .createdFromCurrentUserContext)
            } else if let linkedOccurrence {
                evidence = (linkedOccurrence.day, linkedOccurrence.calendar, linkedOccurrence.timeZone, .linkedOccurrence)
            } else {
                evidence = (
                    LocalCalendarDay.resolve(
                        containing: stored.generatedAt,
                        calendar: userCalendar,
                        timeZone: userTimeZone
                    ),
                    userCalendar,
                    userTimeZone,
                    .generatedAtMigration
                )
            }
            briefEvidenceByID[stored.id] = evidence
            if let decoded, decoded.briefingDay == nil {
                let migratedBrief = decoded.replacingBriefingDay(
                    evidence.day,
                    calendar: evidence.calendar,
                    timeZone: evidence.timeZone
                )
                stored.encodedBrief = try encoder.encode(migratedBrief)
                stored.title = migratedBrief.title
                report.encodedBriefsRewritten += 1
            }
            if try persistLocalCalendarDay(
                ownerType: .brief,
                ownerIdentifier: stored.id,
                day: evidence.day,
                resolutionSource: evidence.source,
                calendar: evidence.calendar,
                timeZone: evidence.timeZone,
                recordedAt: stored.generatedAt
            ) {
                report.briefsBackfilled += 1
            }
        }

        var runEvidenceByOccurrenceHash: [String: Evidence] = [:]
        for run in runs {
            let persistedMetadataDay = (try? run.planMetadata())?.briefingDay
            let evidence = occurrenceEvidenceByHash[run.occurrenceHash]
                ?? run.briefID.flatMap { briefEvidenceByID[$0] }
                ?? persistedMetadataDay.map {
                    Evidence($0, userCalendar, userTimeZone, .createdFromCurrentUserContext)
                }
                ?? Evidence(
                    LocalCalendarDay.resolve(
                        containing: run.scheduledFor,
                        calendar: userCalendar,
                        timeZone: userTimeZone
                    ),
                    userCalendar,
                    userTimeZone,
                    .scheduledForMigration
                )
            runEvidenceByOccurrenceHash[run.occurrenceHash] = evidence
            if run.backfillBriefingDayMetadata(evidence.day) { report.runMetadataRewritten += 1 }
            if try persistLocalCalendarDay(
                ownerType: .run,
                ownerIdentifier: run.id,
                day: evidence.day,
                resolutionSource: occurrenceEvidenceByHash[run.occurrenceHash] == nil ? evidence.source : .linkedOccurrence,
                calendar: evidence.calendar,
                timeZone: evidence.timeZone,
                recordedAt: run.updatedAt
            ) {
                report.runsBackfilled += 1
            }
        }

        for delivery in try context.fetch(FetchDescriptor<StoredDeliveryRecord>()) {
            let evidence = delivery.briefID.flatMap { briefEvidenceByID[$0] }
                ?? runEvidenceByOccurrenceHash[delivery.occurrenceIdentifierHash]
                ?? occurrenceEvidenceByHash[delivery.occurrenceIdentifierHash]
                ?? Evidence(
                    LocalCalendarDay.resolve(
                        containing: delivery.reservedAt,
                        calendar: userCalendar,
                        timeZone: userTimeZone
                    ),
                    userCalendar,
                    userTimeZone,
                    .reservedAtMigration
                )
            if try persistLocalCalendarDay(
                ownerType: .delivery,
                ownerIdentifier: delivery.id,
                day: evidence.day,
                resolutionSource: delivery.briefID.flatMap { briefEvidenceByID[$0] } == nil ? evidence.source : .linkedBrief,
                calendar: evidence.calendar,
                timeZone: evidence.timeZone,
                recordedAt: delivery.reservedAt
            ) {
                report.deliveriesBackfilled += 1
            }
        }

        if report.totalSidecars > 0 || report.encodedBriefsRewritten > 0 || report.runMetadataRewritten > 0 {
            try context.save()
        }
        return report
    }
}
