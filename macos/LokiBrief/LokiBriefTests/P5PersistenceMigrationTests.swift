import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class P5PersistenceMigrationTests: XCTestCase, @unchecked Sendable {
    func testPreEditedAtP3StoreMigratesToV6WithoutReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-pre-edited-at-p3-to-p5-\(UUID().uuidString.lowercased())", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV3PreEditedAt.self)
            let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: storeURL)
            let legacy = try ModelContainer(for: schema, configurations: [configuration])
            legacy.mainContext.insert(StoredSettings(density: .compact))
            legacy.mainContext.insert(LokiBriefSchemaV3PreEditedAt.StoredSlackMessageEvidence(
                id: "legacy-evidence",
                workspaceID: "workspace",
                workspaceName: "Workspace",
                conversationID: "channel",
                conversationName: "general",
                conversationKindRaw: "public_channel",
                messageTimestamp: "1710000000.000001",
                messageDate: Date(timeIntervalSince1970: 1_710_000_000),
                excerpt: "Preserve this legacy evidence.",
                authorID: "user",
                authorDisplayName: "User",
                authorKindRaw: "human",
                directlyMentionsCurrentUser: false,
                replyCount: 0,
                isEdited: false,
                permalink: nil,
                retrievedAt: Date(timeIntervalSince1970: 1_710_000_100),
                channelWeight: 1
            ))
            try legacy.mainContext.save()
        }

        let migrated = try LocalStore(url: storeURL)
        XCTAssertEqual(try migrated.settings().density, .compact)
        let evidence = try XCTUnwrap(try migrated.slackMessageEvidence(workspaceID: "workspace").first)
        XCTAssertEqual(evidence.id, "legacy-evidence")
        XCTAssertNil(evidence.editedAt)
    }

    func testDiskBackedP4StoreMigratesToV6WithoutResettingExistingSettings() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-p4-to-p5-\(UUID().uuidString.lowercased())", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV4.self)
            let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: storeURL)
            let legacy = try ModelContainer(for: schema, migrationPlan: LokiBriefMigrationPlanV4.self, configurations: [configuration])
            let settings = StoredSettings(
                preferredBriefingTime: Date(timeIntervalSince1970: 21_600),
                launchAtLoginPreference: true,
                notificationPreference: false,
                density: .compact,
                deterministicOnly: true
            )
            legacy.mainContext.insert(settings)
            try legacy.mainContext.save()
        }

        let migrated = try LocalStore(url: storeURL)
        XCTAssertEqual(try migrated.settings().preferredBriefingTime, Date(timeIntervalSince1970: 21_600))
        XCTAssertTrue(try migrated.settings().launchAtLoginPreference)
        XCTAssertEqual(try migrated.settings().density, .compact)
        XCTAssertFalse(try migrated.primaryBriefSchedule().enabled)
        XCTAssertEqual(try migrated.primaryBriefSchedule().missedRunPolicy, .runWithinGraceWindow)
        XCTAssertEqual(try migrated.primaryBriefSchedule().catchUpWindow.maximumAge, 6 * 60 * 60)
        XCTAssertFalse(try migrated.notificationDeliverySettings().enabledPreference)
        XCTAssertTrue(try migrated.scheduledBriefingRuns().isEmpty)
        XCTAssertTrue(try migrated.deliveryRecords().isEmpty)
    }

    func testPrePlanMetadataV5StoreMigratesToV7AndBackfillsLocalDayWithoutReset() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-pre-plan-metadata-v5-to-v6-\(UUID().uuidString.lowercased())", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let anchor = Date(timeIntervalSince1970: 1_721_234_567)
        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV5.self)
            let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: storeURL)
            let legacy = try ModelContainer(for: schema, configurations: [configuration])
            legacy.mainContext.insert(StoredSettings(density: .compact))
            legacy.mainContext.insert(LokiBriefSchemaV5.StoredScheduledBriefingRun(
                id: "legacy-v5-run",
                planFingerprint: "legacy-v5-plan-fingerprint",
                scheduledFor: anchor
            ))
            try legacy.mainContext.save()
        }

        let utc = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let calendar = gregorianCalendar(timeZone: utc)
        let expectedDay = LocalCalendarDay.resolve(
            containing: anchor,
            calendar: calendar,
            timeZone: utc
        )
        let migrated = try LocalStore(
            url: storeURL,
            userCalendarProvider: { calendar },
            userTimeZoneProvider: { utc }
        )
        XCTAssertEqual(try migrated.settings().density, .compact)
        let run = try XCTUnwrap(try migrated.scheduledBriefingRuns().first)
        XCTAssertEqual(run.id, "legacy-v5-run")
        XCTAssertEqual(run.planFingerprint, "legacy-v5-plan-fingerprint")
        XCTAssertEqual(run.scheduledFor, anchor)
        XCTAssertEqual(run.schemaVersion, 2)
        XCTAssertFalse(run.planMetadataData.isEmpty)
        XCTAssertEqual(try run.planMetadata().briefingDay, expectedDay)
        XCTAssertEqual(migrated.localCalendarDayMigrationReport.runsBackfilled, 1)
        XCTAssertEqual(migrated.localCalendarDayMigrationReport.runMetadataRewritten, 1)
    }

    func testDiskBackedV6StoreBackfillsLocalDayWithoutChangingAbsoluteEvidenceAndIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-v6-to-v7-local-day-\(UUID().uuidString.lowercased())", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let losAngeles = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let calendar = gregorianCalendar(timeZone: losAngeles)
        let july19 = LocalCalendarDay(year: 2026, month: 7, day: 19)
        let legacyBriefID = "legacy-v6-july-20-brief"
        let legacyOccurrenceID = "legacy-v6-july-19-occurrence"
        let legacySlotID = "legacy-v6-july-19-slot"
        let legacyRunID = "legacy-v6-july-19-run"
        let legacyDeliveryID = "legacy-v6-july-19-delivery"
        let legacyNotificationID = "legacy-v6-july-19-notification"
        let legacyAuditID = "legacy-v6-local-day-audit"
        let legacyTitle = "Loki Brief · 2026-07-20"
        let migratedTitle = "Loki Brief · 2026-07-19"

        let legacyBriefDate = try iso8601Date("2026-07-20T00:00:00Z")
        let generatedAt = try iso8601Date("2026-07-20T00:45:00Z")
        let scheduleUpdatedAt = try iso8601Date("2026-07-20T00:29:00Z")
        let scheduledFor = try iso8601Date("2026-07-20T00:30:00Z")
        let claimedAt = try iso8601Date("2026-07-20T00:31:00Z")
        let occurrenceCompletedAt = try iso8601Date("2026-07-20T00:32:00Z")
        let occurrenceUpdatedAt = try iso8601Date("2026-07-20T00:33:00Z")
        let runUpdatedAt = try iso8601Date("2026-07-20T00:34:00Z")
        let runCompletedAt = try iso8601Date("2026-07-20T00:35:00Z")
        let deliveryReservedAt = try iso8601Date("2026-07-20T00:36:00Z")
        let deliverySubmittedAt = try iso8601Date("2026-07-20T00:37:00Z")
        let deliveryResponseAt = try iso8601Date("2026-07-20T00:38:00Z")
        let auditCapturedAt = try iso8601Date("2026-07-20T00:39:00Z")

        let schedule = BriefSchedule(
            enabled: true,
            localTime: .init(hour: 17, minute: 30),
            followsSystemTimeZone: false,
            persistedTimeZoneIdentifier: losAngeles.identifier,
            missedRunPolicy: .runWithinGraceWindow,
            catchUpWindow: .init(maximumAge: 6 * 60 * 60)
        )
        let occurrence = ScheduleOccurrence(
            key: .init(rawValue: legacyOccurrenceID),
            slotKey: .init(rawValue: legacySlotID),
            scheduleID: schedule.id,
            intendedLocalDate: july19.storageValue,
            intendedLocalTime: schedule.localTime,
            resolvedTimeZoneIdentifier: losAngeles.identifier,
            recurrenceVersion: schedule.recurrenceVersion,
            resolvedExecutionDate: scheduledFor,
            resolvedAfterDSTGap: false,
            repeatedLocalTime: false
        )
        let plan = try ScheduledBriefingPlan(
            id: legacyRunID,
            occurrenceID: legacyOccurrenceID,
            scheduledFor: scheduledFor,
            briefingDay: july19,
            trigger: .catchUpAfterLaunch,
            feedSubscriptionIDs: [],
            slackWorkspaceIDs: [],
            refreshFeedsEnabled: true,
            refreshSlackEnabled: false,
            slackSelections: [],
            localPresentationEnabled: false,
            localPresentationConsentedWorkspaceIDs: [],
            notificationsEnabled: true,
            notificationAuthorization: .authorized,
            notificationPrivacyMode: .minimal,
            entitlementDecisions: []
        )
        let expectedOccurrenceHash = ScheduledBriefingPrivacy.hashIdentifier(legacyOccurrenceID)

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV6.self)
            let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: storeURL)
            let legacy = try ModelContainer(for: schema, configurations: [configuration])

            let legacyBrief = Brief(
                id: legacyBriefID,
                date: legacyBriefDate,
                title: legacyTitle,
                summary: "Legacy UTC-truncated heading fixture.",
                status: .ready,
                sections: [],
                generation: .init(
                    engineID: "legacy-v6-engine",
                    generatedAt: generatedAt,
                    status: .ready,
                    reasonCode: "legacy_v6_generated",
                    fixtureRevision: 6
                ),
                briefingDay: july19
            )
            let storedBrief = try StoredBrief(brief: legacyBrief)
            storedBrief.encodedBrief = try removingJSONKey("briefingDay", from: storedBrief.encodedBrief)
            XCTAssertEqual(storedBrief.title, legacyTitle)
            XCTAssertNil(try storedBrief.decodedBrief().briefingDay)
            legacy.mainContext.insert(storedBrief)

            legacy.mainContext.insert(try StoredBriefSchedule(schedule: schedule, updatedAt: scheduleUpdatedAt))
            legacy.mainContext.insert(StoredScheduleOccurrence(
                occurrence: occurrence,
                state: .succeeded,
                trigger: .catchUpAfterLaunch,
                claimedAt: claimedAt,
                completedAt: occurrenceCompletedAt,
                reasonCode: "legacy_catch_up_completed",
                updatedAt: occurrenceUpdatedAt
            ))

            let storedRun = StoredScheduledBriefingRun(snapshot: .init(
                plan: plan,
                state: .complete,
                reasonCode: ScheduledBriefingReason.runComplete,
                traceID: "legacy-v6-local-day-trace",
                startedAt: scheduledFor,
                updatedAt: runUpdatedAt,
                completedAt: runCompletedAt,
                sourceOutcomes: [],
                vaultOutcome: nil,
                briefID: nil,
                fallbackReasonCode: nil,
                failureReasonCodes: []
            ))
            storedRun.planMetadataData = try removingJSONKey("briefingDay", from: storedRun.planMetadataData)
            storedRun.schemaVersion = 1
            XCTAssertNil(try storedRun.planMetadata().briefingDay)
            legacy.mainContext.insert(storedRun)

            legacy.mainContext.insert(StoredDeliveryRecord(
                id: legacyDeliveryID,
                notificationIdentifier: legacyNotificationID,
                occurrenceIdentifierHash: expectedOccurrenceHash,
                briefID: legacyBriefID,
                outcome: .submitted,
                authorization: .authorized,
                privacyMode: .minimal,
                itemCount: 0,
                sourceCount: 0,
                reservedAt: deliveryReservedAt,
                submittedAt: deliverySubmittedAt,
                responseReceivedAt: deliveryResponseAt,
                reasonCode: "legacy_notification_submitted"
            ))
            legacy.mainContext.insert(StoredStateSnapshot(
                id: legacyAuditID,
                domain: "local-calendar-day-migration",
                state: "legacy-v6",
                capturedAt: auditCapturedAt
            ))
            try legacy.mainContext.save()
        }

        var firstEncodedBrief = Data()
        var firstRunMetadata = Data()
        var firstSidecarIDs: [String] = []

        do {
            let migrated = try LocalStore(
                url: storeURL,
                userCalendarProvider: { calendar },
                userTimeZoneProvider: { losAngeles }
            )
            let report = migrated.localCalendarDayMigrationReport
            XCTAssertEqual(report.occurrencesBackfilled, 1)
            XCTAssertEqual(report.briefsBackfilled, 1)
            XCTAssertEqual(report.runsBackfilled, 1)
            XCTAssertEqual(report.deliveriesBackfilled, 1)
            XCTAssertEqual(report.encodedBriefsRewritten, 1)
            XCTAssertEqual(report.runMetadataRewritten, 1)

            let storedBrief = try XCTUnwrap(try migrated.history().first(where: { $0.id == legacyBriefID }))
            let decodedBrief = try storedBrief.decodedBrief()
            XCTAssertEqual(storedBrief.id, legacyBriefID)
            XCTAssertEqual(storedBrief.title, migratedTitle)
            XCTAssertEqual(storedBrief.briefDate, legacyBriefDate)
            XCTAssertEqual(storedBrief.generatedAt, generatedAt)
            XCTAssertEqual(decodedBrief.id, legacyBriefID)
            XCTAssertEqual(decodedBrief.title, migratedTitle)
            XCTAssertEqual(decodedBrief.briefingDay, july19)
            XCTAssertEqual(decodedBrief.date, legacyBriefDate)
            XCTAssertEqual(decodedBrief.generation.generatedAt, generatedAt)
            XCTAssertFalse(decodedBrief.title.contains("2026-07-20"))
            firstEncodedBrief = storedBrief.encodedBrief

            let storedSchedule = try XCTUnwrap(try migrated.container.mainContext
                .fetch(FetchDescriptor<StoredBriefSchedule>()).first(where: { $0.id == schedule.id }))
            XCTAssertEqual(storedSchedule.updatedAt, scheduleUpdatedAt)
            XCTAssertEqual(storedSchedule.persistedTimeZoneIdentifier, losAngeles.identifier)

            let storedOccurrence = try XCTUnwrap(try migrated.container.mainContext
                .fetch(FetchDescriptor<StoredScheduleOccurrence>()).first(where: { $0.id == legacyOccurrenceID }))
            XCTAssertEqual(storedOccurrence.id, legacyOccurrenceID)
            XCTAssertEqual(storedOccurrence.slotKey, legacySlotID)
            XCTAssertEqual(storedOccurrence.scheduleID, schedule.id)
            XCTAssertEqual(storedOccurrence.intendedLocalDate, july19.storageValue)
            XCTAssertEqual(storedOccurrence.resolvedExecutionDate, scheduledFor)
            XCTAssertEqual(storedOccurrence.claimedAt, claimedAt)
            XCTAssertEqual(storedOccurrence.completedAt, occurrenceCompletedAt)
            XCTAssertEqual(storedOccurrence.updatedAt, occurrenceUpdatedAt)
            XCTAssertEqual(storedOccurrence.activationTriggerRaw, ScheduleActivationTrigger.catchUpAfterLaunch.rawValue)

            let storedRun = try XCTUnwrap(try migrated.scheduledBriefingRuns().first(where: { $0.id == legacyRunID }))
            XCTAssertEqual(storedRun.id, legacyRunID)
            XCTAssertEqual(storedRun.occurrenceHash, expectedOccurrenceHash)
            XCTAssertEqual(storedRun.planFingerprint, plan.fingerprint)
            XCTAssertEqual(storedRun.scheduledFor, scheduledFor)
            XCTAssertEqual(storedRun.startedAt, scheduledFor)
            XCTAssertEqual(storedRun.updatedAt, runUpdatedAt)
            XCTAssertEqual(storedRun.completedAt, runCompletedAt)
            XCTAssertEqual(storedRun.triggerRaw, ScheduledRunTrigger.catchUpAfterLaunch.rawValue)
            XCTAssertEqual(try storedRun.planMetadata().briefingDay, july19)
            firstRunMetadata = storedRun.planMetadataData

            let storedDelivery = try XCTUnwrap(try migrated.deliveryRecords().first(where: { $0.id == legacyDeliveryID }))
            XCTAssertEqual(storedDelivery.id, legacyDeliveryID)
            XCTAssertEqual(storedDelivery.notificationIdentifier, legacyNotificationID)
            XCTAssertEqual(storedDelivery.briefID, legacyBriefID)
            XCTAssertEqual(storedDelivery.occurrenceIdentifierHash, expectedOccurrenceHash)
            XCTAssertEqual(storedDelivery.reservedAt, deliveryReservedAt)
            XCTAssertEqual(storedDelivery.submittedAt, deliverySubmittedAt)
            XCTAssertEqual(storedDelivery.responseReceivedAt, deliveryResponseAt)

            let audit = try XCTUnwrap(try migrated.container.mainContext
                .fetch(FetchDescriptor<StoredStateSnapshot>()).first(where: { $0.id == legacyAuditID }))
            XCTAssertEqual(audit.capturedAt, auditCapturedAt)

            let sidecars = try migrated.localCalendarDaySidecars()
            XCTAssertEqual(sidecars.count, 4)
            firstSidecarIDs = sidecars.map(\.id)
            let sidecarsByID = Dictionary(uniqueKeysWithValues: sidecars.map { ($0.id, $0) })
            let briefSidecar = try XCTUnwrap(sidecarsByID[StoredLocalCalendarDay.identifier(
                ownerType: .brief,
                ownerIdentifier: legacyBriefID
            )])
            let occurrenceSidecar = try XCTUnwrap(sidecarsByID[StoredLocalCalendarDay.identifier(
                ownerType: .occurrence,
                ownerIdentifier: legacyOccurrenceID
            )])
            let runSidecar = try XCTUnwrap(sidecarsByID[StoredLocalCalendarDay.identifier(
                ownerType: .run,
                ownerIdentifier: legacyRunID
            )])
            let deliverySidecar = try XCTUnwrap(sidecarsByID[StoredLocalCalendarDay.identifier(
                ownerType: .delivery,
                ownerIdentifier: legacyDeliveryID
            )])

            for sidecar in [briefSidecar, occurrenceSidecar, runSidecar, deliverySidecar] {
                XCTAssertEqual(sidecar.localDay, july19)
                XCTAssertEqual(sidecar.canonicalKey, july19.storageValue)
                XCTAssertEqual(sidecar.calendarIdentifier, "gregorian")
                XCTAssertEqual(sidecar.timeZoneIdentifier, losAngeles.identifier)
            }
            XCTAssertEqual(briefSidecar.resolutionSourceRaw, LocalCalendarDayResolutionSource.generatedAtMigration.rawValue)
            XCTAssertEqual(briefSidecar.recordedAt, generatedAt)
            XCTAssertEqual(occurrenceSidecar.resolutionSourceRaw, LocalCalendarDayResolutionSource.storedOccurrence.rawValue)
            XCTAssertEqual(occurrenceSidecar.recordedAt, occurrenceUpdatedAt)
            XCTAssertEqual(runSidecar.resolutionSourceRaw, LocalCalendarDayResolutionSource.linkedOccurrence.rawValue)
            XCTAssertEqual(runSidecar.recordedAt, runUpdatedAt)
            XCTAssertEqual(deliverySidecar.resolutionSourceRaw, LocalCalendarDayResolutionSource.linkedBrief.rawValue)
            XCTAssertEqual(deliverySidecar.recordedAt, deliveryReservedAt)
        }

        do {
            let reopened = try LocalStore(
                url: storeURL,
                userCalendarProvider: { calendar },
                userTimeZoneProvider: { losAngeles }
            )
            XCTAssertEqual(reopened.localCalendarDayMigrationReport, .none)

            let storedBrief = try XCTUnwrap(try reopened.history().first(where: { $0.id == legacyBriefID }))
            XCTAssertEqual(storedBrief.encodedBrief, firstEncodedBrief)
            XCTAssertEqual(storedBrief.title, migratedTitle)
            XCTAssertEqual(storedBrief.generatedAt, generatedAt)
            XCTAssertEqual(try storedBrief.decodedBrief().briefingDay, july19)

            let storedRun = try XCTUnwrap(try reopened.scheduledBriefingRuns().first(where: { $0.id == legacyRunID }))
            XCTAssertEqual(storedRun.planMetadataData, firstRunMetadata)
            XCTAssertEqual(storedRun.scheduledFor, scheduledFor)
            XCTAssertEqual(try storedRun.planMetadata().briefingDay, july19)

            let sidecars = try reopened.localCalendarDaySidecars()
            XCTAssertEqual(sidecars.count, 4)
            XCTAssertEqual(sidecars.map(\.id), firstSidecarIDs)
            XCTAssertEqual(Set(sidecars.map(\.id)).count, sidecars.count)

            let audit = try XCTUnwrap(try reopened.container.mainContext
                .fetch(FetchDescriptor<StoredStateSnapshot>()).first(where: { $0.id == legacyAuditID }))
            XCTAssertEqual(audit.capturedAt, auditCapturedAt)
        }
    }

    func testP5ScheduleAndNotificationLedgerRoundTrip() throws {
        let store = try LocalStore(inMemory: true)
        var schedule = try store.primaryBriefSchedule()
        schedule.enabled = true
        schedule.localTime = .init(hour: 6, minute: 45)
        schedule.missedRunPolicy = .runWithinGraceWindow
        schedule.catchUpWindow = .init(maximumAge: 7_200)
        schedule.delivery.notificationsEnabled = true
        try store.savePrimaryBriefSchedule(schedule)

        let reopenedSchedule = try store.primaryBriefSchedule()
        XCTAssertEqual(reopenedSchedule, schedule)

        let input = NotificationDeliveryInput(
            occurrenceKey: "occurrence-persistence-fixture",
            briefID: "brief-persistence-fixture",
            runResult: .completed,
            hasUsableBrief: true,
            itemCount: 8,
            sourceCount: 3,
            privacyMode: .minimal
        )
        let (firstReservation, record) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        XCTAssertEqual(firstReservation, .reserved)
        try store.recordNotificationDelivery(
            identifier: record.notificationIdentifier,
            outcome: .submitted,
            authorization: .authorized,
            reasonCode: "notification_submitted"
        )
        let (secondReservation, _) = try store.reserveNotificationDelivery(input: input, authorization: .authorized)
        XCTAssertEqual(secondReservation, .alreadySubmitted)
        XCTAssertEqual(try store.deliveryRecords().first?.briefID, "brief-persistence-fixture")
        XCTAssertEqual(try store.deliveryRecords().first?.outcome, .submitted)
    }

    private func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }

    private func iso8601Date(_ value: String) throws -> Date {
        try XCTUnwrap(ISO8601DateFormatter().date(from: value))
    }

    private func removingJSONKey(_ key: String, from data: Data) throws -> Data {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNotNil(object.removeValue(forKey: key))
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}
