import Foundation
import SwiftData

enum SlackPersistenceError: LocalizedError, Equatable {
    case selectionLimitExceeded
    case invalidWorkspaceIdentifier
    case invalidConversationIdentifier
    case invalidWeight
    case invalidPermalink

    var errorDescription: String? {
        switch self {
        case .selectionLimitExceeded:
            "Select at most \(SlackPersistenceLimits.maximumSelectedChannels) Slack channels per workspace."
        case .invalidWorkspaceIdentifier:
            "Slack workspace metadata is invalid."
        case .invalidConversationIdentifier:
            "Slack channel metadata is invalid."
        case .invalidWeight:
            "Slack channel weight must be a finite value between 0.5 and 2.0."
        case .invalidPermalink:
            "Slack returned an invalid message link."
        }
    }
}

extension LocalStore {
    private var p3Context: ModelContext { container.mainContext }

    func slackWorkspaceConnections() throws -> [StoredSlackWorkspaceConnection] {
        try p3Context.fetch(FetchDescriptor<StoredSlackWorkspaceConnection>()).sorted {
            if $0.teamName != $1.teamName { return $0.teamName.localizedCaseInsensitiveCompare($1.teamName) == .orderedAscending }
            return $0.id < $1.id
        }
    }

    func slackWorkspaceConnection(id: String) throws -> StoredSlackWorkspaceConnection? {
        try slackWorkspaceConnections().first(where: { $0.id == id })
    }

