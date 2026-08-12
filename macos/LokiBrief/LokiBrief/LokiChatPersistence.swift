import Foundation
import SwiftData

enum LokiChatPersistenceError: Error, LocalizedError, Equatable {
    case invalidIdentifier
    case invalidPagination
    case conversationUnavailable
    case messageConversationMismatch
    case unsupportedPersistedRole
    case messageTooLarge
    case titleTooLarge
    case contextIdentifierTooLarge
    case evidenceInvalid
    case sourceEvidenceNotAllowed
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .invalidIdentifier:
            "A chat record identifier was empty or outside the bounded storage contract."
        case .invalidPagination:
            "The requested conversation page was outside the bounded storage contract."
        case .conversationUnavailable:
            "That local conversation is no longer available."
        case .messageConversationMismatch:
            "A message did not belong to the conversation being stored."
        case .unsupportedPersistedRole:
            "Only user-visible user and assistant messages may be stored."
        case .messageTooLarge:
            "The user-visible message exceeded the local storage bound."
        case .titleTooLarge:
            "The conversation title exceeded the local storage bound."
        case .contextIdentifierTooLarge:
            "The selected context identifier exceeded the local storage bound."
        case .evidenceInvalid:
            "The evidence reference did not satisfy the bounded local storage contract."
        case .sourceEvidenceNotAllowed:
            "The selected source is not allowed in Agent Loki Chat."
        case .encodingFailed:
            "Agent Loki could not encode bounded local chat metadata."
        }
    }
}

extension StoredLokiChatSettings {
    var domainSettings: LokiChatPrivacySettings {
        LokiChatPrivacySettings(
            storeLocalHistory: storeLocalHistory,
            retentionPolicy: LokiChatRetentionPolicy(rawValue: retentionPolicyRaw) ?? .ninetyDays,
            customRetentionDays: customRetentionDays,
            includeSourceExcerpts: includeSourceExcerpts,
            allowFeedEvidence: allowFeedEvidence
        ).normalized()
    }

    func update(from settings: LokiChatPrivacySettings, at date: Date) {
        let normalized = settings.normalized()
        storeLocalHistory = normalized.storeLocalHistory
        retentionPolicyRaw = normalized.retentionPolicy.rawValue
        customRetentionDays = normalized.customRetentionDays
        includeSourceExcerpts = normalized.includeSourceExcerpts
        allowFeedEvidence = normalized.allowFeedEvidence
        updatedAt = date
    }
}

