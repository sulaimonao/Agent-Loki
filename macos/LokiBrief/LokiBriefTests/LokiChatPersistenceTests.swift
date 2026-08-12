import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class LokiChatPersistenceTests: XCTestCase, @unchecked Sendable {
    func testDefaultsAreLocalHistoryNinetyDaysNoExcerptsAndFeedEvidenceOn() throws {
        let store = try LocalStore(inMemory: true)

        let settings = try store.lokiChatPrivacySettings()

        XCTAssertTrue(settings.storeLocalHistory)
        XCTAssertEqual(settings.retentionPolicy, .ninetyDays)
        XCTAssertEqual(settings.effectiveRetentionDays, 90)
        XCTAssertFalse(settings.includeSourceExcerpts)
        XCTAssertTrue(settings.allowFeedEvidence)
        XCTAssertFalse(
            try store.lokiChatWorkspaceEvidencePolicy(
                workspaceIdentifier: "workspace-1"
            ).allowSelectedSlackEvidence
        )
    }

    func testConversationReopensWithStableMessageOrderAndPagination() throws {
        let store = try LocalStore(inMemory: true)
        let base = Date(timeIntervalSince1970: 1_720_000_000)
        for index in 0..<3 {
            var conversation = chatConversation(
                id: "conversation-\(index)",
                updatedAt: base.addingTimeInterval(Double(index))
            )
            conversation.messages = [
                chatMessage(
                    id: "assistant-\(index)",
                    conversationID: conversation.id,
                    sequence: 2,
                    role: .assistant,
                    text: "Answer \(index)",
                    at: base
                ),
                chatMessage(
                    id: "user-\(index)",
                    conversationID: conversation.id,
                    sequence: 1,
                    role: .user,
                    text: "Question \(index)",
                    at: base
                ),
            ]
            XCTAssertTrue(try store.persistLokiConversation(conversation))
        }

        let firstPage = try store.lokiConversationPage(offset: 0, limit: 2)
        let secondPage = try store.lokiConversationPage(offset: 2, limit: 2)
        XCTAssertEqual(firstPage.map(\.id), ["conversation-2", "conversation-1"])
        XCTAssertEqual(secondPage.map(\.id), ["conversation-0"])

        let reopened = try XCTUnwrap(try store.lokiConversation(id: "conversation-1"))
        XCTAssertEqual(reopened.messages.map(\.id), ["user-1", "assistant-1"])
        XCTAssertEqual(reopened.messages.map(\.visibleText), ["Question 1", "Answer 1"])

        XCTAssertTrue(
            try store.persistLokiChatContextSelection(
                id: "context-selection",
                conversationID: "conversation-1",
                requestMessageID: "user-1",
                context: LokiChatContext(
                    scope: .history,
                    selectedAt: base.addingTimeInterval(10)
                ),
                tokenEstimate: 321,
                wasTruncated: true
            )
        )
        let selection = try XCTUnwrap(
            try store.lokiChatContextSelections(conversationID: "conversation-1").first
        )
        XCTAssertEqual(selection.context.scope, .history)
        XCTAssertEqual(selection.tokenEstimate, 321)
        XCTAssertTrue(selection.wasTruncated)
    }

    func testDiskBackedConversationSurvivesStoreReopen() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-p7-chat-reopen-\(UUID().uuidString)", isDirectory: true)
        let storeURL = directory.appendingPathComponent("LokiBrief.store")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            let store = try LocalStore(url: storeURL)
            var conversation = chatConversation(id: "reopen")
            conversation.messages = [
                chatMessage(
                    id: "reopen-user",
                    conversationID: conversation.id,
                    sequence: 0,
                    role: .user,
                    text: "Persist me"
                ),
            ]
            XCTAssertTrue(try store.persistLokiConversation(conversation))
        }

        let reopenedStore = try LocalStore(url: storeURL)
        let reopened = try XCTUnwrap(try reopenedStore.lokiConversation(id: "reopen"))
        XCTAssertEqual(reopened.messages.first?.visibleText, "Persist me")
    }

    func testTransientMessagesBecomeTruthfulInterruptedPartialsAfterRelaunch() throws {
        let store = try LocalStore(inMemory: true)
        var conversation = chatConversation(id: "interrupted")
        conversation.messages = [
            LokiMessage(
                id: "partial",
                conversationID: conversation.id,
                sequence: 0,
                role: .assistant,
                state: .streaming,
                visibleText: "A truthful partial answer",
                isPartial: true
            ),
        ]
        try store.persistLokiConversation(conversation)
        try store.persistLokiEvidenceReference(
            LokiEvidenceReference(
                id: "partial-evidence",
                sourceKind: .brief,
                itemIdentifier: "brief-item",
                retrievedAt: .now,
                displayLabel: "Transient evidence",
                trustClassification: .localAuthoritative
            ),
            conversationID: conversation.id,
            messageID: "partial"
        )
        try store.persistLokiToolReceipt(
            LokiChatToolReceipt(
                id: "partial-receipt",
                requestIdentifier: "request-hash",
                toolName: "get_current_brief",
                status: "success",
                reasonCode: "chat_tool_success",
                requestedAt: .now,
                completedAt: .now,
                durationMilliseconds: 1,
                resultCount: 1,
                evidenceReferenceIDs: ["partial-evidence"],
                argumentKeys: []
            ),
            conversationID: conversation.id,
            messageID: "partial"
        )
        try store.persistLokiGenerationProvenance(
            LokiGenerationProvenance(
                provider: "ollama",
                modelIdentifier: "synthetic",
                assessmentVersion: "1",
                promptTemplateVersion: "1",
                toolSchemaVersion: "1",
                startedAt: .now,
                completedAt: nil,
                durationMilliseconds: nil,
                promptTokenEstimate: nil,
                completionTokenCount: nil,
                evidenceCount: 1,
                status: "started",
                reasonCode: "chat_started"
            ),
            conversationID: conversation.id,
            messageID: "partial"
        )
        let reconciledAt = Date(timeIntervalSince1970: 1_730_000_000)

        XCTAssertEqual(
            try store.reconcileInterruptedLokiChatMessages(at: reconciledAt),
            1
        )

        let message = try XCTUnwrap(
            try store.lokiConversation(id: conversation.id)?.messages.first
        )
        XCTAssertEqual(message.state, .interrupted)
        XCTAssertEqual(message.visibleText, "A truthful partial answer")
        XCTAssertTrue(message.isPartial)
        XCTAssertEqual(message.completedAt, reconciledAt)
        XCTAssertEqual(message.failure?.code, .generationInterrupted)
        XCTAssertTrue(message.failure?.isRecoverable == true)
        XCTAssertTrue(try store.lokiEvidenceReferences(messageID: "partial").isEmpty)
        XCTAssertTrue(try store.lokiToolReceipts(messageID: "partial").isEmpty)
        XCTAssertNil(try store.lokiGenerationProvenance(messageID: "partial"))
    }

    func testRetentionExcludesActiveConversationAndDeletesExpiredConversation() throws {
        let store = try LocalStore(inMemory: true)
        let now = Date(timeIntervalSince1970: 1_740_000_000)
        var settings = try store.lokiChatPrivacySettings()
        settings.retentionPolicy = .thirtyDays
        try store.updateLokiChatPrivacySettings(settings, at: now)
        try store.persistLokiConversation(
            chatConversation(id: "expired", updatedAt: now.addingTimeInterval(-31 * 86_400))
        )
        try store.persistLokiConversation(
            chatConversation(id: "active-expired", updatedAt: now.addingTimeInterval(-31 * 86_400))
        )
        try store.persistLokiConversation(
            chatConversation(id: "recent", updatedAt: now.addingTimeInterval(-29 * 86_400))
        )

        let deleted = try store.enforceLokiChatRetention(
            referenceDate: now,
            excludingConversationIDs: ["active-expired"]
        )

        XCTAssertEqual(deleted, ["expired"])
        XCTAssertNil(try store.lokiConversation(id: "expired"))
        XCTAssertNotNil(try store.lokiConversation(id: "active-expired"))
        XCTAssertNotNil(try store.lokiConversation(id: "recent"))
    }

    func testDeleteOneCascadesChatRowsAndDeleteAllPreservesAssessment() throws {
        let store = try LocalStore(inMemory: true)
        var conversation = chatConversation(id: "delete-me")
        conversation.messages = [
            chatMessage(
                id: "delete-answer",
                conversationID: conversation.id,
                sequence: 0,
                role: .assistant,
                text: "Bounded answer"
            ),
        ]
        try store.persistLokiConversation(conversation)
        try store.persistLokiEvidenceReference(
            LokiEvidenceReference(
                id: "evidence",
                sourceKind: .brief,
                itemIdentifier: "brief-1",
                retrievedAt: .now,
                displayLabel: "Current brief",
                trustClassification: .localAuthoritative
            ),
            conversationID: conversation.id,
            messageID: "delete-answer"
        )
        try store.upsertLokiModelAssessment(modelAssessmentRecord(id: "assessment"))

        try store.deleteLokiConversation(id: conversation.id)

        XCTAssertNil(try store.lokiConversation(id: conversation.id))
        XCTAssertTrue(try store.lokiEvidenceReferences(messageID: "delete-answer").isEmpty)
        XCTAssertEqual(try store.lokiModelAssessments().map(\.id), ["assessment"])

        try store.deleteAllLokiConversations()
        XCTAssertEqual(try store.lokiModelAssessments().map(\.id), ["assessment"])
    }

    func testChatModelSelectionRoundTripsSeparatelyAndDeleteAllClearsIt() throws {
        let store = try LocalStore(inMemory: true)
        let selection = ChatModelSelection(
            provider: "ollama",
            modelIdentifier: "synthetic-model",
            modelDigest: "sha256:synthetic",
            assessmentVersion: ModelCapabilityAssessment.currentAssessmentVersion,
            selectedAt: Date(timeIntervalSince1970: 1_720_000_123)
        )

        try store.saveLokiChatModelSelection(selection)

        XCTAssertEqual(try store.lokiChatModelSelection(), selection)
        try store.deleteAllLokiP7Data()
        XCTAssertNil(try store.lokiChatModelSelection())
        XCTAssertTrue(try store.lokiModelAssessments().isEmpty)
    }
}

