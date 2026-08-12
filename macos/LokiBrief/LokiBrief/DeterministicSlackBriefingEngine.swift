import CryptoKit
import Foundation

struct SlackBriefingPreferences: Codable, Hashable, Sendable {
    var readStates: [String: Bool]
    var briefingWindowHours: Int
    var maximumItems: Int
    var urgencyTerms: [String]

    static let `default` = SlackBriefingPreferences(
        readStates: [:],
        briefingWindowHours: 168,
        maximumItems: 40,
        urgencyTerms: ["urgent", "critical", "action required", "immediate action", "emergency"]
    )
}

struct SlackRankingExplanation: Codable, Hashable, Sendable {
    let itemID: String
    let score: Int
    let reasons: [String]
    let sectionID: String
    let priorityReasonCode: String
}

struct SlackBriefAssemblyResult: Codable, Hashable, Sendable {
    let brief: Brief
    let ranking: [SlackRankingExplanation]
    let excludedEvidenceIDs: [String]
    let failureNotes: [String]
    let selectedRevisionKeys: [String]
}

struct MixedBriefAssemblyResult: Codable, Hashable, Sendable {
    let brief: Brief
    let feedRanking: [FeedRankingExplanation]
    let slackRanking: [SlackRankingExplanation]
    let excludedItemIDs: [String]
    let failureNotes: [String]
    let slackAssembly: SlackBriefAssemblyResult?
}

