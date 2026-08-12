import Foundation

enum BriefPriority: String, Codable, CaseIterable, Sendable { case urgent, high, normal, low }
enum BriefStatus: String, Codable, Sendable { case preview, ready, partial, cancelled, unavailable, failed }
enum SourceKind: String, Codable, CaseIterable, Sendable { case previewFixtures, newsFeeds, slack, discord, supportEmail, google, social }
enum SourceConnectionState: String, Codable, CaseIterable, Sendable { case available, connected, disconnected, authorizationRequired, unavailable, notImplemented, degraded, error }
enum SourceCapability: String, Codable, CaseIterable, Sendable { case preview, messages, feeds, documents, socialPosts }
enum ModelProviderKind: String, Codable, CaseIterable, Sendable { case deterministic, ollama }
enum ModelProviderState: String, Codable, CaseIterable, Sendable { case available, notRunning, notInstalled, connected, noModels, modelSelected, generating, disabled, disconnected, authorizationRequired, degraded, error, notImplemented }
enum ModelProviderCapability: String, Codable, CaseIterable, Sendable { case deterministicSummary, localGeneration, modelDiscovery }
enum BriefingDensity: String, Codable, CaseIterable, Identifiable, Sendable { case compact, comfortable; var id: String { rawValue } }
enum TextOrigin: String, Codable, Sendable { case source, generated }

extension SourceConnectionState {
    func canTransition(to next: SourceConnectionState) -> Bool {
        if self == next { return true }
        switch (self, next) {
        case (.notImplemented, .available), (.unavailable, .available),
             (.available, .authorizationRequired), (.available, .connected),
             (.authorizationRequired, .connected), (.connected, .disconnected),
             (.disconnected, .authorizationRequired), (.disconnected, .connected),
             (_, .degraded), (_, .error):
            return true
        default:
            return false
        }
    }
}

struct BriefSource: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: SourceKind
    let state: SourceConnectionState
    let capabilities: Set<SourceCapability>
    let detail: String
}

struct ProvenanceRecord: Codable, Hashable, Sendable {
    let sourceID: String
    let publicationDate: Date
    let retrievedAt: Date
    let directURL: URL?
    let isSynthetic: Bool
    let origin: TextOrigin
    let format: String?
    let upstreamIdentifier: String?

    init(sourceID: String, publicationDate: Date, retrievedAt: Date, directURL: URL?, isSynthetic: Bool, origin: TextOrigin, format: String? = nil, upstreamIdentifier: String? = nil) {
        self.sourceID = sourceID
        self.publicationDate = publicationDate
        self.retrievedAt = retrievedAt
        self.directURL = directURL
        self.isSynthetic = isSynthetic
        self.origin = origin
        self.format = format
        self.upstreamIdentifier = upstreamIdentifier
    }
}

struct SlackItemAttribution: Codable, Hashable, Sendable {
    let workspaceID: String
    let workspaceName: String
    let channelID: String
    let channelName: String
    let authorName: String
    let messageTimestamp: Date
    let priorityReasonCode: String
    let locallyGenerated: Bool

    init(
        workspaceID: String,
        workspaceName: String,
        channelID: String,
        channelName: String,
        authorName: String,
        messageTimestamp: Date,
        priorityReasonCode: String,
        locallyGenerated: Bool = false
    ) {
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.channelID = channelID
        self.channelName = channelName
        self.authorName = authorName
        self.messageTimestamp = messageTimestamp
        self.priorityReasonCode = priorityReasonCode
        self.locallyGenerated = locallyGenerated
    }
}

