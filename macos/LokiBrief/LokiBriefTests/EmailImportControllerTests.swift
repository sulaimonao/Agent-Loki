import Foundation
import XCTest
@testable import LokiBrief

final class EmailImportControllerTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_691_504_116)

    func testSyntheticEMLProducesDeterministicVaultReadyImportResult() async throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/ticket.eml",
            mailboxIdentifier: "support@example.com",
            displayName: "Support Inbox",
            format: .eml,
            indexingPolicy: .archiveOnly
        )
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let data = Data(messageWithAttachment.utf8)

        let first = try controller.prepareEMLImport(data: data, source: source)
        let second = try controller.prepareEMLImport(data: data, source: source)

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.sourceDisplayName, "Support Inbox")
        XCTAssertEqual(first.mailboxDisplayIdentity, "Support Inbox")
        XCTAssertEqual(first.envelopes.count, 1)
        XCTAssertEqual(first.attachmentCount, 1)
        XCTAssertEqual(first.importedDataRetentionPolicy, .preserveOnAuthorizationRemoval)
        XCTAssertTrue(first.checkpointAfterCommit.completed)
        XCTAssertTrue(first.paginationReceipt.isComplete)
        XCTAssertEqual(first.paginationReceipt.receiptHash, first.admissionPage.receipt.paginationReceiptHash)

        let group = try XCTUnwrap(first.vaultPageGroups.first)
        let descriptors = try group.records.map {
            try ConnectorVaultRecordDescriptor(
                envelope: $0.envelope,
                title: $0.metadata.headers.subject,
                authorReference: $0.metadata.headers.from.first,
                additionalMetadata: [
                    "email_thread_basis": $0.metadata.thread.basis.rawValue,
                    "email_raw_sha256": $0.metadata.rawMessageSHA256,
                ]
            )
        }
        let vaultPage = try ConnectorVaultPage(
            kind: .supportEmail,
            provider: .supportEmail,
            providerAccountIdentifier: group.providerAccountIdentifier,
            accountDisplayName: group.accountDisplayName,
            providerContainerIdentifier: group.providerContainerIdentifier,
            containerDisplayName: group.containerDisplayName,
            containerKind: .mailbox,
            paginationReceipt: group.paginationReceipt,
            records: descriptors
        )
        let mutation = try vaultPage.mutation(at: anchor)

        XCTAssertEqual(mutation.records.count, 1)
        XCTAssertEqual(mutation.records[0].providerRecordID, first.envelopes[0].remoteRecordIdentifier)
        XCTAssertEqual(mutation.records[0].body, first.envelopes[0].normalizedText)
        XCTAssertEqual(mutation.paginationReceiptHash, first.paginationReceipt.receiptHash)

        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let committed = try await database.commit(connectorPage: mutation)
        XCTAssertEqual(committed.insertedCount, 1)
        let stored = try await database.record(id: mutation.records[0].id)
        XCTAssertEqual(stored?.body, first.envelopes[0].normalizedText)
        let reconstructed = try stored.map {
            try ConnectorVaultStoredEnvelope.reconstruct(from: $0)
        }
        XCTAssertEqual(
            reconstructed?.canonicalEnvelopeHash,
            first.envelopes[0].canonicalEnvelopeHash
        )
    }

    func testSameMessageIDReimportUpdatesStableVaultIdentity() async throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/edited-ticket.eml",
            displayName: "Edited ticket",
            format: .eml
        )
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let first = try controller.prepareEMLImport(
            data: Data("Message-ID: <same@example.com>\nFrom: support@example.com\nSubject: Ticket\n\nFirst body".utf8),
            source: source
        )
        let edited = try controller.prepareEMLImport(
            data: Data("Message-ID: <same@example.com>\nFrom: support@example.com\nSubject: Ticket\n\nEdited body".utf8),
            source: source
        )
        let originalEnvelope = try XCTUnwrap(first.envelopes.first)
        let editedEnvelope = try XCTUnwrap(edited.envelopes.first)
        XCTAssertEqual(
            originalEnvelope.deduplicationKey,
            editedEnvelope.deduplicationKey
        )
        XCTAssertNotEqual(
            originalEnvelope.editOrVersionIdentifier,
            editedEnvelope.editOrVersionIdentifier
        )
        XCTAssertNotEqual(
            originalEnvelope.canonicalEnvelopeHash,
            editedEnvelope.canonicalEnvelopeHash
        )

        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let originalPage = try vaultPage(first)
        let editedPage = try vaultPage(edited)
        let inserted = try await database.commit(
            connectorPage: originalPage.mutation()
        )
        let updated = try await database.commit(
            connectorPage: editedPage.mutation()
        )
        XCTAssertEqual(inserted.insertedCount, 1)
        XCTAssertEqual(updated.updatedCount, 1)
    }

    func testMBoxPageSkipsMalformedEntryAndCommitsOnlyReturnedPage() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/support.mbox",
            displayName: "Support mailbox",
            format: .mbox
        )
        let anchor = anchor
        let valid = """
        From support@example.com Tue Aug  8 14:15:16 2023
        Message-ID: <valid@example.com>
        From: support@example.com
        Subject: Valid

        Body
        """
        let malformed = """
        From support@example.com Tue Aug  8 14:16:16 2023
        this is not an RFC header section

        Broken
        """
        let result = try EmailImportController(now: { anchor }).prepareMBoxImport(
            data: Data((valid + "\n" + malformed).utf8),
            source: source
        )

        XCTAssertEqual(result.envelopes.count, 1)
        XCTAssertEqual(result.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertTrue(result.checkpointAfterCommit.completed)
        XCTAssertEqual(
            result.admissionPage.receipt.warningCounts[EmailImportFailureCode.headerSectionMissing.rawValue],
            1
        )
    }

    func testMBoxSeparatorDatePrecedesFileModificationFallback() throws {
        let anchor = anchor
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/separator-date.mbox",
            displayName: "Separator date",
            format: .mbox,
            observedModificationDate: anchor
        )
        let data = Data("""
        From support@example.com Tue Aug  8 14:15:16 -0700 2023
        Message-ID: <separator-date@example.com>
        From: support@example.com
        Subject: Timestamp

        Body
        """.utf8)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let expected = try XCTUnwrap(calendar.date(from: DateComponents(
            year: 2023,
            month: 8,
            day: 8,
            hour: 21,
            minute: 15,
            second: 16
        )))
        let result = try EmailImportController(now: { anchor })
            .prepareMBoxImport(data: data, source: source)
        let record = try XCTUnwrap(result.admissionPage.records.first)

        XCTAssertEqual(record.metadata.headers.receivedDate, expected)
        XCTAssertEqual(record.envelope.sourceTimestamp, expected)
        XCTAssertNotEqual(record.envelope.sourceTimestamp, anchor)
    }

    func testDuplicateMessageIDInOneMBoxPageIsReconciledDeterministically() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/duplicates.mbox",
            displayName: "Duplicate mailbox",
            format: .mbox
        )
        let anchor = anchor
        let original = mboxEntry(
            id: "duplicate@example.com",
            body: "First"
        )
        let edited = mboxEntry(
            id: "duplicate@example.com",
            body: "Edited"
        )

        let controller = EmailImportController(now: { anchor })
        let result = try controller
            .prepareMBoxImport(
                data: Data((original + edited).utf8),
                source: source
            )
        let reversed = try controller.prepareMBoxImport(
            data: Data((edited + original).utf8),
            source: source
        )

        XCTAssertEqual(result.envelopes.count, 1)
        XCTAssertEqual(reversed.envelopes.count, 1)
        XCTAssertEqual(
            result.envelopes[0].sourceHash,
            reversed.envelopes[0].sourceHash
        )
        XCTAssertEqual(result.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertEqual(
            result.admissionPage.receipt.warningCounts[
                EmailImportReasonCode.duplicateMessageSuperseded.rawValue
            ],
            1
        )
    }

    func testDuplicateRawDigestWithoutMessageIDIsSkippedWithinPage() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/duplicate-digest.mbox",
            displayName: "Duplicate digest mailbox",
            format: .mbox
        )
        let entry = """
        From support@example.com Tue Aug  8 14:15:16 2023
        From: support@example.com
        To: customer@example.net
        Subject: No identifier

        Same body
        """
        let anchor = anchor

        let result = try EmailImportController(now: { anchor })
            .prepareMBoxImport(
                data: Data((entry + "\n" + entry + "\n").utf8),
                source: source
            )

        XCTAssertEqual(result.envelopes.count, 1)
        XCTAssertEqual(result.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertEqual(
            result.admissionPage.receipt.warningCounts[
                EmailImportReasonCode.duplicateMessageSkipped.rawValue
            ],
            1
        )
    }

    func testHundredMessageBoundaryResolvesPriorPageInReplyToRoot() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/hundred-boundary.mbox",
            displayName: "Hundred boundary",
            format: .mbox
        )
        var entries = [mboxEntry(id: "root@example.com")]
        entries.append(contentsOf: (0..<98).map {
            mboxEntry(id: "filler-\($0)@example.com")
        })
        entries.append(mboxEntry(
            id: "parent@example.com",
            inReplyTo: "root@example.com"
        ))
        entries.append(mboxEntry(
            id: "child@example.com",
            inReplyTo: "parent@example.com"
        ))
        let data = Data(entries.joined().utf8)
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let session = try controller.makeMBoxImportSession(
            data: data,
            source: source
        )

        let first = try controller.prepareMBoxImport(
            session: session,
            source: source
        )
        XCTAssertEqual(first.envelopes.count, 100)
        XCTAssertFalse(first.checkpointAfterCommit.completed)
        let root = try XCTUnwrap(first.admissionPage.records.first {
            $0.metadata.headers.messageID == "root@example.com"
        })
        let second = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit
        )
        let child = try XCTUnwrap(second.admissionPage.records.first {
            $0.metadata.headers.messageID == "child@example.com"
        })

        // The terminal convergence pass conservatively re-emits the already
        // correct In-Reply-To parent as well as admitting the new child. This
        // makes restart reconstruction independent of historic page sizing.
        XCTAssertEqual(second.envelopes.count, 2)
        XCTAssertEqual(child.metadata.headers.messageID, "child@example.com")
        XCTAssertEqual(child.metadata.thread.basis, .inReplyTo)
        XCTAssertEqual(child.metadata.thread.parentMessageID, "parent@example.com")
        XCTAssertEqual(child.metadata.thread.rootMessageID, "root@example.com")
        XCTAssertEqual(
            child.envelope.parentOrThreadIdentifier,
            root.envelope.parentOrThreadIdentifier
        )
    }

    func testLateParentAfterDefaultBoundaryRepairsChildrenBoundedlyAcrossRetryAndRestart() async throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/late-parent-boundary.mbox",
            displayName: "Late parent boundary",
            format: .mbox
        )
        let childIdentifiers = (0...100).map {
            "late-child-\($0)@example.com"
        }
        let parentIdentifier = "late-parent@example.com"
        let rootIdentifier = "late-root@example.com"
        let entries = childIdentifiers.map {
            mboxEntry(id: $0, inReplyTo: parentIdentifier)
        } + [
            mboxEntry(id: parentIdentifier, inReplyTo: rootIdentifier),
            mboxEntry(id: rootIdentifier),
        ]
        let data = Data(entries.joined().utf8)
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let session = try controller.makeMBoxImportSession(
            data: data,
            source: source
        )

        let first = try controller.prepareMBoxImport(
            session: session,
            source: source
        )
        let uncommittedFirstRetry = try controller.prepareMBoxImport(
            session: session,
            source: source
        )
        XCTAssertEqual(first, uncommittedFirstRetry)
        XCTAssertEqual(first.envelopes.count, 100)
        XCTAssertFalse(first.checkpointAfterCommit.completed)
        XCTAssertNil(first.checkpointAfterCommit.threadRepairGeneration)
        XCTAssertTrue(first.admissionPage.records.allSatisfy {
            $0.metadata.thread.rootMessageID == parentIdentifier
        })

        let second = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit
        )
        let uncommittedSecondRetry = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit
        )
        XCTAssertEqual(second, uncommittedSecondRetry)
        try second.paginationReceipt.validate(after: first.paginationReceipt)
        XCTAssertEqual(second.envelopes.count, 100)
        XCTAssertFalse(second.checkpointAfterCommit.completed)
        XCTAssertEqual(
            second.checkpointAfterCommit.committedByteCount,
            data.count
        )
        XCTAssertEqual(
            second.checkpointAfterCommit.nextByteOffset,
            data.count
        )
        XCTAssertNotNil(second.checkpointAfterCommit.threadRepairGeneration)
        XCTAssertNotNil(
            second.checkpointAfterCommit.threadRepairAfterRemoteIdentifier
        )

        let persistedSecondCheckpoint = try JSONDecoder().decode(
            EmailImportCheckpoint.self,
            from: JSONEncoder().encode(second.checkpointAfterCommit)
        )
        let restartedSession = try controller.makeMBoxImportSession(
            data: data,
            source: source,
            checkpoint: persistedSecondCheckpoint
        )
        let third = try controller.prepareMBoxImport(
            session: restartedSession,
            source: source,
            checkpoint: persistedSecondCheckpoint
        )
        try third.paginationReceipt.validate(after: second.paginationReceipt)
        XCTAssertTrue(third.checkpointAfterCommit.completed)
        XCTAssertNil(third.checkpointAfterCommit.nextByteOffset)
        XCTAssertEqual(
            third.checkpointAfterCommit.threadRepairGeneration,
            second.checkpointAfterCommit.threadRepairGeneration
        )

        let convergedRecords = second.admissionPage.records
            + third.admissionPage.records
        let convergedChildren = convergedRecords.filter {
            childIdentifiers.contains($0.metadata.headers.messageID ?? "")
        }
        XCTAssertEqual(
            Set(convergedChildren.compactMap { $0.metadata.headers.messageID }),
            Set(childIdentifiers)
        )
        XCTAssertTrue(convergedChildren.allSatisfy {
            $0.metadata.thread.rootMessageID == rootIdentifier
        })
        let expectedThreadIdentifier = "email-thread:\(EmailDigest.sha256(rootIdentifier))"
        XCTAssertTrue(convergedChildren.allSatisfy {
            $0.envelope.parentOrThreadIdentifier == expectedThreadIdentifier
        })

        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        _ = try await database.commit(connectorPage: try vaultPage(first).mutation())
        _ = try await database.commit(connectorPage: try vaultPage(second).mutation())
        _ = try await database.commit(connectorPage: try vaultPage(third).mutation())
        for firstRecord in first.admissionPage.records {
            let stored = try await database.record(
                id: "connector:\(firstRecord.envelope.deduplicationKey)"
            )
            XCTAssertEqual(stored?.threadRootID, expectedThreadIdentifier)
        }
    }

    func testUncommittedRetryIsAtomicBeforeCrossPageConflictReconciliation() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/retry-conflict.mbox",
            displayName: "Retry conflict",
            format: .mbox
        )
        let original = mboxEntry(
            id: "retry-conflict@example.com",
            body: "Original"
        )
        let edited = mboxEntry(
            id: "retry-conflict@example.com",
            body: "Edited"
        )
        let data = Data((original + edited).utf8)
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let session = try controller.makeMBoxImportSession(
            data: data,
            source: source
        )

        let first = try controller.prepareMBoxImport(
            session: session,
            source: source,
            pageSize: 1
        )
        let uncommittedRetry = try controller.prepareMBoxImport(
            session: session,
            source: source,
            pageSize: 1
        )
        XCTAssertEqual(first, uncommittedRetry)
        XCTAssertEqual(first.envelopes.count, 1)
        XCTAssertEqual(first.admissionPage.receipt.skippedItemCount, 0)

        let globallyReconciled = try controller.prepareMBoxImport(
            data: data,
            source: source,
            pageSize: 2
        )
        let second = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit,
            pageSize: 1
        )
        let uncommittedSecondRetry = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit,
            pageSize: 1
        )
        XCTAssertEqual(second, uncommittedSecondRetry)
        XCTAssertEqual(second.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertEqual(
            second.admissionPage.receipt.warningCounts[
                EmailImportReasonCode.duplicateMessageSuperseded.rawValue
            ],
            1
        )
        XCTAssertEqual(
            second.envelopes.first?.sourceHash ?? first.envelopes[0].sourceHash,
            globallyReconciled.envelopes[0].sourceHash
        )
    }

    func testPersistedCheckpointRestartRebuildsThreadAndDuplicateContext() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/restart-context.mbox",
            displayName: "Restart context",
            format: .mbox
        )
        let duplicate = mboxEntry(id: "duplicate-across-page@example.com")
        let data = Data((
            mboxEntry(id: "restart-root@example.com")
                + duplicate
                + mboxEntry(
                    id: "restart-child@example.com",
                    inReplyTo: "restart-root@example.com"
                )
                + duplicate
        ).utf8)
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let firstSession = try controller.makeMBoxImportSession(
            data: data,
            source: source
        )
        let first = try controller.prepareMBoxImport(
            session: firstSession,
            source: source,
            pageSize: 2
        )
        let persistedCheckpoint = try JSONDecoder().decode(
            EmailImportCheckpoint.self,
            from: JSONEncoder().encode(first.checkpointAfterCommit)
        )

        let restartedSession = try controller.makeMBoxImportSession(
            data: data,
            source: source,
            checkpoint: persistedCheckpoint
        )
        let resumed = try controller.prepareMBoxImport(
            session: restartedSession,
            source: source,
            checkpoint: persistedCheckpoint,
            pageSize: 2
        )
        let child = try XCTUnwrap(resumed.admissionPage.records.first)

        XCTAssertEqual(resumed.envelopes.count, 1)
        XCTAssertEqual(child.metadata.headers.messageID, "restart-child@example.com")
        XCTAssertEqual(child.metadata.thread.rootMessageID, "restart-root@example.com")
        XCTAssertEqual(resumed.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertEqual(
            resumed.admissionPage.receipt.warningCounts[
                EmailImportReasonCode.duplicateMessageSkipped.rawValue
            ],
            1
        )
    }

    func testCancellationDoesNotPublishHalfPreparedPage() {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/ticket.eml",
            displayName: "Ticket",
            format: .eml
        )
        let anchor = anchor

        XCTAssertThrowsError(
            try EmailImportController(now: { anchor }).prepareEMLImport(
                data: Data(messageWithAttachment.utf8),
                source: source,
                isCancelled: { true }
            )
        ) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
    }

    func testMBoxPaginationReceiptsAdvanceAndAppendStartsNewDeterministicRun() throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/paged.mbox",
            displayName: "Paged mailbox",
            format: .mbox
        )
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let original = Data((mboxEntry(id: "one@example.com")
            + mboxEntry(id: "two@example.com")).utf8)

        let first = try controller.prepareMBoxImport(
            data: original,
            source: source,
            pageSize: 1
        )
        let second = try controller.prepareMBoxImport(
            data: original,
            source: source,
            checkpoint: first.checkpointAfterCommit,
            pageSize: 1
        )
        try second.paginationReceipt.validate(after: first.paginationReceipt)
        XCTAssertTrue(second.checkpointAfterCommit.completed)

        var appended = original
        appended.append(Data(mboxEntry(id: "three@example.com").utf8))
        let append = try controller.prepareMBoxImport(
            data: appended,
            source: source,
            checkpoint: second.checkpointAfterCommit,
            pageSize: 1
        )

        XCTAssertEqual(append.paginationReceipt.pageOrdinal, 0)
        XCTAssertNil(append.paginationReceipt.requestCursor)
        XCTAssertNotEqual(
            append.paginationReceipt.streamIdentifier,
            second.paginationReceipt.streamIdentifier
        )
        XCTAssertEqual(append.envelopes.count, 1)
        XCTAssertTrue(append.envelopes[0].remoteRecordIdentifier.contains(
            EmailDigest.sha256("message-id\u{1f}three@example.com")
        ))
    }

    func testIdenticalUndatedEmailWithDifferentSourceMTimesIsUnchangedInVault() async throws {
        let anchor = anchor
        let firstSource = EmailImportSource(
            sourceIdentifier: "/synthetic/undated.eml",
            displayName: "Undated",
            format: .eml,
            observedModificationDate: anchor
        )
        let touchedSource = EmailImportSource(
            sourceIdentifier: "/synthetic/undated.eml",
            displayName: "Undated",
            format: .eml,
            observedModificationDate: anchor.addingTimeInterval(86_400)
        )
        let data = Data(
            "Message-ID: <undated@example.com>\nFrom: support@example.com\nSubject: Stable\n\nSame body"
                .utf8
        )
        let first = try EmailImportController(now: { anchor })
            .prepareEMLImport(data: data, source: firstSource)
        let replay = try EmailImportController(now: {
            anchor.addingTimeInterval(600)
        }).prepareEMLImport(data: data, source: touchedSource)
        XCTAssertEqual(
            first.envelopes[0].remoteRecordIdentifier,
            replay.envelopes[0].remoteRecordIdentifier
        )
        XCTAssertEqual(
            first.envelopes[0].deduplicationKey,
            replay.envelopes[0].deduplicationKey
        )
        XCTAssertEqual(
            first.envelopes[0].canonicalEnvelopeHash,
            replay.envelopes[0].canonicalEnvelopeHash
        )
        XCTAssertEqual(
            first.envelopes[0].sourceTimestamp,
            Date(timeIntervalSince1970: 0)
        )
        XCTAssertEqual(
            replay.envelopes[0].sourceTimestamp,
            Date(timeIntervalSince1970: 0)
        )
        XCTAssertNil(first.admissionPage.records[0].metadata.headers.receivedDate)
        XCTAssertNil(replay.admissionPage.records[0].metadata.headers.receivedDate)

        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let firstPage = try vaultPage(first)
        let replayPage = try vaultPage(replay)
        let inserted = try await database.commit(
            connectorPage: firstPage.mutation()
        )
        XCTAssertEqual(inserted.insertedCount, 1)
        let replayResult = try await database.commit(
            connectorPage: replayPage.mutation()
        )
        XCTAssertEqual(replayResult.unchangedCount, 1)
        let recordID = "connector:\(replay.envelopes[0].deduplicationKey)"
        let revisions = try await database.revisions(recordID: recordID)
        XCTAssertEqual(revisions, [])
        let loaded = try await database.record(id: recordID)
        let stored = try XCTUnwrap(loaded)
        XCTAssertEqual(
            try ConnectorVaultStoredEnvelope.reconstruct(from: stored)
                .canonicalEnvelopeHash,
            first.envelopes[0].canonicalEnvelopeHash
        )
        XCTAssertEqual(
            try EmailVaultStoredMetadata.reconstruct(from: stored),
            first.admissionPage.records[0].metadata
        )
    }

    func testPartialFailurePageCommitsAndCheckpointResumesNextPage() async throws {
        let source = EmailImportSource(
            sourceIdentifier: "/synthetic/partial-resume.mbox",
            displayName: "Partial resume",
            format: .mbox
        )
        let malformed = """
        From support@example.com Tue Aug  8 14:16:16 2023
        not an RFC header

        Broken
        """
        let data = Data((
            mboxEntry(id: "one@example.com")
                + malformed + "\n"
                + mboxEntry(id: "two@example.com")
        ).utf8)
        let anchor = anchor
        let controller = EmailImportController(now: { anchor })
        let session = try controller.makeMBoxImportSession(
            data: data,
            source: source
        )
        let first = try controller.prepareMBoxImport(
            session: session,
            source: source,
            pageSize: 2
        )
        XCTAssertEqual(first.envelopes.count, 1)
        XCTAssertEqual(first.admissionPage.receipt.skippedItemCount, 1)
        XCTAssertFalse(first.checkpointAfterCommit.completed)

        let database = try VaultDatabase(inMemory: true, traceSink: { _ in })
        let firstPage = try vaultPage(first)
        let firstCommit = try await database.commit(
            connectorPage: firstPage.mutation()
        )
        XCTAssertEqual(firstCommit.insertedCount, 1)
        let second = try controller.prepareMBoxImport(
            session: session,
            source: source,
            checkpoint: first.checkpointAfterCommit,
            pageSize: 2
        )
        try second.paginationReceipt.validate(after: first.paginationReceipt)
        XCTAssertTrue(second.checkpointAfterCommit.completed)
        XCTAssertEqual(second.envelopes.count, 1)
        let secondPage = try vaultPage(second)
        let secondCommit = try await database.commit(
            connectorPage: secondPage.mutation()
        )
        XCTAssertEqual(secondCommit.insertedCount, 1)
        let admitted = try await database.connectorEnvelopes(
            accountID: secondPage.accountID,
            containerIDs: [secondPage.containerID]
        )
        XCTAssertEqual(admitted.count, 2)
    }

    func testBoundedFileReaderEnforcesLimitAndMidReadCancellation() throws {
        let url = try temporaryEmailFile(
            Data(repeating: 0x61, count: 4_096)
        )
        XCTAssertThrowsError(try EmailBoundedFileReader.readAuthorizedFile(
            at: url,
            maximumBytes: 1_024,
            chunkByteCount: 128
        )) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .sourceTooLarge)
        }

        let probe = EmailFileCancellationProbe(cancelAfterCheck: 4)
        XCTAssertThrowsError(try EmailBoundedFileReader.readAuthorizedFile(
            at: url,
            maximumBytes: 8_192,
            chunkByteCount: 256,
            isCancelled: { probe.isCancelled() }
        )) { error in
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
        XCTAssertGreaterThanOrEqual(probe.checkCount, 4)
    }

    func testDetachedFileReaderObservesAlreadyCancelledOwner() async throws {
        let url = try temporaryEmailFile(
            Data(repeating: 0x62, count: 256 * 1_024)
        )
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await EmailBoundedFileReader.readAuthorizedFileDetached(
                at: url,
                maximumBytes: 512 * 1_024,
                chunkByteCount: 1_024
            )
        }

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? EmailImportFailureCode, .cancelled)
        }
    }

    func testPreservedMetadataBudgetAcceptsMaximumAttachmentsAndFailsExplicitlyWhenExceeded() throws {
        let headers = EmailHeaderFields(
            messageID: "budget@example.com",
            inReplyTo: nil,
            references: [],
            from: ["support@example.com"],
            to: ["customer@example.net"],
            cc: [],
            replyTo: [],
            subject: "Metadata budget",
            sentDate: anchor,
            receivedDate: anchor
        )
        let attachments = (0..<EmailImportLimits.maximumAttachments).map {
            EmailAttachmentMetadata(
                identifier: EmailDigest.sha256("attachment-\($0)"),
                filename: String(repeating: "a", count: 220) + "-\($0).bin",
                mediaType: "application/octet-stream",
                byteCount: $0 + 1,
                sha256: EmailDigest.sha256("payload-\($0)"),
                digestBasis: .decodedContent,
                disposition: "attachment",
                contentID: nil,
                wasOversized: false
            )
        }
        let accepted = try EmailPreservedMetadata(
            headers: headers,
            attachments: attachments,
            thread: .init(
                basis: .messageIDRoot,
                parentMessageID: nil,
                rootMessageID: "budget@example.com",
                heuristicKey: nil
            ),
            rawMessageSHA256: EmailDigest.sha256("raw"),
            warnings: [],
            mailboxIdentifierHash: EmailDigest.sha256("mailbox"),
            importSourceIdentifierHash: EmailDigest.sha256("source")
        )
        XCTAssertLessThanOrEqual(
            try accepted.canonicalJSONData().count,
            EmailImportLimits.maximumPreservedMetadataBytes
        )

        let oversizedHeaders = EmailHeaderFields(
            messageID: headers.messageID,
            inReplyTo: nil,
            references: [],
            from: headers.from,
            to: Array(
                repeating: String(
                    repeating: "x",
                    count: EmailImportLimits.maximumHeaderValueCharacters
                ),
                count: 8
            ),
            cc: [],
            replyTo: [],
            subject: headers.subject,
            sentDate: headers.sentDate,
            receivedDate: headers.receivedDate
        )
        XCTAssertThrowsError(try EmailPreservedMetadata(
            headers: oversizedHeaders,
            attachments: [],
            thread: .init(
                basis: .messageIDRoot,
                parentMessageID: nil,
                rootMessageID: "budget@example.com",
                heuristicKey: nil
            ),
            rawMessageSHA256: EmailDigest.sha256("raw"),
            warnings: [],
            mailboxIdentifierHash: EmailDigest.sha256("mailbox"),
            importSourceIdentifierHash: EmailDigest.sha256("source")
        )) { error in
            XCTAssertEqual(
                error as? EmailImportFailureCode,
                .preservedMetadataTooLarge
            )
        }
    }

    private func vaultPage(_ result: EmailImportResult) throws
        -> ConnectorVaultPage
    {
        let group = try XCTUnwrap(result.vaultPageGroups.first)
        return try ConnectorVaultPage(
            kind: .supportEmail,
            provider: .supportEmail,
            providerAccountIdentifier: group.providerAccountIdentifier,
            accountDisplayName: group.accountDisplayName,
            providerContainerIdentifier: group.providerContainerIdentifier,
            containerDisplayName: group.containerDisplayName,
            containerKind: .mailbox,
            paginationReceipt: group.paginationReceipt,
            records: try group.records.map {
                let preserved = try $0.metadata.canonicalJSONData()
                guard let preservedJSON = String(
                    data: preserved,
                    encoding: .utf8
                ) else {
                    throw EmailImportFailureCode.envelopeRejected
                }
                return try ConnectorVaultRecordDescriptor(
                    envelope: $0.envelope,
                    title: $0.metadata.headers.subject,
                    authorReference: $0.metadata.headers.from.first,
                    additionalMetadata: [
                        "email_raw_message_sha256": $0.metadata.rawMessageSHA256,
                        "email_mailbox_id_sha256": $0.metadata.mailboxIdentifierHash,
                        "email_import_source_id_sha256": $0.metadata.importSourceIdentifierHash,
                        EmailVaultStoredMetadata.metadataKey: preservedJSON,
                    ]
                )
            }
        )
    }

    private var messageWithAttachment: String {
        let payload = Data("diagnostic bytes".utf8).base64EncodedString()
        return """
        Message-ID: <ticket-42@example.com>
        Date: Tue, 8 Aug 2023 14:15:16 +0000
        From: Support Agent <support@example.com>
        To: Customer <customer@example.net>
        Subject: Ticket 42
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="mixed"

        --mixed
        Content-Type: text/plain; charset=utf-8

        Resolution steps.
        --mixed
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename="diagnostic.bin"
        Content-Transfer-Encoding: base64

        \(payload)
        --mixed--
        """
    }

    private func mboxEntry(
        id: String,
        inReplyTo: String? = nil,
        body: String = "Body"
    ) -> String {
        "From support@example.com Tue Aug  8 14:15:16 2023\n"
            + "Message-ID: <\(id)>\n"
            + (inReplyTo.map { "In-Reply-To: <\($0)>\n" } ?? "")
            + "From: support@example.com\n"
            + "To: customer@example.net\n"
            + "Subject: Ticket\n\n"
            + "\(body)\n"
    }

    private func temporaryEmailFile(_ data: Data) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("loki-email-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let url = directory.appendingPathComponent("synthetic.eml")
        try data.write(to: url, options: .atomic)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return url
    }
}

private final class EmailFileCancellationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let cancelAfterCheck: Int
    private var checks = 0

    init(cancelAfterCheck: Int) {
        self.cancelAfterCheck = cancelAfterCheck
    }

    var checkCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return checks
    }

    func isCancelled() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        checks += 1
        return checks >= cancelAfterCheck
    }
}