    func upsertSlackWorkspace(_ incoming: StoredSlackWorkspaceConnection) throws {
        guard !incoming.id.isEmpty, !incoming.teamID.isEmpty, !incoming.userID.isEmpty else { throw SlackPersistenceError.invalidWorkspaceIdentifier }
        if let existing = try slackWorkspaceConnection(id: incoming.id) {
            existing.teamID = incoming.teamID
            existing.userID = incoming.userID
            existing.teamName = String(incoming.teamName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            existing.userDisplayName = String(incoming.userDisplayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            existing.connectionStateRaw = incoming.connectionStateRaw
            existing.grantedScopes = incoming.grantedScopes
            existing.tokenType = incoming.tokenType
            existing.credentialIssuedAt = incoming.credentialIssuedAt
            existing.accessExpiresAt = incoming.accessExpiresAt
            existing.credentialSchemaVersion = incoming.credentialSchemaVersion
            existing.enabled = incoming.enabled
            existing.localModelConsent = incoming.localModelConsent
            existing.lastSuccessfulRefresh = incoming.lastSuccessfulRefresh
            existing.lastFailureCode = incoming.lastFailureCode
            existing.lastFailureMessage = incoming.lastFailureMessage.map { String($0.prefix(240)) }
            existing.rateLimitedUntil = incoming.rateLimitedUntil
            existing.updatedAt = incoming.updatedAt
        } else {
            incoming.teamName = String(incoming.teamName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            incoming.userDisplayName = String(incoming.userDisplayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            incoming.localModelConsent = false
            p3Context.insert(incoming)
        }
        try p3Context.save()
    }

    func setSlackWorkspaceEnabled(id: String, enabled: Bool, stateRaw: String) throws {
        guard let workspace = try slackWorkspaceConnection(id: id) else { throw SlackPersistenceError.invalidWorkspaceIdentifier }
        workspace.enabled = enabled
        workspace.connectionStateRaw = stateRaw
        workspace.updatedAt = .now
        try p3Context.save()
    }

    func setSlackLocalModelConsent(workspaceID: String, enabled: Bool) throws {
        guard let workspace = try slackWorkspaceConnection(id: workspaceID) else { throw SlackPersistenceError.invalidWorkspaceIdentifier }
        workspace.localModelConsent = enabled
        workspace.updatedAt = .now
        try p3Context.save()
    }

    func slackConversationSelections(workspaceID: String) throws -> [StoredSlackConversationSelection] {
        try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>())
            .filter { $0.workspaceID == workspaceID }
            .sorted {
                if $0.selected != $1.selected { return $0.selected && !$1.selected }
                if $0.displayName != $1.displayName { return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
                return $0.id < $1.id
            }
    }

    func upsertSlackConversation(_ incoming: StoredSlackConversationSelection) throws {
        guard !incoming.workspaceID.isEmpty, !incoming.conversationID.isEmpty else { throw SlackPersistenceError.invalidConversationIdentifier }
        guard incoming.weight.isFinite else { throw SlackPersistenceError.invalidWeight }
        let all = try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>())
        if incoming.selected {
            let selectedCount = all.filter { $0.workspaceID == incoming.workspaceID && $0.selected && $0.id != incoming.id }.count
            guard selectedCount < SlackPersistenceLimits.maximumSelectedChannels else { throw SlackPersistenceError.selectionLimitExceeded }
        }
        if let existing = all.first(where: { $0.id == incoming.id }) {
            existing.displayName = String(incoming.displayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            existing.kindRaw = incoming.kindRaw
            existing.isMember = incoming.isMember
            existing.selected = incoming.selected
            existing.enabled = incoming.enabled
            existing.weight = min(max(incoming.weight, 0.5), 2)
            existing.lastSuccessfulRefresh = incoming.lastSuccessfulRefresh
            existing.lastFailureCode = incoming.lastFailureCode
            existing.updatedAt = incoming.updatedAt
        } else {
            incoming.displayName = String(incoming.displayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            p3Context.insert(incoming)
        }
        try p3Context.save()
    }

    func setSlackConversationSelected(id: String, selected: Bool) throws {
        let all = try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>())
        guard let conversation = all.first(where: { $0.id == id }) else { throw SlackPersistenceError.invalidConversationIdentifier }
        if selected {
            let selectedCount = all.filter { $0.workspaceID == conversation.workspaceID && $0.selected && $0.id != id }.count
            guard selectedCount < SlackPersistenceLimits.maximumSelectedChannels else { throw SlackPersistenceError.selectionLimitExceeded }
        }
        conversation.selected = selected
        conversation.updatedAt = .now
        try p3Context.save()
    }

    func setSlackConversationEnabled(id: String, enabled: Bool) throws {
        guard let conversation = try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>())
            .first(where: { $0.id == id })
        else { throw SlackPersistenceError.invalidConversationIdentifier }
        conversation.enabled = enabled
        conversation.updatedAt = .now
        try p3Context.save()
    }

    func recordSlackConversationRefresh(
        id: String,
        successfulAt: Date?,
        failureReasonCode: String?
    ) throws {
        guard let conversation = try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>())
            .first(where: { $0.id == id })
        else { throw SlackPersistenceError.invalidConversationIdentifier }
        if let successfulAt {
            conversation.lastSuccessfulRefresh = successfulAt
            conversation.lastFailureCode = nil
        } else if let failureReasonCode {
            let normalized = failureReasonCode.trimmingCharacters(in: .whitespacesAndNewlines)
            conversation.lastFailureCode = normalized.isEmpty
                ? nil
                : String(normalized.prefix(SlackPersistenceLimits.maximumFailureReasonCodeCharacters))
        }
        conversation.updatedAt = .now
        try p3Context.save()
    }

    func setSlackConversationWeight(id: String, weight: Double) throws {
        guard let conversation = try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>()).first(where: { $0.id == id }) else { throw SlackPersistenceError.invalidConversationIdentifier }
        guard weight.isFinite else { throw SlackPersistenceError.invalidWeight }
        conversation.weight = min(max(weight, 0.5), 2)
        conversation.updatedAt = .now
        try p3Context.save()
    }

    func slackMessageEvidence(workspaceID: String? = nil) throws -> [StoredSlackMessageEvidence] {
        let all = try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>())
        return all
            .filter { $0.tombstonedAt == nil && (workspaceID == nil || $0.workspaceID == workspaceID) }
            .sorted {
                if $0.messageDate != $1.messageDate { return $0.messageDate > $1.messageDate }
                return $0.id < $1.id
            }
    }

    func upsertSlackMessageEvidence(_ incoming: StoredSlackMessageEvidence) throws {
        let all = try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>())
        if let existing = all.first(where: { $0.id == incoming.id }) {
            existing.workspaceName = incoming.workspaceName
            existing.conversationName = incoming.conversationName
            existing.conversationKindRaw = incoming.conversationKindRaw
            existing.messageTimestamp = incoming.messageTimestamp
            existing.messageDate = incoming.messageDate
            existing.excerpt = String(incoming.excerpt.prefix(SlackPersistenceLimits.maximumExcerptCharacters))
            existing.authorID = incoming.authorID
            existing.authorDisplayName = String(incoming.authorDisplayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
            existing.authorKindRaw = incoming.authorKindRaw
            existing.directlyMentionsCurrentUser = incoming.directlyMentionsCurrentUser
            existing.replyCount = max(0, incoming.replyCount)
            existing.isEdited = incoming.isEdited
            existing.editedAt = incoming.editedAt
            existing.permalink = try validatedSlackPermalink(incoming.permalink)
            existing.retrievedAt = incoming.retrievedAt
            existing.channelWeight = min(max(incoming.channelWeight, 0.5), 2)
            existing.tombstonedAt = incoming.tombstonedAt
        } else {
            incoming.permalink = try validatedSlackPermalink(incoming.permalink)
            p3Context.insert(incoming)
        }
        try p3Context.save()
        try pruneSlackEvidence(workspaceID: incoming.workspaceID, conversationID: incoming.conversationID, referenceDate: incoming.retrievedAt)
    }

