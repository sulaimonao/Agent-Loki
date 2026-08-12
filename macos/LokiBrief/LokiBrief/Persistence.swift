import Darwin
import Foundation
import OSLog
import SwiftData

@Model final class StoredSettings {
    @Attribute(.unique) var id: String
    var preferredBriefingTime: Date
    var launchAtLoginPreference: Bool
    var notificationPreference: Bool
    var densityRaw: String
    var deterministicOnly: Bool
    var futureLocalModelPreference: Bool
    var schemaVersion: Int

    init(id: String = "primary", preferredBriefingTime: Date = Date(timeIntervalSince1970: 28_800), launchAtLoginPreference: Bool = false, notificationPreference: Bool = false, density: BriefingDensity = .comfortable, deterministicOnly: Bool = true, futureLocalModelPreference: Bool = false) {
        self.id = id; self.preferredBriefingTime = preferredBriefingTime; self.launchAtLoginPreference = launchAtLoginPreference
        self.notificationPreference = notificationPreference; self.densityRaw = density.rawValue; self.deterministicOnly = deterministicOnly
        self.futureLocalModelPreference = futureLocalModelPreference; self.schemaVersion = 1
    }
    var density: BriefingDensity { get { BriefingDensity(rawValue: densityRaw) ?? .comfortable } set { densityRaw = newValue.rawValue } }
}

@Model final class StoredBrief {
    @Attribute(.unique) var id: String
    var briefDate: Date
    var title: String
    var summary: String
    var generatedAt: Date
    var statusRaw: String
    var fixtureRevision: Int
    var itemCount: Int
    var encodedBrief: Data

    init(brief: Brief) throws {
        self.id = brief.id; self.briefDate = brief.date; self.title = brief.title; self.summary = brief.summary
        self.generatedAt = brief.generation.generatedAt; self.statusRaw = brief.status.rawValue
        self.fixtureRevision = brief.generation.fixtureRevision; self.itemCount = brief.itemCount
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        self.encodedBrief = try encoder.encode(brief)
    }

    func update(with brief: Brief) throws {
        briefDate = brief.date
        title = brief.title
        summary = brief.summary
        generatedAt = brief.generation.generatedAt
        statusRaw = brief.status.rawValue
        fixtureRevision = brief.generation.fixtureRevision
        itemCount = brief.itemCount
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encodedBrief = try encoder.encode(brief)
    }

    var historyEntry: BriefHistoryEntry {
        let decoded = try? decodedBrief()
        return .init(id: id, title: title, date: briefDate, generatedAt: generatedAt, status: BriefStatus(rawValue: statusRaw) ?? .unavailable, itemCount: itemCount, fixtureRevision: fixtureRevision, providerKind: decoded?.generation.providerKind, modelName: decoded?.generation.modelName, partialFailureMessage: decoded?.partialFailureMessage, briefingDay: decoded?.resolvedBriefingDay)
    }

    func decodedBrief() throws -> Brief { try JSONDecoder().decode(Brief.self, from: encodedBrief) }
}

@Model final class StoredReadState {
    @Attribute(.unique) var itemID: String
    var isRead: Bool
    init(itemID: String, isRead: Bool) { self.itemID = itemID; self.isRead = isRead }
}

@Model final class StoredStateSnapshot {
    @Attribute(.unique) var id: String
    var domain: String
    var state: String
    var capturedAt: Date
    init(id: String, domain: String, state: String, capturedAt: Date = .now) { self.id = id; self.domain = domain; self.state = state; self.capturedAt = capturedAt }
}

private struct LocalStoreExplicitStorageIdentity: Equatable {
    private struct Item: Equatable {
        let device: Int64
        let inode: UInt64
        let owner: UInt32
        let fileType: UInt32
        let permissions: UInt32
        let linkCount: UInt64

        init(_ information: stat) {
            device = Int64(information.st_dev)
            inode = UInt64(information.st_ino)
            owner = information.st_uid
            fileType = UInt32(information.st_mode & S_IFMT)
            permissions = UInt32(information.st_mode & 0o7777)
            linkCount = UInt64(information.st_nlink)
        }

        func matchesDirectory(_ other: Self) -> Bool {
            device == other.device
                && inode == other.inode
                && owner == other.owner
                && fileType == other.fileType
                && permissions == other.permissions
                && linkCount > 0
                && other.linkCount > 0
        }

        func matchesFileIdentity(_ other: Self) -> Bool {
            device == other.device
                && inode == other.inode
                && owner == other.owner
                && fileType == other.fileType
                && linkCount == other.linkCount
        }
    }

