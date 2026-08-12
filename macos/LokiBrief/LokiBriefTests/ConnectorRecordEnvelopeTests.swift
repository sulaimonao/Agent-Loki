import Foundation
import XCTest
@testable import LokiBrief

final class ConnectorRecordEnvelopeTests: XCTestCase {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    func testEnvelopeNormalizationAttachmentOrderingAndHashAreDeterministic() throws {
        let receipt = try pageReceipt()
        let firstAttachment = try ConnectorAttachmentMetadata(
            attachmentIdentifier: "attachment-b",
            mediaType: "IMAGE/PNG",
            byteCount: 20,
            sourceHash: digest("attachment-b")
        )
        let secondAttachment = try ConnectorAttachmentMetadata(
            attachmentIdentifier: "attachment-a",
            mediaType: "image/jpeg",
            byteCount: 10,
            sourceHash: digest("attachment-a")
        )
        let lhs = try envelope(
            text: "A normalized connector record",
            attachments: [firstAttachment, secondAttachment],
            receipt: receipt
        )
        let rhs = try envelope(
            text: "A normalized connector record",
            attachments: [secondAttachment, firstAttachment],
            receipt: receipt
        )

        XCTAssertEqual(lhs.attachments.map(\.attachmentIdentifier), ["attachment-a", "attachment-b"])
        XCTAssertEqual(lhs, rhs)
        XCTAssertEqual(lhs.canonicalEnvelopeHash, rhs.canonicalEnvelopeHash)
        XCTAssertEqual(lhs.deduplicationKey, rhs.deduplicationKey)
        let roundTrip = try JSONDecoder().decode(
            ConnectorRecordEnvelope.self,
            from: JSONEncoder().encode(lhs)
        )
        XCTAssertEqual(roundTrip, lhs)
        XCTAssertThrowsError(
            try envelope(text: "  not   normalized  ", receipt: receipt)
        ) { error in
            XCTAssertEqual(error as? ConnectorEnvelopeFailureCode, .normalizedTextMismatch)
        }
    }

    func testTextNormalizationPreservesBoundariesAcrossUnsafeScalars() {
        XCTAssertEqual(
            ConnectorTextNormalization.text(
                "body: Alpha\nid: a\tstatus:\u{0}ready\u{202E}safe"
            ),
            "body: Alpha id: a status: ready safe"
        )
    }

    func testReconciliationDeterministicallyHandlesDedupUpdateAndTombstone() throws {
        let receipt = try pageReceipt()
        let original = try envelope(
            text: "Original record",
            version: "1",
            sourceTimestamp: anchor,
            receipt: receipt
        )
        let updated = try envelope(
            text: "Updated record",
            version: "2",
            sourceTimestamp: anchor.addingTimeInterval(10),
            receipt: receipt
        )

        let forward = try XCTUnwrap(
            ConnectorRecordReconciler.reconcile(
                existing: original,
                incoming: [original, updated]
            )
        )
        let reversed = try XCTUnwrap(
            ConnectorRecordReconciler.reconcile(
                existing: original,
                incoming: [updated, original]
            )
        )
        XCTAssertEqual(forward.selectedEnvelope, updated)
        XCTAssertEqual(forward, reversed)
        XCTAssertEqual(forward.disposition, .updated)

        let tombstone = try envelope(
            text: "",
            version: "3",
            sourceTimestamp: anchor.addingTimeInterval(20),
            deletionState: .tombstone,
            receipt: receipt
        )
        let deleted = try XCTUnwrap(
            ConnectorRecordReconciler.reconcile(
                existing: updated,
                incoming: [tombstone]
            )
        )
        XCTAssertEqual(deleted.disposition, .tombstoned)
        XCTAssertNil(deleted.selectedEnvelope.indexHandoff())

        let stale = try XCTUnwrap(
            ConnectorRecordReconciler.reconcile(
                existing: updated,
                incoming: [original]
            )
        )
        XCTAssertEqual(stale.disposition, .staleIgnored)
        XCTAssertEqual(stale.selectedEnvelope, updated)
    }

    func testPaginationReceiptsRequireExactScopeAndCursorAdvancement() throws {
        let first = try pageReceipt(
            page: 0,
            requestCursor: nil,
            nextCursor: "CURSOR_PAGE_1_SENTINEL",
            complete: false
        )
        let second = try pageReceipt(
            page: 1,
            requestCursor: "CURSOR_PAGE_1_SENTINEL",
            nextCursor: nil,
            complete: true
        )
        XCTAssertNoThrow(try first.validate(after: nil))
        XCTAssertNoThrow(try second.validate(after: first))

        let wrongCursor = try ConnectorPaginationReceipt(
            checkpointIdentifier: "checkpoint-1",
            streamIdentifier: "history",
            pageOrdinal: 1,
            requestCursor: "WRONG_CURSOR_SENTINEL",
            nextCursor: nil,
            sourceHighWatermark: "high-water-2",
            isComplete: true
        )
        XCTAssertThrowsError(try wrongCursor.validate(after: first)) { error in
            XCTAssertEqual(error as? ConnectorEnvelopeFailureCode, .paginationDidNotAdvance)
        }

        let wrongScope = try ConnectorPaginationReceipt(
            checkpointIdentifier: "checkpoint-other",
            streamIdentifier: "history",
            pageOrdinal: 1,
            requestCursor: "CURSOR_PAGE_1_SENTINEL",
            nextCursor: nil,
            sourceHighWatermark: "high-water-2",
            isComplete: true
        )
        XCTAssertThrowsError(try wrongScope.validate(after: first)) { error in
            XCTAssertEqual(error as? ConnectorEnvelopeFailureCode, .paginationScopeMismatch)
        }
    }

