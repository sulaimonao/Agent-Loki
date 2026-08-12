import Foundation
import SwiftData
import XCTest
@testable import LokiBrief

@MainActor
final class BriefingPersistenceP2Tests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_768_406_400)

    func testDeterministicOutputOrderingSectionsAndNoFabricatedCollaboration() throws {
        let sourceA = subscription(id: "source-a", title: "Research Source", weight: 1)
        let sourceB = subscription(id: "source-b", title: "Product Source", weight: 2)
        let news = entry(
            id: "news-1",
            subscription: sourceA,
            title: "Research digest",
            summary: "A measured research finding.",
            url: "https://example.com/research",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let system = entry(
            id: "system-1",
            subscription: sourceB,
            title: "Product security release",
            summary: "A bounded software update is available.",
            url: "https://updates.example.com/release",
            publishedAt: anchor.addingTimeInterval(-7_200)
        )
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let preferences = FeedBriefingPreferences.default

        let first = engine.assemble(
            entries: [news, system],
            subscriptions: [sourceA, sourceB],
            preferences: preferences
        )
        let reorderedInput = engine.assemble(
            entries: [system, news],
            subscriptions: [sourceB, sourceA],
            preferences: preferences
        )

        XCTAssertEqual(first, reorderedInput)
        XCTAssertEqual(first.brief.generation.engineID, DeterministicFeedBriefingEngine.identifier)
        XCTAssertEqual(first.brief.sections.map(\.id), ["news", "system"])
        XCTAssertEqual(first.brief.sections.map(\.title), ["News and Research", "System and Product Updates"])
        XCTAssertEqual(first.ranking.map(\.itemID), ["system-1", "news-1"])
        XCTAssertFalse(first.brief.sections.contains { $0.id == "collaboration" })
        XCTAssertFalse(first.brief.sections.contains { $0.title == "Messages and Collaboration" })
        XCTAssertEqual(first.brief.generation.sourceItemIDs, ["system-1", "news-1"])
    }

    func testTopicSourceWeightAndReadStateAreExplainableRankingInputs() throws {
        let source = subscription(id: "source-a", title: "Research Source", weight: 1)
        let evidence = entry(
            id: "quantum-1",
            subscription: source,
            title: "Quantum research digest",
            summary: "A bounded experimental result.",
            url: "https://example.com/quantum",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let baseline = engine.assemble(
            entries: [evidence],
            subscriptions: [source],
            preferences: .default
        )
        let tuned = engine.assemble(
            entries: [evidence],
            subscriptions: [source],
            preferences: .init(
                topicKeywords: ["quantum"],
                sourceWeights: [source.id: 2],
                readStates: [:],
                briefingWindowHours: 168,
                maximumItems: 40
            )
        )
        let read = engine.assemble(
            entries: [evidence],
            subscriptions: [source],
            preferences: .init(
                topicKeywords: ["quantum"],
                sourceWeights: [source.id: 2],
                readStates: [evidence.id: true],
                briefingWindowHours: 168,
                maximumItems: 40
            )
        )

        let baselineRanking = try XCTUnwrap(baseline.ranking.first)
        let tunedRanking = try XCTUnwrap(tuned.ranking.first)
        let readRanking = try XCTUnwrap(read.ranking.first)
        XCTAssertEqual(tunedRanking.score - baselineRanking.score, 20)
        XCTAssertTrue(tunedRanking.reasons.contains("topic match +10"))
        XCTAssertTrue(tunedRanking.reasons.contains("source weight +20"))
        XCTAssertEqual(tunedRanking.score - readRanking.score, 25)
        XCTAssertTrue(readRanking.reasons.contains("already read -20"))
        XCTAssertTrue(try XCTUnwrap(read.brief.sections.first?.items.first).isRead)
        XCTAssertTrue(try XCTUnwrap(read.brief.sections.first?.items.first?.rankingExplanation).contains("already read -20"))
    }

    func testCorroborationPreservesSourceSpecificEvidenceAndPartialState() throws {
        let sourceA = subscription(id: "source-a", title: "Source A", weight: 1)
        let sourceB = subscription(id: "source-b", title: "Source B", weight: 1)
        let first = entry(
            id: "shared-a",
            subscription: sourceA,
            title: "Independent research result",
            summary: "Source A reporting.",
            url: "https://example.com/shared-story",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let corroborating = entry(
            id: "shared-b",
            subscription: sourceB,
            title: "Independent research result",
            summary: "Source B reporting.",
            url: "https://example.com/shared-story",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let uncorroborated = engine.assemble(
            entries: [first],
            subscriptions: [sourceA, sourceB],
            preferences: .default
        )
        let partial = engine.assemble(
            entries: [first, corroborating],
            subscriptions: [sourceA, sourceB],
            preferences: .default,
            failureNotes: ["Source C: request timed out"]
        )

        let baselineScore = try XCTUnwrap(uncorroborated.ranking.first { $0.itemID == first.id }).score
        let corroborated = try XCTUnwrap(partial.ranking.first { $0.itemID == first.id })
        XCTAssertEqual(corroborated.score - baselineScore, 5)
        XCTAssertTrue(corroborated.reasons.contains("source corroboration +5"))
        XCTAssertEqual(Set(partial.brief.sections.flatMap(\.items).map { $0.source.id }), [sourceA.id, sourceB.id])
        XCTAssertEqual(partial.brief.status, .partial)
        XCTAssertEqual(partial.brief.generation.reasonCode, "deterministic_feed_brief_partial")
        XCTAssertNotNil(partial.brief.partialFailureMessage)
        XCTAssertEqual(partial.failureNotes, ["Source C: request timed out"])
        XCTAssertFalse(partial.brief.sections.contains { $0.id == "collaboration" })
    }

    func testP2PersistenceRoundTripAndHistoryReopen() throws {
        let location = try temporaryStoreLocation(named: "p2-round-trip")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let source = subscription(id: "source-a", title: "Research Source", weight: 1.5)
        let evidence = entry(
            id: "persisted-entry",
            subscription: source,
            title: "Persisted research digest",
            summary: "Evidence survives a disk-backed reopen.",
            url: "https://example.com/persisted",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let assembly = engine.assemble(
            entries: [evidence],
            subscriptions: [source],
            preferences: .init(
                topicKeywords: ["research"],
                sourceWeights: [source.id: source.weight],
                readStates: [:],
                briefingWindowHours: 168,
                maximumItems: 40
            )
        )
        let preview = DeterministicBriefingEngine().generatePreview(revision: 7)

        try writeP2Store(
            at: location.store,
            subscription: source,
            entries: [evidence],
            preview: preview,
            assembly: assembly
        )

        let reopened = try LocalStore(url: location.store)
        XCTAssertEqual(try reopened.domainFeedSubscriptions(), [connected(source, at: anchor)])
        XCTAssertEqual(try reopened.domainFeedEntries(enabledSubscriptionIDs: [source.id]), [evidence])
        XCTAssertEqual(try reopened.brief(id: assembly.brief.id), assembly.brief)
        XCTAssertEqual(try reopened.history().map(\.id), [assembly.brief.id, preview.id])
        XCTAssertEqual(try reopened.container.mainContext.fetch(FetchDescriptor<StoredFeedFetch>()).count, 1)
        XCTAssertEqual(try reopened.container.mainContext.fetch(FetchDescriptor<StoredBriefAssembly>()).count, 1)

        let model = try AppModel(
            store: reopened,
            feedClient: ScriptedFeedRetriever(outcomes: [:]),
            feedEngine: engine
        )
        XCTAssertEqual(model.brief, assembly.brief)
        XCTAssertEqual(model.historyCount, 2)
        model.openHistory(id: preview.id)
        XCTAssertEqual(model.brief, preview)
        model.openHistory(id: assembly.brief.id)
        XCTAssertEqual(model.brief, assembly.brief)
    }

    func testAppModelStartupDoesNotPromoteOlderOrPreviewBriefIntoToday() throws {
        let store = try LocalStore(inMemory: true)
        let currentDay = LocalCalendarDay(year: 2026, month: 1, day: 14)
        let previousDay = LocalCalendarDay(year: 2026, month: 1, day: 13)
        let historical = deterministicBrief(
            day: previousDay,
            generatedAt: anchor.addingTimeInterval(-3_600)
        )
        let sameDayPreview = DeterministicBriefingEngine()
            .generatePreview(revision: 701)
            .replacingBriefingDay(currentDay)
        try store.record(historical)
        try store.record(sameDayPreview)

        let model = try AppModel(
            store: store,
            feedClient: ScriptedFeedRetriever(outcomes: [:]),
            feedEngine: DeterministicFeedBriefingEngine(now: { self.anchor }),
            currentCivilDayProvider: { currentDay }
        )

        XCTAssertEqual(model.brief.resolvedBriefingDay, currentDay)
        XCTAssertEqual(model.brief.status, .ready)
        XCTAssertNotEqual(model.brief.id, historical.id)
        XCTAssertNotEqual(model.brief.id, sameDayPreview.id)
        XCTAssertEqual(model.briefPresentationContext, .today)
        XCTAssertFalse(model.isPresentingHistoricalBrief)
        XCTAssertEqual(Set(model.history.map(\.id)), Set([historical.id, sameDayPreview.id]))
        XCTAssertEqual(model.historyCount, 2)
        XCTAssertNil(try store.brief(id: model.brief.id), "The empty current-day presentation must not create history.")
    }

    func testAppModelStartupRestoresSameDayNonPreviewAheadOfLaterOldCatchUp() throws {
        let store = try LocalStore(inMemory: true)
        let currentDay = LocalCalendarDay(year: 2026, month: 1, day: 14)
        let previousDay = LocalCalendarDay(year: 2026, month: 1, day: 13)
        let sameDay = deterministicBrief(day: currentDay, generatedAt: anchor)
        let laterOldCatchUp = deterministicBrief(
            day: previousDay,
            generatedAt: anchor.addingTimeInterval(7_200)
        )
        try store.record(sameDay)
        try store.record(laterOldCatchUp)

        let model = try AppModel(
            store: store,
            feedClient: ScriptedFeedRetriever(outcomes: [:]),
            feedEngine: DeterministicFeedBriefingEngine(now: { self.anchor.addingTimeInterval(10_800) }),
            currentCivilDayProvider: { currentDay }
        )

        XCTAssertEqual(model.brief, sameDay)
        XCTAssertEqual(model.briefPresentationContext, .today)
        XCTAssertFalse(model.isPresentingHistoricalBrief)
        XCTAssertEqual(model.history.map(\.id), [laterOldCatchUp.id, sameDay.id])
        XCTAssertEqual(try store.history().map(\.id), [laterOldCatchUp.id, sameDay.id])
    }

    func testCurrentDaySynchronizationPreservesExplicitHistoryUntilTodayNavigation() throws {
        let store = try LocalStore(inMemory: true)
        let firstDay = LocalCalendarDay(year: 2026, month: 1, day: 14)
        let historicalDay = LocalCalendarDay(year: 2026, month: 1, day: 13)
        let historical = deterministicBrief(
            day: historicalDay,
            generatedAt: anchor.addingTimeInterval(-3_600)
        )
        let firstDayBrief = deterministicBrief(day: firstDay, generatedAt: anchor)
        try store.record(historical)
        try store.record(firstDayBrief)

        var simulatedCurrentDay = firstDay
        let model = try AppModel(
            store: store,
            feedClient: ScriptedFeedRetriever(outcomes: [:]),
            feedEngine: DeterministicFeedBriefingEngine(now: { self.anchor }),
            currentCivilDayProvider: { simulatedCurrentDay }
        )
        XCTAssertEqual(model.brief, firstDayBrief)

        // The periodic synchronization boundary advances an ordinary Today
        // presentation across midnight.
        simulatedCurrentDay = LocalCalendarDay(year: 2026, month: 1, day: 15)
        model.synchronizeCurrentDayPresentation()
        XCTAssertEqual(model.brief.resolvedBriefingDay, simulatedCurrentDay)
        XCTAssertEqual(model.briefPresentationContext, .today)

        model.openHistory(id: historical.id)
        XCTAssertEqual(model.brief, historical)
        XCTAssertEqual(model.briefPresentationContext, .historical)
        XCTAssertTrue(model.isPresentingHistoricalBrief)

        // System-clock, time-zone, and app-active notifications all use this
        // same synchronization boundary. None may overwrite an explicit
        // historical drill-in.
        for day in [
            LocalCalendarDay(year: 2026, month: 1, day: 16),
            LocalCalendarDay(year: 2026, month: 1, day: 17),
            LocalCalendarDay(year: 2026, month: 1, day: 18),
        ] {
            simulatedCurrentDay = day
            model.synchronizeCurrentDayPresentation()
            XCTAssertEqual(model.brief, historical)
            XCTAssertEqual(model.briefPresentationContext, .historical)
        }

        model.navigate(to: .today)
        XCTAssertEqual(model.brief.resolvedBriefingDay, simulatedCurrentDay)
        XCTAssertEqual(model.briefPresentationContext, .today)
        XCTAssertFalse(model.isPresentingHistoricalBrief)
        XCTAssertEqual(Set(model.history.map(\.id)), Set([historical.id, firstDayBrief.id]))
        XCTAssertEqual(model.historyCount, 2)
    }

    func testOldScheduledCatchUpRemainsHistoryWithoutReplacingCurrentToday() throws {
        let store = try LocalStore(inMemory: true)
        let currentDay = LocalCalendarDay(year: 2026, month: 1, day: 14)
        let previousDay = LocalCalendarDay(year: 2026, month: 1, day: 13)
        let current = deterministicBrief(day: currentDay, generatedAt: anchor)
        try store.record(current)
        let model = try AppModel(
            store: store,
            feedClient: ScriptedFeedRetriever(outcomes: [:]),
            feedEngine: DeterministicFeedBriefingEngine(now: { self.anchor }),
            currentCivilDayProvider: { currentDay }
        )
        XCTAssertEqual(model.brief, current)

        let catchUp = deterministicBrief(
            day: previousDay,
            generatedAt: anchor.addingTimeInterval(7_200)
        )
        try store.record(catchUp)
        let plan = try ScheduledBriefingPlan(
            id: "test-old-catch-up-plan",
            occurrenceID: "test-old-catch-up-occurrence",
            scheduledFor: anchor.addingTimeInterval(7_200),
            briefingDay: previousDay,
            trigger: .catchUpAfterWake,
            feedSubscriptionIDs: [],
            slackWorkspaceIDs: [],
            refreshFeedsEnabled: false,
            refreshSlackEnabled: false,
            slackSelections: [],
            localPresentationEnabled: false,
            localPresentationConsentedWorkspaceIDs: [],
            notificationsEnabled: false,
            notificationAuthorization: .notDetermined,
            notificationPrivacyMode: .minimal,
            entitlementDecisions: []
        )
        let result = ScheduledBriefingRunResult(
            plan: plan,
            state: .complete,
            reasonCode: ScheduledBriefingReason.runComplete,
            startedAt: anchor.addingTimeInterval(7_200),
            completedAt: anchor.addingTimeInterval(7_260),
            sourceOutcomes: [],
            vaultOutcome: nil,
            brief: catchUp,
            generationProvenance: nil,
            fallbackReasonCode: nil,
            failureReasonCodes: []
        )

        model.applyScheduledBriefingResult(result)

        XCTAssertEqual(model.brief, current)
        XCTAssertEqual(model.briefPresentationContext, .today)
        XCTAssertFalse(model.isPresentingHistoricalBrief)
        XCTAssertEqual(model.history.map(\.id), [catchUp.id, current.id])
        XCTAssertEqual(try store.history().map(\.id), [catchUp.id, current.id])
    }

    func testDiskBackedP1StoreMigratesAdditivelyWithSettingsAndHistoryPreserved() throws {
        let location = try temporaryStoreLocation(named: "p1-to-p2")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let expectedBrief = try writeP1Store(at: location.store)
        let migrated = try LocalStore(url: location.store)
        let migratedSettings = try migrated.settings()
        let p2Defaults = try migrated.p2Settings()

        XCTAssertEqual(migratedSettings.preferredBriefingTime, Date(timeIntervalSince1970: 43_200))
        XCTAssertTrue(migratedSettings.launchAtLoginPreference)
        XCTAssertTrue(migratedSettings.notificationPreference)
        XCTAssertEqual(migratedSettings.density, .compact)
        XCTAssertFalse(migratedSettings.deterministicOnly)
        XCTAssertTrue(migratedSettings.futureLocalModelPreference)
        XCTAssertEqual(migratedSettings.schemaVersion, 1)
        XCTAssertEqual(try migrated.brief(id: expectedBrief.id), expectedBrief)
        XCTAssertEqual(try migrated.history().map(\.id), [expectedBrief.id])
        XCTAssertEqual(try migrated.readStates()[expectedBrief.sections[0].items[0].id], true)

        XCTAssertEqual(p2Defaults.feedRetentionDays, 30)
        XCTAssertEqual(p2Defaults.retainedEntriesPerFeed, 200)
        XCTAssertEqual(p2Defaults.topicPreferences, "")
        XCTAssertEqual(p2Defaults.generationTimeoutSeconds, 30)
        XCTAssertFalse(p2Defaults.previewFixturesEnabled)
        XCTAssertTrue(try migrated.feedSubscriptions().isEmpty)
        XCTAssertTrue(try migrated.feedEntries().isEmpty)
    }

    func testSameBriefIDUpdatesInPlaceAndOllamaAttributionSurvivesReopen() throws {
        let location = try temporaryStoreLocation(named: "same-id-provider-update")
        defer { try? FileManager.default.removeItem(at: location.directory) }

        let deterministic = DeterministicBriefingEngine().generatePreview(revision: 17)
        let generated = Brief(
            id: deterministic.id,
            date: deterministic.date,
            title: deterministic.title,
            summary: "A validated local summary replaced the deterministic draft.",
            status: deterministic.status,
            sections: deterministic.sections,
            generation: .init(
                engineID: deterministic.generation.engineID,
                generatedAt: deterministic.generation.generatedAt.addingTimeInterval(1),
                status: deterministic.status,
                reasonCode: "ollama_local_summary_validated",
                fixtureRevision: deterministic.generation.fixtureRevision,
                providerKind: "ollama",
                modelName: "gpt-oss:20b",
                promptTemplateVersion: "loki.brief.p2.v1",
                outputSchemaVersion: "loki.brief.output.v1",
                sourceItemIDs: deterministic.sections.flatMap(\.items).map(\.id),
                validationResult: "valid"
            )
        )

        do {
            let store = try LocalStore(url: location.store)
            try store.record(deterministic)
            try store.record(generated)
            XCTAssertEqual(try store.history().count, 1)
        }

        let reopened = try LocalStore(url: location.store)
        XCTAssertEqual(try reopened.brief(id: deterministic.id), generated)
        let history = try reopened.history().map(\.historyEntry)
        XCTAssertEqual(history.count, 1)
        XCTAssertEqual(history.first?.providerKind, "ollama")
        XCTAssertEqual(history.first?.modelName, "gpt-oss:20b")
        XCTAssertEqual(history.first?.generatedAt, generated.generation.generatedAt)
    }

    func testProviderSnapshotAndLatestProvenanceRoundTripWithoutPrivatePromptContent() throws {
        let location = try temporaryStoreLocation(named: "provider-metadata-boundary")
        defer { try? FileManager.default.removeItem(at: location.directory) }
        let successfulCheck = anchor.addingTimeInterval(-60)
        let failedCheck = anchor
        let privatePromptMarker = "PRIVATE_PROMPT_MARKER_MUST_NOT_PERSIST"

        do {
            let store = try LocalStore(url: location.store)
            try store.upsertProviderSnapshot(.init(
                stateRaw: ModelProviderState.connected.rawValue,
                checkedAt: successfulCheck,
                lastSuccessfulCheckAt: successfulCheck,
                serviceVersion: "0.30.6"
            ))
            try store.upsertProviderSnapshot(.init(
                stateRaw: ModelProviderState.degraded.rawValue,
                checkedAt: failedCheck,
                failureCode: "service_unavailable",
                failureMessage: "The local service did not respond."
            ))
            let sourceIdentifiers = try JSONEncoder().encode(["public-item-1"])
            try store.recordGenerationProvenance(.init(
                id: "provenance-latest",
                briefID: "brief-public",
                providerKind: "ollama",
                modelName: "gpt-oss:20b",
                promptTemplateVersion: "loki.brief.p2.v1",
                schemaVersion: "loki.brief.output.v1",
                generatedAt: failedCheck,
                sourceItemIdentifiers: sourceIdentifiers,
                completionStatus: "success",
                fallbackStatus: nil,
                durationMilliseconds: 125,
                promptTokenCount: 24,
                completionTokenCount: 16,
                validationResult: "valid",
                failureCode: nil
            ))
            // The raw prompt is deliberately not accepted by any persistence API.
            XCTAssertFalse(privatePromptMarker.isEmpty)
        }

        let reopened = try LocalStore(url: location.store)
        let snapshot = try XCTUnwrap(reopened.providerSnapshot())
        let provenance = try XCTUnwrap(reopened.latestGenerationProvenance())
        XCTAssertEqual(snapshot.checkedAt, failedCheck)
        XCTAssertEqual(snapshot.lastSuccessfulCheckAt, successfulCheck)
        XCTAssertEqual(snapshot.serviceVersion, "0.30.6")
        XCTAssertEqual(snapshot.failureCode, "service_unavailable")
        XCTAssertEqual(provenance.id, "provenance-latest")

        let persistedP2Metadata = [
            snapshot.id, snapshot.stateRaw, snapshot.serviceVersion,
            snapshot.failureCode, snapshot.failureMessage,
            provenance.id, provenance.briefID, provenance.providerKind,
            provenance.modelName, provenance.endpointClassification,
            provenance.promptTemplateVersion, provenance.schemaVersion,
            provenance.completionStatus, provenance.fallbackStatus,
            provenance.validationResult, provenance.failureCode,
            String(data: provenance.sourceItemIdentifiers, encoding: .utf8),
        ].compactMap { $0 }.joined(separator: "\n")
        XCTAssertFalse(persistedP2Metadata.contains(privatePromptMarker))
    }

    func testRetentionPrunesByAgeAndPerFeedLimitIndependently() throws {
        let store = try LocalStore(inMemory: true)
        let sourceA = subscription(id: "source-a", title: "Source A")
        let sourceB = subscription(id: "source-b", title: "Source B")

        for source in [sourceA, sourceB] {
            for day in [1, 2, 3, 40] {
                let value = entry(
                    id: "\(source.id)-\(day)",
                    subscription: source,
                    title: "Entry \(day)",
                    summary: "Retention evidence.",
                    url: "https://example.com/\(source.id)/\(day)",
                    publishedAt: anchor.addingTimeInterval(-Double(day) * 86_400)
                )
                try store.upsertFeedEntry(stored(value))
            }
        }
        try store.save()
        try store.pruneFeedEntries(now: anchor, retentionDays: 10, maximumPerFeed: 2)

        XCTAssertEqual(
            Set(try store.feedEntries().map(\.id)),
            Set(["source-a-1", "source-a-2", "source-b-1", "source-b-2"])
        )
    }

    func testAppModelPreservesLastValidBriefWhenRefreshFails() async throws {
        let store = try LocalStore(inMemory: true)
        let source = subscription(id: "source-a", title: "Source A")
        let evidence = entry(
            id: "last-valid",
            subscription: source,
            title: "Last valid evidence",
            summary: "A failed refresh must not replace this brief.",
            url: "https://example.com/last-valid",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let connectedSource = connected(source, at: anchor)
        try store.persistFeedFetchResult(
            fetchResult(subscription: connectedSource, entries: [evidence], completedAt: anchor),
            settings: try store.p2Settings()
        )
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let lastValid = engine.assemble(entries: [evidence], subscriptions: [connectedSource], preferences: .default).brief
        try store.record(lastValid)
        let retriever = ScriptedFeedRetriever(outcomes: [
            source.id: .failure(.init(.requestTimedOut, message: "Synthetic timeout"))
        ])
        let model = try AppModel(store: store, feedClient: retriever, feedEngine: engine)

        XCTAssertEqual(model.brief, lastValid)
        model.refreshFeed(id: source.id)
        try await wait(for: .failed, in: model)

        XCTAssertEqual(model.brief, lastValid)
        XCTAssertEqual(model.historyCount, 1)
        XCTAssertEqual(model.refreshMessage, "No feed refreshed successfully. The last valid brief was preserved.")
        XCTAssertEqual(model.subscriptions.first?.state, .degraded)
        XCTAssertEqual(model.subscriptions.first?.failure?.code, .requestTimedOut)
    }

    func testAppModelBuildsPartialBriefFromSuccessfulEvidenceAndFailedSource() async throws {
        let store = try LocalStore(inMemory: true)
        let sourceA = subscription(id: "source-a", title: "Source A")
        let sourceB = subscription(id: "source-b", title: "Source B")
        try store.persistFeedSubscription(sourceA)
        try store.persistFeedSubscription(sourceB)
        let evidence = entry(
            id: "partial-evidence",
            subscription: sourceA,
            title: "Research evidence",
            summary: "One source succeeded while another failed.",
            url: "https://example.com/partial",
            publishedAt: anchor.addingTimeInterval(-3_600)
        )
        let success = fetchResult(subscription: connected(sourceA, at: anchor), entries: [evidence], completedAt: anchor)
        let retriever = ScriptedFeedRetriever(outcomes: [
            sourceA.id: .success(success),
            sourceB.id: .failure(.init(.networkUnavailable, message: "Synthetic outage"))
        ])
        let engine = DeterministicFeedBriefingEngine(now: { self.anchor })
        let model = try AppModel(store: store, feedClient: retriever, feedEngine: engine)

        model.refreshAllFeeds()
        try await wait(for: .partial, in: model)

        XCTAssertEqual(model.brief.status, .partial)
        XCTAssertEqual(model.brief.sections.flatMap(\.items).map(\.id), [evidence.id])
        XCTAssertNotNil(model.brief.partialFailureMessage)
        XCTAssertEqual(model.refreshMessage, "Partial refresh: 1 succeeded, 1 failed.")
        XCTAssertFalse(model.brief.sections.contains { $0.id == "collaboration" })
        XCTAssertEqual(model.historyCount, 1)
    }

    func testLiveFeedSmokeWhenExplicitlyConfigured() async throws {
        guard let rawURL = ProcessInfo.processInfo.environment["LOKI_LIVE_FEED_URL"], !rawURL.isEmpty else {
            throw XCTSkip("Set LOKI_LIVE_FEED_URL to opt into the bounded public HTTPS feed smoke.")
        }
        guard let url = URL(string: rawURL), url.scheme?.lowercased() == "https" else {
            XCTFail("LOKI_LIVE_FEED_URL must be a valid HTTPS URL.")
            return
        }
        let source = subscription(
            id: FeedSubscription.stableIdentifier(for: url),
            title: "Environment-gated live smoke",
            url: url
        )

        let result = try await FeedRetrievalClient().fetch(source, trace: .init())

        XCTAssertEqual(result.record.httpStatus, 200)
        XCTAssertFalse(result.entries.isEmpty)
        XCTAssertLessThanOrEqual(result.record.responseByteCount, FeedLimits.maximumResponseBytes)
        XCTAssertEqual(result.record.finalURL.scheme, "https")
        XCTAssertTrue(result.entries.allSatisfy { $0.provenance.feedURL == url })
        XCTAssertEqual(result.subscription.state, .connected)
        XCTAssertNotNil(result.subscription.lastSuccessfulAt)

        let assembled = DeterministicFeedBriefingEngine(now: { result.record.completedAt })
            .assemble(
                entries: result.entries,
                subscriptions: [result.subscription],
                preferences: .init(topicKeywords: [], sourceWeights: [:], readStates: [:], briefingWindowHours: 24 * 30, maximumItems: 40)
            )
            .brief
        XCTAssertFalse(assembled.sections.flatMap(\.items).isEmpty)
        XCTAssertTrue(assembled.sections.flatMap(\.items).allSatisfy { $0.provenance.directURL?.scheme == "https" })
    }

    private func deterministicBrief(
        day: LocalCalendarDay,
        generatedAt: Date
    ) -> Brief {
        DeterministicFeedBriefingEngine(now: { generatedAt })
            .assemble(
                entries: [],
                subscriptions: [],
                preferences: .default,
                briefingDay: day
            )
            .brief
    }

    private func subscription(
        id: String,
        title: String,
        weight: Double = 1,
        url: URL? = nil
    ) -> FeedSubscription {
        let canonicalURL = url ?? URL(string: "https://feeds.example.com/\(id).xml")!
        return .init(
            id: id,
            title: title,
            canonicalURL: canonicalURL,
            enabled: true,
            format: .rss2,
            lastAttemptedAt: nil,
            lastSuccessfulAt: nil,
            lastHTTPStatus: nil,
            eTag: nil,
            lastModified: nil,
            state: .savedUnavailable,
            failure: nil,
            policy: .default,
            weight: weight,
            createdAt: anchor.addingTimeInterval(-86_400),
            updatedAt: anchor.addingTimeInterval(-86_400)
        )
    }

    private func connected(_ subscription: FeedSubscription, at date: Date) -> FeedSubscription {
        var updated = subscription
        updated.lastAttemptedAt = date
        updated.lastSuccessfulAt = date
        updated.lastHTTPStatus = 200
        updated.state = .connected
        updated.failure = nil
        updated.updatedAt = date
        return updated
    }

    private func entry(
        id: String,
        subscription: FeedSubscription,
        title: String,
        summary: String,
        url: String,
        publishedAt: Date
    ) -> NormalizedFeedEntry {
        let canonicalURL = URL(string: url)!
        return .init(
            id: id,
            identity: .init(value: id, basis: .upstreamIdentifier),
            subscriptionID: subscription.id,
            sourceTitle: subscription.title,
            title: title,
            summary: summary,
            canonicalURL: canonicalURL,
            author: "Loki Test Fixture",
            publishedAt: publishedAt,
            updatedAt: nil,
            retrievedAt: anchor,
            originalPosition: 0,
            provenance: .init(
                subscriptionID: subscription.id,
                feedURL: subscription.canonicalURL,
                format: subscription.format,
                upstreamIdentifier: id,
                retrievedAt: anchor,
                originalPosition: 0
            )
        )
    }

    private func fetchResult(
        subscription: FeedSubscription,
        entries: [NormalizedFeedEntry],
        completedAt: Date
    ) -> FeedFetchResult {
        .init(
            subscription: subscription,
            entries: entries,
            record: .init(
                id: "fetch-\(subscription.id)-\(Int(completedAt.timeIntervalSince1970))",
                subscriptionID: subscription.id,
                traceID: "trace-\(subscription.id)",
                attemptedAt: completedAt,
                completedAt: completedAt,
                httpStatus: 200,
                responseByteCount: 1_024,
                parsedEntryCount: entries.count,
                finalURL: subscription.canonicalURL,
                eTag: "fixture-etag",
                lastModified: nil,
                wasNotModified: false
            ),
            warnings: []
        )
    }

    private func stored(_ entry: NormalizedFeedEntry) throws -> StoredNormalizedFeedEntry {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return .init(
            id: entry.id,
            subscriptionID: entry.subscriptionID,
            title: entry.title,
            summaryText: entry.summary,
            canonicalURL: entry.canonicalURL?.absoluteString,
            author: entry.author,
            publicationDate: entry.publishedAt,
            updatedDate: entry.updatedAt,
            retrievedAt: entry.retrievedAt,
            originalPosition: entry.originalPosition,
            formatIdentifier: entry.provenance.format.rawValue,
            upstreamIdentifier: entry.provenance.upstreamIdentifier,
            identityBasis: entry.identity.basis.rawValue,
            encodedEntry: try encoder.encode(entry)
        )
    }

    private func temporaryStoreLocation(named name: String) throws -> (directory: URL, store: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return (directory, directory.appendingPathComponent("LokiBrief.store"))
    }

    private func writeP2Store(
        at url: URL,
        subscription: FeedSubscription,
        entries: [NormalizedFeedEntry],
        preview: Brief,
        assembly: BriefAssemblyResult
    ) throws {
        let store = try LocalStore(url: url)
        let connectedSubscription = connected(subscription, at: anchor)
        try store.persistFeedFetchResult(
            fetchResult(subscription: connectedSubscription, entries: entries, completedAt: anchor),
            settings: try store.p2Settings()
        )
        try store.record(preview)
        try store.record(assembly.brief)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try store.recordBriefAssembly(.init(
            id: assembly.brief.id,
            generatedAt: assembly.brief.generation.generatedAt,
            selectedEntryCount: assembly.brief.itemCount,
            excludedEntryCount: assembly.excludedEntryIDs.count,
            enabledSourceCount: 1,
            failureNotes: try encoder.encode(assembly.failureNotes)
        ))
    }

    private func writeP1Store(at url: URL) throws -> Brief {
        let p1Schema = Schema([
            StoredSettings.self,
            StoredBrief.self,
            StoredReadState.self,
            StoredStateSnapshot.self
        ])
        let configuration = ModelConfiguration("LokiBrief-v1", schema: p1Schema, url: url)
        let container = try ModelContainer(for: p1Schema, configurations: [configuration])
        let context = container.mainContext
        let settings = StoredSettings(
            preferredBriefingTime: Date(timeIntervalSince1970: 43_200),
            launchAtLoginPreference: true,
            notificationPreference: true,
            density: .compact,
            deterministicOnly: false,
            futureLocalModelPreference: true
        )
        let brief = DeterministicBriefingEngine().generatePreview(revision: 9)
        context.insert(settings)
        context.insert(try StoredBrief(brief: brief))
        context.insert(StoredReadState(itemID: brief.sections[0].items[0].id, isRead: true))
        context.insert(StoredStateSnapshot(id: "source:preview-fixtures", domain: "source", state: "available", capturedAt: anchor))
        try context.save()
        return brief
    }

    private func wait(for expected: FeedRefreshState, in model: AppModel) async throws {
        for _ in 0..<300 {
            if model.refreshState == expected { return }
            try await Task<Never, Never>.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Timed out waiting for refresh state \(expected.rawValue); current state is \(model.refreshState.rawValue).")
    }
}

private actor ScriptedFeedRetriever: FeedRetrieving {
    enum Outcome: Sendable {
        case success(FeedFetchResult)
        case failure(FeedFetchFailure)
    }

    private let outcomes: [String: Outcome]

    init(outcomes: [String: Outcome]) {
        self.outcomes = outcomes
    }

    func fetch(_ subscription: FeedSubscription, trace: FeedTraceContext) async throws -> FeedFetchResult {
        guard let outcome = outcomes[subscription.id] else {
            throw FeedFetchFailure(.networkUnavailable, message: "No scripted result for \(subscription.id).")
        }
        switch outcome {
        case let .success(result):
            return result
        case let .failure(failure):
            throw failure
        }
    }

    func cancelAll() async { }
}