    func tombstoneSlackMessage(id: String, workspaceID: String, conversationID: String, messageTimestamp: String, reasonCode: String, at date: Date = .now) throws {
        for evidence in try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>()) where evidence.id == id {
            evidence.excerpt = ""
            evidence.permalink = nil
            evidence.tombstonedAt = date
        }
        let tombstoneID = "slack-tombstone:\(workspaceID):\(conversationID):\(messageTimestamp)"
        if try p3Context.fetch(FetchDescriptor<StoredSlackDeletionTombstone>()).contains(where: { $0.id == tombstoneID }) == false {
            p3Context.insert(StoredSlackDeletionTombstone(id: tombstoneID, workspaceID: workspaceID, conversationID: conversationID, messageTimestamp: messageTimestamp, deletedAt: date, reasonCode: reasonCode))
        }
        try p3Context.save()
    }

    func slackSyncCursor(workspaceID: String, conversationID: String) throws -> StoredSlackSyncCursor? {
        try p3Context.fetch(FetchDescriptor<StoredSlackSyncCursor>()).first(where: { $0.workspaceID == workspaceID && $0.conversationID == conversationID })
    }

    func upsertSlackSyncCursor(_ incoming: StoredSlackSyncCursor) throws {
        if let existing = try slackSyncCursor(workspaceID: incoming.workspaceID, conversationID: incoming.conversationID) {
            existing.committedOldest = incoming.committedOldest
            existing.windowLatest = incoming.windowLatest
            existing.nextCursor = incoming.nextCursor
            existing.pendingHighWater = incoming.pendingHighWater
            existing.updatedAt = incoming.updatedAt
        } else {
            p3Context.insert(incoming)
        }
        try p3Context.save()
    }

    func recordSlackSyncRun(_ run: StoredSlackSyncRun) throws {
        p3Context.insert(run)
        try p3Context.save()
        let matching = try p3Context.fetch(FetchDescriptor<StoredSlackSyncRun>())
            .filter { $0.workspaceID == run.workspaceID }
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id < $1.id
            }
        for old in matching.dropFirst(SlackPersistenceLimits.maximumSyncRunsPerWorkspace) { p3Context.delete(old) }
        if matching.count > SlackPersistenceLimits.maximumSyncRunsPerWorkspace { try p3Context.save() }
    }

    func deleteSlackWorkspaceContent(workspaceID: String) throws {
        let evidenceIDs = Set(
            try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>())
                .filter { $0.workspaceID == workspaceID }
                .map(\.id)
        )
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackConversationSelection>()) where record.workspaceID == workspaceID { p3Context.delete(record) }
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>()) where record.workspaceID == workspaceID { p3Context.delete(record) }
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackSyncCursor>()) where record.workspaceID == workspaceID { p3Context.delete(record) }
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackSyncRun>()) where record.workspaceID == workspaceID { p3Context.delete(record) }
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackDeletionTombstone>()) where record.workspaceID == workspaceID { p3Context.delete(record) }
        try purgeSlackWorkspaceFromBriefHistory(workspaceID: workspaceID, evidenceIDs: evidenceIDs)
        try p3Context.save()
    }

    func deleteSlackWorkspaceData(workspaceID: String) throws {
        try deleteSlackWorkspaceContent(workspaceID: workspaceID)
        for record in try p3Context.fetch(FetchDescriptor<StoredSlackWorkspaceConnection>()) where record.id == workspaceID { p3Context.delete(record) }
        try p3Context.save()
    }

    private func validatedSlackPermalink(_ value: String?) throws -> String? {
        guard let value else { return nil }
        guard let url = URL(string: value), url.scheme == "https", let host = url.host?.lowercased(), host == "slack.com" || host.hasSuffix(".slack.com"), url.user == nil, url.password == nil else {
            throw SlackPersistenceError.invalidPermalink
        }
        return url.absoluteString
    }

    func pruneSlackEvidence(workspaceID: String, conversationID: String, referenceDate: Date) throws {
        let cutoff = referenceDate.addingTimeInterval(-Double(SlackPersistenceLimits.evidenceRetentionDays) * 86_400)
        let matching = try p3Context.fetch(FetchDescriptor<StoredSlackMessageEvidence>())
            .filter { $0.workspaceID == workspaceID && $0.conversationID == conversationID }
            .sorted {
                if $0.messageDate != $1.messageDate { return $0.messageDate > $1.messageDate }
                return $0.id < $1.id
            }
        for (index, record) in matching.enumerated() where record.messageDate < cutoff || index >= SlackPersistenceLimits.maximumEvidencePerChannel {
            p3Context.delete(record)
        }
        if matching.contains(where: { $0.messageDate < cutoff }) || matching.count > SlackPersistenceLimits.maximumEvidencePerChannel { try p3Context.save() }
    }

    private func purgeSlackWorkspaceFromBriefHistory(workspaceID: String, evidenceIDs: Set<String>) throws {
        let sourcePrefix = "slack:\(workspaceID):"
        var workspaceEvidenceIDs = evidenceIDs
        func belongsToDeletedWorkspace(_ item: BriefItem) -> Bool {
            guard item.source.kind == .slack else { return false }
            return item.slackAttribution?.workspaceID == workspaceID
                || item.source.id.hasPrefix(sourcePrefix)
                || workspaceEvidenceIDs.contains(item.id)
        }
        let storedBriefs = try p3Context.fetch(FetchDescriptor<StoredBrief>())
        var decodableBriefs: [(stored: StoredBrief, decoded: Brief)] = []
        for stored in storedBriefs {
            do {
                let decoded = try stored.decodedBrief()
                decodableBriefs.append((stored, decoded))
                workspaceEvidenceIDs.formUnion(
                    decoded.sections.flatMap(\.items)
                        .filter(belongsToDeletedWorkspace)
                        .map(\.id)
                )
            } catch {
                try deleteLocalCalendarDay(ownerType: .brief, ownerIdentifier: stored.id)
                p3Context.delete(stored)
            }
        }
        for (stored, decoded) in decodableBriefs {
            let removed = decoded.sections.contains { section in
                section.items.contains(where: belongsToDeletedWorkspace)
            }
            guard removed else { continue }
            let sections = decoded.sections.compactMap { section -> BriefSection? in
                let retained = section.items.filter { !belongsToDeletedWorkspace($0) }
                guard !retained.isEmpty else { return nil }
                return BriefSection(id: section.id, title: section.title, items: retained, summary: "\(retained.count) retained deterministic item\(retained.count == 1 ? "" : "s").")
            }
            let itemCount = sections.reduce(0) { $0 + $1.items.count }
            let sourceItemIDs = (decoded.generation.sourceItemIDs ?? []).filter { !workspaceEvidenceIDs.contains($0) }
            let scrubbed = Brief(
                id: decoded.id,
                date: decoded.date,
                title: decoded.title,
                summary: "\(itemCount) retained attributable item\(itemCount == 1 ? "" : "s") after Slack workspace deletion.",
                status: decoded.status,
                sections: sections,
                generation: .init(engineID: decoded.generation.engineID, generatedAt: decoded.generation.generatedAt, status: decoded.status, reasonCode: "slack_workspace_evidence_deleted", fixtureRevision: decoded.generation.fixtureRevision, providerKind: "deterministic", sourceItemIDs: sourceItemIDs, fallbackStatus: "slack_local_generation_purged", validationResult: "not_applicable"),
                partialFailureMessage: decoded.partialFailureMessage,
                briefingDay: decoded.resolvedBriefingDay
            )
            try stored.update(with: scrubbed)
        }
        for provenance in try p3Context.fetch(FetchDescriptor<StoredGenerationProvenanceRecord>()) {
            guard let sourceItemIDs = try? JSONDecoder().decode([String].self, from: provenance.sourceItemIdentifiers),
                  sourceItemIDs.contains(where: workspaceEvidenceIDs.contains)
            else { continue }
            p3Context.delete(provenance)
        }
    }
}

