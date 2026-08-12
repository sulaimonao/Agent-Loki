import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class ConnectorPersistenceTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testV10AddsConnectorModelsThroughOneOrderedLightweightStage() {
        XCTAssertEqual(LokiBriefSchemaV10.versionIdentifier, Schema.Version(10, 0, 0))
        XCTAssertEqual(
            LokiBriefMigrationPlanV10.schemas.count,
            LokiBriefMigrationPlanV9.schemas.count + 1
        )
        XCTAssertEqual(
            LokiBriefMigrationPlanV10.stages.count,
            LokiBriefMigrationPlanV9.stages.count + 1
        )
    }

    func testV9StoreMigratesToV10AndConnectorDefaultsRemainEmpty() throws {
        let fixture = try fixtureURL("v9-to-v10")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV9.self)
            let configuration = ModelConfiguration(
                "LokiBrief-v1",
                schema: schema,
                url: fixture.store
            )
            _ = try ModelContainer(
                for: schema,
                migrationPlan: LokiBriefMigrationPlanV9.self,
                configurations: [configuration]
            )
        }

        let migrated = try LocalStore(url: fixture.store)
        XCTAssertEqual(try migrated.connectorStatuses(), [])
        XCTAssertEqual(try migrated.connectorSyncReceipts(), [])
        XCTAssertNil(try migrated.emailImportAccess(id: "mailbox-a"))
    }

    func testPopulatedV9SettingsSurviveV10ConnectorMigration() throws {
        let fixture = try fixtureURL("populated-v9-to-v10")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }

        do {
            let schema = Schema(versionedSchema: LokiBriefSchemaV9.self)
            let configuration = ModelConfiguration(
                "LokiBrief-v1",
                schema: schema,
                url: fixture.store
            )
            let container = try ModelContainer(
                for: schema,
                migrationPlan: LokiBriefMigrationPlanV9.self,
                configurations: [configuration]
            )
            container.mainContext.insert(StoredSettings(
                preferredBriefingTime: anchor,
                launchAtLoginPreference: true,
                notificationPreference: true,
                density: .compact,
                deterministicOnly: false,
                futureLocalModelPreference: true
            ))
            try container.mainContext.save()
        }

        let migrated = try LocalStore(url: fixture.store)
        let settings = try migrated.settings()
        XCTAssertEqual(settings.preferredBriefingTime, anchor)
        XCTAssertTrue(settings.launchAtLoginPreference)
        XCTAssertTrue(settings.notificationPreference)
        XCTAssertEqual(settings.density, .compact)
        XCTAssertFalse(settings.deterministicOnly)
        XCTAssertTrue(settings.futureLocalModelPreference)
        XCTAssertEqual(try migrated.connectorStatuses(), [])
    }

    func testConnectorStatusReceiptAndEmailAccessRoundTripAndDelete() throws {
        let store = try LocalStore(inMemory: true)
        let status = ConnectorStatusSnapshot(
            id: "discord:account-fixture",
            kind: .discord,
            stableAccountIdentifier: "account-fixture",
            displayName: "Synthetic Community",
            state: .connected,
            credentialReference: "discord-keychain:account-fixture",
            selectedSourceIdentifiers: ["channel-b", "channel-a", "channel-a"],
            cursorData: Data("cursor-v1".utf8),
            lastSuccessfulSync: anchor,
            lastAttemptedSync: anchor,
            importedItemCount: 4,
            skippedItemCount: 1,
            attachmentCount: 2,
            privacyClassification: .localSelectedSource,
            automaticSyncEnabled: false,
            updatedAt: anchor
        )
        try store.saveConnectorStatus(status)

        let loaded = try XCTUnwrap(try store.connectorStatus(id: status.id))
        XCTAssertEqual(loaded.selectedSourceIdentifiers, ["channel-a", "channel-b"])
        XCTAssertEqual(loaded.state, .connected)
        XCTAssertFalse(loaded.automaticSyncEnabled)

        let receipt = ConnectorSyncReceipt(
            id: "receipt-fixture",
            connectorStatusIdentifier: status.id,
            kind: .discord,
            traceID: "trace-fixture",
            startedAt: anchor,
            completedAt: anchor.addingTimeInterval(2),
            status: .connected,
            reasonCode: "discord_sync_complete",
            importedItemCount: 4,
            updatedItemCount: 0,
            tombstonedItemCount: 0,
            skippedItemCount: 1,
            attachmentCount: 2,
            pageCount: 1,
            sourceAllowlistHash: String(repeating: "a", count: 64),
            receiptHash: String(repeating: "b", count: 64)
        )
        try store.saveConnectorSyncReceipt(receipt)
        XCTAssertEqual(
            try store.connectorSyncReceipts(statusIdentifier: status.id),
            [receipt]
        )

        let bookmark = EmailImportAccessSnapshot(
            id: "mailbox-a",
            mailboxIdentity: "mailbox-fixture",
            securityScopedBookmark: Data("synthetic-bookmark".utf8),
            fileIdentityHash: String(repeating: "c", count: 64),
            committedByteOffset: 128,
            highWatermarkHash: String(repeating: "d", count: 64),
            updatedAt: anchor
        )
        try store.saveEmailImportAccess(bookmark)
        XCTAssertEqual(try store.emailImportAccess(id: bookmark.id), bookmark)

        try store.removeConnectorStatus(id: status.id)
        try store.removeEmailImportAccess(id: bookmark.id)
        XCTAssertNil(try store.connectorStatus(id: status.id))
        XCTAssertEqual(try store.connectorSyncReceipts(), [])
        XCTAssertNil(try store.emailImportAccess(id: bookmark.id))
    }

    func testDeleteAllRemovesConnectorControlStateAndAccessBookmarks() throws {
        let store = try LocalStore(inMemory: true)
        try store.saveConnectorStatus(.init(
            id: "support-email:mailbox",
            kind: .supportEmail,
            stableAccountIdentifier: "mailbox",
            displayName: "Synthetic Mailbox",
            state: .connected,
            privacyClassification: .localImportedMailbox
        ))
        try store.saveEmailImportAccess(.init(
            id: "mailbox",
            mailboxIdentity: "mailbox",
            securityScopedBookmark: Data("synthetic".utf8),
            fileIdentityHash: String(repeating: "e", count: 64),
            committedByteOffset: 0,
            highWatermarkHash: nil,
            updatedAt: anchor
        ))

        try store.deleteAllLocalData()

        XCTAssertEqual(try store.connectorStatuses(), [])
        XCTAssertNil(try store.emailImportAccess(id: "mailbox"))
    }

    private func fixtureURL(_ name: String) throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-connector-tests", isDirectory: true)
            .appendingPathComponent("\(name)-\(UUID().uuidString.lowercased())", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return (directory, directory.appendingPathComponent("LokiBrief-v1.store"))
    }
}
