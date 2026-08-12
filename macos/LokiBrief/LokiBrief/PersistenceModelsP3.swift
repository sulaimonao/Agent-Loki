import Foundation
import SwiftData

@Model final class StoredSlackWorkspaceConnection {
    @Attribute(.unique) var id: String
    var teamID: String
    var userID: String
    var teamName: String
    var userDisplayName: String
    var connectionStateRaw: String
    var grantedScopes: String
    var tokenType: String
    var credentialIssuedAt: Date
    var accessExpiresAt: Date
    var credentialSchemaVersion: Int
    var enabled: Bool
    var localModelConsent: Bool
    var lastSuccessfulRefresh: Date?
    var lastFailureCode: String?
    var lastFailureMessage: String?
    var rateLimitedUntil: Date?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        teamID: String,
        userID: String,
        teamName: String,
        userDisplayName: String,
        connectionStateRaw: String,
        grantedScopes: String,
        tokenType: String,
        credentialIssuedAt: Date,
        accessExpiresAt: Date,
        credentialSchemaVersion: Int = 1,
        enabled: Bool = true,
        localModelConsent: Bool = false,
        lastSuccessfulRefresh: Date? = nil,
        lastFailureCode: String? = nil,
        lastFailureMessage: String? = nil,
        rateLimitedUntil: Date? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.teamID = teamID
        self.userID = userID
        self.teamName = teamName
        self.userDisplayName = userDisplayName
        self.connectionStateRaw = connectionStateRaw
        self.grantedScopes = grantedScopes
        self.tokenType = tokenType
        self.credentialIssuedAt = credentialIssuedAt
        self.accessExpiresAt = accessExpiresAt
        self.credentialSchemaVersion = credentialSchemaVersion
        self.enabled = enabled
        self.localModelConsent = localModelConsent
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastFailureCode = lastFailureCode
        self.lastFailureMessage = lastFailureMessage
        self.rateLimitedUntil = rateLimitedUntil
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StoredSlackConversationSelection {
    @Attribute(.unique) var id: String
    var workspaceID: String
    var conversationID: String
    var displayName: String
    var kindRaw: String
    var isMember: Bool
    var selected: Bool
    var enabled: Bool
    var weight: Double
    var lastSuccessfulRefresh: Date?
    var lastFailureCode: String?
    var createdAt: Date
    var updatedAt: Date

    init(
        id: String,
        workspaceID: String,
        conversationID: String,
        displayName: String,
        kindRaw: String,
        isMember: Bool,
        selected: Bool = false,
        enabled: Bool = true,
        weight: Double = 1,
        lastSuccessfulRefresh: Date? = nil,
        lastFailureCode: String? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.displayName = displayName
        self.kindRaw = kindRaw
        self.isMember = isMember
        self.selected = selected
        self.enabled = enabled
        self.weight = weight.isFinite ? min(max(weight, 0.5), 2) : 1
        self.lastSuccessfulRefresh = lastSuccessfulRefresh
        self.lastFailureCode = lastFailureCode
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model final class StoredSlackMessageEvidence {
    @Attribute(.unique) var id: String
    var workspaceID: String
    var workspaceName: String
    var conversationID: String
    var conversationName: String
    var conversationKindRaw: String
    var messageTimestamp: String
    var messageDate: Date
    var excerpt: String
    var authorID: String?
    var authorDisplayName: String
    var authorKindRaw: String
    var directlyMentionsCurrentUser: Bool
    var replyCount: Int
    var isEdited: Bool
    var editedAt: String?
    var permalink: String?
    var retrievedAt: Date
    var channelWeight: Double
    var tombstonedAt: Date?

    init(
        id: String,
        workspaceID: String,
        workspaceName: String,
        conversationID: String,
        conversationName: String,
        conversationKindRaw: String,
        messageTimestamp: String,
        messageDate: Date,
        excerpt: String,
        authorID: String?,
        authorDisplayName: String,
        authorKindRaw: String,
        directlyMentionsCurrentUser: Bool,
        replyCount: Int,
        isEdited: Bool,
        editedAt: String?,
        permalink: String?,
        retrievedAt: Date,
        channelWeight: Double,
        tombstonedAt: Date? = nil
    ) {
        self.id = id
        self.workspaceID = workspaceID
        self.workspaceName = workspaceName
        self.conversationID = conversationID
        self.conversationName = conversationName
        self.conversationKindRaw = conversationKindRaw
        self.messageTimestamp = messageTimestamp
        self.messageDate = messageDate
        self.excerpt = String(excerpt.prefix(SlackPersistenceLimits.maximumExcerptCharacters))
        self.authorID = authorID
        self.authorDisplayName = String(authorDisplayName.prefix(SlackPersistenceLimits.maximumDisplayNameCharacters))
        self.authorKindRaw = authorKindRaw
        self.directlyMentionsCurrentUser = directlyMentionsCurrentUser
        self.replyCount = max(0, replyCount)
        self.isEdited = isEdited
        self.editedAt = editedAt
        self.permalink = permalink
        self.retrievedAt = retrievedAt
        self.channelWeight = channelWeight.isFinite ? min(max(channelWeight, 0.5), 2) : 1
        self.tombstonedAt = tombstonedAt
    }
}

@Model final class StoredSlackSyncCursor {
    @Attribute(.unique) var id: String
    var workspaceID: String
    var conversationID: String
    var committedOldest: String?
    var windowLatest: String?
    var nextCursor: String?
    var pendingHighWater: String?
    var updatedAt: Date

    init(id: String, workspaceID: String, conversationID: String, committedOldest: String? = nil, windowLatest: String? = nil, nextCursor: String? = nil, pendingHighWater: String? = nil, updatedAt: Date = .now) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.committedOldest = committedOldest
        self.windowLatest = windowLatest
        self.nextCursor = nextCursor
        self.pendingHighWater = pendingHighWater
        self.updatedAt = updatedAt
    }
}

@Model final class StoredSlackSyncRun {
    @Attribute(.unique) var id: String
    var workspaceID: String
    var traceID: String
    var startedAt: Date
    var completedAt: Date?
    var stateRaw: String
    var selectedChannelCount: Int
    var successfulChannelCount: Int
    var failedChannelCount: Int
    var normalizedMessageCount: Int
    var rateLimitedUntil: Date?
    var failureReasonCodes: String

    init(id: String, workspaceID: String, traceID: String, startedAt: Date, completedAt: Date? = nil, stateRaw: String, selectedChannelCount: Int, successfulChannelCount: Int = 0, failedChannelCount: Int = 0, normalizedMessageCount: Int = 0, rateLimitedUntil: Date? = nil, failureReasonCodes: String = "") {
        self.id = id
        self.workspaceID = workspaceID
        self.traceID = traceID
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.stateRaw = stateRaw
        self.selectedChannelCount = max(0, selectedChannelCount)
        self.successfulChannelCount = max(0, successfulChannelCount)
        self.failedChannelCount = max(0, failedChannelCount)
        self.normalizedMessageCount = max(0, normalizedMessageCount)
        self.rateLimitedUntil = rateLimitedUntil
        self.failureReasonCodes = failureReasonCodes
    }
}

@Model final class StoredSlackDeletionTombstone {
    @Attribute(.unique) var id: String
    var workspaceID: String
    var conversationID: String
    var messageTimestamp: String
    var deletedAt: Date
    var reasonCode: String

    init(id: String, workspaceID: String, conversationID: String, messageTimestamp: String, deletedAt: Date = .now, reasonCode: String) {
        self.id = id
        self.workspaceID = workspaceID
        self.conversationID = conversationID
        self.messageTimestamp = messageTimestamp
        self.deletedAt = deletedAt
        self.reasonCode = reasonCode
    }
}

enum SlackPersistenceLimits {
    static let maximumSelectedChannels = 20
    static let maximumExcerptCharacters = 500
    static let maximumDisplayNameCharacters = 120
    static let maximumFailureReasonCodeCharacters = 120
    static let maximumEvidencePerChannel = 200
    static let maximumSyncRunsPerWorkspace = 30
    static let evidenceRetentionDays = 30
}

// A pre-seal P3 build persisted Slack evidence before `editedAt` was added while
// retaining the 3.0.0 version identifier. Keep that exact model shape in the
// migration chain so those stores are recognized and upgraded without reset.
enum LokiBriefSchemaV3PreEditedAt: VersionedSchema {
    static let versionIdentifier = Schema.Version(2, 9, 0)

    @Model final class StoredSlackMessageEvidence {
        @Attribute(.unique) var id: String
        var workspaceID: String
        var workspaceName: String
        var conversationID: String
        var conversationName: String
        var conversationKindRaw: String
        var messageTimestamp: String
        var messageDate: Date
        var excerpt: String
        var authorID: String?
        var authorDisplayName: String
        var authorKindRaw: String
        var directlyMentionsCurrentUser: Bool
        var replyCount: Int
        var isEdited: Bool
        var permalink: String?
        var retrievedAt: Date
        var channelWeight: Double
        var tombstonedAt: Date?

        init(
            id: String,
            workspaceID: String,
            workspaceName: String,
            conversationID: String,
            conversationName: String,
            conversationKindRaw: String,
            messageTimestamp: String,
            messageDate: Date,
            excerpt: String,
            authorID: String?,
            authorDisplayName: String,
            authorKindRaw: String,
            directlyMentionsCurrentUser: Bool,
            replyCount: Int,
            isEdited: Bool,
            permalink: String?,
            retrievedAt: Date,
            channelWeight: Double,
            tombstonedAt: Date? = nil
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.workspaceName = workspaceName
            self.conversationID = conversationID
            self.conversationName = conversationName
            self.conversationKindRaw = conversationKindRaw
            self.messageTimestamp = messageTimestamp
            self.messageDate = messageDate
            self.excerpt = excerpt
            self.authorID = authorID
            self.authorDisplayName = authorDisplayName
            self.authorKindRaw = authorKindRaw
            self.directlyMentionsCurrentUser = directlyMentionsCurrentUser
            self.replyCount = replyCount
            self.isEdited = isEdited
            self.permalink = permalink
            self.retrievedAt = retrievedAt
            self.channelWeight = channelWeight
            self.tombstonedAt = tombstonedAt
        }
    }

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV2.models + [
            StoredSlackWorkspaceConnection.self,
            StoredSlackConversationSelection.self,
            StoredSlackMessageEvidence.self,
            StoredSlackSyncCursor.self,
            StoredSlackSyncRun.self,
            StoredSlackDeletionTombstone.self,
        ]
    }
}

enum LokiBriefSchemaV3: VersionedSchema {
    static let versionIdentifier = Schema.Version(3, 0, 0)
    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV2.models + [
            StoredSlackWorkspaceConnection.self,
            StoredSlackConversationSelection.self,
            StoredSlackMessageEvidence.self,
            StoredSlackSyncCursor.self,
            StoredSlackSyncRun.self,
            StoredSlackDeletionTombstone.self,
        ]
    }
}