    let storageURL: URL
    private let parent: Item
    private let database: Item

    static func capture(at storageURL: URL) -> Self? {
        let canonical = storageURL.standardizedFileURL
        guard let parent = information(
                at: canonical.deletingLastPathComponent()
              ),
              let database = information(at: canonical),
              UInt32(parent.st_mode & S_IFMT) == UInt32(S_IFDIR),
              UInt32(database.st_mode & S_IFMT) == UInt32(S_IFREG)
        else { return nil }
        return .init(
            storageURL: canonical,
            parent: .init(parent),
            database: .init(database)
        )
    }

    func matchesCurrent() -> Bool {
        guard let current = Self.capture(at: storageURL) else {
            return false
        }
        return parent.matchesDirectory(current.parent)
            && database.matchesFileIdentity(current.database)
    }

    private static func information(at url: URL) -> stat? {
        var value = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &value)
        }
        return result == 0 ? value : nil
    }
}

@MainActor
final class LocalStore {
    private static let localDayLogger = Logger(
        subsystem: "com.agentloki.LokiBrief",
        category: "local-calendar-day"
    )
    let container: ModelContainer
    let isInMemory: Bool
    let usesExplicitStorageURL: Bool
    let storageURL: URL?
    let userCalendarProvider: () -> Calendar
    let userTimeZoneProvider: () -> TimeZone
    private(set) var localCalendarDayMigrationReport: LocalCalendarDayMigrationReport
    private(set) var modelRoleMigrationReport: P8ModelRoleMigrationReport
    private var explicitStorageIdentity:
        LocalStoreExplicitStorageIdentity?
    private var context: ModelContext { container.mainContext }

    init(
        inMemory: Bool = false,
        url: URL? = nil,
        userCalendarProvider: @escaping () -> Calendar = { .autoupdatingCurrent },
        userTimeZoneProvider: @escaping () -> TimeZone = { .autoupdatingCurrent }
    ) throws {
        let schema = Schema(versionedSchema: LokiBriefSchemaV11.self)
        self.isInMemory = inMemory
        self.usesExplicitStorageURL = url != nil
        self.storageURL = url?.resolvingSymlinksInPath().standardizedFileURL
        self.userCalendarProvider = userCalendarProvider
        self.userTimeZoneProvider = userTimeZoneProvider
        self.localCalendarDayMigrationReport = .none
        self.modelRoleMigrationReport = .notRequired
        self.explicitStorageIdentity = nil
        let configuration = storageURL.map { ModelConfiguration("LokiBrief-v1", schema: schema, url: $0) }
            ?? ModelConfiguration("LokiBrief-v1", schema: schema, isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: schema, migrationPlan: LokiBriefMigrationPlanV11.self, configurations: [configuration])
        localCalendarDayMigrationReport = try backfillLocalCalendarDays()
        modelRoleMigrationReport = try reconcileP8ModelRoleMigration()
        let report = localCalendarDayMigrationReport
        if report.totalSidecars > 0 || report.encodedBriefsRewritten > 0 || report.runMetadataRewritten > 0 {
            Self.localDayLogger.notice(
                "event=local_calendar_day_migration status=success reason_code=v7_local_day_backfill occurrences=\(report.occurrencesBackfilled, privacy: .public) briefs=\(report.briefsBackfilled, privacy: .public) runs=\(report.runsBackfilled, privacy: .public) deliveries=\(report.deliveriesBackfilled, privacy: .public) encoded_briefs=\(report.encodedBriefsRewritten, privacy: .public) run_metadata=\(report.runMetadataRewritten, privacy: .public)"
            )
        }
        if let storageURL {
            guard let identity = LocalStoreExplicitStorageIdentity
                .capture(at: storageURL)
            else {
                throw CocoaError(.fileReadUnknown)
            }
            explicitStorageIdentity = identity
        }
    }

    /// Signed-smoke packages call this before accepting a LocalStore. It
    /// compares the current primary database and parent directory with the
    /// identity captured before `init` returned, closing the otherwise
    /// undetectable replacement window between store construction and package
    /// admission. In-memory and implicit production stores intentionally
    /// return false because they are not eligible for file-backed smoke.
    func validatesExplicitStorageIdentity() -> Bool {
        guard usesExplicitStorageURL,
              let explicitStorageIdentity
        else { return false }
        return explicitStorageIdentity.matchesCurrent()
    }

    func settings() throws -> StoredSettings {
        if let existing = try context.fetch(FetchDescriptor<StoredSettings>()).first { return existing }
        let created = StoredSettings(); context.insert(created); try context.save(); return created
    }