extension SlackWorkspaceConnection {
    static func stableID(teamID: String, userID: String) -> String { "\(teamID):\(userID)" }
}

extension LocalStore {
    func domainSlackWorkspaces() throws -> [SlackWorkspaceConnection] {
        try slackWorkspaceConnections().map { stored in
            let scopes = Set(stored.grantedScopes.split(separator: ",").compactMap { SlackGrantedScope(rawValue: String($0)) })
            return SlackWorkspaceConnection(
                id: stored.id,
                teamID: stored.teamID,
                teamName: stored.teamName,
                userID: stored.userID,
                userDisplayName: stored.userDisplayName,
                state: SlackConnectionState(rawValue: stored.connectionStateRaw) ?? .degraded,
                grantedScopes: scopes,
                credentialMetadata: SlackCredentialMetadata(tokenType: stored.tokenType, issuedAt: stored.credentialIssuedAt, accessExpiration: stored.accessExpiresAt, grantedScopes: scopes, schemaVersion: stored.credentialSchemaVersion),
                localModelConsent: stored.localModelConsent,
                connectedAt: stored.createdAt,
                updatedAt: stored.updatedAt,
                lastFailureReasonCode: stored.lastFailureCode
            )
        }
    }

    func persistSlackWorkspace(_ workspace: SlackWorkspaceConnection, enabled: Bool = true, lastSuccessfulRefresh: Date? = nil, rateLimitedUntil: Date? = nil) throws {
        let scopes = workspace.grantedScopes.map(\.rawValue).sorted().joined(separator: ",")
        let metadata = workspace.credentialMetadata
        try upsertSlackWorkspace(StoredSlackWorkspaceConnection(
            id: workspace.id,
            teamID: workspace.teamID,
            userID: workspace.userID,
            teamName: workspace.teamName,
            userDisplayName: workspace.userDisplayName,
            connectionStateRaw: workspace.state.rawValue,
            grantedScopes: scopes,
            tokenType: metadata?.tokenType ?? "user",
            credentialIssuedAt: metadata?.issuedAt ?? workspace.connectedAt,
            accessExpiresAt: metadata?.accessExpiration ?? workspace.updatedAt,
            credentialSchemaVersion: metadata?.schemaVersion ?? 1,
            enabled: enabled,
            localModelConsent: workspace.localModelConsent,
            lastSuccessfulRefresh: lastSuccessfulRefresh,
            lastFailureCode: workspace.lastFailureReasonCode,
            rateLimitedUntil: rateLimitedUntil,
            createdAt: workspace.connectedAt,
            updatedAt: workspace.updatedAt
        ))
    }