struct BriefItem: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let summary: String
    let priority: BriefPriority
    let source: BriefSource
    let provenance: ProvenanceRecord
    var isRead: Bool
    let availabilityMessage: String?
    let rankingExplanation: String?
    let corroboratingSourceIDs: [String]?
    let slackAttribution: SlackItemAttribution?

    init(id: String, title: String, summary: String, priority: BriefPriority, source: BriefSource, provenance: ProvenanceRecord, isRead: Bool, availabilityMessage: String? = nil, rankingExplanation: String? = nil, corroboratingSourceIDs: [String] = [], slackAttribution: SlackItemAttribution? = nil) {
        self.id = id
        self.title = title
        self.summary = summary
        self.priority = priority
        self.source = source
        self.provenance = provenance
        self.isRead = isRead
        self.availabilityMessage = availabilityMessage
        self.rankingExplanation = rankingExplanation
        self.corroboratingSourceIDs = corroboratingSourceIDs
        self.slackAttribution = slackAttribution
    }
}

struct BriefSection: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let title: String
    let items: [BriefItem]
    let summary: String?

    init(id: String, title: String, items: [BriefItem], summary: String? = nil) {
        self.id = id
        self.title = title
        self.items = items
        self.summary = summary
    }
}

struct BriefGenerationRecord: Codable, Hashable, Sendable {
    let engineID: String
    let generatedAt: Date
    let status: BriefStatus
    let reasonCode: String
    let fixtureRevision: Int
    let providerKind: String?
    let modelName: String?
    let promptTemplateVersion: String?
    let outputSchemaVersion: String?
    let sourceItemIDs: [String]?
    let fallbackStatus: String?
    let durationMilliseconds: Int?
    let promptTokenCount: Int?
    let completionTokenCount: Int?
    let validationResult: String?

    init(engineID: String, generatedAt: Date, status: BriefStatus, reasonCode: String, fixtureRevision: Int, providerKind: String? = nil, modelName: String? = nil, promptTemplateVersion: String? = nil, outputSchemaVersion: String? = nil, sourceItemIDs: [String] = [], fallbackStatus: String? = nil, durationMilliseconds: Int? = nil, promptTokenCount: Int? = nil, completionTokenCount: Int? = nil, validationResult: String? = nil) {
        self.engineID = engineID
        self.generatedAt = generatedAt
        self.status = status
        self.reasonCode = reasonCode
        self.fixtureRevision = fixtureRevision
        self.providerKind = providerKind
        self.modelName = modelName
        self.promptTemplateVersion = promptTemplateVersion
        self.outputSchemaVersion = outputSchemaVersion
        self.sourceItemIDs = sourceItemIDs
        self.fallbackStatus = fallbackStatus
        self.durationMilliseconds = durationMilliseconds
        self.promptTokenCount = promptTokenCount
        self.completionTokenCount = completionTokenCount
        self.validationResult = validationResult
    }
}

struct Brief: Identifiable, Codable, Hashable, Sendable {
    let id: String
    /// Legacy compatibility anchor. User-facing date identity and formatting
    /// must use `resolvedBriefingDay`.
    let date: Date
    let title: String
    let summary: String
    let status: BriefStatus
    let sections: [BriefSection]
    let generation: BriefGenerationRecord
    let partialFailureMessage: String?
    /// Optional only so pre-P6R encoded briefs remain decodable. Every newly
    /// constructed or migrated brief persists an explicit value.
    let briefingDay: LocalCalendarDay?
    var itemCount: Int { sections.reduce(0) { $0 + $1.items.count } }
    var resolvedBriefingDay: LocalCalendarDay {
        briefingDay ?? LocalCalendarDay.resolve(containing: generation.generatedAt)
    }

    init(id: String, date: Date, title: String, summary: String, status: BriefStatus, sections: [BriefSection], generation: BriefGenerationRecord, partialFailureMessage: String? = nil, briefingDay: LocalCalendarDay? = nil) {
        self.id = id
        self.date = date
        self.title = title
        self.summary = summary
        self.status = status
        self.sections = sections
        self.generation = generation
        self.partialFailureMessage = partialFailureMessage
        self.briefingDay = briefingDay ?? LocalCalendarDay.resolve(containing: generation.generatedAt)
    }

