import Foundation
import XCTest
@testable import LokiBrief

final class VaultSearchRetentionExportTests: XCTestCase, @unchecked Sendable {
    private static let anchor = Date(timeIntervalSince1970: 1_785_000_000)

    func testSearchComposesAllFiltersAndUsesDeterministicPagination() async throws {
        let fixture = temporaryDatabase(named: "search-filters")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let slack = try await installScope(in: database, suffix: "slack", provider: "slack")
        let feed = try await installScope(in: database, suffix: "feed", provider: "rss")

        let matching = record(
            id: "matching",
            scope: slack,
            body: "Launch evidence is 100%_ready for bounded review.",
            author: "Ada",
            occurredAt: Self.anchor,
            directlyMentionsUser: true,
            isRead: true,
            contentOrigin: .source
        )
        let sameAccountWrongFilters = record(
            id: "same-account",
            scope: slack,
            body: "Launch draft from another author.",
            author: "Grace",
            occurredAt: Self.anchor.addingTimeInterval(-60),
            contentOrigin: .generated
        )
        let otherProvider = record(
            id: "other-provider",
            scope: feed,
            body: "Launch evidence from a feed.",
            author: "Ada",
            occurredAt: Self.anchor.addingTimeInterval(-120),
            directlyMentionsUser: true,
            isRead: true
        )
        _ = try await database.upsert(records: [matching, sameAccountWrongFilters, otherProvider])

        let filtered = try await database.search(.init(
            text: "launch",
            accountID: slack.accountID,
            containerID: slack.containerID,
            provider: "slack",
            author: "Ada",
            startDate: Self.anchor.addingTimeInterval(-1),
            endDate: Self.anchor.addingTimeInterval(1),
            itemKind: "message",
            directlyMentionsUser: true,
            readFilter: .read,
            deleted: false,
            contentOrigin: .source,
            limit: 10,
            preference: .likeOnly
        ))
        XCTAssertEqual(filtered.mode, .likeFallback)
        XCTAssertEqual(filtered.results.map(\.id), [matching.id])
        XCTAssertEqual(filtered.results.first?.provider, "slack")
        XCTAssertEqual(filtered.results.first?.author, "Ada")

        let specialCharacters = try await database.search(.init(
            text: "100%_ready",
            accountID: slack.accountID,
            preference: .likeOnly
        ))
        XCTAssertEqual(specialCharacters.results.map(\.id), [matching.id])

        let firstPage = try await database.search(.init(text: "", limit: 1, offset: 0, preference: .likeOnly))
        let secondPage = try await database.search(.init(text: "", limit: 1, offset: 1, preference: .likeOnly))
        XCTAssertEqual(firstPage.results.map(\.id), [matching.id])
        XCTAssertEqual(secondPage.results.map(\.id), [sameAccountWrongFilters.id])
        XCTAssertTrue(firstPage.wasTruncated)
        try await database.close()
    }

    func testFTSAndFallbackIndexUpdatesAndDeletionPropagation() async throws {
        let fixture = temporaryDatabase(named: "fts-propagation")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let scope = try await installScope(in: database, suffix: "fts", provider: "slack")
        let initial = record(id: "fts-item", scope: scope, body: "legacyneedle", author: "Indexer")
        _ = try await database.upsert(record: initial)

        let diagnostics = try await database.diagnostics()
        let initialAutomatic = try await database.search(.init(text: "legacyneedle"))
        XCTAssertEqual(initialAutomatic.results.map(\.id), [initial.id])
        XCTAssertEqual(initialAutomatic.mode, diagnostics.ftsAvailable ? .fullText : .likeFallback)

        let updated = record(id: initial.id, scope: scope, body: "freshneedle", author: "Indexer")
        _ = try await database.upsert(record: updated)
        let legacyAfterUpdate = try await database.search(.init(text: "legacyneedle"))
        let freshAfterUpdate = try await database.search(.init(text: "freshneedle"))
        let freshFallback = try await database.search(.init(text: "freshneedle", preference: .likeOnly))
        XCTAssertTrue(legacyAfterUpdate.results.isEmpty)
        XCTAssertEqual(freshAfterUpdate.results.map(\.id), [initial.id])
        XCTAssertEqual(freshFallback.results.map(\.id), [initial.id])

        _ = try await database.tombstone(recordID: initial.id, reason: .sourceDeleted, deletedAt: Self.anchor)
        let freshAfterDeletion = try await database.search(.init(text: "freshneedle"))
        XCTAssertTrue(freshAfterDeletion.results.isEmpty)
        let deleted = try await database.search(.init(
            text: "",
            accountID: scope.accountID,
            deleted: true,
            preference: .likeOnly
        ))
        XCTAssertEqual(deleted.results.map(\.id), [initial.id])
        XCTAssertTrue(deleted.results.allSatisfy(\.isDeleted))
        try await database.close()
    }