    func domainSlackSelections(workspaceID: String) throws -> [SlackConversationSelection] {
        try slackConversationSelections(workspaceID: workspaceID).filter(\.selected).map { stored in
            SlackConversationSelection(
                workspaceID: stored.workspaceID,
                channelID: stored.conversationID,
                displayName: stored.displayName,
                kind: SlackConversationKind(rawValue: stored.kindRaw) ?? .publicChannel,
                enabled: stored.enabled,
                weight: stored.weight,
                selectedAt: stored.createdAt,
                lastSuccessfulRefreshAt: stored.lastSuccessfulRefresh,
                lastFailureReasonCode: stored.lastFailureCode
            )
        }
    }

    func persistDiscoveredSlackConversations(_ conversations: [SlackConversation], workspaceID: String) throws {
        let existing = Dictionary(uniqueKeysWithValues: try slackConversationSelections(workspaceID: workspaceID).map { ($0.conversationID, $0) })
        for conversation in conversations where !conversation.isArchived {
            let prior = existing[conversation.id]
            try upsertSlackConversation(StoredSlackConversationSelection(
                id: "\(workspaceID):\(conversation.id)",
                workspaceID: workspaceID,
                conversationID: conversation.id,
                displayName: conversation.displayName,
                kindRaw: conversation.kind.rawValue,
                isMember: conversation.isMember,
                selected: prior?.selected ?? false,
                enabled: prior?.enabled ?? true,
                weight: prior?.weight ?? 1,
                lastSuccessfulRefresh: prior?.lastSuccessfulRefresh,
                lastFailureCode: prior?.lastFailureCode,
                createdAt: prior?.createdAt ?? conversation.discoveredAt,
                updatedAt: conversation.discoveredAt
            ))
        }
    }