@MainActor
extension LocalStore {
    func lokiChatPrivacySettings() throws -> LokiChatPrivacySettings {
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatSettings>()).first {
            return existing.domainSettings
        }
        let created = StoredLokiChatSettings()
        context.insert(created)
        try context.save()
        return created.domainSettings
    }

    func updateLokiChatPrivacySettings(
        _ settings: LokiChatPrivacySettings,
        at date: Date = .now
    ) throws {
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatSettings>()).first {
            existing.update(from: settings, at: date)
        } else {
            let created = StoredLokiChatSettings(updatedAt: date)
            created.update(from: settings, at: date)
            context.insert(created)
        }

        if !settings.includeSourceExcerpts {
            for reference in try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>()) {
                reference.boundedExcerpt = nil
            }
        }
        try context.save()
    }

    func lokiChatWorkspaceEvidencePolicy(
        workspaceIdentifier: String
    ) throws -> LokiChatWorkspaceEvidencePolicy {
        try validateIdentifier(workspaceIdentifier)
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatWorkspacePolicy>())
            .first(where: { $0.workspaceIdentifier == workspaceIdentifier }) {
            return .init(
                workspaceIdentifier: existing.workspaceIdentifier,
                allowSelectedSlackEvidence: existing.allowSelectedSlackEvidence,
                updatedAt: existing.updatedAt
            )
        }
        return .defaultPolicy(workspaceIdentifier: workspaceIdentifier)
    }

    func updateLokiChatWorkspaceEvidencePolicy(
        _ policy: LokiChatWorkspaceEvidencePolicy
    ) throws {
        try validateIdentifier(policy.workspaceIdentifier)
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatWorkspacePolicy>())
            .first(where: { $0.workspaceIdentifier == policy.workspaceIdentifier }) {
            existing.allowSelectedSlackEvidence = policy.allowSelectedSlackEvidence
            existing.updatedAt = policy.updatedAt
        } else {
            context.insert(StoredLokiChatWorkspacePolicy(
                workspaceIdentifier: policy.workspaceIdentifier,
                allowSelectedSlackEvidence: policy.allowSelectedSlackEvidence,
                updatedAt: policy.updatedAt
            ))
        }
        try context.save()
    }

    @discardableResult
    func persistLokiConversation(_ conversation: LokiConversation) throws -> Bool {
        guard try lokiChatPrivacySettings().storeLocalHistory else { return false }
        try validateIdentifier(conversation.id)
        guard conversation.title.count <= LokiChatLimits.maximumConversationTitleCharacters else {
            throw LokiChatPersistenceError.titleTooLarge
        }
        try validateContext(conversation.context)
        let visibleMessages = conversation.messages.filter(\.role.isUserVisiblePersistedRole)
        for message in visibleMessages {
            guard message.conversationID == conversation.id else {
                throw LokiChatPersistenceError.messageConversationMismatch
            }
            try validateIdentifier(message.id)
            guard message.visibleText.count <= LokiChatLimits.maximumMessageCharacters else {
                throw LokiChatPersistenceError.messageTooLarge
            }
            _ = try encodeBounded(message.answerSegments)
        }

        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiConversation>())
            .first(where: { $0.id == conversation.id }) {
            existing.title = conversation.title
            existing.updatedAt = conversation.updatedAt
            existing.contextScopeRaw = conversation.context.scope.rawValue
            existing.contextTargetIdentifier = conversation.context.targetIdentifier
            existing.contextSelectedAt = conversation.context.selectedAt
        } else {
            context.insert(StoredLokiConversation(
                id: conversation.id,
                title: conversation.title,
                createdAt: conversation.createdAt,
                updatedAt: conversation.updatedAt,
                contextScopeRaw: conversation.context.scope.rawValue,
                contextTargetIdentifier: conversation.context.targetIdentifier,
                contextSelectedAt: conversation.context.selectedAt
            ))
        }
        try context.save()
        for message in visibleMessages {
            _ = try persistLokiMessage(message)
        }
        return true
    }

    @discardableResult
    func persistLokiMessage(_ message: LokiMessage) throws -> Bool {
        guard try lokiChatPrivacySettings().storeLocalHistory else { return false }
        try validateIdentifier(message.id)
        try validateIdentifier(message.conversationID)
        guard message.role.isUserVisiblePersistedRole else {
            throw LokiChatPersistenceError.unsupportedPersistedRole
        }
        guard message.visibleText.count <= LokiChatLimits.maximumMessageCharacters else {
            throw LokiChatPersistenceError.messageTooLarge
        }
        let encodedSegments = try encodeBounded(message.answerSegments)
        let context = container.mainContext
        guard let conversation = try context.fetch(FetchDescriptor<StoredLokiConversation>())
            .first(where: { $0.id == message.conversationID }) else {
            throw LokiChatPersistenceError.conversationUnavailable
        }

        let existing = try context.fetch(FetchDescriptor<StoredLokiMessage>())
            .first(where: { $0.id == message.id })
        if let existing {
            guard existing.conversationID == message.conversationID else {
                throw LokiChatPersistenceError.messageConversationMismatch
            }
            existing.sequence = message.sequence
            existing.roleRaw = message.role.rawValue
            existing.stateRaw = message.state.rawValue
            existing.visibleText = message.visibleText
            existing.answerSegmentsData = encodedSegments
            existing.updatedAt = message.updatedAt
            existing.completedAt = message.completedAt
            existing.failureCodeRaw = message.failure?.code.rawValue
            existing.failureRecoverable = message.failure?.isRecoverable ?? false
            existing.failureMessage = message.failure?.consumerMessage
            existing.retryOfMessageID = message.retryOfMessageID
            existing.isPartial = message.isPartial
        } else {
            context.insert(StoredLokiMessage(
                id: message.id,
                conversationID: message.conversationID,
                sequence: message.sequence,
                roleRaw: message.role.rawValue,
                stateRaw: message.state.rawValue,
                visibleText: message.visibleText,
                answerSegmentsData: encodedSegments,
                createdAt: message.createdAt,
                updatedAt: message.updatedAt,
                completedAt: message.completedAt,
                failureCodeRaw: message.failure?.code.rawValue,
                failureRecoverable: message.failure?.isRecoverable ?? false,
                failureMessage: message.failure?.consumerMessage,
                retryOfMessageID: message.retryOfMessageID,
                isPartial: message.isPartial
            ))
            conversation.messageCount += 1
        }
        conversation.updatedAt = max(conversation.updatedAt, message.updatedAt)
        try context.save()
        return true
    }

    @discardableResult
    func persistLokiChatContextSelection(
        id: String,
        conversationID: String,
        requestMessageID: String,
        context selectedContext: LokiChatContext,
        tokenEstimate: Int,
        wasTruncated: Bool
    ) throws -> Bool {
        guard try lokiChatPrivacySettings().storeLocalHistory else { return false }
        try validateIdentifier(id)
        try validateIdentifier(conversationID)
        try validateIdentifier(requestMessageID)
        try validateContext(selectedContext)
        let model = StoredLokiChatContextSelection(
            id: id,
            conversationID: conversationID,
            requestMessageID: requestMessageID,
            scopeRaw: selectedContext.scope.rawValue,
            targetIdentifier: selectedContext.targetIdentifier,
            selectedAt: selectedContext.selectedAt,
            tokenEstimate: max(0, tokenEstimate),
            wasTruncated: wasTruncated
        )
        let context = container.mainContext
        try validateStoredMessage(
            conversationID: conversationID,
            messageID: requestMessageID,
            context: context
        )
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatContextSelection>())
            .first(where: { $0.id == id }) {
            existing.scopeRaw = model.scopeRaw
            existing.targetIdentifier = model.targetIdentifier
            existing.selectedAt = model.selectedAt
            existing.tokenEstimate = model.tokenEstimate
            existing.wasTruncated = model.wasTruncated
        } else {
            context.insert(model)
        }
        try context.save()
        return true
    }

    @discardableResult
    func persistLokiEvidenceReference(
        _ reference: LokiEvidenceReference,
        conversationID: String,
        messageID: String
    ) throws -> Bool {
        let settings = try lokiChatPrivacySettings()
        guard settings.storeLocalHistory else { return false }
        try validateIdentifier(conversationID)
        try validateIdentifier(messageID)
        guard !reference.id.isEmpty,
              !reference.itemIdentifier.isEmpty,
              !reference.displayLabel.isEmpty,
              reference.id.count <= LokiChatLimits.maximumEvidenceIdentifierCharacters,
              reference.itemIdentifier.count <= LokiChatLimits.maximumEvidenceIdentifierCharacters,
              reference.displayLabel.count <= LokiChatLimits.maximumEvidenceLabelCharacters
        else { throw LokiChatPersistenceError.evidenceInvalid }
        try validateEvidencePolicy(reference, settings: settings)

        let compositeID = evidenceStorageIdentifier(
            messageID: messageID,
            referenceID: reference.id
        )
        let storedExcerpt = settings.includeSourceExcerpts
            ? reference.boundedExcerpt.map {
                String($0.prefix(LokiChatLimits.maximumStoredEvidenceExcerptCharacters))
            }
            : nil
        let directURL = reference.directSourceURL?.scheme?.lowercased() == "https"
            ? reference.directSourceURL?.absoluteString
            : nil
        let context = container.mainContext
        try validateStoredMessage(
            conversationID: conversationID,
            messageID: messageID,
            context: context
        )
        if let existing = try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
            .first(where: { $0.id == compositeID }) {
            existing.sourceKindRaw = reference.sourceKind.rawValue
            existing.accountClassification = reference.accountClassification
            existing.accountIdentifier = reference.accountIdentifier
            existing.containerClassification = reference.containerClassification
            existing.containerIdentifier = reference.containerIdentifier
            existing.itemIdentifier = reference.itemIdentifier
            existing.sourceTimestamp = reference.sourceTimestamp
            existing.retrievedAt = reference.retrievedAt
            existing.localVaultIdentifier = reference.localVaultIdentifier
            existing.displayLabel = reference.displayLabel
            existing.boundedExcerpt = storedExcerpt
            existing.directSourceURLString = directURL
            existing.trustClassificationRaw = reference.trustClassification.rawValue
        } else {
            context.insert(StoredLokiEvidenceReference(
                id: compositeID,
                referenceIdentifier: reference.id,
                conversationID: conversationID,
                messageID: messageID,
                sourceKindRaw: reference.sourceKind.rawValue,
                accountClassification: reference.accountClassification,
                accountIdentifier: reference.accountIdentifier,
                containerClassification: reference.containerClassification,
                containerIdentifier: reference.containerIdentifier,
                itemIdentifier: reference.itemIdentifier,
                sourceTimestamp: reference.sourceTimestamp,
                retrievedAt: reference.retrievedAt,
                localVaultIdentifier: reference.localVaultIdentifier,
                displayLabel: reference.displayLabel,
                boundedExcerpt: storedExcerpt,
                directSourceURLString: directURL,
                trustClassificationRaw: reference.trustClassification.rawValue
            ))
        }
        try context.save()
        return true
    }

    @discardableResult
    func persistLokiToolReceipt(
        _ receipt: LokiChatToolReceipt,
        conversationID: String,
        messageID: String
    ) throws -> Bool {
        guard try lokiChatPrivacySettings().storeLocalHistory else { return false }
        try validateIdentifier(receipt.id)
        try validateIdentifier(conversationID)
        try validateIdentifier(messageID)
        let evidenceData = try encodeBounded(receipt.evidenceReferenceIDs)
        let argumentKeysData = try encodeBounded(receipt.argumentKeys.sorted())
        let context = container.mainContext
        try validateStoredMessage(
            conversationID: conversationID,
            messageID: messageID,
            context: context
        )
        let stored = StoredLokiToolReceipt(
            id: receipt.id,
            conversationID: conversationID,
            messageID: messageID,
            requestIdentifier: receipt.requestIdentifier,
            toolName: receipt.toolName,
            status: receipt.status,
            reasonCode: receipt.reasonCode,
            requestedAt: receipt.requestedAt,
            completedAt: receipt.completedAt,
            durationMilliseconds: receipt.durationMilliseconds,
            resultCount: max(0, receipt.resultCount),
            evidenceReferenceIDsData: evidenceData,
            argumentKeysData: argumentKeysData
        )
        if let existing = try context.fetch(FetchDescriptor<StoredLokiToolReceipt>())
            .first(where: { $0.id == receipt.id }) {
            existing.status = stored.status
            existing.reasonCode = stored.reasonCode
            existing.completedAt = stored.completedAt
            existing.durationMilliseconds = stored.durationMilliseconds
            existing.resultCount = stored.resultCount
            existing.evidenceReferenceIDsData = stored.evidenceReferenceIDsData
            existing.argumentKeysData = stored.argumentKeysData
        } else {
            context.insert(stored)
        }
        try context.save()
        return true
    }

    @discardableResult
    func persistLokiGenerationProvenance(
        _ provenance: LokiGenerationProvenance,
        conversationID: String,
        messageID: String
    ) throws -> Bool {
        guard try lokiChatPrivacySettings().storeLocalHistory else { return false }
        try validateIdentifier(conversationID)
        try validateIdentifier(messageID)
        let context = container.mainContext
        try validateStoredMessage(
            conversationID: conversationID,
            messageID: messageID,
            context: context
        )
        if let existing = try context.fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
            .first(where: { $0.messageID == messageID }) {
            existing.completedAt = provenance.completedAt
            existing.durationMilliseconds = provenance.durationMilliseconds
            existing.promptTokenEstimate = provenance.promptTokenEstimate
            existing.completionTokenCount = provenance.completionTokenCount
            existing.evidenceCount = max(0, provenance.evidenceCount)
            existing.status = provenance.status
            existing.reasonCode = provenance.reasonCode
        } else {
            context.insert(StoredLokiGenerationProvenance(
                messageID: messageID,
                conversationID: conversationID,
                provider: provenance.provider,
                modelIdentifier: provenance.modelIdentifier,
                assessmentVersion: provenance.assessmentVersion,
                promptTemplateVersion: provenance.promptTemplateVersion,
                toolSchemaVersion: provenance.toolSchemaVersion,
                startedAt: provenance.startedAt,
                completedAt: provenance.completedAt,
                durationMilliseconds: provenance.durationMilliseconds,
                promptTokenEstimate: provenance.promptTokenEstimate,
                completionTokenCount: provenance.completionTokenCount,
                evidenceCount: max(0, provenance.evidenceCount),
                status: provenance.status,
                reasonCode: provenance.reasonCode
            ))
        }
        try context.save()
        return true
    }

    func deleteLokiCompletionArtifacts(messageID: String) throws {
        try validateIdentifier(messageID)
        let context = container.mainContext
        try context.transaction {
            for row in try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
            where row.messageID == messageID {
                context.delete(row)
            }
            for row in try context.fetch(FetchDescriptor<StoredLokiToolReceipt>())
            where row.messageID == messageID {
                context.delete(row)
            }
            for row in try context.fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
            where row.messageID == messageID {
                context.delete(row)
            }
        }
    }

    func upsertLokiModelAssessment(_ assessment: LokiModelAssessmentRecord) throws {
        try validateIdentifier(assessment.id)
        try validateIdentifier(assessment.provider)
        try validateIdentifier(assessment.modelIdentifier)
        try validateIdentifier(assessment.assessmentVersion)
        if let providerVersion = assessment.providerVersion {
            try validateIdentifier(providerVersion)
        }
        if let modelDigest = assessment.modelDigest {
            try validateIdentifier(modelDigest)
        }
        let context = container.mainContext
        let provenData = try encodeBounded(assessment.provenCapabilities)
        let missingData = try encodeBounded(assessment.missingCapabilities)
        let diagnosticsData = try encodeBounded(assessment.diagnosticReasonCodes)
        let capabilityAssessmentData = try encodeBounded(assessment.assessment)
        if let existing = try context.fetch(FetchDescriptor<StoredLokiModelAssessment>())
            .first(where: { $0.id == assessment.id }) {
            existing.provider = assessment.provider
            existing.providerVersion = assessment.providerVersion
            existing.modelIdentifier = assessment.modelIdentifier
            existing.modelDigest = assessment.modelDigest
            existing.assessmentVersion = assessment.assessmentVersion
            existing.readinessRaw = assessment.readiness.rawValue
            existing.provenCapabilitiesData = provenData
            existing.missingCapabilitiesData = missingData
            existing.contextWindowClassificationRaw = assessment.contextWindowClassification
            existing.assessedAt = assessment.assessedAt
            existing.durationMilliseconds = max(0, assessment.durationMilliseconds)
            existing.diagnosticReasonCodesData = diagnosticsData
            existing.capabilityAssessmentData = capabilityAssessmentData
            existing.schemaVersion = 2
        } else {
            context.insert(StoredLokiModelAssessment(
                id: assessment.id,
                provider: assessment.provider,
                providerVersion: assessment.providerVersion,
                modelIdentifier: assessment.modelIdentifier,
                modelDigest: assessment.modelDigest,
                assessmentVersion: assessment.assessmentVersion,
                readinessRaw: assessment.readiness.rawValue,
                provenCapabilitiesData: provenData,
                missingCapabilitiesData: missingData,
                contextWindowClassificationRaw: assessment.contextWindowClassification,
                assessedAt: assessment.assessedAt,
                durationMilliseconds: max(0, assessment.durationMilliseconds),
                diagnosticReasonCodesData: diagnosticsData,
                capabilityAssessmentData: capabilityAssessmentData
            ))
        }
        try context.save()
    }

    func lokiModelAssessments() throws -> [LokiModelAssessmentRecord] {
        try container.mainContext.fetch(FetchDescriptor<StoredLokiModelAssessment>())
            .map { stored in
                LokiModelAssessmentRecord(
                    id: stored.id,
                    readiness: ModelReadiness(rawValue: stored.readinessRaw) ?? .error,
                    assessment: try decodeBounded(
                        ModelCapabilityAssessment.self,
                        from: stored.capabilityAssessmentData
                    )
                )
            }
            .sorted {
                if $0.assessedAt != $1.assessedAt { return $0.assessedAt > $1.assessedAt }
                return $0.id < $1.id
            }
    }

    func lokiChatModelSelection() throws -> ChatModelSelection? {
        guard let stored = try container.mainContext
            .fetch(FetchDescriptor<StoredLokiChatModelSelection>())
            .first(where: { $0.id == "primary" }) else {
            return nil
        }
        return ChatModelSelection(
            provider: stored.provider,
            modelIdentifier: stored.modelIdentifier,
            modelDigest: stored.modelDigest,
            assessmentVersion: stored.assessmentVersion,
            selectedAt: stored.selectedAt
        )
    }

    func saveLokiChatModelSelection(_ selection: ChatModelSelection) throws {
        try validateIdentifier(selection.provider)
        try validateIdentifier(selection.modelIdentifier)
        try validateIdentifier(selection.assessmentVersion)
        if let modelDigest = selection.modelDigest {
            try validateIdentifier(modelDigest)
        }
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredLokiChatModelSelection>())
            .first(where: { $0.id == "primary" }) {
            existing.provider = selection.provider
            existing.modelIdentifier = selection.modelIdentifier
            existing.modelDigest = selection.modelDigest
            existing.assessmentVersion = selection.assessmentVersion
            existing.selectedAt = selection.selectedAt
        } else {
            context.insert(StoredLokiChatModelSelection(
                provider: selection.provider,
                modelIdentifier: selection.modelIdentifier,
                modelDigest: selection.modelDigest,
                assessmentVersion: selection.assessmentVersion,
                selectedAt: selection.selectedAt
            ))
        }
        try context.save()
    }

    func clearLokiChatModelSelection() throws {
        let context = container.mainContext
        for selection in try context.fetch(FetchDescriptor<StoredLokiChatModelSelection>()) {
            context.delete(selection)
        }
        try context.save()
    }

    func modelRoleAssignments() throws -> [ModelRoleAssignment] {
        try container.mainContext.fetch(FetchDescriptor<StoredModelRoleAssignment>())
            .map(domainModelRoleAssignment)
            .sorted { $0.role.rawValue < $1.role.rawValue }
    }

    func modelRoleAssignment(for role: ModelRole) throws -> ModelRoleAssignment? {
        guard let stored = try container.mainContext
            .fetch(FetchDescriptor<StoredModelRoleAssignment>())
            .first(where: { $0.id == role.rawValue }) else {
            return nil
        }
        return try domainModelRoleAssignment(stored)
    }

    func saveModelRoleAssignment(_ assignment: ModelRoleAssignment) throws {
        let assignment = try assignment.validatedForPersistence()
        let context = container.mainContext
        try upsertModelRoleAssignment(assignment, context: context)
        try context.save()
    }

    func saveModelRoleAssignments(_ assignments: [ModelRoleAssignment]) throws {
        guard Set(assignments.map(\.role)).count == assignments.count else {
            throw ModelRoleDomainError.invalidAssignment
        }
        let validated = try assignments.map { try $0.validatedForPersistence() }
        let context = container.mainContext
        try context.transaction {
            for assignment in validated {
                try upsertModelRoleAssignment(assignment, context: context)
            }
        }
    }

    func persistModelRoutingReceipt(_ receipt: ModelRoutingReceipt) throws {
        try validateIdentifier(receipt.id)
        try validateIdentifier(receipt.traceID)
        try validateIdentifier(receipt.spanID)
        guard !receipt.reasonCode.isEmpty,
              receipt.event == "model.routing.completed",
              receipt.component == "model_router"
        else { throw ModelRoleDomainError.invalidReceipt }
        switch receipt.status {
        case .ready:
            guard receipt.selectedRole != nil,
                  receipt.effectiveModelIdentifier != nil,
                  receipt.effectiveModelClassification == .local,
                  receipt.assessmentReceiptIdentifier != nil,
                  receipt.switchStatus != .blocked
            else { throw ModelRoleDomainError.invalidReceipt }
        case .blocked:
            guard receipt.selectedRole == nil,
                  receipt.effectiveModelIdentifier == nil,
                  receipt.switchStatus == .blocked
            else { throw ModelRoleDomainError.invalidReceipt }
        }

        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredModelRoutingReceipt>())
            .first(where: { $0.id == receipt.id }) {
            update(existing, from: receipt)
        } else {
            context.insert(storedModelRoutingReceipt(receipt))
        }
        try context.save()
        try pruneModelRoutingReceipts(limit: 2_000)
    }

    func modelRoutingReceipts(limit: Int = 200) throws -> [ModelRoutingReceipt] {
        guard limit > 0, limit <= 2_000 else {
            throw LokiChatPersistenceError.invalidPagination
        }
        return try container.mainContext.fetch(FetchDescriptor<StoredModelRoutingReceipt>())
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
            .prefix(limit)
            .map(domainModelRoutingReceipt)
    }

    func persistModelReasoningReceipt(_ receipt: ModelReasoningReceipt) throws {
        try validateIdentifier(receipt.id)
        try validateIdentifier(receipt.traceID)
        try validateIdentifier(receipt.modelIdentifier)
        try validateIdentifier(receipt.assessmentReceiptIdentifier)
        guard !receipt.reasonCode.isEmpty else {
            throw ModelRoleDomainError.invalidReceipt
        }
        let context = container.mainContext
        if let existing = try context.fetch(FetchDescriptor<StoredModelReasoningReceipt>())
            .first(where: { $0.id == receipt.id }) {
            update(existing, from: receipt)
        } else {
            context.insert(storedModelReasoningReceipt(receipt))
        }
        try context.save()
        try pruneModelReasoningReceipts(limit: 2_000)
    }

    func modelReasoningReceipts(limit: Int = 200) throws -> [ModelReasoningReceipt] {
        guard limit > 0, limit <= 2_000 else {
            throw LokiChatPersistenceError.invalidPagination
        }
        return try container.mainContext.fetch(FetchDescriptor<StoredModelReasoningReceipt>())
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id < $1.id
            }
            .prefix(limit)
            .map(domainModelReasoningReceipt)
    }

    func ollamaWebResearchGlobalSettings() throws -> OllamaWebResearchGlobalSettings {
        let context = container.mainContext
        if let stored = try context.fetch(FetchDescriptor<StoredOllamaWebResearchSettings>())
            .first(where: { $0.id == "primary" }) {
            return .init(
                providerEnabled: stored.providerEnabled,
                externalNetworkDisclosureAccepted:
                    stored.externalNetworkDisclosureAccepted,
                updatedAt: stored.updatedAt
            )
        }
        let defaults = OllamaWebResearchGlobalSettings.defaults()
        context.insert(StoredOllamaWebResearchSettings(
            providerEnabled: defaults.providerEnabled,
            externalNetworkDisclosureAccepted:
                defaults.externalNetworkDisclosureAccepted,
            updatedAt: defaults.updatedAt
        ))
        try context.save()
        return defaults
    }

    func updateOllamaWebResearchGlobalSettings(
        _ settings: OllamaWebResearchGlobalSettings
    ) throws {
        let context = container.mainContext
        if let stored = try context.fetch(FetchDescriptor<StoredOllamaWebResearchSettings>())
            .first(where: { $0.id == "primary" }) {
            stored.providerEnabled = settings.providerEnabled
            stored.externalNetworkDisclosureAccepted =
                settings.externalNetworkDisclosureAccepted
            stored.updatedAt = settings.updatedAt
            stored.schemaVersion = 1
        } else {
            context.insert(StoredOllamaWebResearchSettings(
                providerEnabled: settings.providerEnabled,
                externalNetworkDisclosureAccepted:
                    settings.externalNetworkDisclosureAccepted,
                updatedAt: settings.updatedAt
            ))
        }
        try context.save()
    }

    @discardableResult
    func clearOllamaWebResearchGlobalSettings(
        at date: Date = .now
    ) throws -> OllamaWebResearchGlobalSettings {
        let defaults = OllamaWebResearchGlobalSettings.defaults(at: date)
        try updateOllamaWebResearchGlobalSettings(defaults)
        return defaults
    }

    func ollamaWebResearchConversationPolicy(
        conversationIdentifier: String
    ) throws -> OllamaWebResearchConversationPolicy {
        try validateIdentifier(conversationIdentifier)
        let context = container.mainContext
        if let stored = try context
            .fetch(FetchDescriptor<StoredOllamaWebResearchConversationPolicy>())
            .first(where: { $0.conversationIdentifier == conversationIdentifier }) {
            return .init(
                conversationIdentifier: stored.conversationIdentifier,
                webResearchEnabled: stored.webResearchEnabled,
                updatedAt: stored.updatedAt
            )
        }
        let defaults = OllamaWebResearchConversationPolicy.defaults(
            conversationIdentifier: conversationIdentifier
        )
        context.insert(StoredOllamaWebResearchConversationPolicy(
            conversationIdentifier: defaults.conversationIdentifier,
            webResearchEnabled: defaults.webResearchEnabled,
            updatedAt: defaults.updatedAt
        ))
        try context.save()
        return defaults
    }

    func updateOllamaWebResearchConversationPolicy(
        _ policy: OllamaWebResearchConversationPolicy
    ) throws {
        try validateIdentifier(policy.conversationIdentifier)
        let context = container.mainContext
        if let stored = try context
            .fetch(FetchDescriptor<StoredOllamaWebResearchConversationPolicy>())
            .first(where: {
                $0.conversationIdentifier == policy.conversationIdentifier
            }) {
            stored.webResearchEnabled = policy.webResearchEnabled
            stored.updatedAt = policy.updatedAt
            stored.schemaVersion = 1
        } else {
            context.insert(StoredOllamaWebResearchConversationPolicy(
                conversationIdentifier: policy.conversationIdentifier,
                webResearchEnabled: policy.webResearchEnabled,
                updatedAt: policy.updatedAt
            ))
        }
        try context.save()
    }

    func clearOllamaWebResearchConversationPolicy(
        conversationIdentifier: String
    ) throws {
        try validateIdentifier(conversationIdentifier)
        let context = container.mainContext
        for stored in try context
            .fetch(FetchDescriptor<StoredOllamaWebResearchConversationPolicy>())
        where stored.conversationIdentifier == conversationIdentifier {
            context.delete(stored)
        }
        try context.save()
    }

    func clearAllOllamaWebResearchPersistence(
        at date: Date = .now
    ) throws {
        let context = container.mainContext
        try context.transaction {
            try context.delete(model: StoredOllamaWebResearchConversationPolicy.self)
            if let stored = try context
                .fetch(FetchDescriptor<StoredOllamaWebResearchSettings>())
                .first(where: { $0.id == "primary" }) {
                stored.providerEnabled = false
                stored.externalNetworkDisclosureAccepted = false
                stored.updatedAt = date
                stored.schemaVersion = 1
            } else {
                context.insert(StoredOllamaWebResearchSettings(updatedAt: date))
            }
        }
    }

    @discardableResult
    func reconcileP8ModelRoleMigration(
        at migratedAt: Date = .now
    ) throws -> P8ModelRoleMigrationReport {
        let context = container.mainContext
        if try context.fetch(FetchDescriptor<StoredP8ModelRoleMigrationState>())
            .contains(where: { $0.id == "v8-to-v9-model-roles" }) {
            return .alreadyCompleted
        }

        let legacyChatRow = try context.fetch(FetchDescriptor<StoredLokiChatModelSelection>())
            .first(where: { $0.id == "primary" })
        let legacySummaryRow = try context.fetch(FetchDescriptor<StoredModelSelectionRecord>())
            .first(where: { $0.id == "primary" })
        let legacyChat = legacyChatRow.map {
            LegacyModelPreference(
                provider: $0.provider,
                modelIdentifier: $0.modelIdentifier,
                modelDigest: $0.modelDigest,
                assessmentVersion: $0.assessmentVersion,
                selectedAt: $0.selectedAt
            )
        }
        let legacySummary: LegacyModelPreference?
        if let row = legacySummaryRow,
           let modelIdentifier = row.modelID,
           !modelIdentifier.isEmpty {
            legacySummary = LegacyModelPreference(
                provider: row.providerID,
                modelIdentifier: modelIdentifier,
                modelDigest: nil,
                assessmentVersion: nil,
                selectedAt: row.selectedAt ?? migratedAt
            )
        } else {
            legacySummary = nil
        }

        let storedAssessments = try context.fetch(FetchDescriptor<StoredLokiModelAssessment>())
        var decodedAssessments: [(id: String, assessment: ModelCapabilityAssessment)] = []
        decodedAssessments.reserveCapacity(storedAssessments.count)
        for stored in storedAssessments {
            decodedAssessments.append((
                id: stored.id,
                assessment: try decodeBounded(
                    ModelCapabilityAssessment.self,
                    from: stored.capabilityAssessmentData
                )
            ))
        }
        let candidates = try context.fetch(FetchDescriptor<StoredLocalModelDescriptor>())
            .map { stored -> ModelRoleCandidate in
                let receipt = decodedAssessments
                    .filter {
                        $0.assessment.provider == "ollama"
                            && $0.assessment.modelIdentifier.caseInsensitiveCompare(stored.id)
                                == .orderedSame
                    }
                    .sorted { $0.assessment.assessedAt > $1.assessment.assessedAt }
                    .first
                let assessment = receipt?.assessment
                return ModelRoleCandidate(
                    profile: ModelProfile(
                        provider: "ollama",
                        providerVersion: assessment?.providerVersion,
                        modelIdentifier: stored.id,
                        displayName: stored.displayName,
                        modelDigest: stored.digest,
                        locallyInstalled: true,
                        estimatedCapabilities: [],
                        contextPolicy: assessment?.contextPolicy
                            ?? ModelContextPolicy(declaredContextTokens: nil),
                        reasoningControl: assessment?.reasoningControl ?? .disabled,
                        observedAt: stored.discoveredAt
                    ),
                    assessmentReceiptIdentifier: receipt?.id,
                    assessment: assessment
                )
            }

        let assignments = ModelRoleMigrationPolicy.assignments(for: .init(
            legacyChatPreference: legacyChat,
            legacyBriefSummaryPreference: legacySummary,
            candidates: candidates,
            migratedAt: migratedAt
        ))
        let legacyGemma3Count = [legacyChat, legacySummary]
            .compactMap { $0 }
            .filter { ModelCuratedRolePolicy.isLegacyGemma3($0.modelIdentifier) }
            .count
        let report = P8ModelRoleMigrationReport(
            didRun: true,
            legacyChatPreferenceMigrated: legacyChat != nil,
            legacyBriefSummaryPreferenceMigrated: legacySummary != nil,
            legacyGemma3PreferenceCount: legacyGemma3Count,
            roleCount: assignments.count,
            readyRoleCount: assignments.filter {
                $0.readiness == ModelRoleReadiness.ready
            }.count,
            reasonCode: "p8_v8_to_v9_model_role_migration_complete"
        )
        let reportData = try encodeBounded(report)

        try context.transaction {
            for assignment in assignments {
                try upsertModelRoleAssignment(
                    try assignment.validatedForPersistence(),
                    context: context
                )
            }
            if let legacyChatRow,
               ModelCuratedRolePolicy.isLegacyGemma3(legacyChatRow.modelIdentifier) {
                let primary = assignments.first { $0.role == .primaryAgent }
                if let primary,
                   primary.readiness == .ready,
                   let provider = primary.effectiveProvider,
                   let modelIdentifier = primary.effectiveModelIdentifier {
                    legacyChatRow.provider = provider
                    legacyChatRow.modelIdentifier = modelIdentifier
                    legacyChatRow.modelDigest = primary.modelDigest
                    legacyChatRow.assessmentVersion =
                        ModelCapabilityAssessment.currentAssessmentVersion
                    legacyChatRow.selectedAt = migratedAt
                } else {
                    context.delete(legacyChatRow)
                }
            }
            if let legacySummaryRow,
               let modelIdentifier = legacySummaryRow.modelID,
               ModelCuratedRolePolicy.isLegacyGemma3(modelIdentifier) {
                let summary = assignments.first { $0.role == .briefSummary }
                if let summary,
                   summary.readiness == .ready,
                   let effectiveModelIdentifier = summary.effectiveModelIdentifier {
                    legacySummaryRow.providerID = summary.effectiveProvider ?? "ollama"
                    legacySummaryRow.modelID = effectiveModelIdentifier
                    legacySummaryRow.selectedAt = migratedAt
                } else {
                    legacySummaryRow.modelID = nil
                    legacySummaryRow.localGenerationEnabled = false
                    legacySummaryRow.selectedAt = nil
                }
            }
            if try context.fetch(FetchDescriptor<StoredOllamaWebResearchSettings>())
                .allSatisfy({ $0.id != "primary" }) {
                context.insert(StoredOllamaWebResearchSettings(updatedAt: migratedAt))
            }
            context.insert(StoredP8ModelRoleMigrationState(
                completedAt: migratedAt,
                reasonCode: report.reasonCode,
                reportData: reportData
            ))
        }
        return report
    }

    func deleteAllLokiP8ModelRoleData() throws {
        let context = container.mainContext
        try context.transaction {
            try context.delete(model: StoredModelRoutingReceipt.self)
            try context.delete(model: StoredModelReasoningReceipt.self)
            try context.delete(model: StoredModelRoleAssignment.self)
            try context.delete(model: StoredP8ModelRoleMigrationState.self)
        }
    }

    func lokiConversationPage(
        offset: Int = 0,
        limit: Int = LokiChatLimits.defaultConversationPageSize
    ) throws -> [LokiConversationSummary] {
        guard offset >= 0, limit > 0, limit <= LokiChatLimits.maximumConversationPageSize else {
            throw LokiChatPersistenceError.invalidPagination
        }
        let ordered = try container.mainContext.fetch(FetchDescriptor<StoredLokiConversation>())
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.id < $1.id
            }
        return ordered.dropFirst(offset).prefix(limit).map { stored in
            .init(
                id: stored.id,
                title: stored.title,
                updatedAt: stored.updatedAt,
                messageCount: stored.messageCount,
                contextScope: LokiChatContextScope(rawValue: stored.contextScopeRaw) ?? .today
            )
        }
    }

    func lokiConversation(id: String) throws -> LokiConversation? {
        try validateIdentifier(id)
        let context = container.mainContext
        guard let stored = try context.fetch(FetchDescriptor<StoredLokiConversation>())
            .first(where: { $0.id == id }) else { return nil }
        let messages = try context.fetch(FetchDescriptor<StoredLokiMessage>())
            .filter { $0.conversationID == id }
            .sorted {
                if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id < $1.id
            }
            .map(domainMessage)
        return LokiConversation(
            id: stored.id,
            title: stored.title,
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            context: .init(
                scope: LokiChatContextScope(rawValue: stored.contextScopeRaw) ?? .today,
                targetIdentifier: stored.contextTargetIdentifier,
                selectedAt: stored.contextSelectedAt
            ),
            messages: messages
        )
    }

    func lokiChatContextSelections(
        conversationID: String
    ) throws -> [LokiChatContextSelectionRecord] {
        try validateIdentifier(conversationID)
        return try container.mainContext.fetch(FetchDescriptor<StoredLokiChatContextSelection>())
            .filter { $0.conversationID == conversationID }
            .sorted {
                if $0.selectedAt != $1.selectedAt { return $0.selectedAt < $1.selectedAt }
                return $0.id < $1.id
            }
            .map {
                LokiChatContextSelectionRecord(
                    id: $0.id,
                    conversationID: $0.conversationID,
                    requestMessageID: $0.requestMessageID,
                    context: LokiChatContext(
                        scope: LokiChatContextScope(rawValue: $0.scopeRaw) ?? .today,
                        targetIdentifier: $0.targetIdentifier,
                        selectedAt: $0.selectedAt
                    ),
                    tokenEstimate: $0.tokenEstimate,
                    wasTruncated: $0.wasTruncated
                )
            }
    }

    func lokiEvidenceReferences(messageID: String) throws -> [LokiEvidenceReference] {
        try validateIdentifier(messageID)
        return try container.mainContext.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
            .filter { $0.messageID == messageID }
            .sorted {
                if $0.retrievedAt != $1.retrievedAt { return $0.retrievedAt < $1.retrievedAt }
                return $0.referenceIdentifier < $1.referenceIdentifier
            }
            .map(domainEvidenceReference)
    }

    func lokiToolReceipts(messageID: String) throws -> [LokiChatToolReceipt] {
        try validateIdentifier(messageID)
        return try container.mainContext.fetch(FetchDescriptor<StoredLokiToolReceipt>())
            .filter { $0.messageID == messageID }
            .sorted {
                if $0.requestedAt != $1.requestedAt { return $0.requestedAt < $1.requestedAt }
                return $0.id < $1.id
            }
            .map { stored in
                .init(
                    id: stored.id,
                    requestIdentifier: stored.requestIdentifier,
                    toolName: stored.toolName,
                    status: stored.status,
                    reasonCode: stored.reasonCode,
                    requestedAt: stored.requestedAt,
                    completedAt: stored.completedAt,
                    durationMilliseconds: stored.durationMilliseconds,
                    resultCount: stored.resultCount,
                    evidenceReferenceIDs: try decodeBounded(
                        [String].self,
                        from: stored.evidenceReferenceIDsData
                    ),
                    argumentKeys: try decodeBounded(
                        [String].self,
                        from: stored.argumentKeysData
                    )
                )
            }
    }

    func lokiGenerationProvenance(messageID: String) throws -> LokiGenerationProvenance? {
        try validateIdentifier(messageID)
        guard let stored = try container.mainContext
            .fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
            .first(where: { $0.messageID == messageID }) else { return nil }
        return .init(
            provider: stored.provider,
            modelIdentifier: stored.modelIdentifier,
            assessmentVersion: stored.assessmentVersion,
            promptTemplateVersion: stored.promptTemplateVersion,
            toolSchemaVersion: stored.toolSchemaVersion,
            startedAt: stored.startedAt,
            completedAt: stored.completedAt,
            durationMilliseconds: stored.durationMilliseconds,
            promptTokenEstimate: stored.promptTokenEstimate,
            completionTokenCount: stored.completionTokenCount,
            evidenceCount: stored.evidenceCount,
            status: stored.status,
            reasonCode: stored.reasonCode
        )
    }

    @discardableResult
    func reconcileInterruptedLokiChatMessages(at date: Date = .now) throws -> Int {
        let context = container.mainContext
        let messages = try context.fetch(FetchDescriptor<StoredLokiMessage>())
            .filter { LokiMessageState(rawValue: $0.stateRaw)?.isTransient == true }
        guard !messages.isEmpty else { return 0 }
        let interruptedMessageIDs = Set(messages.map(\.id))
        for reference in try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
        where interruptedMessageIDs.contains(reference.messageID) {
            context.delete(reference)
        }
        for receipt in try context.fetch(FetchDescriptor<StoredLokiToolReceipt>())
        where interruptedMessageIDs.contains(receipt.messageID) {
            context.delete(receipt)
        }
        for provenance in try context.fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
        where interruptedMessageIDs.contains(provenance.messageID) {
            context.delete(provenance)
        }
        for message in messages {
            message.stateRaw = LokiMessageState.interrupted.rawValue
            message.updatedAt = date
            message.completedAt = date
            message.isPartial = !message.visibleText.isEmpty
            message.failureCodeRaw = LokiConversationFailureCode.generationInterrupted.rawValue
            message.failureRecoverable = true
            message.failureMessage = "Generation stopped when Loki Brief closed. The truthful partial response was preserved."
        }
        try context.save()
        return messages.count
    }

    @discardableResult
    func enforceLokiChatRetention(
        referenceDate: Date = .now,
        excludingConversationIDs: Set<String> = []
    ) throws -> [String] {
        let settings = try lokiChatPrivacySettings()
        guard let days = settings.effectiveRetentionDays else { return [] }
        let cutoff = referenceDate.addingTimeInterval(-Double(days) * 86_400)
        let context = container.mainContext
        let expired = try context.fetch(FetchDescriptor<StoredLokiConversation>())
            .filter {
                $0.updatedAt < cutoff && !excludingConversationIDs.contains($0.id)
            }
            .map(\.id)
            .sorted()
        guard !expired.isEmpty else { return [] }
        try context.transaction {
            for identifier in expired {
                try deleteLokiConversationRows(id: identifier, context: context)
            }
        }
        return expired
    }

    func deleteLokiConversation(id: String) throws {
        try validateIdentifier(id)
        let context = container.mainContext
        try context.transaction {
            try deleteLokiConversationRows(id: id, context: context)
        }
    }

    func deleteAllLokiConversations() throws {
        let context = container.mainContext
        try context.transaction {
            try context.delete(model: StoredLokiChatContextSelection.self)
            try context.delete(model: StoredLokiEvidenceReference.self)
            try context.delete(model: StoredLokiToolReceipt.self)
            try context.delete(model: StoredLokiGenerationProvenance.self)
            try context.delete(model: StoredLokiMessage.self)
            try context.delete(model: StoredLokiConversation.self)
        }
    }

    func deleteAllLokiP7Data() throws {
        let context = container.mainContext
        try context.transaction {
            try context.delete(model: StoredLokiChatContextSelection.self)
            try context.delete(model: StoredLokiEvidenceReference.self)
            try context.delete(model: StoredLokiToolReceipt.self)
            try context.delete(model: StoredLokiGenerationProvenance.self)
            try context.delete(model: StoredLokiMessage.self)
            try context.delete(model: StoredLokiConversation.self)
            try context.delete(model: StoredLokiModelAssessment.self)
            try context.delete(model: StoredLokiChatModelSelection.self)
            try context.delete(model: StoredLokiChatWorkspacePolicy.self)
            try context.delete(model: StoredLokiChatSettings.self)
        }
    }

    @discardableResult
    func scrubLokiChatEvidence(
        sourceKind: LokiEvidenceSourceKind,
        accountIdentifier: String?,
        accountClassification: String? = nil,
        containerIdentifier: String? = nil,
        at date: Date = .now
    ) throws -> Int {
        let context = container.mainContext
        let references = try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
            .filter {
                $0.sourceKindRaw == sourceKind.rawValue
                    && (accountIdentifier == nil || $0.accountIdentifier == accountIdentifier)
                    && (accountClassification == nil || $0.accountClassification == accountClassification)
                    && (containerIdentifier == nil || $0.containerIdentifier == containerIdentifier)
            }
        let affectedMessageIDs = Set(references.map(\.messageID))
        guard !affectedMessageIDs.isEmpty else { return 0 }

        try context.transaction {
            for reference in references { context.delete(reference) }
            for receipt in try context.fetch(FetchDescriptor<StoredLokiToolReceipt>())
            where affectedMessageIDs.contains(receipt.messageID) {
                context.delete(receipt)
            }
            for provenance in try context.fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
            where affectedMessageIDs.contains(provenance.messageID) {
                context.delete(provenance)
            }
            for message in try context.fetch(FetchDescriptor<StoredLokiMessage>())
            where affectedMessageIDs.contains(message.id) && message.roleRaw == LokiMessageRole.assistant.rawValue {
                message.visibleText = "This response was removed because its supporting source evidence was deleted."
                message.answerSegmentsData = Data("[]".utf8)
                message.stateRaw = LokiMessageState.sourceEvidenceDeleted.rawValue
                message.updatedAt = date
                message.completedAt = date
                message.failureCodeRaw = LokiConversationFailureCode.sourceEvidenceDeleted.rawValue
                message.failureRecoverable = false
                message.failureMessage = "Supporting source evidence was deleted."
                message.isPartial = false
            }
        }
        return affectedMessageIDs.count
    }

    private func validateIdentifier(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= LokiChatLimits.maximumEvidenceIdentifierCharacters
        else { throw LokiChatPersistenceError.invalidIdentifier }
    }

    private func validateContext(_ context: LokiChatContext) throws {
        guard context.scope.isImplementedInP7 else {
            throw LokiChatPersistenceError.contextIdentifierTooLarge
        }
        guard (context.targetIdentifier?.count ?? 0) <= LokiChatLimits.maximumContextIdentifierCharacters else {
            throw LokiChatPersistenceError.contextIdentifierTooLarge
        }
    }

    private func validateStoredMessage(
        conversationID: String,
        messageID: String,
        context: ModelContext
    ) throws {
        guard try context.fetch(FetchDescriptor<StoredLokiConversation>())
            .contains(where: { $0.id == conversationID }),
              try context.fetch(FetchDescriptor<StoredLokiMessage>())
            .contains(where: {
                $0.id == messageID && $0.conversationID == conversationID
            })
        else {
            throw LokiChatPersistenceError.conversationUnavailable
        }
    }

    private func validateEvidencePolicy(
        _ reference: LokiEvidenceReference,
        settings: LokiChatPrivacySettings
    ) throws {
        switch reference.sourceKind {
        case .feed:
            guard settings.allowFeedEvidence,
                  let feedIdentifier = reference.accountIdentifier,
                  try feedEvidenceIsCurrentlyAuthorized(feedIdentifier)
            else {
                throw LokiChatPersistenceError.sourceEvidenceNotAllowed
            }
        case .slack:
            guard let workspaceIdentifier = reference.accountIdentifier,
                  let channelIdentifier = reference.containerIdentifier,
                  try slackEvidenceIsCurrentlyAuthorized(
                    workspaceIdentifier: workspaceIdentifier,
                    containerIdentifier: channelIdentifier,
                    vaultContainerIdentifier: false
                  )
            else {
                throw LokiChatPersistenceError.sourceEvidenceNotAllowed
            }
        case .vault:
            switch reference.accountClassification?.lowercased() {
            case VaultProviderKind.rss.rawValue:
                guard settings.allowFeedEvidence,
                      let containerIdentifier = reference.containerIdentifier,
                      try rssVaultContainerIsCurrentlyAuthorized(containerIdentifier)
                else {
                    throw LokiChatPersistenceError.sourceEvidenceNotAllowed
                }
            case VaultProviderKind.slack.rawValue:
                guard let archiveAccountIdentifier = reference.accountIdentifier,
                      let workspaceIdentifier = Self.providerAccountIdentifier(
                        fromVaultAccountIdentifier: archiveAccountIdentifier,
                        provider: VaultProviderKind.slack.rawValue
                      ),
                      let containerIdentifier = reference.containerIdentifier,
                      try slackEvidenceIsCurrentlyAuthorized(
                        workspaceIdentifier: workspaceIdentifier,
                        containerIdentifier: containerIdentifier,
                        vaultContainerIdentifier: true
                      )
                else {
                    throw LokiChatPersistenceError.sourceEvidenceNotAllowed
                }
            default:
                throw LokiChatPersistenceError.sourceEvidenceNotAllowed
            }
        case .connectedSourceStatus:
            switch reference.accountClassification {
            case "feed_subscription":
                guard settings.allowFeedEvidence,
                      let feedIdentifier = reference.accountIdentifier,
                      try feedEvidenceIsCurrentlyAuthorized(feedIdentifier)
                else {
                    throw LokiChatPersistenceError.sourceEvidenceNotAllowed
                }
            case "slack_workspace":
                guard let workspaceIdentifier = reference.accountIdentifier,
                      try slackEvidenceIsCurrentlyAuthorized(
                        workspaceIdentifier: workspaceIdentifier,
                        containerIdentifier: reference.containerIdentifier,
                        vaultContainerIdentifier: false
                      )
                else {
                    throw LokiChatPersistenceError.sourceEvidenceNotAllowed
                }
            default:
                throw LokiChatPersistenceError.sourceEvidenceNotAllowed
            }
        case .localAccountEvidence:
            guard reference.accountClassification == "slack_workspace",
                  let workspaceIdentifier = reference.accountIdentifier,
                  try slackEvidenceIsCurrentlyAuthorized(
                    workspaceIdentifier: workspaceIdentifier,
                    containerIdentifier: nil,
                    vaultContainerIdentifier: false
                  )
            else {
                throw LokiChatPersistenceError.sourceEvidenceNotAllowed
            }
        default:
            break
        }
    }

    private func feedEvidenceIsCurrentlyAuthorized(
        _ feedIdentifier: String
    ) throws -> Bool {
        try domainFeedSubscriptions().contains { $0.id == feedIdentifier }
    }

    private func rssVaultContainerIsCurrentlyAuthorized(
        _ containerIdentifier: String
    ) throws -> Bool {
        let accountIdentifier = VaultIdentity.accountID(
            provider: VaultProviderKind.rss.rawValue,
            providerAccountID: "local-feeds"
        )
        return try domainFeedSubscriptions().contains { subscription in
            containerIdentifier == VaultIdentity.containerID(
                provider: VaultProviderKind.rss.rawValue,
                accountID: accountIdentifier,
                providerContainerID: subscription.id
            )
        }
    }

    private func slackEvidenceIsCurrentlyAuthorized(
        workspaceIdentifier: String,
        containerIdentifier: String?,
        vaultContainerIdentifier: Bool
    ) throws -> Bool {
        guard try slackWorkspaceConnection(id: workspaceIdentifier)?
            .localModelConsent == true,
              try lokiChatWorkspaceEvidencePolicy(
                workspaceIdentifier: workspaceIdentifier
              ).allowSelectedSlackEvidence
        else { return false }
        guard let containerIdentifier else { return true }
        let archiveAccountIdentifier = VaultIdentity.accountID(
            provider: VaultProviderKind.slack.rawValue,
            providerAccountID: workspaceIdentifier
        )
        return try slackConversationSelections(workspaceID: workspaceIdentifier)
            .contains { selection in
                guard selection.selected else { return false }
                if vaultContainerIdentifier {
                    return containerIdentifier == VaultIdentity.containerID(
                        provider: VaultProviderKind.slack.rawValue,
                        accountID: archiveAccountIdentifier,
                        providerContainerID: selection.conversationID
                    )
                }
                return containerIdentifier == selection.conversationID
            }
    }

    private static func providerAccountIdentifier(
        fromVaultAccountIdentifier accountIdentifier: String,
        provider: String
    ) -> String? {
        let prefix = "\(provider):"
        guard accountIdentifier.hasPrefix(prefix) else { return nil }
        let value = String(accountIdentifier.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }

    private func evidenceStorageIdentifier(messageID: String, referenceID: String) -> String {
        "\(messageID)\u{1f}\(referenceID)"
    }

    private func encodeBounded<T: Encodable>(_ value: T) throws -> Data {
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let data = try encoder.encode(value)
            guard data.count <= LokiChatLimits.maximumMessageCharacters else {
                throw LokiChatPersistenceError.encodingFailed
            }
            return data
        } catch let error as LokiChatPersistenceError {
            throw error
        } catch {
            throw LokiChatPersistenceError.encodingFailed
        }
    }

    private func decodeBounded<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= LokiChatLimits.maximumMessageCharacters else {
            throw LokiChatPersistenceError.encodingFailed
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LokiChatPersistenceError.encodingFailed
        }
    }

    private func domainMessage(_ stored: StoredLokiMessage) throws -> LokiMessage {
        let failure = stored.failureCodeRaw.map {
            LokiConversationFailure(
                code: LokiConversationFailureCode(rawValue: $0) ?? .unknown,
                isRecoverable: stored.failureRecoverable,
                consumerMessage: stored.failureMessage ?? "The local chat operation did not complete."
            )
        }
        return LokiMessage(
            id: stored.id,
            conversationID: stored.conversationID,
            sequence: stored.sequence,
            role: LokiMessageRole(rawValue: stored.roleRaw) ?? .assistant,
            state: LokiMessageState(rawValue: stored.stateRaw) ?? .failed,
            visibleText: stored.visibleText,
            answerSegments: try decodeBounded(
                [LokiChatAnswerSegment].self,
                from: stored.answerSegmentsData
            ),
            createdAt: stored.createdAt,
            updatedAt: stored.updatedAt,
            completedAt: stored.completedAt,
            failure: failure,
            retryOfMessageID: stored.retryOfMessageID,
            isPartial: stored.isPartial
        )
    }

    private func domainEvidenceReference(
        _ stored: StoredLokiEvidenceReference
    ) -> LokiEvidenceReference {
        LokiEvidenceReference(
            id: stored.referenceIdentifier,
            sourceKind: LokiEvidenceSourceKind(rawValue: stored.sourceKindRaw) ?? .vault,
            accountClassification: stored.accountClassification,
            accountIdentifier: stored.accountIdentifier,
            containerClassification: stored.containerClassification,
            containerIdentifier: stored.containerIdentifier,
            itemIdentifier: stored.itemIdentifier,
            sourceTimestamp: stored.sourceTimestamp,
            retrievedAt: stored.retrievedAt,
            localVaultIdentifier: stored.localVaultIdentifier,
            displayLabel: stored.displayLabel,
            boundedExcerpt: stored.boundedExcerpt,
            directSourceURL: stored.directSourceURLString.flatMap(URL.init(string:)),
            trustClassification: LokiEvidenceTrustClassification(
                rawValue: stored.trustClassificationRaw
            ) ?? .authorizedSource
        )
    }

    private func upsertModelRoleAssignment(
        _ assignment: ModelRoleAssignment,
        context: ModelContext
    ) throws {
        let modalitiesData = try encodeBounded(
            assignment.verifiedInputModalities.map(\.rawValue).sorted()
        )
        let thinkingModesData = try encodeBounded(
            assignment.verifiedThinkingModes.map(\.rawValue).sorted()
        )
        let dispositionsData = try encodeBounded(
            assignment.dispositions.map(\.rawValue).sorted()
        )
        if let existing = try context.fetch(FetchDescriptor<StoredModelRoleAssignment>())
            .first(where: { $0.id == assignment.role.rawValue }) {
            existing.roleRaw = assignment.role.rawValue
            existing.requestedProvider = assignment.requestedProvider
            existing.requestedModelIdentifier = assignment.requestedModelIdentifier
            existing.effectiveProvider = assignment.effectiveProvider
            existing.effectiveModelIdentifier = assignment.effectiveModelIdentifier
            existing.requestedClassificationRaw =
                assignment.requestedClassification.rawValue
            existing.effectiveClassificationRaw =
                assignment.effectiveClassification.rawValue
            existing.modelDigest = assignment.modelDigest
            existing.assessmentReceiptIdentifier =
                assignment.assessmentReceiptIdentifier
            existing.assessmentTimestamp = assignment.assessmentTimestamp
            existing.verifiedInputModalitiesData = modalitiesData
            existing.verifiedThinkingModesData = thinkingModesData
            existing.verifiedToolSupportRaw = assignment.verifiedToolSupport.rawValue
            existing.verifiedStructuredOutputSupport =
                assignment.verifiedStructuredOutputSupport
            existing.verifiedStreamingSupport = assignment.verifiedStreamingSupport
            existing.configuredContextTokens = assignment.configuredContextTokens
            existing.effectiveContextTokens = assignment.effectiveContextTokens
            existing.readinessRaw = assignment.readiness.rawValue
            existing.reasonCode = assignment.reasonCode
            existing.sourceRaw = assignment.source.rawValue
            existing.inheritedFromRoleRaw = assignment.inheritedFromRole?.rawValue
            existing.dispositionsData = dispositionsData
            existing.isExplicitlyAssigned = assignment.isExplicitlyAssigned
            existing.selectedAt = assignment.selectedAt
            existing.updatedAt = assignment.updatedAt
            existing.schemaVersion = 1
        } else {
            context.insert(StoredModelRoleAssignment(
                id: assignment.role.rawValue,
                roleRaw: assignment.role.rawValue,
                requestedProvider: assignment.requestedProvider,
                requestedModelIdentifier: assignment.requestedModelIdentifier,
                effectiveProvider: assignment.effectiveProvider,
                effectiveModelIdentifier: assignment.effectiveModelIdentifier,
                requestedClassificationRaw: assignment.requestedClassification.rawValue,
                effectiveClassificationRaw: assignment.effectiveClassification.rawValue,
                modelDigest: assignment.modelDigest,
                assessmentReceiptIdentifier: assignment.assessmentReceiptIdentifier,
                assessmentTimestamp: assignment.assessmentTimestamp,
                verifiedInputModalitiesData: modalitiesData,
                verifiedThinkingModesData: thinkingModesData,
                verifiedToolSupportRaw: assignment.verifiedToolSupport.rawValue,
                verifiedStructuredOutputSupport:
                    assignment.verifiedStructuredOutputSupport,
                verifiedStreamingSupport: assignment.verifiedStreamingSupport,
                configuredContextTokens: assignment.configuredContextTokens,
                effectiveContextTokens: assignment.effectiveContextTokens,
                readinessRaw: assignment.readiness.rawValue,
                reasonCode: assignment.reasonCode,
                sourceRaw: assignment.source.rawValue,
                inheritedFromRoleRaw: assignment.inheritedFromRole?.rawValue,
                dispositionsData: dispositionsData,
                isExplicitlyAssigned: assignment.isExplicitlyAssigned,
                selectedAt: assignment.selectedAt,
                updatedAt: assignment.updatedAt
            ))
        }
    }

    private func domainModelRoleAssignment(
        _ stored: StoredModelRoleAssignment
    ) throws -> ModelRoleAssignment {
        guard let role = ModelRole(rawValue: stored.roleRaw),
              stored.id == role.rawValue,
              let requestedClassification = ModelLocalityClassification(
                rawValue: stored.requestedClassificationRaw
              ),
              let effectiveClassification = ModelLocalityClassification(
                rawValue: stored.effectiveClassificationRaw
              ),
              let readiness = ModelRoleReadiness(rawValue: stored.readinessRaw),
              let toolSupport = ModelVerifiedToolSupport(
                rawValue: stored.verifiedToolSupportRaw
              ),
              let source = ModelRoleAssignmentSource(rawValue: stored.sourceRaw)
        else { throw ModelRoleDomainError.invalidAssignment }
        let modalityValues = try decodeBounded(
            [String].self,
            from: stored.verifiedInputModalitiesData
        )
        let thinkingValues = try decodeBounded(
            [String].self,
            from: stored.verifiedThinkingModesData
        )
        let dispositionValues = try decodeBounded(
            [String].self,
            from: stored.dispositionsData
        )
        let modalities = Set(modalityValues.compactMap(ModelInputModality.init(rawValue:)))
        let thinkingModes = Set(thinkingValues.compactMap(ModelReasoningControl.init(rawValue:)))
        let dispositions = Set(
            dispositionValues.compactMap(ModelRoleAssignmentDisposition.init(rawValue:))
        )
        guard modalities.count == modalityValues.count,
              thinkingModes.count == thinkingValues.count,
              dispositions.count == dispositionValues.count
        else { throw ModelRoleDomainError.invalidAssignment }
        let assignment = ModelRoleAssignment(
            role: role,
            requestedProvider: stored.requestedProvider,
            requestedModelIdentifier: stored.requestedModelIdentifier,
            effectiveProvider: stored.effectiveProvider,
            effectiveModelIdentifier: stored.effectiveModelIdentifier,
            requestedClassification: requestedClassification,
            effectiveClassification: effectiveClassification,
            modelDigest: stored.modelDigest,
            assessmentReceiptIdentifier: stored.assessmentReceiptIdentifier,
            assessmentTimestamp: stored.assessmentTimestamp,
            verifiedInputModalities: modalities,
            verifiedThinkingModes: thinkingModes,
            verifiedToolSupport: toolSupport,
            verifiedStructuredOutputSupport: stored.verifiedStructuredOutputSupport,
            verifiedStreamingSupport: stored.verifiedStreamingSupport,
            configuredContextTokens: stored.configuredContextTokens,
            effectiveContextTokens: stored.effectiveContextTokens,
            readiness: readiness,
            reasonCode: stored.reasonCode,
            source: source,
            inheritedFromRole: stored.inheritedFromRoleRaw.flatMap(ModelRole.init(rawValue:)),
            dispositions: dispositions,
            isExplicitlyAssigned: stored.isExplicitlyAssigned,
            selectedAt: stored.selectedAt,
            updatedAt: stored.updatedAt
        )
        return try assignment.validatedForPersistence()
    }

    private func storedModelRoutingReceipt(
        _ receipt: ModelRoutingReceipt
    ) -> StoredModelRoutingReceipt {
        StoredModelRoutingReceipt(
            id: receipt.id,
            timestamp: receipt.timestamp,
            event: receipt.event,
            traceID: receipt.traceID,
            spanID: receipt.spanID,
            parentSpanID: receipt.parentSpanID,
            component: receipt.component,
            statusRaw: receipt.status.rawValue,
            reasonCode: receipt.reasonCode,
            durationMilliseconds: receipt.durationMilliseconds,
            requestedRoleRaw: receipt.requestedRole.rawValue,
            selectedRoleRaw: receipt.selectedRole?.rawValue,
            requestedModelIdentifier: receipt.requestedModelIdentifier,
            effectiveModelIdentifier: receipt.effectiveModelIdentifier,
            requestedModelClassificationRaw:
                receipt.requestedModelClassification.rawValue,
            effectiveModelClassificationRaw:
                receipt.effectiveModelClassification.rawValue,
            assessmentReceiptIdentifier: receipt.assessmentReceiptIdentifier,
            switchStatusRaw: receipt.switchStatus.rawValue,
            effectiveContextTokens: receipt.effectiveContextTokens,
            attachmentsPresent: receipt.attachmentsPresent
        )
    }

    private func update(
        _ stored: StoredModelRoutingReceipt,
        from receipt: ModelRoutingReceipt
    ) {
        stored.timestamp = receipt.timestamp
        stored.event = receipt.event
        stored.traceID = receipt.traceID
        stored.spanID = receipt.spanID
        stored.parentSpanID = receipt.parentSpanID
        stored.component = receipt.component
        stored.statusRaw = receipt.status.rawValue
        stored.reasonCode = receipt.reasonCode
        stored.durationMilliseconds = receipt.durationMilliseconds
        stored.requestedRoleRaw = receipt.requestedRole.rawValue
        stored.selectedRoleRaw = receipt.selectedRole?.rawValue
        stored.requestedModelIdentifier = receipt.requestedModelIdentifier
        stored.effectiveModelIdentifier = receipt.effectiveModelIdentifier
        stored.requestedModelClassificationRaw =
            receipt.requestedModelClassification.rawValue
        stored.effectiveModelClassificationRaw =
            receipt.effectiveModelClassification.rawValue
        stored.assessmentReceiptIdentifier = receipt.assessmentReceiptIdentifier
        stored.switchStatusRaw = receipt.switchStatus.rawValue
        stored.effectiveContextTokens = receipt.effectiveContextTokens
        stored.attachmentsPresent = receipt.attachmentsPresent
        stored.schemaVersion = 1
    }

    private func domainModelRoutingReceipt(
        _ stored: StoredModelRoutingReceipt
    ) throws -> ModelRoutingReceipt {
        guard stored.event == "model.routing.completed",
              stored.component == "model_router",
              let status = ModelRoutingStatus(rawValue: stored.statusRaw),
              let requestedRole = ModelRole(rawValue: stored.requestedRoleRaw),
              let requestedClassification = ModelLocalityClassification(
                rawValue: stored.requestedModelClassificationRaw
              ),
              let effectiveClassification = ModelLocalityClassification(
                rawValue: stored.effectiveModelClassificationRaw
              ),
              let switchStatus = ModelRoutingSwitchStatus(rawValue: stored.switchStatusRaw)
        else { throw ModelRoleDomainError.invalidReceipt }
        let selectedRole: ModelRole?
        if let selectedRoleRaw = stored.selectedRoleRaw {
            guard let decoded = ModelRole(rawValue: selectedRoleRaw) else {
                throw ModelRoleDomainError.invalidReceipt
            }
            selectedRole = decoded
        } else {
            selectedRole = nil
        }
        return ModelRoutingReceipt(
            id: stored.id,
            timestamp: stored.timestamp,
            traceID: stored.traceID,
            spanID: stored.spanID,
            parentSpanID: stored.parentSpanID,
            status: status,
            reasonCode: stored.reasonCode,
            durationMilliseconds: stored.durationMilliseconds,
            requestedRole: requestedRole,
            selectedRole: selectedRole,
            requestedModelIdentifier: stored.requestedModelIdentifier,
            effectiveModelIdentifier: stored.effectiveModelIdentifier,
            requestedModelClassification: requestedClassification,
            effectiveModelClassification: effectiveClassification,
            assessmentReceiptIdentifier: stored.assessmentReceiptIdentifier,
            switchStatus: switchStatus,
            effectiveContextTokens: stored.effectiveContextTokens,
            attachmentsPresent: stored.attachmentsPresent
        )
    }

    private func storedModelReasoningReceipt(
        _ receipt: ModelReasoningReceipt
    ) -> StoredModelReasoningReceipt {
        StoredModelReasoningReceipt(
            id: receipt.id,
            traceID: receipt.traceID,
            reasoningModeRaw: receipt.reasoningMode.rawValue,
            modelIdentifier: receipt.modelIdentifier,
            assessmentReceiptIdentifier: receipt.assessmentReceiptIdentifier,
            startedAt: receipt.startedAt,
            durationMilliseconds: receipt.durationMilliseconds,
            promptTokens: receipt.usage.promptTokens,
            completionTokens: receipt.usage.completionTokens,
            totalTokens: receipt.usage.totalTokens,
            toolLoopCount: receipt.toolLoopCount,
            statusRaw: receipt.status.rawValue,
            reasonCode: receipt.reasonCode
        )
    }

    private func update(
        _ stored: StoredModelReasoningReceipt,
        from receipt: ModelReasoningReceipt
    ) {
        stored.traceID = receipt.traceID
        stored.reasoningModeRaw = receipt.reasoningMode.rawValue
        stored.modelIdentifier = receipt.modelIdentifier
        stored.assessmentReceiptIdentifier = receipt.assessmentReceiptIdentifier
        stored.startedAt = receipt.startedAt
        stored.durationMilliseconds = receipt.durationMilliseconds
        stored.promptTokens = receipt.usage.promptTokens
        stored.completionTokens = receipt.usage.completionTokens
        stored.totalTokens = receipt.usage.totalTokens
        stored.toolLoopCount = receipt.toolLoopCount
        stored.statusRaw = receipt.status.rawValue
        stored.reasonCode = receipt.reasonCode
        stored.schemaVersion = 1
    }

    private func domainModelReasoningReceipt(
        _ stored: StoredModelReasoningReceipt
    ) throws -> ModelReasoningReceipt {
        guard let reasoningMode = ReasoningMode(rawValue: stored.reasoningModeRaw),
              let status = ModelReasoningCompletionStatus(rawValue: stored.statusRaw)
        else { throw ModelRoleDomainError.invalidReceipt }
        return ModelReasoningReceipt(
            id: stored.id,
            traceID: stored.traceID,
            reasoningMode: reasoningMode,
            modelIdentifier: stored.modelIdentifier,
            assessmentReceiptIdentifier: stored.assessmentReceiptIdentifier,
            startedAt: stored.startedAt,
            durationMilliseconds: stored.durationMilliseconds,
            usage: .init(
                promptTokens: stored.promptTokens,
                completionTokens: stored.completionTokens,
                totalTokens: stored.totalTokens
            ),
            toolLoopCount: stored.toolLoopCount,
            status: status,
            reasonCode: stored.reasonCode
        )
    }

    private func pruneModelRoutingReceipts(limit: Int) throws {
        let context = container.mainContext
        let ordered = try context.fetch(FetchDescriptor<StoredModelRoutingReceipt>())
            .sorted {
                if $0.timestamp != $1.timestamp { return $0.timestamp > $1.timestamp }
                return $0.id < $1.id
            }
        guard ordered.count > limit else { return }
        for receipt in ordered.dropFirst(limit) {
            context.delete(receipt)
        }
        try context.save()
    }

    private func pruneModelReasoningReceipts(limit: Int) throws {
        let context = container.mainContext
        let ordered = try context.fetch(FetchDescriptor<StoredModelReasoningReceipt>())
            .sorted {
                if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
                return $0.id < $1.id
            }
        guard ordered.count > limit else { return }
        for receipt in ordered.dropFirst(limit) {
            context.delete(receipt)
        }
        try context.save()
    }

    private func deleteLokiConversationRows(id: String, context: ModelContext) throws {
        for row in try context.fetch(FetchDescriptor<StoredLokiChatContextSelection>())
        where row.conversationID == id {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<StoredLokiEvidenceReference>())
        where row.conversationID == id {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<StoredLokiToolReceipt>())
        where row.conversationID == id {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<StoredLokiGenerationProvenance>())
        where row.conversationID == id {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<StoredLokiMessage>())
        where row.conversationID == id {
            context.delete(row)
        }
        for row in try context.fetch(FetchDescriptor<StoredLokiConversation>())
        where row.id == id {
            context.delete(row)
        }
    }
}