    func testPageReconciliationBindsEveryRecordToOneReceipt() throws {
        let receipt = try pageReceipt()
        let older = try envelope(
            text: "Older",
            version: "1",
            sourceTimestamp: anchor,
            receipt: receipt
        )
        let newer = try envelope(
            text: "Newer",
            version: "2",
            sourceTimestamp: anchor.addingTimeInterval(1),
            receipt: receipt
        )
        let results = try ConnectorRecordReconciler.reconcilePage(
            [newer, older],
            after: nil
        )
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].selectedEnvelope, newer)

        let otherReceipt = try ConnectorPaginationReceipt(
            checkpointIdentifier: "checkpoint-1",
            streamIdentifier: "history",
            pageOrdinal: 0,
            requestCursor: nil,
            nextCursor: "other-next",
            sourceHighWatermark: "high-water",
            isComplete: false
        )
        let mismatched = try envelope(
            text: "Mismatch",
            version: "3",
            sourceTimestamp: anchor.addingTimeInterval(2),
            receipt: otherReceipt
        )
        XCTAssertThrowsError(
            try ConnectorRecordReconciler.reconcilePage([newer, mismatched], after: nil)
        ) { error in
            XCTAssertEqual(error as? ConnectorEnvelopeFailureCode, .paginationReceiptMismatch)
        }
    }

    func testSensitiveAndReasoningClassificationsCannotCrossIndexHandoff() throws {
        let receipt = try pageReceipt()
        XCTAssertThrowsError(
            try envelope(
                text: "Ephemeral private reasoning",
                policy: .localIndexAllowed,
                content: .hiddenReasoning,
                receipt: receipt
            )
        ) { error in
            XCTAssertEqual(
                error as? ConnectorEnvelopeFailureCode,
                .sensitiveContentCannotBeIndexed
            )
        }

        let archiveOnly = try envelope(
            text: "Ephemeral private reasoning",
            policy: .archiveOnly,
            content: .hiddenReasoning,
            receipt: receipt
        )
        XCTAssertNil(archiveOnly.indexHandoff())

        XCTAssertThrowsError(
            try envelope(
                text: "Classified source content",
                policy: .localIndexAllowed,
                containsSensitiveMaterial: true,
                receipt: receipt
            )
        ) { error in
            XCTAssertEqual(
                error as? ConnectorEnvelopeFailureCode,
                .sensitiveContentCannotBeIndexed
            )
        }
    }

    func testIndexHandoffOmitsCursorAndAttachmentMetadata() throws {
        let cursor = "PRIVATE_PROVIDER_CURSOR_MUST_NOT_CROSS_INDEX_HANDOFF"
        let receipt = try pageReceipt(
            nextCursor: cursor,
            complete: false
        )
        let attachmentHash = digest("attachment-secret-metadata")
        let attachment = try ConnectorAttachmentMetadata(
            attachmentIdentifier: "attachment-1",
            mediaType: "image/png",
            byteCount: 50,
            sourceHash: attachmentHash
        )
        let value = try envelope(
            text: "Indexable record",
            attachments: [attachment],
            receipt: receipt
        )
        let handoff = try XCTUnwrap(value.indexHandoff())
        let encoded = try JSONEncoder().encode(handoff)
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(text.contains(cursor))
        XCTAssertFalse(text.contains(attachmentHash))
        XCTAssertFalse(text.contains(receipt.receiptHash))
        XCTAssertEqual(handoff.normalizedText, "Indexable record")
        XCTAssertEqual(handoff.provenanceReceiptHash, value.canonicalEnvelopeHash)
    }

    private func pageReceipt(
        page: Int = 0,
        requestCursor: String? = nil,
        nextCursor: String? = nil,
        complete: Bool = true
    ) throws -> ConnectorPaginationReceipt {
        try .init(
            checkpointIdentifier: "checkpoint-1",
            streamIdentifier: "history",
            pageOrdinal: page,
            requestCursor: requestCursor,
            nextCursor: nextCursor,
            sourceHighWatermark: "high-water",
            isComplete: complete
        )
    }

    private func envelope(
        text: String,
        attachments: [ConnectorAttachmentMetadata] = [],
        version: String = "1",
        sourceTimestamp: Date? = nil,
        deletionState: ConnectorRecordDeletionState = .available,
        policy: ConnectorRecordPolicyClassification = .localIndexAllowed,
        content: ConnectorRecordContentClassification = .providerRecord,
        containsSensitiveMaterial: Bool = false,
        receipt: ConnectorPaginationReceipt
    ) throws -> ConnectorRecordEnvelope {
        try .init(
            provider: "Example Provider",
            pseudonymousAccountIdentifier: "account-pseudonym-1",
            remoteRecordIdentifier: "remote-record-1",
            recordType: "Message",
            parentOrThreadIdentifier: "thread-1",
            sourceTimestamp: sourceTimestamp ?? anchor,
            ingestionTimestamp: anchor.addingTimeInterval(60),
            normalizedText: text,
            attachments: attachments,
            deletionState: deletionState,
            editOrVersionIdentifier: version,
            sourceHash: digest(
                [text, version, deletionState.rawValue].joined(separator: "|")
            ),
            paginationReceipt: receipt,
            provenance: try .init(
                sourceSystem: "example-provider-api",
                sourceContainerIdentifier: "container-pseudonym-1",
                sourceURL: URL(string: "https://example.invalid/record/1"),
                retrievedAt: anchor,
                policyBasis: "explicit local indexing consent"
            ),
            policyClassification: policy,
            contentClassification: content,
            containsSensitiveMaterial: containsSensitiveMaterial
        )
    }

    private func digest(_ value: String) -> String {
        ConnectorEnvelopeDigest.sha256(value)
    }
}