    func domainSlackEvidence(workspaceID: String? = nil) throws -> [SlackMessageEvidence] {
        try slackMessageEvidence(workspaceID: workspaceID).compactMap { stored in
            guard let timestamp = SlackTimestamp(rawValue: stored.messageTimestamp) else { return nil }
            let permalink = stored.permalink.flatMap(URL.init(string:))
            return SlackMessageEvidence(
                id: stored.id,
                workspaceID: stored.workspaceID,
                workspaceName: stored.workspaceName,
                channelID: stored.conversationID,
                channelName: stored.conversationName,
                channelKind: SlackConversationKind(rawValue: stored.conversationKindRaw) ?? .publicChannel,
                messageTimestamp: timestamp,
                excerpt: stored.excerpt,
                author: SlackMessageAuthor(id: stored.authorID ?? "unknown", displayName: stored.authorDisplayName, kind: SlackMessageAuthorKind(rawValue: stored.authorKindRaw) ?? .unknown, isDeleted: false),
                directlyMentionsAuthenticatedUser: stored.directlyMentionsCurrentUser,
                replyCount: stored.replyCount,
                isEdited: stored.isEdited,
                editedAt: stored.editedAt.flatMap(SlackTimestamp.init(rawValue:)),
                permalink: permalink,
                retrievedAt: stored.retrievedAt,
                selectedChannelWeight: stored.channelWeight,
                state: .available
            )
        }
    }

    func persistSlackEvidence(_ evidence: SlackMessageEvidence) throws {
        if evidence.state != .available {
            try tombstoneSlackMessage(id: evidence.id, workspaceID: evidence.workspaceID, conversationID: evidence.channelID, messageTimestamp: evidence.messageTimestamp.rawValue, reasonCode: evidence.state == .deleted ? "slack_message_deleted" : "slack_message_inaccessible", at: evidence.retrievedAt)
            return
        }
        try upsertSlackMessageEvidence(StoredSlackMessageEvidence(
            id: evidence.id,
            workspaceID: evidence.workspaceID,
            workspaceName: evidence.workspaceName,
            conversationID: evidence.channelID,
            conversationName: evidence.channelName,
            conversationKindRaw: evidence.channelKind.rawValue,
            messageTimestamp: evidence.messageTimestamp.rawValue,
            messageDate: evidence.messageTimestamp.date,
            excerpt: evidence.excerpt,
            authorID: evidence.author.id == "unknown" ? nil : evidence.author.id,
            authorDisplayName: evidence.author.displayName,
            authorKindRaw: evidence.author.kind.rawValue,
            directlyMentionsCurrentUser: evidence.directlyMentionsAuthenticatedUser,
            replyCount: evidence.replyCount,
            isEdited: evidence.isEdited,
            editedAt: evidence.editedAt?.rawValue,
            permalink: evidence.permalink?.absoluteString,
            retrievedAt: evidence.retrievedAt,
            channelWeight: evidence.selectedChannelWeight
        ))
    }

    func domainSlackCursor(workspaceID: String, conversationID: String) throws -> SlackSyncCursor? {
        guard let stored = try slackSyncCursor(workspaceID: workspaceID, conversationID: conversationID) else { return nil }
        return SlackSyncCursor(
            workspaceID: stored.workspaceID,
            channelID: stored.conversationID,
            committedOldest: stored.committedOldest.flatMap(SlackTimestamp.init(rawValue:)),
            windowLatest: stored.windowLatest.flatMap(SlackTimestamp.init(rawValue:)),
            nextCursor: stored.nextCursor,
            pendingHighWater: stored.pendingHighWater.flatMap(SlackTimestamp.init(rawValue:)),
            updatedAt: stored.updatedAt
        )
    }

    func persistSlackCursor(_ cursor: SlackSyncCursor) throws {
        try upsertSlackSyncCursor(StoredSlackSyncCursor(
            id: cursor.id,
            workspaceID: cursor.workspaceID,
            conversationID: cursor.channelID,
            committedOldest: cursor.committedOldest?.rawValue,
            windowLatest: cursor.windowLatest?.rawValue,
            nextCursor: cursor.nextCursor,
            pendingHighWater: cursor.pendingHighWater?.rawValue,
            updatedAt: cursor.updatedAt
        ))
    }

    func persistSlackSyncRun(_ run: SlackSyncRun) throws {
        let codes = run.channelResults.compactMap(\.failureReasonCode).sorted().joined(separator: ",")
        try recordSlackSyncRun(StoredSlackSyncRun(
            id: run.id,
            workspaceID: run.workspaceID,
            traceID: run.traceID,
            startedAt: run.startedAt,
            completedAt: run.completedAt,
            stateRaw: run.state.rawValue,
            selectedChannelCount: run.selectedChannelCount,
            successfulChannelCount: run.successfulChannelCount,
            failedChannelCount: run.failedChannelCount,
            normalizedMessageCount: run.normalizedMessageCount,
            rateLimitedUntil: run.rateLimitState?.retryAt,
            failureReasonCodes: codes
        ))
    }
}