    func testSearchRejectsOversizedAndExcessivelyTokenizedQueries() async throws {
        let fixture = temporaryDatabase(named: "search-bounds")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)

        do {
            _ = try await database.search(.init(text: String(repeating: "x", count: VaultLimits.maximumSearchCharacters + 1)))
            XCTFail("Expected an oversized query to fail")
        } catch let failure as VaultDatabaseFailure {
            XCTAssertEqual(failure.reasonCode, "vault_search_query_too_long")
        }

        let tooManyTokens = (0...VaultLimits.maximumSearchTokens).map { "t\($0)" }.joined(separator: " ")
        do {
            _ = try await database.search(.init(text: tooManyTokens))
            XCTFail("Expected excessive search tokens to fail")
        } catch let failure as VaultDatabaseFailure {
            XCTAssertEqual(failure.reasonCode, "vault_search_too_many_tokens")
        }
        try await database.close()
    }

    func testAccountScopedRetentionRemovesFTSAndRevisionsWithoutCrossAccountDeletion() async throws {
        let fixture = temporaryDatabase(named: "retention-account")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = try await installScope(in: database, suffix: "retained-first", provider: "slack")
        let second = try await installScope(in: database, suffix: "retained-second", provider: "slack")
        let oldDate = Self.anchor.addingTimeInterval(-120 * 86_400)
        let oldFirst = record(id: "old-first", scope: first, body: "obsolete first needle", occurredAt: oldDate)
        let oldSecond = record(id: "old-second", scope: second, body: "obsolete second remains", occurredAt: oldDate)
        let recentFirst = record(id: "recent-first", scope: first, body: "recent survives", occurredAt: Self.anchor)
        _ = try await database.upsert(records: [oldFirst, oldSecond, recentFirst])
        _ = try await database.upsert(record: record(
            id: oldFirst.id,
            scope: first,
            body: "obsolete first edited needle",
            occurredAt: oldDate
        ))
        let revisionsBeforeRetention = try await database.revisions(recordID: oldFirst.id)
        XCTAssertEqual(revisionsBeforeRetention.count, 1)

        let result = try await database.applyRetention(.init(
            accountID: first.accountID,
            recordAgeDays: 30,
            maximumRecordsPerContainer: 100,
            tombstoneAgeDays: 365
        ), now: Self.anchor)
        XCTAssertEqual(result.recordsRemovedByAge, 1)
        let removedOldFirst = try await database.record(id: oldFirst.id)
        let revisionsAfterRetention = try await database.revisions(recordID: oldFirst.id)
        let preservedRecentFirst = try await database.record(id: recentFirst.id)
        let preservedOldSecond = try await database.record(id: oldSecond.id)
        let searchAfterRetention = try await database.search(.init(text: "needle"))
        let firstTombstones = try await database.tombstones(accountID: first.accountID)
        let secondTombstones = try await database.tombstones(accountID: second.accountID)
        XCTAssertNil(removedOldFirst)
        XCTAssertTrue(revisionsAfterRetention.isEmpty)
        XCTAssertNotNil(preservedRecentFirst)
        XCTAssertNotNil(preservedOldSecond)
        XCTAssertTrue(searchAfterRetention.results.isEmpty)
        XCTAssertEqual(firstTombstones.map(\.recordID), [oldFirst.id])
        XCTAssertTrue(secondTombstones.isEmpty)
        try await database.close()
    }

    func testContainerScopedRetentionAndTombstoneExpiryStayInsideContainer() async throws {
        let fixture = temporaryDatabase(named: "retention-container")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = try await installScope(in: database, suffix: "container-first", provider: "slack")
        let secondContainer = try await installContainer(
            in: database,
            accountID: first.accountID,
            suffix: "container-second"
        )
        let second = Scope(accountID: first.accountID, containerID: secondContainer)
        let oldDate = Self.anchor.addingTimeInterval(-60 * 86_400)
        let firstItem = record(id: "container-old-first", scope: first, body: "remove me", occurredAt: oldDate)
        let secondItem = record(id: "container-old-second", scope: second, body: "preserve me", occurredAt: oldDate)
        _ = try await database.upsert(records: [firstItem, secondItem])

        let result = try await database.applyRetention(.init(
            accountID: first.accountID,
            containerID: first.containerID,
            recordAgeDays: 30,
            maximumRecordsPerContainer: 100,
            tombstoneAgeDays: 365
        ), now: Self.anchor)
        XCTAssertEqual(result.recordsRemovedByAge, 1)
        let removedFirstItem = try await database.record(id: firstItem.id)
        let preservedSecondItem = try await database.record(id: secondItem.id)
        let containerTombstones = try await database.tombstones(accountID: first.accountID)
        XCTAssertNil(removedFirstItem)
        XCTAssertNotNil(preservedSecondItem)
        XCTAssertEqual(containerTombstones.map(\.recordID), [firstItem.id])

        _ = try await database.applyRetention(.init(
            accountID: first.accountID,
            containerID: first.containerID,
            recordAgeDays: 365,
            maximumRecordsPerContainer: 100,
            tombstoneAgeDays: 30
        ), now: Self.anchor.addingTimeInterval(400 * 86_400))
        let expiredTombstones = try await database.tombstones(accountID: first.accountID)
        let secondAfterExpiry = try await database.record(id: secondItem.id)
        XCTAssertTrue(expiredTombstones.isEmpty)
        XCTAssertNotNil(secondAfterExpiry)
        try await database.close()
    }

    func testStorageSummaryAndScopedDeterministicExportWithTamperDetection() async throws {
        let fixture = temporaryDatabase(named: "export")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let database = try VaultDatabase(url: fixture.database)
        let first = try await installScope(in: database, suffix: "export-first", provider: "slack")
        let second = try await installScope(in: database, suffix: "export-second", provider: "rss")
        let firstOld = record(
            id: "export-first-old",
            scope: first,
            body: "exported bounded needle",
            occurredAt: Self.anchor.addingTimeInterval(-86_400)
        )
        let firstNew = record(id: "export-first-new", scope: first, body: "new scoped record", occurredAt: Self.anchor)
        let secondItem = record(id: "export-second", scope: second, body: "other account private marker", occurredAt: Self.anchor)
        _ = try await database.upsert(records: [firstOld, firstNew, secondItem])

        let storage = try await database.storageSummary()
        XCTAssertEqual(storage.accountCount, 2)
        XCTAssertEqual(storage.recordCount, 3)
        XCTAssertGreaterThan(storage.databaseBytes, 0)
        XCTAssertGreaterThanOrEqual(storage.totalArchiveBytes, storage.databaseBytes)
        XCTAssertEqual(storage.oldestItemAt, firstOld.occurredAt)
        XCTAssertEqual(storage.newestItemAt, firstNew.occurredAt)
        let contributions = Dictionary(uniqueKeysWithValues: storage.accountContributions.map { ($0.accountID, $0) })
        XCTAssertEqual(contributions[first.accountID]?.itemCount, 2)
        XCTAssertEqual(contributions[second.accountID]?.itemCount, 1)

        let localTimeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.locale = Locale(identifier: "en_US_POSIX")
        localCalendar.timeZone = localTimeZone
        let exportTime = try XCTUnwrap(
            ISO8601DateFormatter().date(from: "2026-07-20T00:45:00Z")
        )
        let firstURL = fixture.directory.appendingPathComponent("first.lokivault")
        let secondURL = fixture.directory.appendingPathComponent("second.lokivault")
        let firstExport = try await database.export(
            to: firstURL,
            exportedAt: exportTime,
            localCalendar: localCalendar,
            localTimeZone: localTimeZone
        )
        let secondExport = try await database.export(
            to: secondURL,
            exportedAt: exportTime,
            localCalendar: localCalendar,
            localTimeZone: localTimeZone
        )
        XCTAssertEqual(firstExport.recordCount, 3)
        XCTAssertEqual(firstExport.payloadChecksum, secondExport.payloadChecksum)
        XCTAssertEqual(try Data(contentsOf: firstURL), try Data(contentsOf: secondURL))
        XCTAssertTrue(try VaultDatabase.verifyExport(at: firstURL).isValid)

        let exportText = try XCTUnwrap(String(data: Data(contentsOf: firstURL), encoding: .utf8))
        let manifestLine = try XCTUnwrap(exportText.split(separator: "\n").first)
        let manifestEnvelope = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(manifestLine.utf8)) as? [String: Any]
        )
        let manifest = try XCTUnwrap(manifestEnvelope["payload"] as? [String: Any])
        XCTAssertEqual(manifest["exported_at"] as? String, "2026-07-20T00:45:00.000Z")
        XCTAssertEqual(manifest["exported_local_day"] as? String, "2026-07-19")
        XCTAssertEqual(manifest["export_calendar_identifier"] as? String, "gregorian")
        XCTAssertEqual(manifest["export_time_zone_identifier"] as? String, "America/Los_Angeles")
        XCTAssertFalse(exportText.contains("access_token"))
        XCTAssertFalse(exportText.contains("refresh_token"))
        XCTAssertFalse(exportText.contains("authorization_code"))
        let permissions = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: firstURL.path)[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o077, 0)

        let accountURL = fixture.directory.appendingPathComponent("account.lokivault")
        let accountExport = try await database.export(
            to: accountURL,
            scope: .init(accountID: first.accountID),
            exportedAt: exportTime
        )
        XCTAssertEqual(accountExport.accountCount, 1)
        XCTAssertEqual(accountExport.recordCount, 2)
        let accountText = try XCTUnwrap(String(data: Data(contentsOf: accountURL), encoding: .utf8))
        XCTAssertFalse(accountText.contains(second.accountID))
        XCTAssertFalse(accountText.contains("other account private marker"))

        let dateURL = fixture.directory.appendingPathComponent("date.lokivault")
        let dateExport = try await database.export(
            to: dateURL,
            scope: .init(startDate: Self.anchor.addingTimeInterval(-1), endDate: Self.anchor.addingTimeInterval(1)),
            exportedAt: exportTime
        )
        XCTAssertEqual(dateExport.recordCount, 2)

        var tampered = try XCTUnwrap(String(data: Data(contentsOf: firstURL), encoding: .utf8))
        tampered = tampered.replacingOccurrences(of: "exported bounded needle", with: "tampered bounded needle")
        let tamperedURL = fixture.directory.appendingPathComponent("tampered.lokivault")
        try Data(tampered.utf8).write(to: tamperedURL)
        let verification = try VaultDatabase.verifyExport(at: tamperedURL)
        XCTAssertFalse(verification.isValid)
        XCTAssertEqual(verification.reasonCode, "vault_export_line_checksum_invalid")
        try await database.close()
    }

    private struct Scope {
        let accountID: String
        let containerID: String
    }

    private func installScope(in database: VaultDatabase, suffix: String, provider: String) async throws -> Scope {
        let accountID = "account-\(suffix)"
        _ = try await database.upsert(account: .init(
            id: accountID,
            provider: provider,
            providerAccountID: "provider-account-\(suffix)",
            displayName: "Account \(suffix)",
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        ))
        let containerID = try await installContainer(in: database, accountID: accountID, suffix: suffix)
        return .init(accountID: accountID, containerID: containerID)
    }

    private func installContainer(in database: VaultDatabase, accountID: String, suffix: String) async throws -> String {
        let containerID = "container-\(suffix)"
        _ = try await database.upsert(container: .init(
            id: containerID,
            accountID: accountID,
            providerContainerID: "provider-container-\(suffix)",
            kind: "channel",
            displayName: "Container \(suffix)",
            createdAt: Self.anchor,
            updatedAt: Self.anchor
        ))
        return containerID
    }

    private func record(
        id: String,
        scope: Scope,
        body: String,
        author: String = "Fixture Author",
        occurredAt: Date = anchor,
        directlyMentionsUser: Bool = false,
        isRead: Bool = false,
        contentOrigin: VaultContentOrigin = .source
    ) -> VaultRecordInput {
        .init(
            id: id,
            accountID: scope.accountID,
            containerID: scope.containerID,
            providerRecordID: "provider-\(id)",
            kind: "message",
            title: "Title \(id)",
            body: body,
            author: author,
            sourceURL: URL(string: "https://example.invalid/items/\(id)"),
            occurredAt: occurredAt,
            capturedAt: Self.anchor,
            modifiedAt: Self.anchor,
            metadata: ["fixture": "true"],
            directlyMentionsUser: directlyMentionsUser,
            isRead: isRead,
            contentOrigin: contentOrigin,
            providerMetadataVersion: 1,
            threadRootID: nil,
            replyCount: 0
        )
    }

    private func temporaryDatabase(named name: String) -> (directory: URL, database: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-vault-search-tests-\(name)-\(UUID().uuidString)", isDirectory: true)
        return (directory, directory.appendingPathComponent("loki-vault.sqlite3"))
    }
}
