import CryptoKit
import Foundation

/// Prepares atomic admission pages. It performs no file I/O and does not write
/// checkpoints, envelopes, attachment bytes, or message bodies to a second
/// store. A caller may persist the returned page and its checkpoint together.
struct EmailImportController: Sendable {
    private let parser: EmailMessageParser
    private let mboxReader: EmailMBoxReader
    private let now: @Sendable () -> Date
    private let traceSink: EmailTraceSink?

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: EmailTraceSink? = nil,
        mboxReader: EmailMBoxReader = .init()
    ) {
        self.now = now
        self.traceSink = traceSink
        parser = EmailMessageParser(now: now, traceSink: traceSink)
        self.mboxReader = mboxReader
    }

    /// Creates the bounded task-owned session a multi-page caller keeps for one
    /// immutable authorized mailbox snapshot. It owns no bookmark or persistent
    /// body store and should be released when that import loop ends.
    func makeMBoxImportSession(
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailMBoxReadSession {
        let session = try mboxReader.makeSession(
            for: data,
            source: source,
            checkpoint: checkpoint,
            isCancelled: isCancelled
        )
        let reconciliationState = try rebuildMBoxReconciliationState(
            session: session,
            source: source,
            checkpoint: checkpoint,
            isCancelled: isCancelled
        )
        try session.restoreReconciliationState(
            reconciliationState,
            checkpoint: checkpoint
        )
        return session
    }

    func prepareEMLImport(
        data: Data,
        source: EmailImportSource,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailImportResult {
        let page = try prepareEMLPage(
            data: data,
            source: source,
            trace: trace,
            isCancelled: isCancelled
        )
        return importResult(page: page, source: source)
    }

    func prepareMBoxImport(
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailImportResult {
        let page = try prepareMBoxPage(
            data: data,
            source: source,
            checkpoint: checkpoint,
            pageSize: pageSize,
            trace: trace,
            isCancelled: isCancelled
        )
        return importResult(page: page, source: source)
    }

    func prepareMBoxImport(
        session: EmailMBoxReadSession,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailImportResult {
        let page = try prepareMBoxPage(
            session: session,
            source: source,
            checkpoint: checkpoint,
            pageSize: pageSize,
            trace: trace,
            isCancelled: isCancelled
        )
        return importResult(page: page, source: source)
    }

    func prepareEMLPage(
        data: Data,
        source: EmailImportSource,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailAdmissionPage {
        guard source.format == .eml else { throw EmailImportFailureCode.checkpointInvalid }
        try checkCancellation(isCancelled, trace: trace)
        let ingestionDate = now()
        let streamIdentifier = paginationStreamIdentifier(
            source: source,
            runStartByteOffset: 0
        )
        let pagination = try makePaginationReceipt(
            source: source,
            streamIdentifier: streamIdentifier,
            pageOrdinal: 0,
            requestOffset: nil,
            nextOffset: nil,
            sourceByteCount: data.count,
            complete: true
        )
        let parsed = try parser.parse(
            data,
            trace: trace.child(),
            isCancelled: isCancelled
        )
        try checkCancellation(isCancelled, trace: trace)
        let record = try makeRecord(
            parsed,
            source: source,
            pagination: pagination,
            ingestionDate: ingestionDate
        )
        let checkpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .eml,
            nextPageOrdinal: 1,
            paginationStreamIdentifier: streamIdentifier,
            committedByteCount: data.count,
            committedPrefixSHA256: EmailDigest.sha256(data),
            completed: true
        )
        return preparedPage(
            records: [record],
            checkpoint: checkpoint,
            pagination: pagination,
            source: source,
            skipped: 0,
            additionalReasonCounts: [:],
            trace: trace
        )
    }

    func prepareMBoxPage(
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailAdmissionPage {
        let session = try makeMBoxImportSession(
            data: data,
            source: source,
            checkpoint: checkpoint,
            isCancelled: isCancelled
        )
        return try prepareMBoxPage(
            session: session,
            source: source,
            checkpoint: checkpoint,
            pageSize: pageSize,
            trace: trace,
            isCancelled: isCancelled
        )
    }

    func prepareMBoxPage(
        session: EmailMBoxReadSession,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailAdmissionPage {
        guard source.format == .mbox else { throw EmailImportFailureCode.checkpointInvalid }
        guard session.sourceIdentifierHash == source.sourceIdentifierHash else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        try checkCancellation(isCancelled, trace: trace)
        let committedReconciliationState = try session.reconciliationState(
            checkpoint: checkpoint
        )
        let readPage = try session.readPage(
            checkpoint: checkpoint,
            pageSize: pageSize,
            isCancelled: isCancelled
        )
        let startsNewPaginationRun = checkpoint == nil || checkpoint?.completed == true
        let pageOrdinal = startsNewPaginationRun ? 0 : (checkpoint?.nextPageOrdinal ?? 0)
        let streamIdentifier: String
        if startsNewPaginationRun {
            streamIdentifier = paginationStreamIdentifier(
                source: source,
                runStartByteOffset: readPage.requestByteOffset ?? 0
            )
        } else if let retained = checkpoint?.paginationStreamIdentifier {
            streamIdentifier = retained
        } else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        let requestCursorOverride: String?
        if !startsNewPaginationRun,
           checkpoint?.completed == false,
           let repairGeneration = checkpoint?.threadRepairGeneration {
            requestCursorOverride = threadRepairPaginationCursor(
                generation: repairGeneration,
                afterRemoteIdentifier:
                    checkpoint?.threadRepairAfterRemoteIdentifier
            )
        } else {
            requestCursorOverride = nil
        }
        let ingestionDate = now()
        var parsedMessages: [EmailParsedMBoxEntry] = []
        var skipped = readPage.skippedEntries.count
        var reasonCounts = Dictionary(grouping: readPage.skippedEntries) {
            $0.reasonCode.rawValue
        }.mapValues(\.count)
        parsedMessages.reserveCapacity(readPage.entries.count)

        for entry in readPage.entries {
            try checkCancellation(isCancelled, trace: trace)
            do {
                let parsed = try parser.parse(
                    entry.data,
                    receivedAtFallback: EmailMBoxSeparatorDateParser.parse(
                        entry.separatorLine
                    ),
                    trace: trace.child(),
                    isCancelled: isCancelled
                )
                parsedMessages.append(.init(
                    message: parsed,
                    locator: try EmailMBoxEntryLocator(entry)
                ))
            } catch EmailImportFailureCode.cancelled {
                throw EmailImportFailureCode.cancelled
            } catch {
                skipped += 1
                let reason = (error as? EmailImportFailureCode)?.rawValue
                    ?? (error as? ConnectorEnvelopeFailureCode)?.rawValue
                    ?? "email_message_admission_failed"
                reasonCounts[reason, default: 0] += 1
            }
        }

        // Selection and compact-state reconciliation do not depend on the
        // pagination values. A valid provisional receipt lets us determine the
        // bounded repair continuation before constructing the final receipt
        // embedded in every returned record.
        let provisionalNextCursorOverride = readPage.isComplete
            ? threadRepairPaginationCursor(
                generation: EmailDigest.sha256(
                    "email-thread-repair-provisional-v1\u{1f}"
                        + streamIdentifier + "\u{1f}" + String(pageOrdinal)
                ),
                afterRemoteIdentifier: nil
            )
            : nil
        let provisionalPagination = try makePaginationReceipt(
            source: source,
            streamIdentifier: streamIdentifier,
            pageOrdinal: pageOrdinal,
            requestOffset: startsNewPaginationRun ? nil : readPage.requestByteOffset,
            nextOffset: readPage.nextByteOffset,
            requestCursorOverride: requestCursorOverride,
            nextCursorOverride: provisionalNextCursorOverride,
            sourceByteCount: session.sourceByteCount,
            complete: false
        )
        let provisionalReconciliation = try reconcileMBoxMessages(
            parsedMessages,
            committedState: committedReconciliationState,
            source: source,
            pagination: provisionalPagination,
            ingestionDate: ingestionDate,
            trace: trace,
            isCancelled: isCancelled
        )
        let repairPlan: EmailMBoxThreadRepairPlan
        if readPage.isComplete {
            repairPlan = try makeThreadRepairPlan(
                state: provisionalReconciliation.nextState,
                currentRemoteIdentifiers: Set(
                    provisionalReconciliation.records.map {
                        $0.envelope.remoteRecordIdentifier
                    }
                ),
                checkpoint: checkpoint,
                maximumAdditionalRecords: max(
                    0,
                    pageSize - provisionalReconciliation.records.count
                ),
                trace: trace,
                isCancelled: isCancelled
            )
        } else {
            repairPlan = .init(
                generation: nil,
                afterRemoteIdentifier: nil,
                candidatesToReemit: [],
                isComplete: false
            )
        }
        let completed = readPage.isComplete && repairPlan.isComplete
        let logicalNextByteOffset = readPage.nextByteOffset
            ?? (completed ? nil : readPage.committedByteCount)
        let nextCursorOverride: String?
        if readPage.nextByteOffset == nil, !completed,
           let repairGeneration = repairPlan.generation {
            nextCursorOverride = threadRepairPaginationCursor(
                generation: repairGeneration,
                afterRemoteIdentifier: repairPlan.afterRemoteIdentifier
            )
        } else {
            nextCursorOverride = nil
        }
        let pagination = try makePaginationReceipt(
            source: source,
            streamIdentifier: streamIdentifier,
            pageOrdinal: pageOrdinal,
            requestOffset: startsNewPaginationRun ? nil : readPage.requestByteOffset,
            nextOffset: logicalNextByteOffset,
            requestCursorOverride: requestCursorOverride,
            nextCursorOverride: nextCursorOverride,
            sourceByteCount: session.sourceByteCount,
            complete: completed
        )
        let reconciled = provisionalPagination == pagination
            ? provisionalReconciliation
            : try reconcileMBoxMessages(
                parsedMessages,
                committedState: committedReconciliationState,
                source: source,
                pagination: pagination,
                ingestionDate: ingestionDate,
                trace: trace,
                isCancelled: isCancelled
            )
        guard reconciled.nextState == provisionalReconciliation.nextState,
              Set(reconciled.records.map { $0.envelope.remoteRecordIdentifier })
                == Set(provisionalReconciliation.records.map {
                    $0.envelope.remoteRecordIdentifier
                })
        else { throw EmailImportFailureCode.checkpointInvalid }
        let repairRecords = try makeThreadRepairRecords(
            repairPlan.candidatesToReemit,
            state: reconciled.nextState,
            session: session,
            source: source,
            pagination: pagination,
            ingestionDate: ingestionDate,
            trace: trace,
            isCancelled: isCancelled
        )
        var records = reconciled.records + repairRecords
        records.sort {
            $0.envelope.deduplicationKey < $1.envelope.deduplicationKey
        }
        guard records.count <= pageSize else {
            throw EmailImportFailureCode.reconciliationStateTooLarge
        }
        skipped += reconciled.skipped
        for (reason, count) in reconciled.reasonCounts {
            reasonCounts[reason, default: 0] += count
        }
        try checkCancellation(isCancelled, trace: trace)
        let nextCheckpoint = try EmailImportCheckpoint(
            sourceIdentifierHash: source.sourceIdentifierHash,
            format: .mbox,
            nextPageOrdinal: pageOrdinal + 1,
            paginationStreamIdentifier: streamIdentifier,
            nextByteOffset: logicalNextByteOffset,
            committedByteCount: readPage.committedByteCount,
            committedPrefixSHA256: readPage.committedPrefixSHA256,
            threadRepairGeneration: readPage.isComplete
                ? repairPlan.generation : nil,
            threadRepairAfterRemoteIdentifier: readPage.isComplete
                ? repairPlan.afterRemoteIdentifier : nil,
            completed: completed
        )
        let page = preparedPage(
            records: records,
            checkpoint: nextCheckpoint,
            pagination: pagination,
            source: source,
            skipped: skipped,
            additionalReasonCounts: reasonCounts,
            trace: trace
        )
        try session.stageReconciliationState(
            reconciled.nextState,
            for: nextCheckpoint
        )
        return page
    }
}

private struct EmailMBoxAdmissionCandidate {
    let ordinal: Int
    let message: EmailParsedMessage
    let state: EmailMBoxReconciliationMessageState
}

private struct EmailParsedMBoxEntry {
    let message: EmailParsedMessage
    let locator: EmailMBoxEntryLocator
}

private struct EmailMBoxReconciliationVersion {
    let state: EmailMBoxReconciliationMessageState
    let candidate: EmailMBoxAdmissionCandidate?
}

private struct EmailMBoxReconciliationOutcome {
    let records: [EmailAdmissionRecord]
    let nextState: EmailMBoxReconciliationState
    let skipped: Int
    let reasonCounts: [String: Int]
}

private struct EmailMBoxThreadRepairCandidate {
    let remoteIdentifier: String
    let state: EmailMBoxReconciliationMessageState
    let targetThread: EmailThreadRelation
}

private struct EmailMBoxThreadRepairPlan {
    let generation: String?
    let afterRemoteIdentifier: String?
    let candidatesToReemit: [EmailMBoxThreadRepairCandidate]
    let isComplete: Bool
}

private extension EmailImportController {
    func rebuildMBoxReconciliationState(
        session: EmailMBoxReadSession,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> EmailMBoxReconciliationState {
        var state = EmailMBoxReconciliationState()
        guard checkpoint?.committedByteCount ?? 0 > 0 else { return state }
        let reconstructionParser = EmailMessageParser()
        let pagination = try makePaginationReceipt(
            source: source,
            streamIdentifier: checkpoint?.paginationStreamIdentifier
                ?? paginationStreamIdentifier(
                    source: source,
                    runStartByteOffset: 0
                ),
            pageOrdinal: max(0, (checkpoint?.nextPageOrdinal ?? 1) - 1),
            requestOffset: nil,
            nextOffset: nil,
            sourceByteCount: session.sourceByteCount,
            complete: checkpoint?.completed ?? false
        )
        let trace = EmailTraceContext()
        try session.forEachCommittedPrefixEntry(
            isCancelled: isCancelled
        ) { entry in
            do {
                let parsed = try reconstructionParser.parse(
                    entry.data,
                    receivedAtFallback: EmailMBoxSeparatorDateParser.parse(
                        entry.separatorLine
                    ),
                    isCancelled: isCancelled
                )
                let reconciled = try reconcileMBoxMessages(
                    [.init(
                        message: parsed,
                        locator: try EmailMBoxEntryLocator(entry)
                    )],
                    committedState: state,
                    source: source,
                    pagination: pagination,
                    ingestionDate: Date(timeIntervalSince1970: 0),
                    trace: trace,
                    isCancelled: isCancelled
                )
                state = reconciled.nextState
            } catch EmailImportFailureCode.cancelled {
                throw EmailImportFailureCode.cancelled
            } catch EmailImportFailureCode.reconciliationStateTooLarge {
                throw EmailImportFailureCode.reconciliationStateTooLarge
            } catch {
                // A prefix entry that cannot be admitted was skipped in the
                // committed run and therefore contributes no identity context.
            }
        }
        return state
    }

    func makeThreadRepairPlan(
        state: EmailMBoxReconciliationState,
        currentRemoteIdentifiers: Set<String>,
        checkpoint: EmailImportCheckpoint?,
        maximumAdditionalRecords: Int,
        trace: EmailTraceContext,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> EmailMBoxThreadRepairPlan {
        let ancestryByMessageID = state.ancestryByMessageID
        var candidates: [EmailMBoxThreadRepairCandidate] = []
        candidates.reserveCapacity(min(
            state.selectedByRemoteIdentifier.count,
            EmailImportLimits.maximumMessagesPerPage
        ))
        for (remoteIdentifier, selected) in state.selectedByRemoteIdentifier
            .sorted(by: { $0.key < $1.key }) {
            try checkCancellation(isCancelled, trace: trace)
            // References carry their authoritative root in the message itself.
            // Every In-Reply-To-only record is conservatively covered because
            // an intermediate later version can otherwise make the actually
            // admitted relation impossible to infer after a restart.
            guard let ancestry = selected.ancestry,
                  ancestry.inReplyTo != nil,
                  ancestry.references.isEmpty
            else { continue }
            let target = EmailThreader.relation(
                for: ancestry,
                including: ancestryByMessageID
            )
            candidates.append(.init(
                remoteIdentifier: remoteIdentifier,
                state: selected,
                targetThread: target
            ))
        }
        guard !candidates.isEmpty else {
            return .init(
                generation: nil,
                afterRemoteIdentifier: nil,
                candidatesToReemit: [],
                isComplete: true
            )
        }

        let generation = threadRepairGeneration(candidates)
        var nextIndex = 0
        if checkpoint?.threadRepairGeneration == generation,
           let after = checkpoint?.threadRepairAfterRemoteIdentifier {
            guard let priorIndex = candidates.firstIndex(where: {
                $0.remoteIdentifier == after
            }) else { throw EmailImportFailureCode.checkpointInvalid }
            nextIndex = priorIndex + 1
        }

        let capacity = max(0, maximumAdditionalRecords)
        var candidatesToReemit: [EmailMBoxThreadRepairCandidate] = []
        candidatesToReemit.reserveCapacity(min(capacity, candidates.count - nextIndex))
        while nextIndex < candidates.count {
            try checkCancellation(isCancelled, trace: trace)
            let candidate = candidates[nextIndex]
            if currentRemoteIdentifiers.contains(candidate.remoteIdentifier) {
                nextIndex += 1
                continue
            }
            guard candidatesToReemit.count < capacity else { break }
            candidatesToReemit.append(candidate)
            nextIndex += 1
        }
        return .init(
            generation: generation,
            afterRemoteIdentifier: nextIndex == 0
                ? nil : candidates[nextIndex - 1].remoteIdentifier,
            candidatesToReemit: candidatesToReemit,
            isComplete: nextIndex == candidates.count
        )
    }

    func threadRepairGeneration(
        _ candidates: [EmailMBoxThreadRepairCandidate]
    ) -> String {
        var hasher = SHA256()
        for candidate in candidates {
            let relation = candidate.targetThread
            let values = [
                candidate.remoteIdentifier,
                candidate.state.rawMessageSHA256,
                relation.basis.rawValue,
                relation.parentMessageID ?? "",
                relation.rootMessageID ?? "",
                relation.heuristicKey ?? "",
            ]
            for value in values {
                let data = Data(value.utf8)
                hasher.update(data: Data(String(data.count).utf8))
                hasher.update(data: Data([0x3a]))
                hasher.update(data: data)
                hasher.update(data: Data([0x1f]))
            }
            hasher.update(data: Data([0x1e]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    func makeThreadRepairRecords(
        _ candidates: [EmailMBoxThreadRepairCandidate],
        state: EmailMBoxReconciliationState,
        session: EmailMBoxReadSession,
        source: EmailImportSource,
        pagination: ConnectorPaginationReceipt,
        ingestionDate: Date,
        trace: EmailTraceContext,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> [EmailAdmissionRecord] {
        let ancestryByMessageID = state.ancestryByMessageID
        var records: [EmailAdmissionRecord] = []
        records.reserveCapacity(candidates.count)
        for candidate in candidates {
            try checkCancellation(isCancelled, trace: trace)
            guard state.selectedByRemoteIdentifier[candidate.remoteIdentifier]
                    == candidate.state,
                  let ancestry = candidate.state.ancestry,
                  EmailThreader.relation(
                    for: ancestry,
                    including: ancestryByMessageID
                  ) == candidate.targetThread
            else { throw EmailImportFailureCode.checkpointInvalid }
            let entry = try session.committedEntry(
                at: candidate.state.sourceLocator,
                isCancelled: isCancelled
            )
            let parsed = try parser.parse(
                entry.data,
                receivedAtFallback: EmailMBoxSeparatorDateParser.parse(
                    entry.separatorLine
                ),
                trace: trace.child(),
                isCancelled: isCancelled
            )
            guard parsed.stableRemoteIdentifier == candidate.remoteIdentifier,
                  parsed.rawMessageSHA256 == candidate.state.rawMessageSHA256
            else { throw EmailImportFailureCode.mailboxChanged }
            records.append(try makeRecord(
                parsed,
                thread: candidate.targetThread,
                source: source,
                pagination: pagination,
                ingestionDate: ingestionDate
            ))
        }
        return records
    }

    func threadRepairPaginationCursor(
        generation: String,
        afterRemoteIdentifier: String?
    ) -> String {
        "email-thread-repair-v1:\(generation):"
            + (afterRemoteIdentifier ?? "start")
    }

    func reconcileMBoxMessages(
        _ entries: [EmailParsedMBoxEntry],
        committedState: EmailMBoxReconciliationState,
        source: EmailImportSource,
        pagination: ConnectorPaginationReceipt,
        ingestionDate: Date,
        trace: EmailTraceContext,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> EmailMBoxReconciliationOutcome {
        var skipped = 0
        var reasonCounts: [String: Int] = [:]
        var sequentialAncestry = committedState.ancestryByMessageID
        var preliminaryRelations: [EmailThreadRelation] = []
        preliminaryRelations.reserveCapacity(entries.count)
        for entry in entries {
            let relation = EmailThreader.relations(
                for: [entry.message.headers],
                including: sequentialAncestry
            )[0]
            preliminaryRelations.append(relation)
            if let ancestry = EmailThreadAncestry(entry.message.headers),
               sequentialAncestry[ancestry.messageID] == nil {
                sequentialAncestry[ancestry.messageID] = ancestry
            }
        }
        var candidates: [EmailMBoxAdmissionCandidate] = []
        candidates.reserveCapacity(entries.count)
        for (ordinal, pair) in zip(entries, preliminaryRelations).enumerated() {
            try checkCancellation(isCancelled, trace: trace)
            let (entry, relation) = pair
            let message = entry.message
            do {
                let record = try makeRecord(
                    message,
                    thread: relation,
                    source: source,
                    pagination: pagination,
                    ingestionDate: ingestionDate
                )
                candidates.append(.init(
                    ordinal: ordinal,
                    message: message,
                    state: .init(
                        stableRemoteIdentifier: message.stableRemoteIdentifier,
                        rawMessageSHA256: message.rawMessageSHA256,
                        sourceTimestamp: record.envelope.sourceTimestamp,
                        ancestry: EmailThreadAncestry(message.headers),
                        sourceLocator: entry.locator
                    )
                ))
            } catch EmailImportFailureCode.cancelled {
                throw EmailImportFailureCode.cancelled
            } catch {
                skipped += 1
                let reason = (error as? EmailImportFailureCode)?.rawValue
                    ?? (error as? ConnectorEnvelopeFailureCode)?.rawValue
                    ?? "email_message_admission_failed"
                reasonCounts[reason, default: 0] += 1
            }
        }

        var nextState = committedState
        var selectedCandidates: [EmailMBoxAdmissionCandidate] = []
        let grouped = Dictionary(
            grouping: candidates,
            by: { $0.state.stableRemoteIdentifier }
        ).sorted { $0.key < $1.key }
        selectedCandidates.reserveCapacity(grouped.count)

        for (remoteIdentifier, currentCandidates) in grouped {
            try checkCancellation(isCancelled, trace: trace)
            let existing = committedState
                .selectedByRemoteIdentifier[remoteIdentifier]
            var versions: [String: EmailMBoxReconciliationVersion] = [:]
            if let existing {
                versions[existing.rawMessageSHA256] = .init(
                    state: existing,
                    candidate: nil
                )
            }
            for candidate in currentCandidates {
                let digest = candidate.state.rawMessageSHA256
                if let retained = versions[digest] {
                    // An already committed exact raw version remains the
                    // representative. Otherwise choose the same version's
                    // deterministic timestamp representative.
                    guard retained.candidate != nil,
                          reconciliationStateIsEarlier(
                            retained.state,
                            than: candidate.state
                          )
                    else { continue }
                }
                versions[digest] = .init(
                    state: candidate.state,
                    candidate: candidate
                )
            }
            guard let selected = versions.values.max(by: {
                reconciliationStateIsEarlier($0.state, than: $1.state)
            }) else { continue }

            nextState.selectedByRemoteIdentifier[remoteIdentifier]
                = selected.state
            guard nextState.selectedByRemoteIdentifier.count
                    <= EmailImportLimits.maximumReconciliationEntries
            else {
                throw EmailImportFailureCode.reconciliationStateTooLarge
            }
            if let candidate = selected.candidate {
                selectedCandidates.append(candidate)
            }

            if let existing {
                if existing.rawMessageSHA256
                    != selected.state.rawMessageSHA256 {
                    skipped += 1
                    reasonCounts[
                        EmailImportReasonCode.duplicateMessageSuperseded.rawValue,
                        default: 0
                    ] += 1
                }
                for candidate in currentCandidates
                    where candidate.ordinal != selected.candidate?.ordinal {
                    skipped += 1
                    let reason = candidate.state.rawMessageSHA256
                        == selected.state.rawMessageSHA256
                        ? EmailImportReasonCode.duplicateMessageSkipped
                        : EmailImportReasonCode.duplicateMessageSuperseded
                    reasonCounts[reason.rawValue, default: 0] += 1
                }
            } else {
                for candidate in currentCandidates
                    where candidate.ordinal != selected.candidate?.ordinal {
                    skipped += 1
                    let reason = candidate.state.rawMessageSHA256
                        == selected.state.rawMessageSHA256
                        ? EmailImportReasonCode.duplicateMessageSkipped
                        : EmailImportReasonCode.duplicateMessageSuperseded
                    reasonCounts[reason.rawValue, default: 0] += 1
                }
            }
        }

        let finalRelations = EmailThreader.relations(
            for: selectedCandidates.map { $0.message.headers },
            including: nextState.ancestryByMessageID
        )
        var records: [EmailAdmissionRecord] = []
        records.reserveCapacity(selectedCandidates.count)
        for (candidate, relation) in zip(selectedCandidates, finalRelations) {
            try checkCancellation(isCancelled, trace: trace)
            do {
                records.append(try makeRecord(
                    candidate.message,
                    thread: relation,
                    source: source,
                    pagination: pagination,
                    ingestionDate: ingestionDate
                ))
            } catch EmailImportFailureCode.cancelled {
                throw EmailImportFailureCode.cancelled
            } catch {
                if let prior = committedState.selectedByRemoteIdentifier[
                    candidate.state.stableRemoteIdentifier
                ] {
                    nextState.selectedByRemoteIdentifier[
                        candidate.state.stableRemoteIdentifier
                    ] = prior
                } else {
                    nextState.selectedByRemoteIdentifier.removeValue(
                        forKey: candidate.state.stableRemoteIdentifier
                    )
                }
                skipped += 1
                let reason = (error as? EmailImportFailureCode)?.rawValue
                    ?? (error as? ConnectorEnvelopeFailureCode)?.rawValue
                    ?? "email_message_admission_failed"
                reasonCounts[reason, default: 0] += 1
            }
        }
        records.sort {
            $0.envelope.deduplicationKey < $1.envelope.deduplicationKey
        }
        return .init(
            records: records,
            nextState: nextState,
            skipped: skipped,
            reasonCounts: reasonCounts
        )
    }

    func reconciliationStateIsEarlier(
        _ lhs: EmailMBoxReconciliationMessageState,
        than rhs: EmailMBoxReconciliationMessageState
    ) -> Bool {
        if lhs.sourceTimestamp != rhs.sourceTimestamp {
            return lhs.sourceTimestamp < rhs.sourceTimestamp
        }
        return lhs.rawMessageSHA256 < rhs.rawMessageSHA256
    }

    func makeRecord(
        _ message: EmailParsedMessage,
        thread suppliedThread: EmailThreadRelation? = nil,
        source: EmailImportSource,
        pagination: ConnectorPaginationReceipt,
        ingestionDate: Date
    ) throws -> EmailAdmissionRecord {
        let thread = suppliedThread ?? EmailThreader.relation(for: message.headers)
        let attachments = try message.attachments.map {
            try ConnectorAttachmentMetadata(
                attachmentIdentifier: "email-attachment:\($0.identifier)",
                mediaType: $0.mediaType,
                byteCount: $0.byteCount,
                sourceHash: $0.sha256
            )
        }
        let provenance = try ConnectorRecordProvenance(
            sourceSystem: "support_email",
            sourceContainerIdentifier: source.sourceIdentifierHash,
            sourceURL: nil,
            retrievedAt: ingestionDate,
            policyBasis: source.indexingPolicy.policyBasis
        )
        let envelope = try ConnectorRecordEnvelope(
            provider: "support_email",
            pseudonymousAccountIdentifier: source.mailboxIdentifierHash,
            remoteRecordIdentifier: message.stableRemoteIdentifier,
            recordType: "support_email_message",
            parentOrThreadIdentifier: thread.connectorParentIdentifier,
            sourceTimestamp: message.headers.sentDate
                ?? message.headers.receivedDate
                ?? Date(timeIntervalSince1970: 0),
            ingestionTimestamp: ingestionDate,
            normalizedText: ConnectorTextNormalization.text(admissionText(for: message)),
            attachments: attachments,
            editOrVersionIdentifier: message.editOrVersionIdentifier,
            sourceHash: message.rawMessageSHA256,
            paginationReceipt: pagination,
            provenance: provenance,
            policyClassification: source.indexingPolicy.connectorPolicy,
            contentClassification: .providerRecord,
            containsSensitiveMaterial: false
        )
        return .init(
            envelope: envelope,
            metadata: try .init(
                headers: message.headers,
                attachments: message.attachments,
                thread: thread,
                rawMessageSHA256: message.rawMessageSHA256,
                warnings: message.warnings,
                mailboxIdentifierHash: source.mailboxIdentifierHash,
                importSourceIdentifierHash: source.sourceIdentifierHash
            )
        )
    }

    func admissionText(for message: EmailParsedMessage) -> String {
        var sections: [String] = []
        sections.append("Subject: \(message.headers.subject)")
        if !message.headers.from.isEmpty {
            sections.append("From: \(message.headers.from.joined(separator: ", "))")
        }
        if !message.headers.to.isEmpty {
            sections.append("To: \(message.headers.to.joined(separator: ", "))")
        }
        if !message.headers.cc.isEmpty {
            sections.append("Cc: \(message.headers.cc.joined(separator: ", "))")
        }
        if !message.headers.replyTo.isEmpty {
            sections.append("Reply-To: \(message.headers.replyTo.joined(separator: ", "))")
        }
        if !message.normalizedBody.isEmpty { sections.append(message.normalizedBody) }
        if !message.attachments.isEmpty {
            sections.append("Attachments: " + message.attachments.map {
                "\($0.filename) [\($0.mediaType), \($0.byteCount) bytes, sha256 \($0.sha256)]"
            }.joined(separator: "; "))
        }
        return sections.joined(separator: "\n")
    }

    func makePaginationReceipt(
        source: EmailImportSource,
        streamIdentifier: String,
        pageOrdinal: Int,
        requestOffset: Int?,
        nextOffset: Int?,
        requestCursorOverride: String? = nil,
        nextCursorOverride: String? = nil,
        sourceByteCount: Int,
        complete: Bool
    ) throws -> ConnectorPaginationReceipt {
        try .init(
            checkpointIdentifier: "email-import:\(source.sourceIdentifierHash)",
            streamIdentifier: streamIdentifier,
            pageOrdinal: pageOrdinal,
            requestCursor: requestCursorOverride
                ?? requestOffset.map { "byte:\($0)" },
            nextCursor: nextCursorOverride
                ?? nextOffset.map { "byte:\($0)" },
            sourceHighWatermark: "bytes:\(sourceByteCount)",
            isComplete: complete
        )
    }

    func paginationStreamIdentifier(
        source: EmailImportSource,
        runStartByteOffset: Int
    ) -> String {
        EmailDigest.sha256(
            "email-pagination-v1\u{1f}\(source.sourceIdentifierHash)\u{1f}\(runStartByteOffset)"
        )
    }

    func preparedPage(
        records: [EmailAdmissionRecord],
        checkpoint: EmailImportCheckpoint,
        pagination: ConnectorPaginationReceipt,
        source: EmailImportSource,
        skipped: Int,
        additionalReasonCounts: [String: Int],
        trace: EmailTraceContext
    ) -> EmailAdmissionPage {
        var reasonCounts = additionalReasonCounts
        for warning in records.flatMap({ $0.metadata.warnings }) {
            reasonCounts[warning.rawValue, default: 0] += 1
        }
        let receipt = EmailImportReceipt(
            schemaVersion: 1,
            sourceFormat: source.format,
            pageOrdinal: pagination.pageOrdinal,
            importedItemCount: records.count,
            skippedItemCount: skipped,
            attachmentCount: records.reduce(0) { $0 + $1.metadata.attachments.count },
            warningCounts: reasonCounts,
            paginationReceiptHash: pagination.receiptHash,
            completed: checkpoint.completed
        )
        emit(
            .pagePrepared,
            skipped == 0 ? .success : .degraded,
            skipped == 0 ? "email_page_prepared" : "email_page_prepared_with_skips",
            trace: trace,
            metadata: [
                ("source_hash", source.sourceIdentifierHash),
                ("format", source.format.rawValue),
                ("page_ordinal", String(pagination.pageOrdinal)),
                ("imported_count", String(records.count)),
                ("skipped_count", String(skipped)),
                ("attachment_count", String(receipt.attachmentCount)),
            ]
        )
        return .init(
            records: records,
            paginationReceipt: pagination,
            checkpointAfterCommit: checkpoint,
            receipt: receipt
        )
    }

    func importResult(
        page: EmailAdmissionPage,
        source: EmailImportSource
    ) -> EmailImportResult {
        let groups: [EmailVaultPageGroup]
        if page.records.isEmpty {
            groups = []
        } else {
            groups = [.init(
                provider: "support_email",
                providerAccountIdentifier: source.mailboxIdentifierHash,
                accountDisplayName: source.displayName,
                providerContainerIdentifier: source.sourceIdentifierHash,
                containerDisplayName: source.displayName,
                containerKind: "mailbox",
                paginationReceipt: page.paginationReceipt,
                records: page.records
            )]
        }
        return .init(
            sourceFormat: source.format,
            sourceDisplayName: source.displayName,
            mailboxDisplayIdentity: source.displayName,
            admissionPage: page,
            vaultPageGroups: groups,
            importedDataRetentionPolicy: .preserveOnAuthorizationRemoval
        )
    }

    func checkCancellation(
        _ isCancelled: @Sendable () -> Bool,
        trace: EmailTraceContext
    ) throws {
        if isCancelled() {
            emit(
                .cancellation,
                .skipped,
                EmailImportFailureCode.cancelled.rawValue,
                trace: trace
            )
            throw EmailImportFailureCode.cancelled
        }
    }

    func emit(
        _ event: EmailTraceEventName,
        _ status: EmailTraceStatus,
        _ reason: String,
        trace: EmailTraceContext,
        metadata: [(String, String)] = []
    ) {
        traceSink?(.init(
            timestamp: now(),
            event: event,
            status: status,
            reasonCode: String(reason.prefix(120)),
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            metadata: EmailTracePrivacy.metadata(metadata)
        ))
    }
}