struct DeterministicSlackBriefingEngine: Sendable {
    static let identifier = "loki.deterministic.slack.v1"

    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let timeZone: @Sendable () -> TimeZone
    private let eventSink: TraceSink?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent },
        eventSink: TraceSink? = nil
    ) {
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
        self.eventSink = eventSink
    }

    func assemble(
        evidence: [SlackMessageEvidence],
        preferences: SlackBriefingPreferences,
        failureNotes: [String] = [],
        trace: SlackTraceContext = .init(),
        briefingDay requestedBriefingDay: LocalCalendarDay? = nil
    ) -> SlackBriefAssemblyResult {
        let generatedAt = now()
        let resolutionCalendar = calendar()
        let resolutionTimeZone = timeZone()
        let briefingDay = requestedBriefingDay ?? LocalCalendarDay.resolve(
            containing: generatedAt,
            calendar: resolutionCalendar,
            timeZone: resolutionTimeZone
        )
        emit(
            trace: trace,
            at: generatedAt,
            status: .started,
            reasonCode: "slack_deterministic_assembly_started",
            metadata: .init([(.normalizedCount, String(evidence.count))])
        )

        let windowHours = min(max(preferences.briefingWindowHours, 1), 24 * 30)
        let cutoff = generatedAt.addingTimeInterval(-Double(windowHours) * 3_600)
        let futureTolerance = generatedAt.addingTimeInterval(300)
        let deduplicated = deduplicate(evidence)
        var excluded = Set(evidence.map(\.id)).subtracting(deduplicated.map(\.id))
        var ranked: [(evidence: SlackMessageEvidence, explanation: SlackRankingExplanation)] = []

        for message in deduplicated {
            guard message.state == .available,
                  message.selectedChannelWeight.isFinite,
                  message.messageTimestamp.date >= cutoff,
                  message.messageTimestamp.date <= futureTolerance,
                  !message.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                excluded.insert(message.id)
                continue
            }
            ranked.append((message, rank(message, generatedAt: generatedAt, preferences: preferences)))
        }

        ranked.sort(by: deterministicRankOrder)
        let maximumItems = min(max(preferences.maximumItems, 1), 40)
        if ranked.count > maximumItems {
            excluded.formUnion(ranked.dropFirst(maximumItems).map(\.evidence.id))
            ranked = Array(ranked.prefix(maximumItems))
        }

        let grouped = Dictionary(grouping: ranked, by: { $0.explanation.sectionID })
        let sections = [
            makeSection(id: "attention", title: "Needs Attention", ranked: grouped["attention"] ?? [], preferences: preferences),
            makeSection(id: "collaboration", title: "Messages and Collaboration", ranked: grouped["collaboration"] ?? [], preferences: preferences),
        ].filter { !$0.items.isEmpty }
        let selectedRevisionKeys = ranked.map { revisionKey(for: $0.evidence) }
        let selectedIDs = ranked.map(\.evidence.id)
        let status: BriefStatus = failureNotes.isEmpty ? .ready : .partial
        let sourceCount = Set(ranked.map { "\($0.evidence.workspaceID):\($0.evidence.channelID)" }).count
        let summary = ranked.isEmpty
            ? "No retained Slack messages matched the current deterministic briefing window."
            : "\(ranked.count) attributable Slack message\(ranked.count == 1 ? "" : "s") from \(sourceCount) selected channel\(sourceCount == 1 ? "" : "s"), ordered by deterministic rules."
        let brief = Brief(
            id: stableBriefIdentifier(
                briefingDay: briefingDay,
                selectedRevisionKeys: selectedRevisionKeys,
                preferences: preferences,
                failures: failureNotes
            ),
            date: briefingDay.referenceDate(calendar: resolutionCalendar, timeZone: resolutionTimeZone) ?? generatedAt,
            title: "Loki Brief · \(briefingDay.storageValue)",
            summary: summary,
            status: status,
            sections: sections,
            generation: .init(
                engineID: Self.identifier,
                generatedAt: generatedAt,
                status: status,
                reasonCode: failureNotes.isEmpty ? "deterministic_slack_brief_assembled" : "deterministic_slack_brief_partial",
                fixtureRevision: 0,
                providerKind: "deterministic",
                sourceItemIDs: selectedIDs,
                validationResult: "not_applicable"
            ),
            partialFailureMessage: failureNotes.isEmpty
                ? nil
                : "\(failureNotes.count) Slack channel refresh\(failureNotes.count == 1 ? "" : "es") failed; retained attributable evidence remains available.",
            briefingDay: briefingDay
        )
        emit(
            trace: trace,
            at: generatedAt,
            status: failureNotes.isEmpty ? .success : .degraded,
            reasonCode: failureNotes.isEmpty ? "slack_deterministic_assembly_succeeded" : "slack_deterministic_assembly_partial",
            metadata: .init([
                (.normalizedCount, String(ranked.count)),
                (.skippedCount, String(excluded.count)),
                (.failureCount, String(failureNotes.count)),
                (.directMentionCount, String(ranked.filter(\.evidence.directlyMentionsAuthenticatedUser).count)),
            ])
        )
        return .init(
            brief: brief,
            ranking: ranked.map(\.explanation),
            excludedEvidenceIDs: excluded.sorted(),
            failureNotes: failureNotes,
            selectedRevisionKeys: selectedRevisionKeys
        )
    }

    private func deduplicate(_ evidence: [SlackMessageEvidence]) -> [SlackMessageEvidence] {
        var retained: [String: SlackMessageEvidence] = [:]
        for candidate in evidence {
            guard let current = retained[candidate.deduplicationKey] else {
                retained[candidate.deduplicationKey] = candidate
                continue
            }
            retained[candidate.deduplicationKey] = preferred(candidate, over: current) ? candidate : current
        }
        return retained.values.sorted {
            if $0.workspaceID != $1.workspaceID { return $0.workspaceID < $1.workspaceID }
            if $0.channelID != $1.channelID { return $0.channelID < $1.channelID }
            return $0.messageTimestamp < $1.messageTimestamp
        }
    }

    private func preferred(_ candidate: SlackMessageEvidence, over current: SlackMessageEvidence) -> Bool {
        let stateOrder: [SlackMessageEvidenceState: Int] = [.available: 0, .inaccessible: 1, .deleted: 2]
        if stateOrder[candidate.state, default: 0] != stateOrder[current.state, default: 0] {
            return stateOrder[candidate.state, default: 0] > stateOrder[current.state, default: 0]
        }
        let candidateRevision = candidate.editedAt ?? candidate.messageTimestamp
        let currentRevision = current.editedAt ?? current.messageTimestamp
        if candidateRevision != currentRevision { return candidateRevision > currentRevision }
        if candidate.retrievedAt != current.retrievedAt { return candidate.retrievedAt > current.retrievedAt }
        if candidate.excerpt != current.excerpt { return candidate.excerpt < current.excerpt }
        return candidate.id < current.id
    }

    private func rank(
        _ evidence: SlackMessageEvidence,
        generatedAt: Date,
        preferences: SlackBriefingPreferences
    ) -> SlackRankingExplanation {
        var score = 0
        var reasons: [String] = []
        let ageHours = max(0, generatedAt.timeIntervalSince(evidence.messageTimestamp.date) / 3_600)
        let recency: Int
        switch ageHours {
        case 0..<6: recency = 40
        case 6..<24: recency = 30
        case 24..<72: recency = 20
        default: recency = 10
        }
        score += recency
        reasons.append("recency +\(recency)")

        let weight = min(max(evidence.selectedChannelWeight, 0.5), 2)
        let weightPoints = Int((weight * 10).rounded())
        score += weightPoints
        reasons.append("selected channel weight +\(weightPoints)")

        let urgency = matchedUrgencyTerm(in: evidence.excerpt, configuredTerms: preferences.urgencyTerms)
        let sectionID: String
        let priorityReasonCode: String
        if evidence.directlyMentionsAuthenticatedUser {
            score += 30
            reasons.append("direct mention +30")
            sectionID = "attention"
            priorityReasonCode = "slack_direct_mention"
        } else if weight >= 1.5, urgency != nil {
            score += 20
            reasons.append("weighted urgency phrase +20")
            sectionID = "attention"
            priorityReasonCode = "slack_weighted_urgency"
        } else {
            sectionID = "collaboration"
            priorityReasonCode = "slack_collaboration_default"
        }

        if evidence.replyCount > 0 {
            let points = min(10, evidence.replyCount * 2)
            score += points
            reasons.append("thread activity +\(points)")
        }
        if preferences.readStates[evidence.id] == true {
            score -= 20
            reasons.append("already read -20")
        } else {
            score += 5
            reasons.append("unread +5")
        }
        return .init(
            itemID: evidence.id,
            score: score,
            reasons: reasons,
            sectionID: sectionID,
            priorityReasonCode: priorityReasonCode
        )
    }

    private func matchedUrgencyTerm(in text: String, configuredTerms: [String]) -> String? {
        let normalizedText = normalizedWords(text)
        let bounded = " \(normalizedText) "
        return configuredTerms
            .map(normalizedWords)
            .filter { !$0.isEmpty && $0.count <= 80 }
            .sorted()
            .first { bounded.contains(" \($0) ") }
    }

    private func normalizedWords(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        var result = ""
        var previousWasSeparator = true
        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                result.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                result.append(" ")
                previousWasSeparator = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    private func deterministicRankOrder(
        _ lhs: (evidence: SlackMessageEvidence, explanation: SlackRankingExplanation),
        _ rhs: (evidence: SlackMessageEvidence, explanation: SlackRankingExplanation)
    ) -> Bool {
        if lhs.explanation.score != rhs.explanation.score { return lhs.explanation.score > rhs.explanation.score }
        if lhs.evidence.messageTimestamp != rhs.evidence.messageTimestamp {
            return lhs.evidence.messageTimestamp > rhs.evidence.messageTimestamp
        }
        let leftTitle = stableComparisonText("\(lhs.evidence.author.displayName) \(lhs.evidence.channelName)")
        let rightTitle = stableComparisonText("\(rhs.evidence.author.displayName) \(rhs.evidence.channelName)")
        if leftTitle != rightTitle { return leftTitle < rightTitle }
        return lhs.evidence.id < rhs.evidence.id
    }

    private func makeSection(
        id: String,
        title: String,
        ranked: [(evidence: SlackMessageEvidence, explanation: SlackRankingExplanation)],
        preferences: SlackBriefingPreferences
    ) -> BriefSection {
        let items = ranked.map { value -> BriefItem in
            let evidence = value.evidence
            let sourceID = "slack:\(evidence.workspaceID):\(evidence.channelID)"
            let source = BriefSource(
                id: sourceID,
                name: "#\(evidence.channelName)",
                kind: .slack,
                state: .connected,
                capabilities: [.messages],
                detail: "Read-only evidence from an explicitly selected Slack channel."
            )
            return BriefItem(
                id: evidence.id,
                title: "\(evidence.author.displayName) in #\(evidence.channelName)",
                summary: evidence.excerpt,
                priority: priority(for: value.explanation.score),
                source: source,
                provenance: .init(
                    sourceID: sourceID,
                    publicationDate: evidence.messageTimestamp.date,
                    retrievedAt: evidence.retrievedAt,
                    directURL: evidence.permalink,
                    isSynthetic: false,
                    origin: .source,
                    format: "slack.message",
                    upstreamIdentifier: evidence.messageTimestamp.rawValue
                ),
                isRead: preferences.readStates[evidence.id] ?? false,
                rankingExplanation: "Score \(value.explanation.score): \(value.explanation.reasons.joined(separator: ", ")).",
                slackAttribution: .init(
                    workspaceID: evidence.workspaceID,
                    workspaceName: evidence.workspaceName,
                    channelID: evidence.channelID,
                    channelName: evidence.channelName,
                    authorName: evidence.author.displayName,
                    messageTimestamp: evidence.messageTimestamp.date,
                    priorityReasonCode: value.explanation.priorityReasonCode,
                    locallyGenerated: false
                )
            )
        }
        return .init(
            id: id,
            title: title,
            items: items,
            summary: "\(items.count) deterministically selected Slack message\(items.count == 1 ? "" : "s")."
        )
    }

    private func priority(for score: Int) -> BriefPriority {
        switch score {
        case 85...: .urgent
        case 65...: .high
        case 35...: .normal
        default: .low
        }
    }

    private func revisionKey(for evidence: SlackMessageEvidence) -> String {
        let excerptDigest = SHA256.hash(data: Data(evidence.excerpt.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(evidence.id):\(evidence.messageTimestamp.rawValue):\(evidence.editedAt?.rawValue ?? "original"):\(excerptDigest)"
    }

    private func stableBriefIdentifier(
        briefingDay: LocalCalendarDay,
        selectedRevisionKeys: [String],
        preferences: SlackBriefingPreferences,
        failures: [String]
    ) -> String {
        let reads = preferences.readStates.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let urgency = preferences.urgencyTerms.map(normalizedWords).filter { !$0.isEmpty }.sorted().joined(separator: "|")
        let material = "\(briefingDay.storageValue)\u{1f}\(selectedRevisionKeys.joined(separator: "|"))\u{1f}\(reads)\u{1f}\(preferences.briefingWindowHours)\u{1f}\(preferences.maximumItems)\u{1f}\(urgency)\u{1f}\(failures.sorted().joined(separator: "|"))"
        return "slack-brief-\(digest(material))"
    }

    private func digest(_ material: String) -> String {
        SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func stableComparisonText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }

    private func emit(
        trace: SlackTraceContext,
        at timestamp: Date,
        status: SlackTraceStatus,
        reasonCode: String,
        metadata: SlackTraceMetadata
    ) {
        eventSink?(.init(
            ts: timestamp,
            event: .deterministicAssembly,
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            component: "slack_briefing_engine",
            status: status,
            reasonCode: reasonCode,
            durationMilliseconds: nil,
            metadata: metadata
        ))
    }
}

struct DeterministicMixedBriefingEngine: Sendable {
    static let identifier = "loki.deterministic.mixed.v1"
    static let orderedSections = ["attention", "collaboration", "news", "system"]

    private let slackEngine: DeterministicSlackBriefingEngine

    init(slackEngine: DeterministicSlackBriefingEngine = .init()) {
        self.slackEngine = slackEngine
    }

    func assemble(
        feedResult: BriefAssemblyResult,
        slackEvidence: [SlackMessageEvidence],
        slackPreferences: SlackBriefingPreferences,
        slackFailureNotes: [String] = [],
        maximumItems: Int = 40,
        trace: SlackTraceContext = .init()
    ) -> MixedBriefAssemblyResult {
        let hasAvailableSlackEvidence = slackEvidence.contains {
            $0.state == .available && $0.selectedChannelWeight.isFinite && !$0.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard hasAvailableSlackEvidence || !slackFailureNotes.isEmpty else {
            return .init(
                brief: feedResult.brief,
                feedRanking: feedResult.ranking,
                slackRanking: [],
                excludedItemIDs: feedResult.excludedEntryIDs,
                failureNotes: feedResult.failureNotes,
                slackAssembly: nil
            )
        }

        let slackResult = slackEngine.assemble(
            evidence: slackEvidence,
            preferences: slackPreferences,
            failureNotes: slackFailureNotes,
            trace: trace,
            briefingDay: feedResult.brief.resolvedBriefingDay
        )
        let feedScores = Dictionary(uniqueKeysWithValues: feedResult.ranking.map { ($0.itemID, $0.score) })
        let slackScores = Dictionary(uniqueKeysWithValues: slackResult.ranking.map { ($0.itemID, $0.score) })
        var candidates: [(item: BriefItem, sectionID: String, score: Int)] = []
        for section in feedResult.brief.sections {
            for item in section.items {
                candidates.append((item, section.id, feedScores[item.id] ?? score(for: item.priority)))
            }
        }
        for section in slackResult.brief.sections {
            for item in section.items {
                candidates.append((item, section.id, slackScores[item.id] ?? score(for: item.priority)))
            }
        }
        candidates.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.item.provenance.publicationDate != $1.item.provenance.publicationDate {
                return $0.item.provenance.publicationDate > $1.item.provenance.publicationDate
            }
            let leftTitle = stableComparisonText($0.item.title)
            let rightTitle = stableComparisonText($1.item.title)
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            return $0.item.id < $1.item.id
        }
        let boundedMaximum = min(max(maximumItems, 1), 40)
        let dropped = candidates.dropFirst(boundedMaximum).map(\.item.id)
        candidates = Array(candidates.prefix(boundedMaximum))

        let sections = Self.orderedSections.compactMap { sectionID -> BriefSection? in
            let items = candidates.filter { $0.sectionID == sectionID }.map(\.item)
            guard !items.isEmpty else { return nil }
            let title: String
            switch sectionID {
            case "attention": title = "Needs Attention"
            case "collaboration": title = "Messages and Collaboration"
            case "news": title = "News and Research"
            default: title = "System and Product Updates"
            }
            return .init(
                id: sectionID,
                title: title,
                items: items,
                summary: "\(items.count) deterministically selected item\(items.count == 1 ? "" : "s")."
            )
        }
        let selectedIDs = candidates.map(\.item.id)
        let allFailureNotes = (feedResult.failureNotes + slackFailureNotes).sorted()
        let status = mixedStatus(feedStatus: feedResult.brief.status, hasSlackItems: !slackResult.ranking.isEmpty, failures: allFailureNotes)
        let sourceCount = Set(candidates.map(\.item.source.id)).count
        let summary = candidates.isEmpty
            ? "No retained source items matched the current deterministic briefing window."
            : "\(candidates.count) attributable item\(candidates.count == 1 ? "" : "s") from \(sourceCount) source\(sourceCount == 1 ? "" : "s"), ordered by deterministic rules."
        let mixedID = stableMixedIdentifier(
            feedBriefID: feedResult.brief.id,
            slackRevisionKeys: slackResult.selectedRevisionKeys,
            selectedIDs: selectedIDs,
            failures: allFailureNotes,
            maximumItems: boundedMaximum
        )
        let brief = Brief(
            id: mixedID,
            date: feedResult.brief.date,
            title: feedResult.brief.title,
            summary: summary,
            status: status,
            sections: sections,
            generation: .init(
                engineID: Self.identifier,
                generatedAt: slackResult.brief.generation.generatedAt,
                status: status,
                reasonCode: allFailureNotes.isEmpty ? "deterministic_mixed_brief_assembled" : "deterministic_mixed_brief_partial",
                fixtureRevision: feedResult.brief.generation.fixtureRevision,
                providerKind: "deterministic",
                sourceItemIDs: selectedIDs,
                validationResult: "not_applicable"
            ),
            partialFailureMessage: allFailureNotes.isEmpty
                ? nil
                : "\(allFailureNotes.count) source refresh\(allFailureNotes.count == 1 ? "" : "es") failed; retained attributable evidence remains available.",
            briefingDay: feedResult.brief.resolvedBriefingDay
        )
        return .init(
            brief: brief,
            feedRanking: feedResult.ranking,
            slackRanking: slackResult.ranking,
            excludedItemIDs: (feedResult.excludedEntryIDs + slackResult.excludedEvidenceIDs + dropped).sorted(),
            failureNotes: allFailureNotes,
            slackAssembly: slackResult
        )
    }

    private func mixedStatus(feedStatus: BriefStatus, hasSlackItems: Bool, failures: [String]) -> BriefStatus {
        if failures.isEmpty, feedStatus == .ready { return .ready }
        if hasSlackItems { return .partial }
        switch feedStatus {
        case .cancelled, .failed, .unavailable: return feedStatus
        default: return .partial
        }
    }

    private func score(for priority: BriefPriority) -> Int {
        switch priority {
        case .urgent: 85
        case .high: 65
        case .normal: 35
        case .low: 0
        }
    }

    private func stableMixedIdentifier(
        feedBriefID: String,
        slackRevisionKeys: [String],
        selectedIDs: [String],
        failures: [String],
        maximumItems: Int
    ) -> String {
        let material = "\(feedBriefID)\u{1f}\(slackRevisionKeys.joined(separator: "|"))\u{1f}\(selectedIDs.joined(separator: "|"))\u{1f}\(failures.joined(separator: "|"))\u{1f}\(maximumItems)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "mixed-brief-\(digest)"
    }

    private func stableComparisonText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
}