    func replacingBriefingDay(
        _ day: LocalCalendarDay,
        calendar _: Calendar = .autoupdatingCurrent,
        timeZone _: TimeZone = .autoupdatingCurrent
    ) -> Brief {
        let correctedTitle = title.hasPrefix("Loki Brief · ")
            ? "Loki Brief · \(day.storageValue)"
            : title
        return Brief(
            id: id,
            // Migration adds civil-day truth without rewriting the legacy
            // compatibility value. Absolute generation/audit instants remain
            // byte-for-byte unchanged as well.
            date: date,
            title: correctedTitle,
            summary: summary,
            status: status,
            sections: sections,
            generation: generation,
            partialFailureMessage: partialFailureMessage,
            briefingDay: day
        )
    }
}

struct BriefHistoryEntry: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let date: Date
    let generatedAt: Date
    let status: BriefStatus
    let itemCount: Int
    let fixtureRevision: Int
    let providerKind: String?
    let modelName: String?
    let partialFailureMessage: String?
    let briefingDay: LocalCalendarDay

    init(id: String, title: String, date: Date, generatedAt: Date, status: BriefStatus, itemCount: Int, fixtureRevision: Int, providerKind: String? = nil, modelName: String? = nil, partialFailureMessage: String? = nil, briefingDay: LocalCalendarDay? = nil) {
        self.id = id
        self.title = title
        self.date = date
        self.generatedAt = generatedAt
        self.status = status
        self.itemCount = itemCount
        self.fixtureRevision = fixtureRevision
        self.providerKind = providerKind
        self.modelName = modelName
        self.partialFailureMessage = partialFailureMessage
        self.briefingDay = briefingDay ?? LocalCalendarDay.resolve(containing: generatedAt)
    }
}

struct ModelProvider: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let name: String
    let kind: ModelProviderKind
    let state: ModelProviderState
    let capabilities: Set<ModelProviderCapability>
    let detail: String
}

struct ModelSelection: Codable, Hashable, Sendable { let providerID: String; let modelID: String? }
struct GenerationRequest: Codable, Hashable, Sendable { let briefDate: Date; let deterministicOnly: Bool }
struct GenerationResult: Codable, Hashable, Sendable { let text: String; let provenance: GenerationProvenance }
struct GenerationFailure: Error, Codable, Hashable, Sendable { let reasonCode: String; let message: String }
struct GenerationProvenance: Codable, Hashable, Sendable { let providerID: String; let deterministic: Bool; let generatedAt: Date }

protocol SourceConnector: Sendable {
    var source: BriefSource { get }
    func snapshot() async -> SourceConnectionState
}

protocol ModelProviding: Sendable {
    var provider: ModelProvider { get }
    func generate(_ request: GenerationRequest) async throws -> GenerationResult
}

protocol BriefingEngine: Sendable {
    var identifier: String { get }
    func generatePreview(revision: Int) -> Brief
}

enum FoundationCatalog {
    static let sources: [BriefSource] = [
        .init(id: "preview-fixtures", name: "Preview Fixtures", kind: .previewFixtures, state: .available, capabilities: [.preview], detail: "Synthetic, deterministic sample content stored with the app."),
        .init(id: "news-feeds", name: "News Feeds", kind: .newsFeeds, state: .available, capabilities: [.feeds], detail: "User-managed RSS, Atom, and JSON Feed subscriptions refresh manually or through an enabled while-running Delivery schedule."),
        .init(id: "slack", name: "Slack", kind: .slack, state: .authorizationRequired, capabilities: [.messages], detail: "Read-only Slack authorization requires approved release configuration."),
        .init(id: "discord", name: "Discord", kind: .discord, state: .authorizationRequired, capabilities: [.messages], detail: "Native GET-only Discord REST history with explicit server, channel, and thread allowlists."),
        .init(id: "support-email", name: "Support Email", kind: .supportEmail, state: .available, capabilities: [.messages], detail: "Credential-free local .eml and .mbox import with inert HTML-to-text sanitization."),
        .init(id: "google", name: "Google", kind: .google, state: .notImplemented, capabilities: [.documents], detail: "No account access is configured."),
        .init(id: "social", name: "Facebook / Instagram", kind: .social, state: .notImplemented, capabilities: [.socialPosts], detail: "No social account access is configured.")
    ]