private func chatConversation(
    id: String,
    updatedAt: Date = Date(timeIntervalSince1970: 1_720_000_000)
) -> LokiConversation {
    LokiConversation(
        id: id,
        title: "Conversation \(id)",
        createdAt: updatedAt,
        updatedAt: updatedAt,
        context: LokiChatContext(scope: .today, selectedAt: updatedAt)
    )
}

private func chatMessage(
    id: String,
    conversationID: String,
    sequence: Int,
    role: LokiMessageRole,
    text: String,
    at: Date = Date(timeIntervalSince1970: 1_720_000_000)
) -> LokiMessage {
    LokiMessage(
        id: id,
        conversationID: conversationID,
        sequence: sequence,
        role: role,
        state: .completed,
        visibleText: text,
        createdAt: at,
        completedAt: at
    )
}

private func modelAssessmentRecord(id: String) -> LokiModelAssessmentRecord {
    LokiModelAssessmentRecord(
        id: id,
        readiness: .ready,
        assessment: ModelCapabilityAssessment(
            provider: "ollama",
            providerVersion: "0.12.0",
            modelIdentifier: "synthetic-model",
            modelDigest: "sha256:synthetic",
            capabilitiesProven: [.chat, .streaming, .structuredOutput, .toolCalling, .cancellation],
            capabilitiesMissing: [.vision, .embedding, .webResearch],
            contextPolicy: ModelContextPolicy(declaredContextTokens: 65_536),
            assessedAt: Date(timeIntervalSince1970: 1_720_000_000),
            durationMilliseconds: 123,
            diagnostics: [
                .init(
                    probe: .ordinaryChat,
                    status: .success,
                    reasonCode: "synthetic_probe_passed",
                    durationMilliseconds: 10
                ),
            ]
        )
    )
}
