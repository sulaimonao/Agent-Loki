import Foundation
import Sparkle
import XCTest
@testable import LokiBrief

final class UpdateDomainTests: XCTestCase {
    private let signedEvidence = UpdateSignatureEvidence(
        feedIsSigned: true,
        archiveIsSigned: true,
        algorithm: .edDSA
    )

    func testDefaultPolicyIsStableManualAndStrictlySigned() {
        let policy = UpdatePolicy()

        XCTAssertEqual(UpdateChannel.default, .stable)
        XCTAssertEqual(policy.channel, .stable)
        XCTAssertFalse(policy.automaticallyChecksForUpdates)
        XCTAssertTrue(policy.requiresSignedFeed)
        XCTAssertTrue(policy.requiresSignedArchive)
        XCTAssertFalse(policy.allowsDeltaUpdates)
        XCTAssertNil(policy.failure(for: signedEvidence))
    }

    func testShippedSparkleConfigurationRequiresSignedFullUpdatesAndNoFirstLaunchAutomation() throws {
        let info = Bundle.main.infoDictionary ?? [:]

        XCTAssertEqual(info["SUEnableAutomaticChecks"] as? Bool, false)
        XCTAssertEqual(info["SUAutomaticallyUpdate"] as? Bool, false)
        XCTAssertEqual(info["SUAllowsAutomaticUpdates"] as? Bool, false)
        XCTAssertEqual(info["SUEnableInstallerLauncherService"] as? Bool, true)
        XCTAssertEqual(info["SUEnableDownloaderService"] as? Bool, false)
        XCTAssertEqual(info["SURequireSignedFeed"] as? Bool, true)
        XCTAssertEqual(info["SUVerifyUpdateBeforeExtraction"] as? Bool, true)
        XCTAssertEqual(info["SUSignedFeedFailureExpirationInterval"] as? Int, 0)

        let configuredFeedKeys = [
            "LOKI_UPDATE_STABLE_FEED_URL",
            "LOKI_UPDATE_BETA_FEED_URL",
            "LOKI_UPDATE_INTERNAL_FEED_URL",
        ]
        let hasConfiguredFeed = configuredFeedKeys.contains { key in
            guard let value = info[key] as? String else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        let publicKey = (info["SUPublicEDKey"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if hasConfiguredFeed {
            XCTAssertFalse(publicKey.isEmpty, "Configured update feeds require an operator-supplied EdDSA public key")
        } else {
            XCTAssertTrue(publicKey.isEmpty, "A build without update feeds must not embed owner-specific update key material")
        }
        if !publicKey.isEmpty {
            XCTAssertEqual(try XCTUnwrap(Data(base64Encoded: publicKey)).count, 32)
        }
    }

    func testAppTargetLoadsEmbeddedSparkleFromItsPrivateFrameworksDirectory() throws {
        let projectFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("LokiBrief.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        let requiredSetting = "LD_RUNPATH_SEARCH_PATHS = (\"$(inherited)\", \"@executable_path/../Frameworks\")"

        XCTAssertEqual(
            project.components(separatedBy: requiredSetting).count - 1,
            2,
            "Both Debug and Release app configurations must load the embedded Sparkle framework"
        )
    }

    func testFeedResolverSelectsEveryChannelAndRejectsCredentialBearingURLs() throws {
        let stableURL = try XCTUnwrap(URL(string: "https://updates.example.test/stable/appcast.xml"))
        let betaURL = try XCTUnwrap(URL(string: "https://updates.example.test/beta/appcast.xml"))
        let internalURL = try XCTUnwrap(URL(string: "https://updates.example.test/internal/appcast.xml"))
        let resolver = UpdateFeedResolver(
            configuration: UpdateFeedConfiguration(
                feeds: [.stable: stableURL, .beta: betaURL, .internal: internalURL]
            )
        )

        XCTAssertEqual(try resolver.resolve(), stableURL)
        XCTAssertEqual(try resolver.resolve(channel: .beta), betaURL)
        XCTAssertEqual(try resolver.resolve(channel: .internal), internalURL)

        try assertFeedResolutionError("http://updates.example.test/appcast.xml", equals: .invalidScheme)
        try assertFeedResolutionError("https://user:pass@updates.example.test/appcast.xml", equals: .credentialsNotAllowed)
        try assertFeedResolutionError("https://updates.example.test/appcast.xml?token=private", equals: .queryNotAllowed)
        try assertFeedResolutionError("https://updates.example.test/appcast.xml#private", equals: .fragmentNotAllowed)
    }

    func testReleaseNotesAreSanitizedAndBounded() {
        let notes = String(repeating: "a", count: 5_000) + "\u{202E}\u{0000}"
        let availability = makeAvailability(releaseNotes: notes)

        XCTAssertEqual(availability.releaseNotes.count, UpdateAvailability.maximumReleaseNotesCharacters)
        XCTAssertFalse(availability.releaseNotes.unicodeScalars.contains(where: { $0.value == 0x202E }))
        XCTAssertFalse(availability.releaseNotes.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
    }

    func testSemanticAndNumericVersionOrderingDoesNotOverflow() {
        XCTAssertLessThan(version("Display A", "1.0.2"), version("Display B", "1.0.10"))
        XCTAssertLessThan(version("Display A", "2.0.0-beta.2"), version("Display B", "2.0.0-beta.10"))
        XCTAssertLessThan(
            version("Display A", "999999999999999999999999999999"),
            version("Display B", "1000000000000000000000000000000")
        )

        let compact = version("1.0", "7")
        let expanded = version("1.0.0+metadata", "7")
        XCTAssertFalse(compact < expanded)
        XCTAssertFalse(expanded < compact)
    }

    func testStrictPolicyRejectsUnsignedDSAAndDeltaUpdates() {
        let policy = UpdatePolicy()

        XCTAssertEqual(
            policy.failure(
                for: UpdateSignatureEvidence(feedIsSigned: false, archiveIsSigned: true, algorithm: .edDSA)
            )?.code,
            .unsignedFeed
        )
        XCTAssertEqual(
            policy.failure(
                for: UpdateSignatureEvidence(feedIsSigned: true, archiveIsSigned: false, algorithm: .edDSA)
            )?.code,
            .unsignedArchive
        )
        XCTAssertEqual(
            policy.failure(
                for: UpdateSignatureEvidence(feedIsSigned: true, archiveIsSigned: true, algorithm: .dsa)
            )?.code,
            .dsaProhibited
        )
        XCTAssertEqual(
            policy.failure(
                for: UpdateSignatureEvidence(
                    feedIsSigned: true,
                    archiveIsSigned: true,
                    algorithm: .edDSA,
                    isDeltaUpdate: true
                )
            )?.code,
            .deltaProhibited
        )
    }

    func testInvalidSignatureAndTamperedArchiveAreRejected() {
        let validChecksum = String(repeating: "a", count: 64)
        let changedChecksum = String(repeating: "b", count: 64)

        let invalidSignature = UpdateArchiveEvidence(
            expectedSHA256: validChecksum,
            observedSHA256: validChecksum,
            signatureEvidence: UpdateSignatureEvidence(
                feedIsSigned: true,
                archiveIsSigned: true,
                algorithm: .unknown
            )
        )
        XCTAssertEqual(
            UpdateArchiveEvidenceValidator.failure(for: invalidSignature, policy: UpdatePolicy())?.code,
            .invalidSignature
        )

        let tampered = UpdateArchiveEvidence(
            expectedSHA256: validChecksum,
            observedSHA256: changedChecksum,
            signatureEvidence: signedEvidence
        )
        XCTAssertEqual(
            UpdateArchiveEvidenceValidator.failure(for: tampered, policy: UpdatePolicy())?.code,
            .invalidSignature
        )

        let valid = UpdateArchiveEvidence(
            expectedSHA256: validChecksum.uppercased(),
            observedSHA256: validChecksum,
            signatureEvidence: signedEvidence
        )
        XCTAssertNil(UpdateArchiveEvidenceValidator.failure(for: valid, policy: UpdatePolicy()))
    }

    func testPendingReceiptReconcilesSuccessfulRelaunchAndFailedReplacementTruthfully() {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let completedAt = Date(timeIntervalSince1970: 1_700_000_003)
        let pending = PendingUpdateReceipt(
            channel: .stable,
            previousVersion: version("1.0.0", "1"),
            candidateVersion: version("1.0.1", "2"),
            startedAt: startedAt
        )

        let installed = UpdateReceiptReconciler.reconcile(
            pending,
            installedVersion: version("1.0.1", "2"),
            completedAt: completedAt
        )
        XCTAssertEqual(installed.status, .installed)
        XCTAssertEqual(installed.previousVersion, version("1.0.0", "1"))
        XCTAssertEqual(installed.resultingVersion, version("1.0.1", "2"))
        XCTAssertEqual(installed.reasonCode, "update_install_receipt_confirmed")

        let recovered = UpdateReceiptReconciler.reconcile(
            pending,
            installedVersion: version("1.0.0", "1"),
            completedAt: completedAt
        )
        XCTAssertEqual(recovered.status, .recovered)
        XCTAssertEqual(recovered.resultingVersion, version("1.0.0", "1"))
        XCTAssertEqual(recovered.reasonCode, "update_install_receipt_recovered_without_replacement")
    }

    func testProviderErrorsClassifyWrappedOfflineSignatureOlderAndRelaunchFailures() {
        let wrappedOffline = NSError(
            domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
            code: 2_001,
            userInfo: [
                NSUnderlyingErrorKey: NSError(
                    domain: NSURLErrorDomain,
                    code: NSURLErrorNotConnectedToInternet
                )
            ]
        )
        XCTAssertEqual(
            SecureUpdateProviderErrorClassifier.classify(wrappedOffline).code,
            .offline
        )
        XCTAssertEqual(
            SecureUpdateProviderErrorClassifier.classify(NSError(
                domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
                code: 3_001
            )).code,
            .invalidSignature
        )
        XCTAssertEqual(
            SecureUpdateProviderErrorClassifier.classify(NSError(
                domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
                code: 4_006
            )).code,
            .olderVersion
        )
        XCTAssertEqual(
            SecureUpdateProviderErrorClassifier.classify(NSError(
                domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
                code: 4_004
            )).code,
            .relaunchFailed
        )
        XCTAssertEqual(
            SecureUpdateProviderErrorClassifier.classify(NSError(
                domain: SecureUpdateProviderErrorClassifier.sparkleErrorDomain,
                code: 4_008
            )).code,
            .installationBlocked
        )
        let policyFailure = UpdateFailure(
            code: .wrongChannel,
            isRecoverable: false,
            consumerMessage: "The update belongs to another channel."
        )
        XCTAssertEqual(policyFailure.localizedDescription, policyFailure.consumerMessage)
        XCTAssertEqual(SecureUpdateProviderErrorClassifier.classify(policyFailure).code, .wrongChannel)
        XCTAssertEqual(SecureUpdateProviderErrorClassifier.classify(policyFailure as NSError).code, .wrongChannel)
    }

    func testNoUpdateReasonsAreClassifiedTruthfully() {
        func error(reason: Int?) -> NSError {
            var userInfo: [String: Any] = [:]
            if let reason { userInfo[SPUNoUpdateFoundReasonKey] = NSNumber(value: reason) }
            return NSError(domain: SUSparkleErrorDomain, code: 1_001, userInfo: userInfo)
        }

        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: 1)), .upToDate)
        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: 2)), .olderFeed)
        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: 3)), .incompatibleSystem)
        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: 4)), .incompatibleSystem)
        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: 5)), .incompatibleSystem)
        XCTAssertEqual(SecureUpdateNoUpdateClassifier.classify(error(reason: nil)), .unknown)
    }

    func testOperationGateSerializesRecoveryAndInvalidatesLateInstallPreparation() {
        var gate = SecureUpdateOperationGate()
        let firstAttempt = gate.beginInstallPreparation()
        XCTAssertTrue(gate.isCurrentInstallPreparation(firstAttempt))

        gate.invalidateInstallPreparation()
        XCTAssertFalse(gate.isCurrentInstallPreparation(firstAttempt))
        XCTAssertTrue(gate.beginRecovery())
        XCTAssertFalse(gate.allowsCheck(providerCanCheck: true))
        XCTAssertFalse(gate.beginRecovery())

        gate.finishRecovery()
        XCTAssertTrue(gate.allowsCheck(providerCanCheck: true))
        gate.requireRestart()
        XCTAssertFalse(gate.allowsCheck(providerCanCheck: true))
        let replacementAttempt = gate.beginInstallPreparation()
        XCTAssertNotEqual(firstAttempt, replacementAttempt)
        gate.finishInstallPreparation(replacementAttempt)
        XCTAssertNil(gate.installPreparationID)
    }

    func testSparkleChoiceDispositionClearsOrRetainsCandidateByStage() {
        XCTAssertEqual(
            SecureUpdateChoiceClassifier.classify(choice: .install, stage: .notDownloaded),
            .proceed
        )
        XCTAssertEqual(
            SecureUpdateChoiceClassifier.classify(choice: .skip, stage: .downloaded),
            .clearAvailability(reasonCode: "update_user_skipped_version")
        )
        XCTAssertEqual(
            SecureUpdateChoiceClassifier.classify(choice: .dismiss, stage: .notDownloaded),
            .clearAvailability(reasonCode: "update_user_dismissed_before_download")
        )
        XCTAssertEqual(
            SecureUpdateChoiceClassifier.classify(choice: .dismiss, stage: .downloaded),
            .retainDownloaded(reasonCode: "update_download_retained_after_dismiss")
        )
        XCTAssertEqual(
            SecureUpdateChoiceClassifier.classify(choice: .dismiss, stage: .installing),
            .retainInstalling(reasonCode: "update_install_retained_after_dismiss")
        )
    }

    func testMenuAndNotificationRoutesAreFixedAndPayloadFree() {
        XCTAssertEqual(
            UpdateRoute.check(from: .appMenu),
            UpdateRoute(source: .appMenu, action: .check)
        )
        XCTAssertEqual(
            UpdateRoute.check(from: .menuBar),
            UpdateRoute(source: .menuBar, action: .check)
        )
        XCTAssertEqual(
            UpdateRoute.notification(identifier: UpdateRoute.availabilityNotificationIdentifier),
            UpdateRoute(source: .notification, action: .showAvailability)
        )
        XCTAssertNil(UpdateRoute.notification(identifier: "com.agentloki.untrusted.payload"))
    }

    func testCheckEvaluationUsesMachineBuildAuthorityAndFailClosedChannelMatching() {
        let policy = UpdatePolicy(channel: .stable)
        let current = version("2.1.0", "42")
        let wrongChannel = makeAvailability(channel: .beta, version: version("2.2.0", "1"))
        let older = makeAvailability(version: version("9.0.0", "41"))
        let equivalent = makeAvailability(version: version("2.1", "42"))
        let newerBuildWithLowerDisplay = makeAvailability(version: version("1.0.0", "43"))

        XCTAssertEqual(
            failureCode(
                in: UpdateCheckResult.evaluate(
                    currentVersion: current,
                    candidate: wrongChannel,
                    policy: policy,
                    signatureEvidence: signedEvidence
                ).outcome
            ),
            .wrongChannel
        )
        XCTAssertEqual(
            failureCode(
                in: UpdateCheckResult.evaluate(
                    currentVersion: current,
                    candidate: older,
                    policy: policy,
                    signatureEvidence: signedEvidence
                ).outcome
            ),
            .olderVersion
        )

        let equivalentResult = UpdateCheckResult.evaluate(
            currentVersion: current,
            candidate: equivalent,
            policy: policy,
            signatureEvidence: signedEvidence
        )
        guard case .noUpdate(let reportedCurrent) = equivalentResult.outcome else {
            return XCTFail("Equivalent semantic versions must not be offered as an update")
        }
        XCTAssertEqual(reportedCurrent, current)

        let newerResult = UpdateCheckResult.evaluate(
            currentVersion: current,
            candidate: newerBuildWithLowerDisplay,
            policy: policy,
            signatureEvidence: signedEvidence
        )
        guard case .available(let accepted) = newerResult.outcome else {
            return XCTFail("A higher machine build must be accepted regardless of display version")
        }
        XCTAssertEqual(accepted.version.buildVersion, "43")

        for prereleaseChannel in [UpdateChannel.beta, .internal] {
            let prereleasePolicy = UpdatePolicy(channel: prereleaseChannel)
            let stableCandidate = makeAvailability(
                channel: .stable,
                version: version("2.2.0", "44")
            )
            guard case .available = UpdateCheckResult.evaluate(
                currentVersion: current,
                candidate: stableCandidate,
                policy: prereleasePolicy,
                signatureEvidence: signedEvidence
            ).outcome else {
                return XCTFail("An opt-in prerelease channel must continue accepting stable releases")
            }
        }

        XCTAssertFalse(UpdateChannel.beta.accepts(candidateChannel: .internal))
        XCTAssertFalse(UpdateChannel.internal.accepts(candidateChannel: .beta))
        XCTAssertFalse(UpdateChannel.stable.accepts(candidateChannel: .beta))
        XCTAssertFalse(UpdateChannel.stable.accepts(candidateChannel: .internal))
    }

    func testStateMachineCoversOfflineFeedUnavailableAndRetry() throws {
        var machine = UpdateStateMachine()
        let offline = UpdateFailure(code: .offline, isRecoverable: true, consumerMessage: "Offline")
        let unavailable = UpdateFailure(
            code: .feedUnavailable,
            isRecoverable: true,
            consumerMessage: "Feed unavailable"
        )

        XCTAssertEqual(try machine.transition(.requestCheck(.manual)), .checking(.manual))
        XCTAssertEqual(
            try machine.transition(
                .checkCompleted(UpdateCheckResult(channel: .stable, outcome: .offline(offline)))
            ),
            .offline(offline)
        )
        XCTAssertEqual(try machine.transition(.retry), .checking(.manual))
        XCTAssertEqual(
            try machine.transition(
                .checkCompleted(UpdateCheckResult(channel: .stable, outcome: .feedUnavailable(unavailable)))
            ),
            .feedUnavailable(unavailable)
        )
        XCTAssertEqual(try machine.transition(.retry), .checking(.manual))
    }

    func testStateMachineCompletesDownloadInstallAndRelaunchWithReadinessGate() throws {
        let availability = makeAvailability(version: version("2.2.0", "50"), contentLength: 100)
        var machine = UpdateStateMachine()

        _ = try machine.transition(.requestCheck(.manual))
        XCTAssertEqual(
            try machine.transition(
                .checkCompleted(UpdateCheckResult(channel: .stable, outcome: .available(availability)))
            ),
            .updateAvailable(availability)
        )
        XCTAssertEqual(
            try machine.transition(.beginDownload),
            .downloading(availability, UpdateDownloadProgress(receivedBytes: 0, expectedBytes: 100))
        )
        XCTAssertEqual(
            try machine.transition(
                .reportDownloadProgress(UpdateDownloadProgress(receivedBytes: 40, expectedBytes: 100))
            ),
            .downloading(availability, UpdateDownloadProgress(receivedBytes: 40, expectedBytes: 100))
        )
        XCTAssertEqual(try machine.transition(.downloadCompleted), .readyToInstall(availability))

        let blocked = UpdateInstallReadiness(blockers: [.activeFeedWork, .activeVaultDatabaseWork])
        XCTAssertEqual(try machine.transition(.requestInstall(blocked)), .installBlocked(availability, blocked))
        XCTAssertEqual(try machine.transition(.retry), .readyToInstall(availability))
        XCTAssertEqual(try machine.transition(.requestInstall(.ready)), .installing(availability))
        XCTAssertEqual(try machine.transition(.beginRelaunch), .relaunching(availability))

        let receipt = makeReceipt(status: .installed)
        XCTAssertEqual(try machine.transition(.relaunchSucceeded(receipt)), .installed(receipt))
    }

    func testStateMachineDownloadFailureHasDeterministicRecoveryAndInvalidTransitionPreservesState() throws {
        let availability = makeAvailability()
        let failure = UpdateFailure(
            code: .downloadFailed,
            isRecoverable: true,
            consumerMessage: "Download failed"
        )
        var machine = UpdateStateMachine()

        XCTAssertThrowsError(try machine.transition(.beginDownload)) { error in
            XCTAssertEqual(
                error as? UpdateStateTransitionError,
                UpdateStateTransitionError(state: .idle, event: "begin_download")
            )
        }
        XCTAssertEqual(machine.state, .idle)

        _ = try machine.transition(.requestCheck(.manual))
        _ = try machine.transition(
            .checkCompleted(UpdateCheckResult(channel: .stable, outcome: .available(availability)))
        )
        _ = try machine.transition(.beginDownload)
        XCTAssertEqual(try machine.transition(.downloadFailed(failure)), .failed(failure))

        let receipt = makeReceipt(status: .recovered)
        XCTAssertEqual(try machine.transition(.recoveryCompleted(receipt)), .recovered(receipt))
    }

    func testAutomaticCheckIsOffByDefault() throws {
        var machine = UpdateStateMachine()
        let resultingState = try machine.transition(.requestCheck(.automatic))

        guard case .failed(let failure) = resultingState else {
            return XCTFail("An automatic check must be rejected when the policy disables it")
        }
        XCTAssertEqual(failure.code, .automaticCheckDisabled)
    }

    private func version(_ marketing: String, _ build: String) -> UpdateVersion {
        UpdateVersion(marketingVersion: marketing, buildVersion: build)
    }

    private func makeAvailability(
        channel: UpdateChannel = .stable,
        version: UpdateVersion = UpdateVersion(marketingVersion: "2.0.0", buildVersion: "2"),
        releaseNotes: String = "Security and reliability improvements.",
        contentLength: Int64? = nil
    ) -> UpdateAvailability {
        UpdateAvailability(
            channel: channel,
            version: version,
            releaseNotes: releaseNotes,
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            contentLength: contentLength
        )
    }

    private func makeReceipt(status: UpdateReceiptStatus) -> UpdateReceipt {
        UpdateReceipt(
            receiptID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            channel: .stable,
            previousVersion: version("2.0.0", "2"),
            resultingVersion: version("2.2.0", "50"),
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            completedAt: Date(timeIntervalSince1970: 1_700_000_001),
            reasonCode: "update_\(status.rawValue)"
        )
    }

    private func failureCode(in outcome: UpdateCheckOutcome) -> UpdateFailureCode? {
        guard case .rejected(let failure) = outcome else { return nil }
        return failure.code
    }

    private func assertFeedResolutionError(
        _ rawURL: String,
        equals expected: UpdateFeedResolutionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        let url = try XCTUnwrap(URL(string: rawURL), file: file, line: line)
        let resolver = UpdateFeedResolver(
            configuration: UpdateFeedConfiguration(feeds: [.stable: url])
        )
        XCTAssertThrowsError(try resolver.resolve(), file: file, line: line) { error in
            XCTAssertEqual(error as? UpdateFeedResolutionError, expected, file: file, line: line)
        }
    }
}
