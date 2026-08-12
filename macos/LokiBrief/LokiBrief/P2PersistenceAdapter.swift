import Foundation

extension LocalStore {
    func domainFeedSubscriptions() throws -> [FeedSubscription] {
        try feedSubscriptions().map { stored in
            guard let url = URL(string: stored.canonicalURL) else { throw FeedFetchFailure(.invalidURL) }
            let failure = stored.failureCode.flatMap(FeedFetchFailureCode.init(rawValue:)).map {
                FeedFetchFailure($0, message: stored.failureMessage, httpStatus: stored.lastHTTPStatus)
            }
            return FeedSubscription(
                id: stored.id,
                title: stored.displayName,
                canonicalURL: url,
                enabled: stored.enabled,
                format: FeedFormat(rawValue: stored.formatRaw) ?? .unknown,
                lastAttemptedAt: stored.lastAttemptedAt,
                lastSuccessfulAt: stored.lastSuccessfulAt,
                lastHTTPStatus: stored.lastHTTPStatus,
                eTag: stored.eTag,
                lastModified: stored.lastModified,
                state: FeedSubscriptionState(rawValue: stored.stateRaw) ?? .savedUnavailable,
                failure: failure,
                policy: .init(requestTimeout: FeedLimits.requestTimeout, resourceTimeout: FeedLimits.resourceTimeout, maximumRedirects: FeedLimits.maximumRedirects, maximumResponseBytes: FeedLimits.maximumResponseBytes, maximumRetainedEntries: min(max(stored.retentionCount, 1), FeedLimits.maximumRetainedEntriesPerFeed), retentionDays: FeedLimits.defaultRetentionDays),
                weight: min(max(stored.weight, 0.5), 2),
                createdAt: stored.createdAt,
                updatedAt: stored.updatedAt
            )
        }
    }

    func persistFeedSubscription(_ subscription: FeedSubscription) throws {
        if let stored = try feedSubscriptions().first(where: { $0.id == subscription.id }) {
            stored.displayName = subscription.title
            stored.canonicalURL = subscription.canonicalURL.absoluteString
            stored.enabled = subscription.enabled
            stored.formatRaw = subscription.format.rawValue
            stored.lastAttemptedAt = subscription.lastAttemptedAt
            stored.lastSuccessfulAt = subscription.lastSuccessfulAt
            stored.lastHTTPStatus = subscription.lastHTTPStatus
            stored.eTag = subscription.eTag
            stored.lastModified = subscription.lastModified
            stored.stateRaw = subscription.state.rawValue
            stored.failureCode = subscription.failure?.reasonCode
            stored.failureMessage = subscription.failure?.message
            stored.retentionCount = subscription.policy.maximumRetainedEntries
            stored.weight = subscription.weight
            stored.updatedAt = subscription.updatedAt
            try save()
        } else {
            try insertFeedSubscription(.init(
                id: subscription.id,
                displayName: subscription.title,
                canonicalURL: subscription.canonicalURL.absoluteString,
                enabled: subscription.enabled,
                formatRaw: subscription.format.rawValue,
                lastAttemptedAt: subscription.lastAttemptedAt,
                lastSuccessfulAt: subscription.lastSuccessfulAt,
                lastHTTPStatus: subscription.lastHTTPStatus,
                eTag: subscription.eTag,
                lastModified: subscription.lastModified,
                stateRaw: subscription.state.rawValue,
                failureCode: subscription.failure?.reasonCode,
                failureMessage: subscription.failure?.message,
                retentionCount: subscription.policy.maximumRetainedEntries,
                weight: subscription.weight,
                createdAt: subscription.createdAt,
                updatedAt: subscription.updatedAt
            ))
        }
    }

    func persistFeedFetchResult(_ result: FeedFetchResult, settings: StoredP2Settings) throws {
        try persistFeedSubscription(result.subscription)
        try recordFetch(.init(
            id: result.record.id,
            subscriptionID: result.record.subscriptionID,
            traceID: result.record.traceID,
            attemptedAt: result.record.attemptedAt,
            completedAt: result.record.completedAt,
            statusRaw: result.record.wasNotModified ? "not_modified" : "success",
            httpStatus: result.record.httpStatus,
            responseByteCount: result.record.responseByteCount,
            parsedEntryCount: result.record.parsedEntryCount,
            eTag: result.record.eTag,
            lastModified: result.record.lastModified
        ))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]; encoder.dateEncodingStrategy = .iso8601
        for entry in result.entries {
            let encoded = try encoder.encode(entry)
            try upsertFeedEntry(.init(
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
                encodedEntry: encoded
            ))
        }
        try save()
        try pruneFeedEntries(now: result.record.completedAt, retentionDays: min(max(settings.feedRetentionDays, 1), 365), maximumPerFeed: min(max(settings.retainedEntriesPerFeed, 1), FeedLimits.maximumRetainedEntriesPerFeed))
    }

    func domainFeedEntries(enabledSubscriptionIDs: Set<String>) throws -> [NormalizedFeedEntry] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try feedEntries(enabledSubscriptionIDs: enabledSubscriptionIDs).map { stored in
            do { return try decoder.decode(NormalizedFeedEntry.self, from: stored.encodedEntry) }
            catch { throw FeedFetchFailure(.invalidEntry, message: "A stored feed entry could not be decoded safely.") }
        }
    }

    func persistModelCatalog(_ catalog: OllamaModelCatalog) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let formatter = ISO8601DateFormatter()
        let models = try catalog.models.map { model -> StoredLocalModelDescriptor in
            let details = try encoder.encode(model)
            return .init(id: model.id, displayName: model.name, modifiedAt: model.modifiedAt.flatMap(formatter.date), sizeBytes: model.sizeBytes ?? 0, digest: model.digest, details: details, discoveredAt: catalog.discoveredAt)
        }
        try replaceLocalModels(with: models)
    }

    func domainLocalModels() throws -> [OllamaModelDescriptor] {
        let decoder = JSONDecoder()
        return try localModels().map { try decoder.decode(OllamaModelDescriptor.self, from: $0.details) }
    }

    func persistModelSelection(_ selection: OllamaModelSelection?, enabled: Bool) throws {
        let record = try modelSelection()
        record.modelID = selection?.model.id
        record.localGenerationEnabled = enabled
        record.selectedAt = selection?.selectedAt
        try save()
    }

    func persistGenerationProvenance(_ provenance: OllamaGenerationProvenance) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let identifiers = try encoder.encode(provenance.sourceItemIdentifiers)
        let identifier = "generation-\(provenance.deterministicBriefIdentifier)-\(Int(provenance.generatedAt.timeIntervalSince1970 * 1_000))-\(UUID().uuidString.lowercased())"
        try recordGenerationProvenance(.init(
            id: identifier,
            briefID: provenance.deterministicBriefIdentifier,
            providerKind: provenance.providerKind,
            modelName: provenance.selectedModelName,
            endpointClassification: provenance.endpointClassification.rawValue,
            promptTemplateVersion: provenance.promptTemplateVersion,
            schemaVersion: provenance.schemaVersion,
            generatedAt: provenance.generatedAt,
            sourceItemIdentifiers: identifiers,
            completionStatus: provenance.completionStatus.rawValue,
            fallbackStatus: provenance.fallbackStatus.rawValue,
            durationMilliseconds: provenance.durationMilliseconds,
            promptTokenCount: provenance.promptTokenCount,
            completionTokenCount: provenance.outputTokenCount,
            validationResult: provenance.validationResult.rawValue,
            failureCode: provenance.failureReasonCode
        ))
    }
}