    static let providers: [ModelProvider] = [
        .init(id: "deterministic", name: "Deterministic briefing engine", kind: .deterministic, state: .available, capabilities: [.deterministicSummary], detail: "Authoritative offline selection, ranking, grouping, and fallback."),
        .init(id: "ollama", name: "Ollama", kind: .ollama, state: .disabled, capabilities: [.localGeneration, .modelDiscovery], detail: "Optional fixed-loopback provider. Check the service, discover installed models, and explicitly select one.")
    ]
}

struct FoundationConnector: SourceConnector {
    let source: BriefSource
    func snapshot() async -> SourceConnectionState { source.state }
}

struct DeferredProvider: ModelProviding {
    let provider: ModelProvider
    func generate(_ request: GenerationRequest) async throws -> GenerationResult {
        throw GenerationFailure(reasonCode: "provider_not_enabled_p1", message: "Provider execution is unavailable in the foundation gate.")
    }
}

struct DeterministicBriefingEngine: BriefingEngine {
    let identifier = "loki.deterministic.preview.v1"

    func generatePreview(revision: Int) -> Brief {
        let anchor = Date(timeIntervalSince1970: 1_750_000_000 + Double(revision * 60))
        let calendar = Calendar.autoupdatingCurrent
        let timeZone = TimeZone.autoupdatingCurrent
        let briefingDay = LocalCalendarDay.resolve(containing: anchor, calendar: calendar, timeZone: timeZone)
        let source = FoundationCatalog.sources[0]
        func item(_ suffix: String, _ title: String, _ summary: String, _ priority: BriefPriority, _ origin: TextOrigin = .generated, unavailable: String? = nil) -> BriefItem {
            .init(id: "preview-r\(revision)-\(suffix)", title: title, summary: summary, priority: priority, source: source,
                  provenance: .init(sourceID: source.id, publicationDate: anchor.addingTimeInterval(-3600), retrievedAt: anchor, directURL: URL(string: "https://example.invalid/preview/\(suffix)"), isSynthetic: true, origin: origin), isRead: false, availabilityMessage: unavailable)
        }
        let sections = [
            BriefSection(id: "attention", title: "Needs Attention", items: [item("review", "Review the release checklist", "A synthetic checkpoint is ready for a focused review.", .urgent)]),
            BriefSection(id: "collaboration", title: "Messages and Collaboration", items: [item("collab", "Two project notes summarized", "Preview-only collaboration context is grouped without private messages.", .high, .source)]),
            BriefSection(id: "research", title: "News and Research", items: [item("research", "Local-first research digest", "Three synthetic findings emphasize attribution and concise reading.", .normal)]),
            BriefSection(id: "system", title: "System and Product Updates", items: [item("system", "Connector status unchanged", "Production sources and local model providers remain inactive.", .low), item("scheduled", "Scheduled delivery is configuration-gated", "Loki Brief can assemble and deliver a daily brief after you explicitly enable a schedule and eligible sources.", .low, unavailable: "Disabled until configured")])
        ]
        return Brief(id: "preview-brief-r\(revision)", date: briefingDay.referenceDate(calendar: calendar, timeZone: timeZone) ?? anchor, title: "Your quiet start to the day", summary: "A deterministic sample briefing with explicit provenance and no network activity.", status: .preview, sections: sections,
                     generation: .init(engineID: identifier, generatedAt: anchor, status: .preview, reasonCode: "preview_fixture_generated", fixtureRevision: revision), briefingDay: briefingDay)
    }
}
