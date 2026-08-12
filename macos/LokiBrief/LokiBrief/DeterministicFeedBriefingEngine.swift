import CryptoKit
import Foundation

struct FeedBriefingPreferences: Codable, Hashable, Sendable {
    var topicKeywords: [String]
    var sourceWeights: [String: Double]
    var readStates: [String: Bool]
    var briefingWindowHours: Int
    var maximumItems: Int

    static let `default` = FeedBriefingPreferences(topicKeywords: [], sourceWeights: [:], readStates: [:], briefingWindowHours: 168, maximumItems: 40)
}

struct FeedRankingExplanation: Codable, Hashable, Sendable {
    let itemID: String
    let score: Int
    let reasons: [String]
    let sectionID: String
}

struct BriefAssemblyResult: Codable, Hashable, Sendable {
    let brief: Brief
    let ranking: [FeedRankingExplanation]
    let excludedEntryIDs: [String]
    let failureNotes: [String]
}

struct DeterministicFeedBriefingEngine: Sendable {
    static let identifier = "loki.deterministic.feed.v1"
    static let orderedSections = ["attention", "collaboration", "news", "system"]

    private let now: @Sendable () -> Date
    private let calendar: @Sendable () -> Calendar
    private let timeZone: @Sendable () -> TimeZone

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
        timeZone: @escaping @Sendable () -> TimeZone = { .autoupdatingCurrent }
    ) {
        self.now = now
        self.calendar = calendar
        self.timeZone = timeZone
    }

    func assemble(entries: [NormalizedFeedEntry], subscriptions: [FeedSubscription], preferences: FeedBriefingPreferences, failureNotes: [String] = [], briefingDay requestedBriefingDay: LocalCalendarDay? = nil) -> BriefAssemblyResult {
        let generatedAt = now()
        let resolutionCalendar = calendar()
        let resolutionTimeZone = timeZone()
        let briefingDay = requestedBriefingDay ?? LocalCalendarDay.resolve(
            containing: generatedAt,
            calendar: resolutionCalendar,
            timeZone: resolutionTimeZone
        )
        let windowHours = min(max(preferences.briefingWindowHours, 1), 24 * 30)
        let cutoff = generatedAt.addingTimeInterval(-Double(windowHours) * 3_600)
        let subscriptionByID = Dictionary(uniqueKeysWithValues: subscriptions.map { ($0.id, $0) })
        let enabled = Set(subscriptions.filter(\.enabled).map(\.id))
        let corroboratingSources = Dictionary(grouping: entries.compactMap { entry -> (String, String)? in
            guard let url = entry.canonicalURL?.absoluteString else { return nil }
            return (url, entry.subscriptionID)
        }, by: \.0).mapValues { Array(Set($0.map(\.1))).sorted() }

        var ranked: [(entry: NormalizedFeedEntry, explanation: FeedRankingExplanation, effectiveDate: Date)] = []
        var excluded: [String] = []
        for entry in entries {
            guard enabled.contains(entry.subscriptionID), subscriptionByID[entry.subscriptionID] != nil else { excluded.append(entry.id); continue }
            let effectiveDate = entry.publishedAt ?? entry.updatedAt ?? entry.retrievedAt
            guard effectiveDate >= cutoff, effectiveDate <= generatedAt.addingTimeInterval(300) else { excluded.append(entry.id); continue }
            let section = sectionID(for: entry)
            let explanation = rank(entry, effectiveDate: effectiveDate, generatedAt: generatedAt, sectionID: section, corroboratingSourceCount: entry.canonicalURL.flatMap { corroboratingSources[$0.absoluteString]?.count } ?? 1, preferences: preferences, subscription: subscriptionByID[entry.subscriptionID]!)
            ranked.append((entry, explanation, effectiveDate))
        }
        ranked.sort {
            if $0.explanation.score != $1.explanation.score { return $0.explanation.score > $1.explanation.score }
            if $0.effectiveDate != $1.effectiveDate { return $0.effectiveDate > $1.effectiveDate }
            let leftTitle = stableComparisonText($0.entry.title)
            let rightTitle = stableComparisonText($1.entry.title)
            if leftTitle != rightTitle { return leftTitle < rightTitle }
            return $0.entry.id < $1.entry.id
        }
        if ranked.count > min(max(preferences.maximumItems, 1), 100) {
            excluded.append(contentsOf: ranked.dropFirst(min(max(preferences.maximumItems, 1), 100)).map(\.entry.id))
            ranked = Array(ranked.prefix(min(max(preferences.maximumItems, 1), 100)))
        }

        let grouped = Dictionary(grouping: ranked, by: { $0.explanation.sectionID })
        let sections = [
            makeSection(id: "attention", title: "Needs Attention", ranked: grouped["attention"] ?? [], preferences: preferences, corroboratingSources: corroboratingSources),
            makeSection(id: "news", title: "News and Research", ranked: grouped["news"] ?? [], preferences: preferences, corroboratingSources: corroboratingSources),
            makeSection(id: "system", title: "System and Product Updates", ranked: grouped["system"] ?? [], preferences: preferences, corroboratingSources: corroboratingSources)
        ].filter { !$0.items.isEmpty }
        let selectedIDs = ranked.map(\.entry.id)
        let sourceCount = Set(ranked.map(\.entry.subscriptionID)).count
        let status: BriefStatus = failureNotes.isEmpty ? .ready : .partial
        let summary = ranked.isEmpty
            ? "No retained feed items matched the current deterministic briefing window."
            : "\(ranked.count) attributable item\(ranked.count == 1 ? "" : "s") from \(sourceCount) enabled source\(sourceCount == 1 ? "" : "s"), ordered by deterministic rules."
        let briefID = stableBriefIdentifier(briefingDay: briefingDay, selectedIDs: selectedIDs, preferences: preferences, failures: failureNotes)
        let brief = Brief(
            id: briefID,
            date: briefingDay.referenceDate(calendar: resolutionCalendar, timeZone: resolutionTimeZone) ?? generatedAt,
            title: "Loki Brief · \(briefingDay.storageValue)",
            summary: summary,
            status: status,
            sections: sections,
            generation: .init(engineID: Self.identifier, generatedAt: generatedAt, status: status, reasonCode: failureNotes.isEmpty ? "deterministic_feed_brief_assembled" : "deterministic_feed_brief_partial", fixtureRevision: 0, providerKind: "deterministic", sourceItemIDs: selectedIDs, fallbackStatus: nil, validationResult: "not_applicable"),
            partialFailureMessage: failureNotes.isEmpty ? nil : "\(failureNotes.count) source refresh\(failureNotes.count == 1 ? "" : "es") failed; the last valid evidence remains available.",
            briefingDay: briefingDay
        )
        return .init(brief: brief, ranking: ranked.map(\.explanation), excludedEntryIDs: excluded.sorted(), failureNotes: failureNotes)
    }

    private func rank(_ entry: NormalizedFeedEntry, effectiveDate: Date, generatedAt: Date, sectionID: String, corroboratingSourceCount: Int, preferences: FeedBriefingPreferences, subscription: FeedSubscription) -> FeedRankingExplanation {
        var score = 0
        var reasons: [String] = []
        let ageHours = max(0, generatedAt.timeIntervalSince(effectiveDate) / 3_600)
        let recency: Int
        switch ageHours {
        case 0..<6: recency = 40
        case 6..<24: recency = 30
        case 24..<72: recency = 20
        default: recency = 10
        }
        score += recency; reasons.append("recency +\(recency)")

        let haystack = "\(entry.title) \(entry.summary)".folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let topics = preferences.topicKeywords.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.filter { !$0.isEmpty }
        let topicMatches = min(3, topics.filter(haystack.contains).count)
        if topicMatches > 0 { let points = topicMatches * 10; score += points; reasons.append("topic match +\(points)") }

        let configuredWeight = preferences.sourceWeights[subscription.id] ?? subscription.weight
        let weight = min(max(configuredWeight, 0.5), 2)
        let weightPoints = Int((weight * 10).rounded())
        score += weightPoints; reasons.append("source weight +\(weightPoints)")

        if corroboratingSourceCount > 1 {
            let points = min(10, (corroboratingSourceCount - 1) * 5)
            score += points; reasons.append("source corroboration +\(points)")
        }
        if sectionID == "attention" { score += 15; reasons.append("explicit attention category +15") }
        else if sectionID == "system" { score += 5; reasons.append("product/system category +5") }
        if preferences.readStates[entry.id] == true { score -= 20; reasons.append("already read -20") }
        else { score += 5; reasons.append("unread +5") }
        return .init(itemID: entry.id, score: score, reasons: reasons, sectionID: sectionID)
    }

    private func makeSection(id: String, title: String, ranked: [(entry: NormalizedFeedEntry, explanation: FeedRankingExplanation, effectiveDate: Date)], preferences: FeedBriefingPreferences, corroboratingSources: [String: [String]]) -> BriefSection {
        let items = ranked.map { value -> BriefItem in
            let entry = value.entry
            let source = BriefSource(id: entry.subscriptionID, name: entry.sourceTitle, kind: .newsFeeds, state: .connected, capabilities: [.feeds], detail: "Manually refreshed public HTTPS feed.")
            return BriefItem(
                id: entry.id,
                title: entry.title,
                summary: entry.summary,
                priority: priority(for: value.explanation.score),
                source: source,
                provenance: .init(sourceID: entry.subscriptionID, publicationDate: entry.publishedAt ?? entry.updatedAt ?? entry.retrievedAt, retrievedAt: entry.retrievedAt, directURL: entry.canonicalURL, isSynthetic: false, origin: .source, format: entry.provenance.format.rawValue, upstreamIdentifier: entry.provenance.upstreamIdentifier),
                isRead: preferences.readStates[entry.id] ?? false,
                rankingExplanation: "Score \(value.explanation.score): \(value.explanation.reasons.joined(separator: ", ")).",
                corroboratingSourceIDs: entry.canonicalURL.flatMap { corroboratingSources[$0.absoluteString] } ?? []
            )
        }
        return .init(id: id, title: title, items: items, summary: "\(items.count) deterministically selected item\(items.count == 1 ? "" : "s").")
    }

    private func sectionID(for entry: NormalizedFeedEntry) -> String {
        let text = "\(entry.title) \(entry.summary)".lowercased()
        let attentionTerms = ["urgent", "critical", "action required", "immediate action", "emergency"]
        if attentionTerms.contains(where: text.contains) { return "attention" }
        let systemTerms = ["release", "released", "update", "version", "security", "patch", "product", "system", "software", "firmware", "api", "sdk"]
        return systemTerms.contains(where: text.contains) ? "system" : "news"
    }

    private func priority(for score: Int) -> BriefPriority {
        switch score {
        case 85...: .urgent
        case 65...: .high
        case 35...: .normal
        default: .low
        }
    }

    private func stableBriefIdentifier(briefingDay: LocalCalendarDay, selectedIDs: [String], preferences: FeedBriefingPreferences, failures: [String]) -> String {
        let topics = preferences.topicKeywords.map { $0.lowercased() }.sorted().joined(separator: "|")
        let weights = preferences.sourceWeights.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "|")
        let material = "\(briefingDay.storageValue)\u{1f}\(selectedIDs.joined(separator: "|"))\u{1f}\(topics)\u{1f}\(weights)\u{1f}\(failures.sorted().joined(separator: "|"))"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "feed-brief-\(digest)"
    }

    private func stableComparisonText(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
    }
}
