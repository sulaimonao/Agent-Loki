import XCTest
@testable import LokiBrief

final class P6ReleasePolicyTests: XCTestCase, @unchecked Sendable {
    func testEarlyAccessPolicyExhaustivelyClassifiesFeatures() async {
        XCTAssertEqual(
            LokiBriefEarlyAccessEntitlementProvider.includedFeatures
                .union(LokiBriefEarlyAccessEntitlementProvider.futureFeaturesNotOffered),
            Set(LokiPaidFeature.allCases)
        )
        XCTAssertTrue(
            LokiBriefEarlyAccessEntitlementProvider.includedFeatures
                .isDisjoint(with: LokiBriefEarlyAccessEntitlementProvider.futureFeaturesNotOffered)
        )

        let provider = LokiBriefEarlyAccessEntitlementProvider()
        for feature in LokiBriefEarlyAccessEntitlementProvider.includedFeatures {
            let entitlement = await provider.entitlement(for: feature)
            XCTAssertEqual(entitlement.state, .available)
            XCTAssertTrue(entitlement.acquisitionAllowed)
            XCTAssertEqual(entitlement.reasonCode, "loki_brief_early_access_included")
            XCTAssertTrue(entitlement.existingDataReadable)
            XCTAssertTrue(entitlement.exportAllowed)
            XCTAssertTrue(entitlement.deletionAllowed)
        }

        for feature in LokiBriefEarlyAccessEntitlementProvider.futureFeaturesNotOffered {
            let entitlement = await provider.entitlement(for: feature)
            XCTAssertEqual(entitlement.state, .unavailable)
            XCTAssertFalse(entitlement.acquisitionAllowed)
            XCTAssertEqual(entitlement.reasonCode, "loki_brief_early_access_feature_not_offered")
        }
    }

    @MainActor
    func testFreshInstallDefaultsContainNoLiveFixtureOrBackgroundOptIn() throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store)

        XCTAssertFalse(try store.p2Settings().previewFixturesEnabled)
        XCTAssertNotEqual(model.brief.status, .preview)
        XCTAssertFalse(try store.settings().launchAtLoginPreference)
        XCTAssertFalse(try store.settings().notificationPreference)
        XCTAssertFalse(try store.primaryBriefSchedule().enabled)

        let notifications = try store.notificationDeliverySettings()
        XCTAssertFalse(notifications.enabledPreference)
        XCTAssertEqual(notifications.privacyMode, .minimal)
    }

    func testConsumerPresentationNeverReturnsRawReasonCodesOrPaths() {
        let samples = [
            "no_active_delivery_run",
            "slack_token_expired",
            "scheduled_vault_reconciliation_failed",
            "/private/tmp/LokiSecret",
        ]

        for sample in samples {
            let presented = LokiBriefPresentation.reason(for: sample)
            XCTAssertFalse(presented.contains(sample))
            XCTAssertFalse(presented.contains("/private/"))
            XCTAssertFalse(presented.contains("_"))
        }

        let privatePath = "The database at /private/tmp/LokiSecret.sqlite could not be opened."
        let sanitizedPath = LokiBriefPresentation.message(for: privatePath)
        XCTAssertFalse(sanitizedPath.contains("/private/"))
        XCTAssertFalse(sanitizedPath.contains("LokiSecret"))
        XCTAssertEqual(
            LokiBriefPresentation.message(for: "scheduled_vault_reconciliation_failed"),
            "The operation could not be completed. Retry or review the related settings."
        )
        XCTAssertEqual(
            LokiBriefPresentation.message(for: "Reconnect Slack to continue."),
            "Reconnect Slack to continue."
        )
        let embeddedReason = LokiBriefPresentation.message(
            for: "Historical acquisition is paused (vault_entitlement_provider_not_configured)."
        )
        XCTAssertFalse(embeddedReason.contains("vault_entitlement"))
        XCTAssertFalse(embeddedReason.contains("_"))

        XCTAssertEqual(LokiBriefPresentation.label(for: "notRegistered"), "Not Registered")
        XCTAssertEqual(LokiBriefPresentation.label(for: "modelSelected"), "Model Selected")
        XCTAssertEqual(LokiBriefPresentation.label(for: "configurationRequired"), "Configuration Required")
        XCTAssertEqual(LokiBriefPresentation.label(for: "manual_run_now"), "Manual Run Now")
        XCTAssertEqual(LokiBriefPresentation.label(for: "catch_up_after_wake"), "Catch Up After Wake")
        XCTAssertEqual(LokiBriefPresentation.label(for: "partially_succeeded"), "Partially Succeeded")
        XCTAssertEqual(LokiBriefPresentation.feedFormat(for: "jsonFeed11"), "JSON Feed 1.1")
        XCTAssertEqual(LokiBriefPresentation.slackScope(for: "channels:history"), "Public channel history")
        XCTAssertEqual(LokiBriefPresentation.reason(for: "delivery_plan_preparing"), "The operation is in progress.")
        XCTAssertEqual(LokiBriefPresentation.reason(for: "scheduled_delivery_started"), "The operation is in progress.")
        XCTAssertEqual(LokiBriefPresentation.reason(for: "scheduled_briefing_complete"), "The operation completed.")
        XCTAssertEqual(LokiBriefPresentation.reason(for: "vault_backfill_completed"), "The operation completed.")
        XCTAssertEqual(LokiBriefPresentation.reason(for: "none"), "No stop condition was recorded.")
    }

    @MainActor
    func testDeleteAllDoesNotRecreatePreviewFixtures() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store)
        model.previewReset()
        XCTAssertEqual(model.brief.status, .preview)

        await model.deleteAllData()

        XCTAssertNotEqual(model.brief.status, .preview)
        XCTAssertTrue(model.brief.sections.isEmpty)
        XCTAssertFalse(try store.p2Settings().previewFixturesEnabled)
        XCTAssertTrue(try store.history().isEmpty)
    }
}