    func p2Settings() throws -> StoredP2Settings {
        if let existing = try context.fetch(FetchDescriptor<StoredP2Settings>()).first { return existing }
        let created = StoredP2Settings(); context.insert(created); try context.save(); return created
    }

    func save() throws { try context.save() }

    func connectorStatuses() throws -> [ConnectorStatusSnapshot] {
        try context.fetch(FetchDescriptor<StoredConnectorStatus>())
            .map { try $0.domain() }
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                return $0.id < $1.id
            }
    }

    func connectorStatus(id: String) throws -> ConnectorStatusSnapshot? {
        try context.fetch(FetchDescriptor<StoredConnectorStatus>())
            .first(where: { $0.id == id })
            .map { try $0.domain() }
    }

    func saveConnectorStatus(_ value: ConnectorStatusSnapshot) throws {
        let all = try context.fetch(FetchDescriptor<StoredConnectorStatus>())
        if let existing = all.first(where: { $0.id == value.id }) {
            try existing.update(with: value)
        } else {
            context.insert(try StoredConnectorStatus(value))
        }
        try context.save()
    }

    func removeConnectorStatus(id: String) throws {
        for value in try context.fetch(FetchDescriptor<StoredConnectorStatus>())
        where value.id == id {
            context.delete(value)
        }
        for receipt in try context.fetch(FetchDescriptor<StoredConnectorSyncReceipt>())
        where receipt.connectorStatusIdentifier == id {
            context.delete(receipt)
        }
        try context.save()
    }

    func connectorSyncReceipts(
        statusIdentifier: String? = nil
    ) throws -> [ConnectorSyncReceipt] {
        try context.fetch(FetchDescriptor<StoredConnectorSyncReceipt>())
            .filter {
                statusIdentifier == nil
                    || $0.connectorStatusIdentifier == statusIdentifier
            }
            .map { try $0.domain() }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
    }

    func saveConnectorSyncReceipt(_ value: ConnectorSyncReceipt) throws {
        let all = try context.fetch(FetchDescriptor<StoredConnectorSyncReceipt>())
        guard !all.contains(where: { $0.id == value.id }) else { return }
        context.insert(try StoredConnectorSyncReceipt(value))
        let sameConnector = try context.fetch(FetchDescriptor<StoredConnectorSyncReceipt>())
            .filter { $0.connectorStatusIdentifier == value.connectorStatusIdentifier }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
        for obsolete in sameConnector.dropFirst(100) {
            context.delete(obsolete)
        }
        try context.save()
    }

    func emailImportAccess(id: String) throws -> EmailImportAccessSnapshot? {
        try context.fetch(FetchDescriptor<StoredEmailImportAccess>())
            .first(where: { $0.id == id })?
            .domain()
    }

    func saveEmailImportAccess(_ value: EmailImportAccessSnapshot) throws {
        let all = try context.fetch(FetchDescriptor<StoredEmailImportAccess>())
        if let existing = all.first(where: { $0.id == value.id }) {
            existing.update(with: value)
        } else {
            context.insert(StoredEmailImportAccess(value))
        }
        try context.save()
    }

    func removeEmailImportAccess(id: String) throws {
        for value in try context.fetch(FetchDescriptor<StoredEmailImportAccess>())
        where value.id == id {
            context.delete(value)
        }
        try context.save()
    }

    func attachedDataSources() throws -> [AttachedDataSourceRecord] {
        try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
            .map { try $0.domain() }
            .sorted {
                if $0.kind.rawValue != $1.kind.rawValue {
                    return $0.kind.rawValue < $1.kind.rawValue
                }
                let displayOrder = $0.displayName.localizedCaseInsensitiveCompare(
                    $1.displayName
                )
                if displayOrder != .orderedSame {
                    return displayOrder == .orderedAscending
                }
                return $0.id < $1.id
            }
    }

    func attachedDataSource(id: String) throws -> AttachedDataSourceRecord? {
        try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
            .first(where: { $0.id == id })
            .map { try $0.domain() }
    }

    /// Bookmark bytes intentionally cross only this private-store boundary.
    /// They never enter `AttachedDataSourceRecord`, receipts, or diagnostics.
    func attachedDataSourceBookmark(id: String) throws -> Data? {
        try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
            .first(where: { $0.id == id })?
            .bookmarkData()
    }

    /// A nil bookmark preserves the currently stored bookmark. Detachment is a
    /// separate operation so ordinary status updates cannot revoke authority by
    /// accident or silently retain bytes after the domain says access ended.
    func saveAttachedDataSource(
        _ value: AttachedDataSourceRecord,
        securityScopedBookmark: Data? = nil
    ) throws {
        try value.validate()
        let all = try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
        if let existing = all.first(where: { $0.id == value.id }) {
            if let securityScopedBookmark {
                try existing.update(
                    with: value,
                    replacingBookmarkWith: securityScopedBookmark
                )
            } else {
                try existing.update(with: value)
            }
        } else {
            context.insert(
                try StoredAttachedDataSource(
                    value,
                    securityScopedBookmark: securityScopedBookmark
                )
            )
        }
        try context.save()
    }

    @discardableResult
    func detachAttachedDataSource(
        id: String,
        at date: Date = .now
    ) throws -> AttachedDataSourceRecord? {
        guard let stored = try context.fetch(
            FetchDescriptor<StoredAttachedDataSource>()
        ).first(where: { $0.id == id }) else { return nil }
        let detached = try stored.domain().detached(at: date)
        try stored.updateRemovingBookmark(with: detached)
        try context.save()
        return detached
    }

    func removeAttachedDataSource(
        id: String,
        removeReceipts: Bool = true
    ) throws {
        for value in try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
        where value.id == id {
            context.delete(value)
        }
        if removeReceipts {
            for receipt in try context.fetch(
                FetchDescriptor<StoredAttachedDataSourceReceipt>()
            ) where receipt.sourceIdentifier == id {
                context.delete(receipt)
            }
        }
        try context.save()
    }

    func attachedDataSourceReceipts(
        sourceIdentifier: String? = nil
    ) throws -> [AttachedDataSourceReceipt] {
        try context.fetch(FetchDescriptor<StoredAttachedDataSourceReceipt>())
            .filter {
                sourceIdentifier == nil || $0.sourceIdentifier == sourceIdentifier
            }
            .map { try $0.domain() }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
    }

    func attachedDataSourceReceipt(id: String) throws -> AttachedDataSourceReceipt? {
        try context.fetch(FetchDescriptor<StoredAttachedDataSourceReceipt>())
            .first(where: { $0.id == id })
            .map { try $0.domain() }
    }

    func saveAttachedDataSourceReceipt(
        _ value: AttachedDataSourceReceipt
    ) throws {
        try value.validate()
        let all = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        )
        if let existing = all.first(where: { $0.id == value.id }) {
            guard try existing.domain() == value else {
                throw AttachedDataSourceFailureCode.receiptConflict
            }
            return
        }
        context.insert(try StoredAttachedDataSourceReceipt(value))
        let sameSource = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        ).filter { $0.sourceIdentifier == value.sourceIdentifier }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
        for obsolete in sameSource.dropFirst(
            AttachedDataSourceLimits.maximumReceiptsPerSource
        ) {
            context.delete(obsolete)
        }
        try context.save()
    }

    /// Finalizes the private source record and its success receipt in one
    /// SwiftData save after Loki Vault has committed the matching generation.
    /// A task-owned Vault generation marker remains the cross-store recovery
    /// authority if the process stops before this save completes.
    func finalizeAttachedDataSourcePublication(
        source: AttachedDataSourceRecord,
        receipt: AttachedDataSourceReceipt,
        securityScopedBookmark: Data? = nil,
        removeBookmark: Bool = false
    ) throws {
        try source.validate()
        try receipt.validate()
        guard receipt.sourceIdentifier == source.id,
              receipt.outcome == .succeeded,
              receipt.atomicPublicationCommitted,
              receipt.generationIdentifier
                == source.currentGenerationIdentifier,
              source.pendingGenerationIdentifier == nil,
              source.frozenImportPlan == nil,
              !(removeBookmark && securityScopedBookmark != nil)
        else { throw AttachedDataSourceFailureCode.persistenceCorrupt }

        let storedSources = try context.fetch(
            FetchDescriptor<StoredAttachedDataSource>()
        )
        if let existing = storedSources.first(where: { $0.id == source.id }) {
            if removeBookmark {
                try existing.updateRemovingBookmark(with: source)
            } else if let securityScopedBookmark {
                try existing.update(
                    with: source,
                    replacingBookmarkWith: securityScopedBookmark
                )
            } else {
                try existing.update(with: source)
            }
        } else {
            context.insert(try StoredAttachedDataSource(
                source,
                securityScopedBookmark: removeBookmark
                    ? nil : securityScopedBookmark
            ))
        }

        let storedReceipts = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        )
        if let existing = storedReceipts.first(where: { $0.id == receipt.id }) {
            guard try existing.domain() == receipt else {
                throw AttachedDataSourceFailureCode.receiptConflict
            }
        } else {
            context.insert(try StoredAttachedDataSourceReceipt(receipt))
        }
        let sameSource = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        ).filter { $0.sourceIdentifier == receipt.sourceIdentifier }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
        for obsolete in sameSource.dropFirst(
            AttachedDataSourceLimits.maximumReceiptsPerSource
        ) {
            context.delete(obsolete)
        }
        try context.save()
    }

    /// Commits the truthful removed state and its audit receipt together while
    /// preserving any independently retained read-only file bookmark.
    func finalizeAttachedDataSourceRemoval(
        source: AttachedDataSourceRecord,
        receipt: AttachedDataSourceReceipt
    ) throws {
        try source.validate()
        try receipt.validate()
        guard receipt.sourceIdentifier == source.id,
              receipt.operation == .removeLocalData,
              receipt.outcome == .succeeded,
              !receipt.atomicPublicationCommitted,
              source.localDataRetentionState == .removed,
              source.currentGenerationIdentifier == nil,
              source.pendingGenerationIdentifier == nil,
              source.frozenImportPlan == nil,
              source.latestReceiptIdentifier == receipt.id
        else { throw AttachedDataSourceFailureCode.persistenceCorrupt }

        let storedSources = try context.fetch(
            FetchDescriptor<StoredAttachedDataSource>()
        )
        if let existing = storedSources.first(where: { $0.id == source.id }) {
            try existing.update(with: source)
        } else {
            context.insert(try StoredAttachedDataSource(
                source,
                securityScopedBookmark: nil
            ))
        }

        let storedReceipts = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        )
        if let existing = storedReceipts.first(where: { $0.id == receipt.id }) {
            guard try existing.domain() == receipt else {
                throw AttachedDataSourceFailureCode.receiptConflict
            }
        } else {
            context.insert(try StoredAttachedDataSourceReceipt(receipt))
        }
        let sameSource = try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        ).filter { $0.sourceIdentifier == receipt.sourceIdentifier }
            .sorted {
                if $0.completedAt != $1.completedAt {
                    return $0.completedAt > $1.completedAt
                }
                return $0.id < $1.id
            }
        for obsolete in sameSource.dropFirst(
            AttachedDataSourceLimits.maximumReceiptsPerSource
        ) {
            context.delete(obsolete)
        }
        try context.save()
    }

    func removeAttachedDataSourceReceipts(sourceIdentifier: String) throws {
        for receipt in try context.fetch(
            FetchDescriptor<StoredAttachedDataSourceReceipt>()
        ) where receipt.sourceIdentifier == sourceIdentifier {
            context.delete(receipt)
        }
        try context.save()
    }

    /// Persisted preview/import/refresh work cannot resume implicitly after a
    /// process restart. This helper preserves any published generation while
    /// moving transient states to an explicit-resume state and reason code.
    @discardableResult
    func reconcileInterruptedAttachedDataSourceOperations(
        at date: Date = .now
    ) throws -> [AttachedDataSourceRecord] {
        let stored = try context.fetch(FetchDescriptor<StoredAttachedDataSource>())
        var reconciled: [AttachedDataSourceRecord] = []
        var changed = false
        for value in stored {
            let original = try value.domain()
            let recovered = try original.reconcilingInterruptedOperation(at: date)
            if recovered != original {
                try value.update(with: recovered)
                changed = true
            }
            reconciled.append(recovered)
        }
        if changed { try context.save() }
        return reconciled.sorted { $0.id < $1.id }
    }

    func record(_ brief: Brief) throws {
        let all = try context.fetch(FetchDescriptor<StoredBrief>())
        if let existing = all.first(where: { $0.id == brief.id }) {
            try existing.update(with: brief)
        } else {
            context.insert(try StoredBrief(brief: brief))
        }
        try persistLocalCalendarDay(
            ownerType: .brief,
            ownerIdentifier: brief.id,
            day: brief.resolvedBriefingDay,
            resolutionSource: .createdFromCurrentUserContext,
            recordedAt: brief.generation.generatedAt
        )
        try context.save()
        try pruneBriefHistory(referenceDate: brief.generation.generatedAt)
    }

    func history() throws -> [StoredBrief] {
        try context.fetch(FetchDescriptor<StoredBrief>()).sorted { $0.generatedAt > $1.generatedAt }
    }

    func brief(id: String) throws -> Brief? {
        try context.fetch(FetchDescriptor<StoredBrief>()).first(where: { $0.id == id }).map { try $0.decodedBrief() }
    }

    func setRead(_ itemID: String, isRead: Bool) throws {
        if let state = try context.fetch(FetchDescriptor<StoredReadState>()).first(where: { $0.itemID == itemID }) { state.isRead = isRead }
        else { context.insert(StoredReadState(itemID: itemID, isRead: isRead)) }
        try context.save()
    }

    func readStates() throws -> [String: Bool] { Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<StoredReadState>()).map { ($0.itemID, $0.isRead) }) }

    func feedSubscriptions() throws -> [StoredFeedSubscription] {
        try context.fetch(FetchDescriptor<StoredFeedSubscription>()).sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id < $1.id
        }
    }

    func insertFeedSubscription(_ subscription: StoredFeedSubscription) throws {
        context.insert(subscription)
        try context.save()
    }

    func removeFeedSubscription(id: String) throws {
        let subscriptions = try context.fetch(FetchDescriptor<StoredFeedSubscription>())
        for subscription in subscriptions where subscription.id == id { context.delete(subscription) }
        let entries = try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>())
        for entry in entries where entry.subscriptionID == id { context.delete(entry) }
        let fetches = try context.fetch(FetchDescriptor<StoredFeedFetch>())
        for fetch in fetches where fetch.subscriptionID == id { context.delete(fetch) }
        try context.save()
    }

    func recordFetch(_ fetch: StoredFeedFetch) throws {
        context.insert(fetch)
        try context.save()
        let matching = try context.fetch(FetchDescriptor<StoredFeedFetch>())
            .filter { $0.subscriptionID == fetch.subscriptionID }
            .sorted {
                let lhs = $0.completedAt ?? $0.attemptedAt
                let rhs = $1.completedAt ?? $1.attemptedAt
                if lhs != rhs { return lhs > rhs }
                return $0.id < $1.id
            }
        for record in matching.dropFirst(FeedLimits.maximumFetchRecordsPerFeed) { context.delete(record) }
        if matching.count > FeedLimits.maximumFetchRecordsPerFeed { try context.save() }
    }

    func feedEntries(enabledSubscriptionIDs: Set<String>? = nil) throws -> [StoredNormalizedFeedEntry] {
        let all = try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>())
        let filtered = enabledSubscriptionIDs.map { identifiers in all.filter { identifiers.contains($0.subscriptionID) } } ?? all
        return filtered.sorted {
            let lhsDate = $0.publicationDate ?? $0.updatedDate ?? $0.retrievedAt
            let rhsDate = $1.publicationDate ?? $1.updatedDate ?? $1.retrievedAt
            if lhsDate != rhsDate { return lhsDate > rhsDate }
            return $0.id < $1.id
        }
    }

    func upsertFeedEntry(_ entry: StoredNormalizedFeedEntry) throws {
        let allEntries = try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>())
        if let canonicalURL = entry.canonicalURL {
            for duplicate in allEntries where duplicate.id != entry.id && duplicate.subscriptionID == entry.subscriptionID && duplicate.canonicalURL == canonicalURL {
                context.delete(duplicate)
            }
        }
        if let existing = allEntries.first(where: { $0.id == entry.id }) {
            existing.subscriptionID = entry.subscriptionID
            existing.title = entry.title
            existing.summaryText = entry.summaryText
            existing.canonicalURL = entry.canonicalURL
            existing.author = entry.author
            existing.publicationDate = entry.publicationDate
            existing.updatedDate = entry.updatedDate
            existing.retrievedAt = entry.retrievedAt
            existing.originalPosition = entry.originalPosition
            existing.formatIdentifier = entry.formatIdentifier
            existing.upstreamIdentifier = entry.upstreamIdentifier
            existing.identityBasis = entry.identityBasis
            existing.encodedEntry = entry.encodedEntry
        } else {
            context.insert(entry)
        }
    }

    func pruneFeedEntries(now: Date, retentionDays: Int, maximumPerFeed: Int) throws {
        let cutoff = now.addingTimeInterval(-Double(max(1, retentionDays)) * 86_400)
        let all = try context.fetch(FetchDescriptor<StoredNormalizedFeedEntry>())
        let grouped = Dictionary(grouping: all, by: \.subscriptionID)
        for entries in grouped.values {
            let sorted = entries.sorted {
                let lhs = $0.publicationDate ?? $0.updatedDate ?? $0.retrievedAt
                let rhs = $1.publicationDate ?? $1.updatedDate ?? $1.retrievedAt
                if lhs != rhs { return lhs > rhs }
                return $0.id < $1.id
            }
            for (index, entry) in sorted.enumerated() {
                let effectiveDate = entry.publicationDate ?? entry.updatedDate ?? entry.retrievedAt
                if effectiveDate < cutoff || index >= max(1, maximumPerFeed) { context.delete(entry) }
            }
        }
        try context.save()
    }

    func recordBriefAssembly(_ assembly: StoredBriefAssembly) throws {
        if let existing = try context.fetch(FetchDescriptor<StoredBriefAssembly>()).first(where: { $0.id == assembly.id }) {
            existing.generatedAt = assembly.generatedAt
            existing.selectedEntryCount = assembly.selectedEntryCount
            existing.excludedEntryCount = assembly.excludedEntryCount
            existing.enabledSourceCount = assembly.enabledSourceCount
            existing.failureNotes = assembly.failureNotes
        } else {
            context.insert(assembly)
        }
        try context.save()
    }

    func modelSelection() throws -> StoredModelSelectionRecord {
        if let existing = try context.fetch(FetchDescriptor<StoredModelSelectionRecord>()).first { return existing }
        let created = StoredModelSelectionRecord(); context.insert(created); try context.save(); return created
    }

    func localModels() throws -> [StoredLocalModelDescriptor] {
        try context.fetch(FetchDescriptor<StoredLocalModelDescriptor>()).sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func replaceLocalModels(with models: [StoredLocalModelDescriptor]) throws {
        for model in try context.fetch(FetchDescriptor<StoredLocalModelDescriptor>()) { context.delete(model) }
        for model in models { context.insert(model) }
        try context.save()
    }

    func upsertProviderSnapshot(_ snapshot: StoredModelProviderSnapshotP2) throws {
        if let existing = try context.fetch(FetchDescriptor<StoredModelProviderSnapshotP2>()).first(where: { $0.id == snapshot.id }) {
            existing.stateRaw = snapshot.stateRaw
            existing.checkedAt = snapshot.checkedAt
            existing.lastSuccessfulCheckAt = snapshot.lastSuccessfulCheckAt ?? existing.lastSuccessfulCheckAt
            existing.serviceVersion = snapshot.serviceVersion ?? existing.serviceVersion
            existing.failureCode = snapshot.failureCode
            existing.failureMessage = snapshot.failureMessage
        } else {
            context.insert(snapshot)
        }
        try context.save()
    }

    func providerSnapshot(id: String = "ollama") throws -> StoredModelProviderSnapshotP2? {
        try context.fetch(FetchDescriptor<StoredModelProviderSnapshotP2>()).first(where: { $0.id == id })
    }

    func recordGenerationProvenance(_ provenance: StoredGenerationProvenanceRecord) throws {
        context.insert(provenance)
        try context.save()
        let all = try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()).sorted {
            if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
            return $0.id < $1.id
        }
        for record in all.dropFirst(FeedLimits.maximumGenerationProvenanceRecords) { context.delete(record) }
        if all.count > FeedLimits.maximumGenerationProvenanceRecords { try context.save() }
    }

    func generationProvenance(briefID: String) throws -> StoredGenerationProvenanceRecord? {
        try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()).first(where: { $0.briefID == briefID })
    }

    func latestGenerationProvenance() throws -> StoredGenerationProvenanceRecord? {
        try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()).sorted {
            if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
            return $0.id < $1.id
        }.first
    }

    func latestSuccessfulLocalGenerationProvenance() throws -> StoredGenerationProvenanceRecord? {
        try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>())
            .filter {
                $0.providerKind == "ollama"
                    && $0.completionStatus == OllamaGenerationCompletionStatus.success.rawValue
            }
            .sorted {
                if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
                return $0.id < $1.id
            }
            .first
    }

    func seedFoundationSnapshots() throws {
        var existing = Dictionary(uniqueKeysWithValues: try context.fetch(FetchDescriptor<StoredStateSnapshot>()).map { ($0.id, $0) })
        for source in FoundationCatalog.sources { upsertSnapshot(id: "source:\(source.id)", domain: "source", state: source.state.rawValue, existing: &existing) }
        for provider in FoundationCatalog.providers { upsertSnapshot(id: "provider:\(provider.id)", domain: "provider", state: provider.state.rawValue, existing: &existing) }
        try context.save()
    }

    private func upsertSnapshot(id: String, domain: String, state: String, existing: inout [String: StoredStateSnapshot]) {
        if let snapshot = existing[id] { snapshot.domain = domain; snapshot.state = state; snapshot.capturedAt = .now }
        else { let snapshot = StoredStateSnapshot(id: id, domain: domain, state: state); context.insert(snapshot); existing[id] = snapshot }
    }

    private func pruneBriefHistory(referenceDate: Date) throws {
        let cutoff = referenceDate.addingTimeInterval(-Double(FeedLimits.briefHistoryRetentionDays) * 86_400)
        let all = try context.fetch(FetchDescriptor<StoredBrief>()).sorted {
            if $0.generatedAt != $1.generatedAt { return $0.generatedAt > $1.generatedAt }
            return $0.id < $1.id
        }
        var removedIDs: Set<String> = []
        for (index, brief) in all.enumerated() where brief.generatedAt < cutoff || index >= FeedLimits.maximumBriefHistoryRecords {
            removedIDs.insert(brief.id)
            context.delete(brief)
        }
        guard !removedIDs.isEmpty else { return }
        for assembly in try context.fetch(FetchDescriptor<StoredBriefAssembly>()) where removedIDs.contains(assembly.id) { context.delete(assembly) }
        for provenance in try context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()) where removedIDs.contains(provenance.briefID) { context.delete(provenance) }
        for identifier in removedIDs {
            try deleteLocalCalendarDay(ownerType: .brief, ownerIdentifier: identifier)
        }
        try context.save()
    }

    func deleteAllLocalData() throws {
        try context.delete(model: StoredReadState.self); try context.delete(model: StoredBrief.self)
        try context.delete(model: StoredStateSnapshot.self); try context.delete(model: StoredSettings.self)
        try context.delete(model: StoredFeedSubscription.self); try context.delete(model: StoredFeedFetch.self)
        try context.delete(model: StoredNormalizedFeedEntry.self); try context.delete(model: StoredBriefAssembly.self)
        try context.delete(model: StoredModelProviderSnapshotP2.self); try context.delete(model: StoredLocalModelDescriptor.self)
        try context.delete(model: StoredModelSelectionRecord.self); try context.delete(model: StoredGenerationProvenanceRecord.self)
        try context.delete(model: StoredP2Settings.self)
        try context.delete(model: StoredSlackWorkspaceConnection.self)
        try context.delete(model: StoredSlackConversationSelection.self)
        try context.delete(model: StoredSlackMessageEvidence.self)
        try context.delete(model: StoredSlackSyncCursor.self)
        try context.delete(model: StoredSlackSyncRun.self)
        try context.delete(model: StoredSlackDeletionTombstone.self)
        try context.delete(model: StoredVaultAccount.self)
        try context.delete(model: StoredVaultContainer.self)
        try context.delete(model: StoredVaultSyncPolicy.self)
        try context.delete(model: StoredVaultBackfillSummary.self)
        try context.delete(model: StoredVaultBackfillCursor.self)
        try context.delete(model: StoredVaultStorageSnapshot.self)
        try context.delete(model: StoredVaultRetentionPolicy.self)
        try context.delete(model: StoredVaultEntitlement.self)
        try context.delete(model: StoredVaultDeletionRecord.self)
        try context.delete(model: StoredVaultImportCheckpoint.self)
        try context.delete(model: StoredBriefSchedule.self)
        try context.delete(model: StoredScheduleOccurrence.self)
        try context.delete(model: StoredScheduledBriefingRun.self)
        try context.delete(model: StoredScheduledBriefingSourceResult.self)
        try context.delete(model: StoredNotificationDeliverySettings.self)
        try context.delete(model: StoredDeliveryRecord.self)
        try context.delete(model: StoredLocalCalendarDay.self)
        try context.delete(model: StoredLokiChatSettings.self)
        try context.delete(model: StoredLokiChatWorkspacePolicy.self)
        try context.delete(model: StoredLokiConversation.self)
        try context.delete(model: StoredLokiMessage.self)
        try context.delete(model: StoredLokiChatContextSelection.self)
        try context.delete(model: StoredLokiEvidenceReference.self)
        try context.delete(model: StoredLokiToolReceipt.self)
        try context.delete(model: StoredLokiGenerationProvenance.self)
        try context.delete(model: StoredLokiModelAssessment.self)
        try context.delete(model: StoredLokiChatModelSelection.self)
        try context.delete(model: StoredModelRoleAssignment.self)
        try context.delete(model: StoredModelRoutingReceipt.self)
        try context.delete(model: StoredModelReasoningReceipt.self)
        try context.delete(model: StoredP8ModelRoleMigrationState.self)
        try context.delete(model: StoredOllamaWebResearchConversationPolicy.self)
        try context.delete(model: StoredOllamaWebResearchSettings.self)
        try context.delete(model: StoredConnectorSyncReceipt.self)
        try context.delete(model: StoredConnectorStatus.self)
        try context.delete(model: StoredEmailImportAccess.self)
        try context.delete(model: StoredAttachedDataSourceReceipt.self)
        try context.delete(model: StoredAttachedDataSource.self)
        try context.save()
    }
}
