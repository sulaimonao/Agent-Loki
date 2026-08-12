import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class P3PersistenceMigrationTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_768_406_400)

    func testDiskBackedP2StoreMigratesToP3WithoutResettingP2Families() throws {
        let location = try temporaryStoreLocation(named: "p2-to-p3")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let expectedBrief = DeterministicBriefingEngine().generatePreview(revision: 23)

        try writeActualP2Store(at: location.store, brief: expectedBrief)
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: location.store.path)[.size] as? NSNumber
        ).intValue

        let migrated = try LocalStore(url: location.store)

        XCTAssertEqual(try migrated.settings().densityRaw, BriefingDensity.compact.rawValue)
        XCTAssertEqual(try migrated.p2Settings().topicPreferences, "security,research")
        XCTAssertEqual(try migrated.history().map(\.id), [expectedBrief.id])
        XCTAssertEqual(try migrated.readStates()[expectedBrief.sections[0].items[0].id], true)
        XCTAssertEqual(try migrated.feedSubscriptions().map(\.id), ["p2-feed"])
        XCTAssertEqual(try migrated.feedEntries().map(\.id), ["p2-entry"])
        XCTAssertEqual(try migrated.providerSnapshot()?.serviceVersion, "0.30.6")
        XCTAssertEqual(try migrated.localModels().map(\.id), ["gemma3:latest"])
        XCTAssertNil(try migrated.modelSelection().modelID)
        XCTAssertFalse(try migrated.modelSelection().localGenerationEnabled)
        XCTAssertEqual(try migrated.latestGenerationProvenance()?.briefID, expectedBrief.id)
        XCTAssertTrue(try migrated.slackWorkspaceConnections().isEmpty)
        XCTAssertTrue(try migrated.slackConversationSelections(workspaceID: "missing").isEmpty)
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: location.store.path)[.size] as? NSNumber).intValue,
            originalSize
        )
    }

    func testDiskBackedP3StoreMigratesToP4WithEmptyVaultDefaults() throws {
        let location = try temporaryStoreLocation(named: "p3-to-p4")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let workspaceID = SlackWorkspaceConnection.stableID(teamID: "T-P3", userID: "U-P3")
        try writeActualP3Store(at: location.store, workspaceID: workspaceID)
        let originalSize = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: location.store.path)[.size] as? NSNumber
        ).intValue

        let migrated = try LocalStore(url: location.store)

        XCTAssertEqual(try migrated.settings().densityRaw, BriefingDensity.compact.rawValue)
        XCTAssertEqual(try migrated.slackWorkspaceConnections().map(\.id), [workspaceID])
        XCTAssertTrue(try migrated.vaultAccounts().isEmpty)
        XCTAssertTrue(try migrated.vaultContainers().isEmpty)
        XCTAssertNil(try migrated.vaultImportCheckpoint(id: "missing"))
        XCTAssertGreaterThanOrEqual(
            try XCTUnwrap(FileManager.default.attributesOfItem(atPath: location.store.path)[.size] as? NSNumber).intValue,
            originalSize
        )
    }

    func testSlackRoundTripDefaultsConsentOffAndDeletionPreservesFeedData() throws {
        let store = try LocalStore(inMemory: true)
        let workspaceID = SlackWorkspaceConnection.stableID(teamID: "T123", userID: "U123")
        let workspace = SlackWorkspaceConnection(
            id: workspaceID,
            teamID: "T123",
            teamName: "Test Workspace",
            userID: "U123",
            userDisplayName: "Test Member",
            state: .connected,
            grantedScopes: Set(SlackGrantedScope.allCases),
            credentialMetadata: .init(
                tokenType: "user",
                issuedAt: anchor,
                accessExpiration: anchor.addingTimeInterval(4_320),
                grantedScopes: Set(SlackGrantedScope.allCases),
                schemaVersion: 1
            ),
            localModelConsent: true,
            connectedAt: anchor,
            updatedAt: anchor,
            lastFailureReasonCode: nil
        )
        let feed = StoredFeedSubscription(
            id: "preserved-feed",
            displayName: "Preserved feed",
            canonicalURL: "https://example.com/feed.xml",
            formatRaw: FeedFormat.rss2.rawValue,
            createdAt: anchor,
            updatedAt: anchor
        )
        try store.insertFeedSubscription(feed)
        try store.persistSlackWorkspace(workspace)

        let persistedWorkspace = try XCTUnwrap(store.slackWorkspaceConnection(id: workspaceID))
        XCTAssertFalse(persistedWorkspace.localModelConsent, "New Slack connections must ignore an eager true value and default local-model consent off.")
        XCTAssertFalse(persistedWorkspace.grantedScopes.contains("xox"))

        let conversation = SlackConversation(
            id: "C123",
            workspaceID: workspaceID,
            displayName: "release-room",
            kind: .privateChannel,
            isMember: true,
            isArchived: false,
            discoveredAt: anchor
        )
        try store.persistDiscoveredSlackConversations([conversation], workspaceID: workspaceID)
        try store.setSlackConversationSelected(id: "\(workspaceID):C123", selected: true)
        try store.setSlackConversationWeight(id: "\(workspaceID):C123", weight: 1.8)

        let timestamp = try XCTUnwrap(SlackTimestamp(rawValue: "1768406400.000001"))
        let evidence = SlackMessageEvidence(
            id: "slack-evidence-1",
            workspaceID: workspaceID,
            workspaceName: "Test Workspace",
            channelID: "C123",
            channelName: "release-room",
            channelKind: .privateChannel,
            messageTimestamp: timestamp,
            excerpt: "A bounded selected-channel message.",
            author: .init(id: "U321", displayName: "A member", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: true,
            replyCount: 2,
            isEdited: false,
            editedAt: nil,
            permalink: URL(string: "https://example.slack.com/archives/C123/p1768406400000001"),
            retrievedAt: anchor,
            selectedChannelWeight: 1.8,
            state: .available
        )
        try store.persistSlackEvidence(evidence)
        try store.persistSlackCursor(.init(
            workspaceID: workspaceID,
            channelID: "C123",
            committedOldest: timestamp,
            windowLatest: nil,
            nextCursor: nil,
            pendingHighWater: nil,
            updatedAt: anchor
        ))

        XCTAssertEqual(try store.domainSlackSelections(workspaceID: workspaceID).count, 1)
        XCTAssertEqual(try store.domainSlackEvidence(workspaceID: workspaceID), [evidence])
        XCTAssertNotNil(try store.domainSlackCursor(workspaceID: workspaceID, conversationID: "C123"))

        try store.deleteSlackWorkspaceData(workspaceID: workspaceID)

        XCTAssertTrue(try store.domainSlackWorkspaces().isEmpty)
        XCTAssertTrue(try store.domainSlackEvidence(workspaceID: workspaceID).isEmpty)
        XCTAssertTrue(try store.slackConversationSelections(workspaceID: workspaceID).isEmpty)
        XCTAssertEqual(try store.feedSubscriptions().map(\.id), ["preserved-feed"])
    }

    func testSlackWorkspaceDeletionPurgesEvidenceIDBasedBriefAndLocalGenerationProvenance() throws {
        let store = try LocalStore(inMemory: true)
        let workspaceID = SlackWorkspaceConnection.stableID(teamID: "T-delete", userID: "U-delete")
        let timestamp = try XCTUnwrap(SlackTimestamp(rawValue: "1768406400.000777"))
        let evidence = SlackMessageEvidence(
            id: "evidence-id-without-workspace-prefix",
            workspaceID: workspaceID,
            workspaceName: "Deletion Fixture",
            channelID: "C-delete",
            channelName: "selected-channel",
            channelKind: .privateChannel,
            messageTimestamp: timestamp,
            excerpt: "Slack-derived text that must leave retained history.",
            author: .init(id: "U-author", displayName: "Fixture Author", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: true,
            replyCount: 0,
            isEdited: false,
            editedAt: nil,
            permalink: URL(string: "https://fixture.slack.com/archives/C-delete/p1768406400000777"),
            retrievedAt: anchor,
            selectedChannelWeight: 1,
            state: .available
        )
        try store.persistSlackEvidence(evidence)

        let generationTime = anchor.addingTimeInterval(60)
        let slackAssembly = DeterministicSlackBriefingEngine(now: { generationTime })
            .assemble(evidence: [evidence], preferences: .default)
        let slackItem = try XCTUnwrap(slackAssembly.brief.sections.flatMap(\.items).first)
        let feedItem = try XCTUnwrap(DeterministicBriefingEngine().generatePreview(revision: 31).sections.first?.items.first)
        let brief = Brief(
            id: "mixed-history-with-slack",
            date: anchor,
            title: "Mixed retained history",
            summary: "Feed and Slack evidence.",
            status: .ready,
            sections: [
                .init(id: "collaboration", title: "Messages and Collaboration", items: [slackItem]),
                .init(id: "news", title: "News and Research", items: [feedItem]),
            ],
            generation: .init(
                engineID: DeterministicMixedBriefingEngine.identifier,
                generatedAt: anchor,
                status: .ready,
                reasonCode: "ollama_local_summary_validated",
                fixtureRevision: 31,
                providerKind: "ollama",
                sourceItemIDs: [evidence.id, feedItem.id],
                validationResult: "valid"
            ),
            partialFailureMessage: nil
        )
        try store.record(brief)
        try store.recordGenerationProvenance(.init(
            id: "slack-derived-provenance",
            briefID: brief.id,
            providerKind: "ollama",
            modelName: "fixture-model",
            promptTemplateVersion: "fixture.prompt.v1",
            schemaVersion: "fixture.output.v1",
            generatedAt: anchor,
            sourceItemIdentifiers: try JSONEncoder().encode([evidence.id, feedItem.id]),
            completionStatus: "success",
            fallbackStatus: nil,
            durationMilliseconds: 1,
            promptTokenCount: 1,
            completionTokenCount: 1,
            validationResult: "valid",
            failureCode: nil
        ))
        try store.recordGenerationProvenance(.init(
            id: "feed-only-provenance",
            briefID: "feed-only-history",
            providerKind: "ollama",
            modelName: "fixture-model",
            promptTemplateVersion: "fixture.prompt.v1",
            schemaVersion: "fixture.output.v1",
            generatedAt: anchor.addingTimeInterval(-1),
            sourceItemIdentifiers: try JSONEncoder().encode([feedItem.id]),
            completionStatus: "success",
            fallbackStatus: nil,
            durationMilliseconds: 1,
            promptTokenCount: 1,
            completionTokenCount: 1,
            validationResult: "valid",
            failureCode: nil
        ))

        try store.deleteSlackWorkspaceContent(workspaceID: workspaceID)

        let scrubbed = try XCTUnwrap(store.brief(id: brief.id))
        XCTAssertEqual(scrubbed.sections.flatMap(\.items).map(\.id), [feedItem.id])
        XCTAssertEqual(scrubbed.generation.sourceItemIDs, [feedItem.id])
        XCTAssertEqual(scrubbed.generation.providerKind, "deterministic")
        XCTAssertEqual(scrubbed.generation.reasonCode, "slack_workspace_evidence_deleted")
        XCTAssertNil(try store.generationProvenance(briefID: brief.id))
        XCTAssertNotNil(try store.generationProvenance(briefID: "feed-only-history"))
        XCTAssertTrue(try store.domainSlackEvidence(workspaceID: workspaceID).isEmpty)
    }

    func testSlackWorkspaceDeletionDropsUndecodableBriefAndPreservesValidFeedData() throws {
        let store = try LocalStore(inMemory: true)
        let workspaceID = SlackWorkspaceConnection.stableID(teamID: "T-malformed", userID: "U-malformed")
        let malformedBrief = DeterministicBriefingEngine().generatePreview(revision: 41)
        let validFeedBrief = DeterministicBriefingEngine().generatePreview(revision: 42)
        try store.record(malformedBrief)
        try store.record(validFeedBrief)
        try store.insertFeedSubscription(StoredFeedSubscription(
            id: "unrelated-valid-feed",
            displayName: "Unrelated valid feed",
            canonicalURL: "https://example.com/unrelated.xml",
            formatRaw: FeedFormat.rss2.rawValue,
            createdAt: anchor,
            updatedAt: anchor
        ))

        let malformedStored = try XCTUnwrap(
            store.history().first(where: { $0.id == malformedBrief.id })
        )
        malformedStored.encodedBrief = Data(
            #"{"workspaceID":"T-malformed:U-malformed","excerpt":"Slack text that must not remain""#.utf8
        )
        try store.save()

        try store.deleteSlackWorkspaceContent(workspaceID: workspaceID)

        XCTAssertFalse(try store.history().contains(where: { $0.id == malformedBrief.id }))
        let retained = try XCTUnwrap(store.brief(id: validFeedBrief.id))
        XCTAssertEqual(retained, validFeedBrief)
        XCTAssertTrue(retained.sections.flatMap(\.items).allSatisfy { $0.source.kind != .slack })
        XCTAssertEqual(try store.feedSubscriptions().map(\.id), ["unrelated-valid-feed"])
    }

    func testEditedSlackEvidenceRoundTripPreservesDeterministicBriefIdentity() throws {
        let store = try LocalStore(inMemory: true)
        let messageTimestamp = SlackTimestamp(date: anchor.addingTimeInterval(-120))
        let editedAt = SlackTimestamp(date: anchor.addingTimeInterval(-30))
        let evidence = SlackMessageEvidence(
            id: "edited-roundtrip-evidence",
            workspaceID: "T-edited:U-edited",
            workspaceName: "Edited Fixture",
            channelID: "C-edited",
            channelName: "edited-channel",
            channelKind: .privateChannel,
            messageTimestamp: messageTimestamp,
            excerpt: "Edited evidence must retain its revision identity.",
            author: .init(id: "U-author", displayName: "Fixture Author", kind: .user, isDeleted: false),
            directlyMentionsAuthenticatedUser: false,
            replyCount: 1,
            isEdited: true,
            editedAt: editedAt,
            permalink: nil,
            retrievedAt: anchor,
            selectedChannelWeight: 1,
            state: .available
        )
        let engineNow = anchor
        let engine = DeterministicSlackBriefingEngine(now: { engineNow })
        let before = engine.assemble(evidence: [evidence], preferences: .default)

        try store.persistSlackEvidence(evidence)
        let restored = try XCTUnwrap(store.domainSlackEvidence(workspaceID: evidence.workspaceID).first)
        let after = engine.assemble(evidence: [restored], preferences: .default)

        XCTAssertEqual(restored.editedAt, editedAt)
        XCTAssertEqual(restored.isEdited, true)
        XCTAssertEqual(after.selectedRevisionKeys, before.selectedRevisionKeys)
        XCTAssertEqual(after.brief.id, before.brief.id)
    }

    func testP3SwiftDataSchemaStoresSlackCredentialMetadataButNoCredentialSecrets() throws {
        let schema = Schema(versionedSchema: LokiBriefSchemaV3.self)
        let workspace = try XCTUnwrap(
            schema.entities.first { $0.name.hasSuffix("StoredSlackWorkspaceConnection") }
        )
        let persistedNames = Set(workspace.properties.map { $0.name })

        XCTAssertTrue(persistedNames.isSuperset(of: [
            "tokenType", "credentialIssuedAt", "accessExpiresAt", "credentialSchemaVersion",
        ]))
        XCTAssertTrue(persistedNames.isDisjoint(with: [
            "accessToken", "refreshToken", "clientSecret", "client_secret", "authorizationCode",
        ]))
        XCTAssertTrue(
            schema.entities.flatMap { $0.properties }.map { $0.name }.allSatisfy {
                !["accessToken", "refreshToken", "clientSecret", "client_secret"].contains($0)
            }
        )
    }

    func testConversationEnablementAndRefreshStatePreserveSelectionWeightAndLastSuccess() throws {
        let store = try LocalStore(inMemory: true)
        let id = "T-state:U-state:C-state"
        try store.upsertSlackConversation(.init(
            id: id,
            workspaceID: "T-state:U-state",
            conversationID: "C-state",
            displayName: "state-fixture",
            kindRaw: SlackConversationKind.privateChannel.rawValue,
            isMember: true,
            selected: true,
            enabled: true,
            weight: 1.8
        ))

        try store.setSlackConversationEnabled(id: id, enabled: false)
        var stored = try XCTUnwrap(store.slackConversationSelections(workspaceID: "T-state:U-state").first)
        XCTAssertFalse(stored.enabled)
        XCTAssertTrue(stored.selected)
        XCTAssertEqual(stored.weight, 1.8)

        try store.recordSlackConversationRefresh(id: id, successfulAt: anchor, failureReasonCode: "ignored_on_success")
        stored = try XCTUnwrap(store.slackConversationSelections(workspaceID: "T-state:U-state").first)
        XCTAssertEqual(stored.lastSuccessfulRefresh, anchor)
        XCTAssertNil(stored.lastFailureCode)

        let overlongFailure = String(repeating: "f", count: SlackPersistenceLimits.maximumFailureReasonCodeCharacters + 20)
        try store.recordSlackConversationRefresh(id: id, successfulAt: nil, failureReasonCode: overlongFailure)
        stored = try XCTUnwrap(store.slackConversationSelections(workspaceID: "T-state:U-state").first)
        XCTAssertEqual(stored.lastSuccessfulRefresh, anchor, "A later failure must retain the last successful refresh time.")
        XCTAssertEqual(stored.lastFailureCode?.count, SlackPersistenceLimits.maximumFailureReasonCodeCharacters)
    }

    func testSelectionLimitAndNonFiniteWeightsFailClosed() throws {
        let store = try LocalStore(inMemory: true)
        let workspaceID = "T123:U123"
        for index in 0..<SlackPersistenceLimits.maximumSelectedChannels {
            try store.upsertSlackConversation(.init(
                id: "\(workspaceID):C\(index)",
                workspaceID: workspaceID,
                conversationID: "C\(index)",
                displayName: "channel-\(index)",
                kindRaw: SlackConversationKind.publicChannel.rawValue,
                isMember: true,
                selected: true
            ))
        }
        XCTAssertThrowsError(try store.upsertSlackConversation(.init(
            id: "\(workspaceID):C-over-limit",
            workspaceID: workspaceID,
            conversationID: "C-over-limit",
            displayName: "over-limit",
            kindRaw: SlackConversationKind.publicChannel.rawValue,
            isMember: true,
            selected: true
        ))) { error in
            XCTAssertEqual(error as? SlackPersistenceError, .selectionLimitExceeded)
        }
        XCTAssertThrowsError(try store.setSlackConversationWeight(id: "\(workspaceID):C0", weight: .nan))
    }

    private func temporaryStoreLocation(named name: String) throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("LokiBrief.store"))
    }

    private func writeActualP2Store(at url: URL, brief: Brief) throws {
        let schema = Schema(versionedSchema: LokiBriefSchemaV2.self)
        let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.insert(StoredSettings(density: .compact, deterministicOnly: false))
        context.insert(StoredP2Settings(topicPreferences: "security,research", previewFixturesEnabled: false))
        context.insert(try StoredBrief(brief: brief))
        context.insert(StoredReadState(itemID: brief.sections[0].items[0].id, isRead: true))
        context.insert(StoredStateSnapshot(id: "source:news-feeds", domain: "source", state: "connected", capturedAt: anchor))
        context.insert(StoredFeedSubscription(
            id: "p2-feed",
            displayName: "P2 Feed",
            canonicalURL: "https://example.com/feed.xml",
            formatRaw: FeedFormat.rss2.rawValue,
            createdAt: anchor,
            updatedAt: anchor
        ))
        context.insert(StoredFeedFetch(
            id: "p2-fetch",
            subscriptionID: "p2-feed",
            traceID: "p2-trace",
            attemptedAt: anchor,
            completedAt: anchor,
            statusRaw: "success",
            httpStatus: 200,
            responseByteCount: 512,
            parsedEntryCount: 1
        ))
        context.insert(StoredNormalizedFeedEntry(
            id: "p2-entry",
            subscriptionID: "p2-feed",
            title: "P2 evidence",
            summaryText: "Persisted before P3 migration.",
            canonicalURL: "https://example.com/item",
            author: "Fixture",
            publicationDate: anchor,
            updatedDate: nil,
            retrievedAt: anchor,
            originalPosition: 0,
            formatIdentifier: FeedFormat.rss2.rawValue,
            upstreamIdentifier: "p2-entry",
            identityBasis: "upstreamIdentifier",
            encodedEntry: Data("{}".utf8)
        ))
        context.insert(StoredBriefAssembly(
            id: brief.id,
            generatedAt: brief.generation.generatedAt,
            selectedEntryCount: brief.itemCount,
            excludedEntryCount: 0,
            enabledSourceCount: 1,
            failureNotes: Data("[]".utf8)
        ))
        context.insert(StoredModelProviderSnapshotP2(
            stateRaw: ModelProviderState.connected.rawValue,
            checkedAt: anchor,
            lastSuccessfulCheckAt: anchor,
            serviceVersion: "0.30.6"
        ))
        context.insert(StoredLocalModelDescriptor(
            id: "gemma3:latest",
            displayName: "gemma3:latest",
            modifiedAt: anchor,
            sizeBytes: 1,
            digest: "fixture",
            details: Data("{}".utf8),
            discoveredAt: anchor
        ))
        context.insert(StoredModelSelectionRecord(
            modelID: "gemma3:latest",
            localGenerationEnabled: true,
            selectedAt: anchor
        ))
        context.insert(StoredGenerationProvenanceRecord(
            id: "p2-generation",
            briefID: brief.id,
            providerKind: "ollama",
            modelName: "gemma3:latest",
            promptTemplateVersion: "loki.brief.p2.v1",
            schemaVersion: "loki.brief.output.v1",
            generatedAt: anchor,
            sourceItemIdentifiers: Data("[]".utf8),
            completionStatus: "success",
            fallbackStatus: nil,
            durationMilliseconds: 1,
            promptTokenCount: 1,
            completionTokenCount: 1,
            validationResult: "valid",
            failureCode: nil
        ))
        try context.save()
    }

    private func writeActualP3Store(at url: URL, workspaceID: String) throws {
        let schema = Schema(versionedSchema: LokiBriefSchemaV3.self)
        let configuration = ModelConfiguration("LokiBrief-v1", schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = container.mainContext
        context.insert(StoredSettings(density: .compact, deterministicOnly: true))
        context.insert(StoredSlackWorkspaceConnection(
            id: workspaceID,
            teamID: "T-P3",
            userID: "U-P3",
            teamName: "P3 Workspace",
            userDisplayName: "P3 User",
            connectionStateRaw: SlackConnectionState.connected.rawValue,
            grantedScopes: SlackGrantedScope.allCases.map(\.rawValue).sorted().joined(separator: ","),
            tokenType: "user",
            credentialIssuedAt: anchor,
            accessExpiresAt: anchor.addingTimeInterval(3_600),
            enabled: true,
            localModelConsent: false,
            createdAt: anchor,
            updatedAt: anchor
        ))
        try context.save()
    }
}
