import Foundation
import XCTest
@testable import LokiBrief

private final class UpdateTraceEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UpdateTraceEvent] = []

    func record(_ event: UpdateTraceEvent) {
        lock.lock()
        stored.append(event)
        lock.unlock()
    }

    func snapshot() -> [UpdateTraceEvent] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

final class UpdateTraceTests: XCTestCase {
    @MainActor
    func testControllerCheckAndReceiptBoundariesEmitInspectableMetadata() throws {
        let suiteName = "com.agentloki.LokiBriefTests.P6U.Trace.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let installedVersion = UpdateVersion(
            marketingVersion: try XCTUnwrap(
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String
            ),
            buildVersion: try XCTUnwrap(
                Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleVersion"
                ) as? String
            )
        )
        let pending = PendingUpdateReceipt(
            channel: .stable,
            previousVersion: UpdateVersion(marketingVersion: "0.9.0", buildVersion: "0"),
            candidateVersion: installedVersion,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        defaults.set(try JSONEncoder().encode(pending), forKey: "LokiBrief.PendingUpdateReceipt")
        let recorder = UpdateTraceEventRecorder()
        let logger = UpdateProductionTraceLogger(
            subsystem: "com.agentloki.tests",
            eventSink: { recorder.record($0) }
        )
        let controller = SecureUpdateController(
            model: try AppModel(store: LocalStore(inMemory: true)),
            defaults: defaults,
            traceLogger: logger,
            feedConfiguration: UpdateFeedConfiguration(feeds: [
                .stable: URL(string: "https://updates.example.test/stable/appcast.xml")!,
            ]),
            providerStarter: { _ in }
        )
        controller.emitCheckStarted(trigger: .manual)

        let events = recorder.snapshot()
        let check = try XCTUnwrap(events.last(where: { $0.event == .check }))
        XCTAssertEqual(check.metadata[.channel], UpdateChannel.stable.rawValue)
        XCTAssertEqual(check.metadata[.checkTrigger], UpdateCheckTrigger.manual.rawValue)
        XCTAssertEqual(check.metadata[.currentVersion], controller.currentVersion.marketingVersion)
        XCTAssertEqual(check.metadata[.currentBuild], controller.currentVersion.buildVersion)
        let receipt = try XCTUnwrap(events.last(where: { $0.event == .recovery }))
        XCTAssertEqual(receipt.metadata[.receiptStatus], UpdateReceiptStatus.installed.rawValue)
        XCTAssertEqual(receipt.metadata[.currentBuild], installedVersion.buildVersion)
        XCTAssertEqual(receipt.reasonCode, "update_install_receipt_confirmed")
        XCTAssertFalse(receipt.traceID.isEmpty)
    }

    func testReadinessBridgePreservesTraceAndBlockerEvidence() async throws {
        let recorder = UpdateTraceEventRecorder()
        let sink = SecureUpdateReadinessTraceSink(logger: UpdateProductionTraceLogger(
            subsystem: "com.agentloki.tests",
            eventSink: { recorder.record($0) }
        ))
        await sink.record(ApplicationUpdateReadinessEvent(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            event: "application_update.readiness.completed",
            traceID: "trace-linked",
            spanID: "span-readiness",
            parentSpanID: "span-check",
            component: "application_update_readiness",
            status: .skipped,
            reasonCode: "update_install_blocked_vault_database_work",
            durationMilliseconds: 5,
            metadata: ["blocker_count": "1"]
        ))

        let event = try XCTUnwrap(recorder.snapshot().last)
        XCTAssertEqual(event.event, .installReadiness)
        XCTAssertEqual(event.traceID, "trace-linked")
        XCTAssertEqual(event.parentSpanID, "span-check")
        XCTAssertEqual(event.metadata[.blockerCount], "1")
        XCTAssertEqual(event.status, .skipped)
    }

    func testTraceEventCarriesStableSchemaAndCausalLinks() throws {
        let root = UpdateTraceContext(traceID: "trace-root", spanID: "span-root")
        let child = root.child(spanID: "span-child")
        let event = UpdateTraceEvent(
            ts: Date(timeIntervalSince1970: 1_700_000_000),
            event: .download,
            context: child,
            status: .success,
            reasonCode: "update_download_complete",
            durationMS: 25,
            metadata: UpdateTraceMetadata([
                .channel: UpdateChannel.stable.rawValue,
                .candidateVersion: "2.2.0",
                .candidateBuild: "50",
                .byteCount: "1024"
            ])
        )

        XCTAssertEqual(child.traceID, root.traceID)
        XCTAssertEqual(child.parentSpanID, root.spanID)
        XCTAssertEqual(event.component, "secure_update")

        let line = try UpdateProductionTraceLogger().encodedLine(for: event)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
        )
        XCTAssertEqual(object["event"] as? String, "update_download")
        XCTAssertEqual(object["trace_id"] as? String, "trace-root")
        XCTAssertEqual(object["span_id"] as? String, "span-child")
        XCTAssertEqual(object["parent_span_id"] as? String, "span-root")
        XCTAssertEqual(object["component"] as? String, "secure_update")
        XCTAssertEqual(object["status"] as? String, "success")
        XCTAssertEqual(object["reason_code"] as? String, "update_download_complete")
        XCTAssertEqual(object["duration_ms"] as? Int, 25)
        let metadata = try XCTUnwrap(object["metadata"] as? [String: String])
        XCTAssertEqual(metadata["candidate_version"], "2.2.0")
        XCTAssertEqual(metadata["byte_count"], "1024")
    }

    func testMetadataAllowlistHasNoURLTokenPathHostOrContentKeys() {
        for key in UpdateTraceMetadataKey.allCases {
            let rawValue = key.rawValue.lowercased()
            XCTAssertFalse(rawValue.contains("url"), key.rawValue)
            XCTAssertFalse(rawValue.contains("token"), key.rawValue)
            XCTAssertFalse(rawValue.contains("content"), key.rawValue)
            XCTAssertFalse(rawValue.contains("notes"), key.rawValue)
            XCTAssertFalse(rawValue.contains("path"), key.rawValue)
            XCTAssertFalse(rawValue.contains("host"), key.rawValue)
        }
    }

    func testSensitiveMetadataValuesAreRedactedAndNeverEncoded() throws {
        let metadata = UpdateTraceMetadata([
            .candidateVersion: "https://updates.example.test/appcast.xml",
            .currentBuild: "token=hunter2",
            .route: "Bearer private-credential"
        ])
        XCTAssertEqual(metadata[.candidateVersion], "[redacted]")
        XCTAssertEqual(metadata[.currentBuild], "[redacted]")
        XCTAssertEqual(metadata[.route], "[redacted]")

        let event = UpdateTraceEvent(
            event: .feedValidation,
            context: UpdateTraceContext(traceID: "trace-redaction", spanID: "span-redaction"),
            status: .failed,
            reasonCode: "update_feed_rejected",
            metadata: metadata
        )
        let encoded = try UpdateProductionTraceLogger().encodedLine(for: event).lowercased()
        XCTAssertFalse(encoded.contains("https://"))
        XCTAssertFalse(encoded.contains("hunter2"))
        XCTAssertFalse(encoded.contains("private-credential"))
    }

    func testFailureDegradedAndSkippedPathsRemainExplicit() {
        let context = UpdateTraceContext(traceID: "trace-status", spanID: "span-status")
        let events = [
            UpdateTraceEvent(
                event: .feedResolution,
                context: context,
                status: .degraded,
                reasonCode: "update_feed_offline"
            ),
            UpdateTraceEvent(
                event: .download,
                context: context.child(spanID: "span-failed"),
                status: .failed,
                reasonCode: "update_download_failed"
            ),
            UpdateTraceEvent(
                event: .policy,
                context: context.child(spanID: "span-skipped"),
                status: .skipped,
                reasonCode: "automatic_check_disabled"
            )
        ]

        XCTAssertEqual(events.map(\.status), [.degraded, .failed, .skipped])
        XCTAssertEqual(
            events.map(\.reasonCode),
            ["update_feed_offline", "update_download_failed", "automatic_check_disabled"]
        )
        XCTAssertTrue(events.allSatisfy { !$0.traceID.isEmpty && !$0.spanID.isEmpty })
    }

    func testMetadataIsBoundedTypedAndDeterministic() {
        let oversized = String(repeating: "v", count: 1_000)
        let metadata = UpdateTraceMetadata([
            .candidateVersion: oversized,
            .progressBasisPoints: "25000",
            .automatic: "yes",
            .transitionFrom: "not-a-state",
            .route: "stable_route"
        ])

        XCTAssertEqual(metadata[.candidateVersion]?.count, UpdateTraceMetadata.maximumValueCharacters)
        XCTAssertEqual(metadata[.progressBasisPoints], "unknown")
        XCTAssertEqual(metadata[.automatic], "unknown")
        XCTAssertEqual(metadata[.transitionFrom], "unknown")
        XCTAssertEqual(metadata[.route], "stable_route")
    }

    func testInvalidReasonCodeAndNegativeDurationAreNormalized() {
        let event = UpdateTraceEvent(
            event: .stateTransition,
            context: UpdateTraceContext(traceID: "trace-normalization", spanID: "span-normalization"),
            status: .failed,
            reasonCode: "not a stable reason",
            durationMS: -50
        )

        XCTAssertEqual(event.reasonCode, "update_reason_invalid")
        XCTAssertEqual(event.durationMS, 0)
    }
}
