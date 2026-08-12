import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class LokiChatPrivacyTests: XCTestCase, @unchecked Sendable {
    func testHistoryDisabledMakesConversationWritesNoOp() throws {
        let store = try LocalStore(inMemory: true)
        var settings = try store.lokiChatPrivacySettings()
        settings.storeLocalHistory = false
        try store.updateLokiChatPrivacySettings(settings)

        let conversation = privateConversation(id: "not-stored")
        XCTAssertFalse(try store.persistLokiConversation(conversation))
        XCTAssertNil(try store.lokiConversation(id: conversation.id))
    }

    func testOnlyUserAndAssistantMessagesCanBePersisted() throws {
        let store = try LocalStore(inMemory: true)
        let conversation = privateConversation(id: "roles")
        try store.persistLokiConversation(conversation)
        let hiddenSystemMessage = LokiMessage(
            id: "hidden-system",
            conversationID: conversation.id,
            sequence: 0,
            role: .system,
            state: .completed,
            visibleText: "Never persist private system policy."
        )

        XCTAssertThrowsError(try store.persistLokiMessage(hiddenSystemMessage)) { error in
            XCTAssertEqual(
                error as? LokiChatPersistenceError,
                .unsupportedPersistedRole
            )
        }
    }

    func testSourceExcerptsAreOffByDefaultAndExistingExcerptsAreScrubbedWhenDisabled() throws {
        let store = try LocalStore(inMemory: true)
        try seedAssistantMessage(store: store, conversationID: "excerpt", messageID: "answer")
        let reference = LokiEvidenceReference(
            id: "brief-reference",
            sourceKind: .brief,
            itemIdentifier: "brief-item",
            retrievedAt: .now,
            displayLabel: "Current brief",
            boundedExcerpt: "Bounded source excerpt",
            trustClassification: .localAuthoritative
        )

        try store.persistLokiEvidenceReference(
            reference,
            conversationID: "excerpt",
            messageID: "answer"
        )
        XCTAssertNil(
            try store.lokiEvidenceReferences(messageID: "answer").first?.boundedExcerpt
        )

        var settings = try store.lokiChatPrivacySettings()
        settings.includeSourceExcerpts = true
        try store.updateLokiChatPrivacySettings(settings)
        try store.persistLokiEvidenceReference(
            reference,
            conversationID: "excerpt",
            messageID: "answer"
        )
        XCTAssertEqual(
            try store.lokiEvidenceReferences(messageID: "answer").first?.boundedExcerpt,
            "Bounded source excerpt"
        )

        settings.includeSourceExcerpts = false
        try store.updateLokiChatPrivacySettings(settings)
        XCTAssertNil(
            try store.lokiEvidenceReferences(messageID: "answer").first?.boundedExcerpt
        )
    }

    func testFeedAndSlackEvidenceUseSeparateExplicitPolicies() throws {
        let store = try LocalStore(inMemory: true)
        try seedAssistantMessage(store: store, conversationID: "policies", messageID: "answer")
        let feed = LokiEvidenceReference(
            id: "feed-reference",
            sourceKind: .feed,
            accountClassification: "feed_subscription",
            accountIdentifier: "feed-1",
            containerClassification: "feed",
            containerIdentifier: "feed-1",
            itemIdentifier: "feed-item",
            retrievedAt: .now,
            displayLabel: "Feed item",
            trustClassification: .untrustedExternalContent
        )
        let slack = LokiEvidenceReference(
            id: "slack-reference",
            sourceKind: .slack,
            accountClassification: "slack_workspace",
            accountIdentifier: "workspace-1",
            containerClassification: "selected_channel",
            containerIdentifier: "channel-1",
            itemIdentifier: "slack-item",
            retrievedAt: .now,
            displayLabel: "Selected Slack message",
            trustClassification: .untrustedExternalContent
        )
        try seedFeedAuthorization(store: store, feedID: "feed-1")

        XCTAssertTrue(
            try store.persistLokiEvidenceReference(
                feed,
                conversationID: "policies",
                messageID: "answer"
            )
        )
        XCTAssertThrowsError(
            try store.persistLokiEvidenceReference(
                slack,
                conversationID: "policies",
                messageID: "answer"
            )
        ) { error in
            XCTAssertEqual(
                error as? LokiChatPersistenceError,
                .sourceEvidenceNotAllowed
            )
        }

        try seedSlackAuthorization(
            store: store,
            workspaceID: "workspace-1",
            channelIDs: ["channel-1"]
        )
        XCTAssertTrue(
            try store.persistLokiEvidenceReference(
                slack,
                conversationID: "policies",
                messageID: "answer"
            )
        )
    }

    func testDirectSourceActionsRejectCredentialsAndNonHTTPSURLs() throws {
        let credentialURL = try XCTUnwrap(
            URL(string: "https://user:secret@example.com/item#private-fragment")
        )
        let insecureURL = try XCTUnwrap(URL(string: "http://example.com/item"))
        let safeURL = try XCTUnwrap(URL(string: "https://example.com/item#fragment"))

        func reference(url: URL) -> LokiEvidenceReference {
            LokiEvidenceReference(
                id: UUID().uuidString,
                sourceKind: .feed,
                itemIdentifier: "item",
                retrievedAt: .now,
                displayLabel: "Source",
                directSourceURL: url,
                trustClassification: .untrustedExternalContent
            )
        }

        XCTAssertNil(reference(url: credentialURL).directSourceURL)
        XCTAssertNil(reference(url: insecureURL).directSourceURL)
        XCTAssertEqual(
            reference(url: safeURL).directSourceURL?.absoluteString,
            "https://example.com/item"
        )
    }

    func testDeletingSourceEvidenceRemovesReceiptsAndReplacesDependentAnswer() throws {
        let store = try LocalStore(inMemory: true)
        try seedAssistantMessage(store: store, conversationID: "scrub", messageID: "answer")
        try seedFeedAuthorization(store: store, feedID: "feed-1")
        let rssAccountIdentifier = VaultIdentity.accountID(
            provider: "rss",
            providerAccountID: "local-feeds"
        )
        try store.persistLokiEvidenceReference(
            LokiEvidenceReference(
                id: "vault-reference",
                sourceKind: .vault,
                accountClassification: "rss",
                accountIdentifier: rssAccountIdentifier,
                containerClassification: "feed",
                containerIdentifier: VaultIdentity.containerID(
                    provider: "rss",
                    accountID: rssAccountIdentifier,
                    providerContainerID: "feed-1"
                ),
                itemIdentifier: "vault-item",
                retrievedAt: .now,
                displayLabel: "Vault item",
                trustClassification: .localAuthoritative
            ),
            conversationID: "scrub",
            messageID: "answer"
        )
        try store.persistLokiToolReceipt(
            LokiChatToolReceipt(
                id: "receipt",
                requestIdentifier: "request",
                toolName: "get_vault_item",
                status: "success",
                reasonCode: "bounded_result",
                requestedAt: .now,
                completedAt: .now,
                durationMilliseconds: 2,
                resultCount: 1,
                evidenceReferenceIDs: ["vault-reference"],
                argumentKeys: ["item_id"]
            ),
            conversationID: "scrub",
            messageID: "answer"
        )

        XCTAssertEqual(
            try store.scrubLokiChatEvidence(sourceKind: .vault, accountIdentifier: nil),
            1
        )

        let message = try XCTUnwrap(try store.lokiConversation(id: "scrub")?.messages.first)
        XCTAssertEqual(message.state, .sourceEvidenceDeleted)
        XCTAssertEqual(message.failure?.code, .sourceEvidenceDeleted)
        XCTAssertTrue(try store.lokiEvidenceReferences(messageID: "answer").isEmpty)
        XCTAssertTrue(try store.lokiToolReceipts(messageID: "answer").isEmpty)
    }

    func testAccountScopedStatusScrubPreservesOtherWorkspaceEvidence() throws {
        let store = try LocalStore(inMemory: true)
        try seedAssistantMessage(
            store: store,
            conversationID: "workspace-one",
            messageID: "answer-one"
        )
        try seedAssistantMessage(
            store: store,
            conversationID: "workspace-two",
            messageID: "answer-two"
        )
        for workspaceID in ["workspace-1", "workspace-2"] {
            try seedSlackAuthorization(
                store: store,
                workspaceID: workspaceID,
                channelIDs: []
            )
        }
        for (workspaceID, conversationID, messageID) in [
            ("workspace-1", "workspace-one", "answer-one"),
            ("workspace-2", "workspace-two", "answer-two"),
        ] {
            try store.persistLokiEvidenceReference(
                .init(
                    id: "status-\(workspaceID)",
                    sourceKind: .connectedSourceStatus,
                    accountClassification: "slack_workspace",
                    accountIdentifier: workspaceID,
                    itemIdentifier: workspaceID,
                    retrievedAt: .now,
                    displayLabel: "Connected source status",
                    trustClassification: .localAuthoritative
                ),
                conversationID: conversationID,
                messageID: messageID
            )
        }

        XCTAssertEqual(
            try store.scrubLokiChatEvidence(
                sourceKind: .connectedSourceStatus,
                accountIdentifier: "workspace-1"
            ),
            1
        )
        XCTAssertTrue(
            try store.lokiEvidenceReferences(messageID: "answer-one").isEmpty
        )
        XCTAssertEqual(
            try store.lokiEvidenceReferences(messageID: "answer-two")
                .map(\.accountIdentifier),
            ["workspace-2"]
        )
        XCTAssertEqual(
            try store.lokiConversation(id: "workspace-two")?.messages.first?.state,
            .completed
        )
    }

    func testVaultAndSourceStatusPersistenceRechecksProviderConsent() throws {
        let store = try LocalStore(inMemory: true)
        try seedAssistantMessage(
            store: store,
            conversationID: "defense",
            messageID: "answer"
        )
        let rssVault = LokiEvidenceReference(
            id: "rss-vault",
            sourceKind: .vault,
            accountClassification: "rss",
            accountIdentifier: "rss:local-feeds",
            containerClassification: "feed",
            containerIdentifier: VaultIdentity.containerID(
                provider: "rss",
                accountID: VaultIdentity.accountID(
                    provider: "rss",
                    providerAccountID: "local-feeds"
                ),
                providerContainerID: "feed-1"
            ),
            itemIdentifier: "rss-item",
            retrievedAt: .now,
            displayLabel: "RSS archive item",
            trustClassification: .untrustedExternalContent
        )
        let slackVault = LokiEvidenceReference(
            id: "slack-vault",
            sourceKind: .vault,
            accountClassification: "slack",
            accountIdentifier: "slack:workspace-1",
            containerClassification: "channel",
            containerIdentifier: VaultIdentity.containerID(
                provider: "slack",
                accountID: VaultIdentity.accountID(
                    provider: "slack",
                    providerAccountID: "workspace-1"
                ),
                providerContainerID: "channel-1"
            ),
            itemIdentifier: "slack-item",
            retrievedAt: .now,
            displayLabel: "Slack archive item",
            trustClassification: .untrustedExternalContent
        )
        var settings = try store.lokiChatPrivacySettings()
        settings.allowFeedEvidence = false
        try store.updateLokiChatPrivacySettings(settings)

        XCTAssertThrowsError(
            try store.persistLokiEvidenceReference(
                rssVault,
                conversationID: "defense",
                messageID: "answer"
            )
        )
        XCTAssertThrowsError(
            try store.persistLokiEvidenceReference(
                slackVault,
                conversationID: "defense",
                messageID: "answer"
            )
        )

        try seedSlackAuthorization(
            store: store,
            workspaceID: "workspace-1",
            channelIDs: ["channel-1"]
        )
        XCTAssertTrue(
            try store.persistLokiEvidenceReference(
                slackVault,
                conversationID: "defense",
                messageID: "answer"
            )
        )

        settings.allowFeedEvidence = true
        try store.updateLokiChatPrivacySettings(settings)
        try seedFeedAuthorization(store: store, feedID: "feed-1")
        XCTAssertTrue(
            try store.persistLokiEvidenceReference(
                rssVault,
                conversationID: "defense",
                messageID: "answer"
            )
        )
        XCTAssertThrowsError(
            try store.persistLokiEvidenceReference(
                .init(
                    id: "unknown-vault",
                    sourceKind: .vault,
                    accountClassification: "unknown",
                    accountIdentifier: "unknown:account",
                    containerIdentifier: "unknown-container",
                    itemIdentifier: "unknown-item",
                    retrievedAt: .now,
                    displayLabel: "Unknown archive item",
                    trustClassification: .untrustedExternalContent
                ),
                conversationID: "defense",
                messageID: "answer"
            )
        )
    }

    func testFeedStatusAndVaultScrubPreservesSlackAndOtherFeedContainers() throws {
        let store = try LocalStore(inMemory: true)
        for (conversationID, messageID) in [
            ("feed-one", "feed-answer-one"),
            ("feed-two", "feed-answer-two"),
            ("slack", "slack-answer"),
        ] {
            try seedAssistantMessage(
                store: store,
                conversationID: conversationID,
                messageID: messageID
            )
        }
        try seedSlackAuthorization(
            store: store,
            workspaceID: "workspace-1",
            channelIDs: ["channel-1"]
        )
        try seedFeedAuthorization(store: store, feedID: "feed-1")
        try seedFeedAuthorization(store: store, feedID: "feed-2")
        let rssAccountID = VaultIdentity.accountID(
            provider: "rss",
            providerAccountID: "local-feeds"
        )
        let firstContainerID = VaultIdentity.containerID(
            provider: "rss",
            accountID: rssAccountID,
            providerContainerID: "feed-1"
        )
        let secondContainerID = VaultIdentity.containerID(
            provider: "rss",
            accountID: rssAccountID,
            providerContainerID: "feed-2"
        )
        for (identifier, containerID, conversationID, messageID) in [
            ("rss-one", firstContainerID, "feed-one", "feed-answer-one"),
            ("rss-two", secondContainerID, "feed-two", "feed-answer-two"),
        ] {
            try store.persistLokiEvidenceReference(.init(
                id: identifier,
                sourceKind: .vault,
                accountClassification: "rss",
                accountIdentifier: rssAccountID,
                containerClassification: "feed",
                containerIdentifier: containerID,
                itemIdentifier: identifier,
                retrievedAt: .now,
                displayLabel: identifier,
                trustClassification: .untrustedExternalContent
            ), conversationID: conversationID, messageID: messageID)
        }
        try store.persistLokiEvidenceReference(.init(
            id: "slack-status",
            sourceKind: .connectedSourceStatus,
            accountClassification: "slack_workspace",
            accountIdentifier: "workspace-1",
            itemIdentifier: "workspace-1",
            retrievedAt: .now,
            displayLabel: "Slack status",
            trustClassification: .localAuthoritative
        ), conversationID: "slack", messageID: "slack-answer")

        XCTAssertEqual(
            try store.scrubLokiChatEvidence(
                sourceKind: .vault,
                accountIdentifier: nil,
                accountClassification: "rss",
                containerIdentifier: firstContainerID
            ),
            1
        )
        XCTAssertTrue(
            try store.lokiEvidenceReferences(messageID: "feed-answer-one").isEmpty
        )
        XCTAssertEqual(
            try store.lokiEvidenceReferences(messageID: "feed-answer-two").map(\.id),
            ["rss-two"]
        )
        XCTAssertEqual(
            try store.lokiEvidenceReferences(messageID: "slack-answer").map(\.id),
            ["slack-status"]
        )
    }

    func testExportContainsOnlyUserVisibleBoundedData() throws {
        let date = Date(timeIntervalSince1970: 1_720_000_000)
        var conversation = privateConversation(id: "export", at: date)
        conversation.messages = [
            LokiMessage(
                id: "system",
                conversationID: conversation.id,
                sequence: 0,
                role: .system,
                state: .completed,
                visibleText: "RAW_PROVIDER_PAYLOAD_SENTINEL"
            ),
            LokiMessage(
                id: "user",
                conversationID: conversation.id,
                sequence: 1,
                role: .user,
                state: .completed,
                visibleText: "What is observed?"
            ),
            LokiMessage(
                id: "assistant",
                conversationID: conversation.id,
                sequence: 2,
                role: .assistant,
                state: .completed,
                visibleText: "The current brief is ready."
            ),
        ]
        let snapshot = LokiChatExportSnapshot(
            exportedAt: date,
            conversation: conversation,
            evidenceByMessageID: [:],
            toolReceiptsByMessageID: [:],
            provenanceByMessageID: [:]
        )

        let json = try LokiChatExportRenderer.render(snapshot, format: .json)
        let text = try XCTUnwrap(String(data: json.data, encoding: .utf8))

        XCTAssertLessThanOrEqual(json.data.count, LokiChatLimits.maximumExportBytes)
        XCTAssertTrue(text.contains("What is observed?"))
        XCTAssertTrue(text.contains("The current brief is ready."))
        XCTAssertFalse(text.contains("RAW_PROVIDER_PAYLOAD_SENTINEL"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("hidden reasoning"))
    }
}

private func privateConversation(
    id: String,
    at date: Date = Date(timeIntervalSince1970: 1_720_000_000)
) -> LokiConversation {
    LokiConversation(
        id: id,
        title: "Private test conversation",
        createdAt: date,
        updatedAt: date,
        context: LokiChatContext(scope: .thisBrief, selectedAt: date)
    )
}

@MainActor
private func seedAssistantMessage(
    store: LocalStore,
    conversationID: String,
    messageID: String
) throws {
    var conversation = privateConversation(id: conversationID)
    conversation.messages = [
        LokiMessage(
            id: messageID,
            conversationID: conversationID,
            sequence: 0,
            role: .assistant,
            state: .completed,
            visibleText: "Evidence-bound answer."
        ),
    ]
    try store.persistLokiConversation(conversation)
}

@MainActor
private func seedFeedAuthorization(
    store: LocalStore,
    feedID: String
) throws {
    let date = Date(timeIntervalSince1970: 1_720_000_000)
    try store.persistFeedSubscription(.init(
        id: feedID,
        title: feedID,
        canonicalURL: URL(string: "https://example.com/\(feedID).xml")!,
        enabled: true,
        format: .rss2,
        lastAttemptedAt: date,
        lastSuccessfulAt: date,
        lastHTTPStatus: 200,
        eTag: nil,
        lastModified: nil,
        state: .connected,
        failure: nil,
        policy: .default,
        weight: 1,
        createdAt: date,
        updatedAt: date
    ))
}

@MainActor
private func seedSlackAuthorization(
    store: LocalStore,
    workspaceID: String,
    channelIDs: [String]
) throws {
    let date = Date(timeIntervalSince1970: 1_720_000_000)
    try store.upsertSlackWorkspace(.init(
        id: workspaceID,
        teamID: "team-\(workspaceID)",
        userID: "user-\(workspaceID)",
        teamName: workspaceID,
        userDisplayName: "Test user",
        connectionStateRaw: SlackConnectionState.connected.rawValue,
        grantedScopes: "",
        tokenType: "bot",
        credentialIssuedAt: date,
        accessExpiresAt: date.addingTimeInterval(3_600),
        enabled: true,
        localModelConsent: false,
        createdAt: date,
        updatedAt: date
    ))
    try store.setSlackLocalModelConsent(
        workspaceID: workspaceID,
        enabled: true
    )
    for channelID in channelIDs {
        try store.upsertSlackConversation(.init(
            id: "\(workspaceID):\(channelID)",
            workspaceID: workspaceID,
            conversationID: channelID,
            displayName: channelID,
            kindRaw: SlackConversationKind.privateChannel.rawValue,
            isMember: true,
            selected: true,
            enabled: false,
            createdAt: date,
            updatedAt: date
        ))
    }
    try store.updateLokiChatWorkspaceEvidencePolicy(.init(
        workspaceIdentifier: workspaceID,
        allowSelectedSlackEvidence: true,
        updatedAt: date
    ))
}
