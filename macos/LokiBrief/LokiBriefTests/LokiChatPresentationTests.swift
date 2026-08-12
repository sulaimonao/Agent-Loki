import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class LokiChatPresentationTests: XCTestCase, @unchecked Sendable {
    func testSemanticSourceAuthorityFirstUseHasNoBuildAuthority() throws {
        let presentation = P8SemanticSourceAuthorityPresentation(
            buildSourceKinds: [],
            searchFilterSourceKinds: [],
            indexedSourceKinds: [],
            availableBuildSourceKinds: [
                .brief,
                .schedule,
                .chatMessage,
                .slackRecord,
            ],
            rebuildRequired: false,
            isWorking: false
        )

        XCTAssertEqual(
            presentation.selectedBuildSourceSummary,
            "No Index Sources selected."
        )
        XCTAssertFalse(presentation.canRebuildSelectedSources)
        XCTAssertFalse(
            try XCTUnwrap(
                presentation.rows.first {
                    $0.sourceKind == .slackRecord
                }
            ).selectedForNextRebuild
        )
        XCTAssertFalse(
            try XCTUnwrap(
                presentation.rows.first {
                    $0.sourceKind == .vaultRecord
                }
            ).selectedForNextRebuild
        )
    }

    func testSemanticBuildAuthorityAndSearchFiltersPresentIndependentStates() throws {
        let presentation = P8SemanticSourceAuthorityPresentation(
            buildSourceKinds: [
                .brief,
                .schedule,
                .chatMessage,
            ],
            searchFilterSourceKinds: [.slackRecord],
            indexedSourceKinds: [.brief, .schedule],
            availableBuildSourceKinds: [
                .brief,
                .schedule,
                .chatMessage,
                .slackRecord,
            ],
            rebuildRequired: true,
            isWorking: false
        )

        XCTAssertTrue(presentation.canRebuildSelectedSources)
        XCTAssertEqual(
            presentation.selectedBuildSourceSummary,
            "Selected for next rebuild: Briefs, Final Chat Messages, Schedules."
        )

        let brief = try XCTUnwrap(
            presentation.rows.first { $0.sourceKind == .brief }
        )
        XCTAssertTrue(brief.selectedForNextRebuild)
        XCTAssertTrue(brief.presentInActiveGeneration)
        XCTAssertFalse(brief.enabledAsSearchFilter)
        XCTAssertTrue(brief.rebuildRequired)

        let slack = try XCTUnwrap(
            presentation.rows.first {
                $0.sourceKind == .slackRecord
            }
        )
        XCTAssertFalse(slack.selectedForNextRebuild)
        XCTAssertFalse(slack.presentInActiveGeneration)
        XCTAssertTrue(slack.enabledAsSearchFilter)
        XCTAssertTrue(slack.searchFilterIsNotIndexed)

        let connector = try XCTUnwrap(
            presentation.rows.first {
                $0.sourceKind == .connectorRecord
            }
        )
        XCTAssertFalse(connector.availableForRebuild)
    }

    func testP7ContextScopesExposeFiveEnabledAndThreeTruthfulDeferredOptions() {
        XCTAssertEqual(
            LokiChatContextScope.implementedCases,
            [.thisBrief, .today, .vault, .connectedSources, .history]
        )
        XCTAssertEqual(
            LokiChatContextScope.deferredCases,
            [.journal, .goalsAndTasks, .web]
        )
        XCTAssertEqual(
            LokiChatPresentation.deferredScopeLabel(.journal),
            "Journal — planned"
        )
        XCTAssertEqual(
            LokiChatPresentation.deferredScopeLabel(.goalsAndTasks),
            "Goals & Tasks — planned"
        )
        XCTAssertEqual(
            LokiChatPresentation.deferredScopeLabel(.web),
            "Web — planned"
        )
    }

    func testHistoryDisclosureStatesLocalHistoryAndNoDurableMemory() {
        XCTAssertEqual(
            LokiChatPresentation.localHistoryDisclosure,
            "Chat history is stored locally."
        )
        XCTAssertEqual(
            LokiChatPresentation.localHistoryDisclosure(storeLocalHistory: false),
            "Chat history storage is off; new turns are retained only for this app session. Previously stored history remains local until you delete it."
        )
        XCTAssertEqual(
            LokiChatPresentation.noDurableMemoryDisclosure,
            "Agent Loki does not create durable personal memories in this version."
        )
    }

    func testDeletionAnnouncementsNeverClaimSuccessAfterFailure() {
        XCTAssertEqual(
            LokiChatPresentation.deletionAnnouncement(all: false, succeeded: false),
            "Agent Loki could not delete that local conversation."
        )
        XCTAssertEqual(
            LokiChatPresentation.deletionAnnouncement(all: true, succeeded: false),
            "Agent Loki could not delete all local conversations."
        )
    }

    func testPrivacyDraftTracksExternalResetWithoutOverwritingOrdinaryUnsavedEdits() {
        var committed = LokiChatPrivacySettings.defaults
        var unsaved = committed
        unsaved.storeLocalHistory = false
        var externallyChanged = committed
        externallyChanged.includeSourceExcerpts = true

        XCTAssertEqual(
            LokiChatPresentation.reconciledPrivacyDraft(
                unsaved,
                previousCommitted: committed,
                newCommitted: externallyChanged
            ),
            unsaved
        )

        committed = externallyChanged
        XCTAssertEqual(
            LokiChatPresentation.reconciledPrivacyDraft(
                unsaved,
                previousCommitted: committed,
                newCommitted: .defaults
            ),
            .defaults
        )
    }

    func testReadinessGatesSendingUntilAssessmentIsReady() {
        let state = LokiChatViewState()
        state.composerText = "What changed?"
        XCTAssertFalse(state.canSubmit)

        state.modelReadiness = LokiChatModelReadinessPresentation(
            readiness: .ready,
            providerName: "Ollama",
            modelName: "Synthetic model",
            requiredCapabilitiesMissing: [],
            recommendedCapabilitiesMissing: [],
            contextWindowSummary: "64k usable",
            failureMessage: nil
        )

        XCTAssertTrue(state.canSubmit)
        state.selectedScope = .connectedSources
        state.selectedContextIdentifier = "source-a"
        XCTAssertFalse(state.canSubmit)
        state.attachedSourceOptions = [
            .init(
                id: "source-a",
                displayName: "Selected data",
                kind: .sqlite
            ),
        ]
        XCTAssertTrue(state.canSubmit)
        XCTAssertEqual(state.selectedContext.targetIdentifier, "source-a")
        state.selectedScope = .web
        XCTAssertFalse(state.canSubmit)
    }

    func testStreamingTextDoesNotCreatePerTokenAccessibilityAnnouncements() throws {
        let message = LokiMessage(
            id: "assistant",
            conversationID: "conversation",
            sequence: 1,
            role: .assistant,
            state: .waitingForFirstToken,
            visibleText: ""
        )
        let state = LokiChatViewState(messages: [message])

        state.generationStarted(messageID: message.id)
        let revisionAfterStart = state.announcementRevision
        XCTAssertEqual(state.announcementText, "Agent Loki is responding.")

        state.updateStreamingText(messageID: message.id, text: "One")
        state.updateStreamingText(messageID: message.id, text: "One two")
        state.updateStreamingText(messageID: message.id, text: "One two three")

        XCTAssertEqual(state.announcementRevision, revisionAfterStart)
        XCTAssertEqual(try XCTUnwrap(state.messages.first).visibleText, "One two three")

        state.generationCompleted(messageID: message.id)
        XCTAssertEqual(state.announcementRevision, revisionAfterStart + 1)
        XCTAssertEqual(state.announcementText, "Agent Loki response complete.")
    }

    func testLiveBridgeGenerationSynchronizationAnnouncesLifecycleExactlyOnce() {
        let state = LokiChatViewState(
            selectedConversationID: "ephemeral-conversation"
        )
        XCTAssertTrue(state.hasConversationToDelete)

        state.synchronizeGeneration(
            activeMessageID: "assistant",
            terminalStateByMessageID: [:]
        )
        let startedRevision = state.announcementRevision
        XCTAssertEqual(state.announcementText, "Agent Loki is responding.")

        state.synchronizeGeneration(
            activeMessageID: "assistant",
            terminalStateByMessageID: ["assistant": .streaming]
        )
        XCTAssertEqual(state.announcementRevision, startedRevision)

        state.synchronizeGeneration(
            activeMessageID: nil,
            terminalStateByMessageID: ["assistant": .completed]
        )
        XCTAssertEqual(state.announcementRevision, startedRevision + 1)
        XCTAssertEqual(state.announcementText, "Agent Loki response complete.")

        state.synchronizeGeneration(
            activeMessageID: nil,
            terminalStateByMessageID: ["assistant": .completed]
        )
        XCTAssertEqual(state.announcementRevision, startedRevision + 1)
    }

    func testDeferredInitialScopeFallsBackToThisBrief() {
        let state = LokiChatViewState(selectedScope: .web)

        XCTAssertEqual(state.selectedScope, .thisBrief)
        XCTAssertEqual(state.selectedContext.scope, .thisBrief)
    }

    func testReadinessPresentationNeverTreatsPartialCompatibilityAsReady() {
        let presentation = LokiChatModelReadinessPresentation(
            readiness: .partiallyCompatible,
            providerName: "Ollama",
            modelName: "Unverified model",
            requiredCapabilitiesMissing: ["toolCalling"],
            recommendedCapabilitiesMissing: ["reasoning"],
            contextWindowSummary: "Below recommended",
            failureMessage: "Required tool calling was not proven."
        )

        XCTAssertFalse(presentation.canSend)
        XCTAssertEqual(presentation.statusTitle, "Missing required capabilities")
        XCTAssertEqual(presentation.modelDisclosure, "Ollama · Unverified model")
    }

    func testModelAuthoredCitationsAreRestrictedToApplicationEvidenceAllowlist() {
        let sanitized = LokiChatController.sanitizedModelCitations(
            "Supported [evidence:allowed] fabricated [evidence:fake] trailing.",
            allowedEvidenceIDs: ["allowed"]
        )

        XCTAssertTrue(sanitized.contains("[evidence:allowed]"))
        XCTAssertFalse(sanitized.contains("[evidence:fake]"))
        XCTAssertTrue(sanitized.contains("fabricated"))
    }
}
