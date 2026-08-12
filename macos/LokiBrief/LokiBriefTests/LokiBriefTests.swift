import XCTest
import SwiftData
@testable import LokiBrief

final class LokiBriefDomainTests: XCTestCase {
    let engine = DeterministicBriefingEngine()

    func testFixtureIdentifiersAreStable() {
        XCTAssertEqual(engine.generatePreview(revision: 1), engine.generatePreview(revision: 1))
        XCTAssertNotEqual(engine.generatePreview(revision: 1).id, engine.generatePreview(revision: 2).id)
    }

    func testFixtureIsExplicitlySyntheticAndNeverLive() {
        let items = engine.generatePreview(revision: 1).sections.flatMap(\.items)
        XCTAssertTrue(items.allSatisfy(\.provenance.isSynthetic))
        XCTAssertTrue(items.allSatisfy { $0.source.kind == .previewFixtures })
        XCTAssertEqual(engine.generatePreview(revision: 1).status, .preview)
    }

    func testGeneratedAndSourceTextAreDistinct() {
        let origins = Set(engine.generatePreview(revision: 1).sections.flatMap(\.items).map(\.provenance.origin))
        XCTAssertEqual(origins, [.generated, .source])
    }

    func testBriefGroupingAndPriorityOrdering() {
        let brief = engine.generatePreview(revision: 1)
        XCTAssertEqual(brief.sections.map(\.title), ["Needs Attention", "Messages and Collaboration", "News and Research", "System and Product Updates"])
        XCTAssertEqual(brief.sections.first?.items.first?.priority, .urgent)
    }

    func testUnavailableRenderingModelIsExplicit() {
        let items = engine.generatePreview(revision: 1).sections.flatMap(\.items)
        XCTAssertNotNil(items.first { $0.availabilityMessage != nil })
    }

    func testSourceCapabilitiesAndFoundationStates() {
        XCTAssertTrue(FoundationCatalog.sources.first { $0.kind == .newsFeeds }!.capabilities.contains(.feeds))
        XCTAssertEqual(FoundationCatalog.sources.first { $0.kind == .previewFixtures }!.state, .available)
        XCTAssertFalse(FoundationCatalog.sources.contains { $0.state == .connected })
    }

    func testSourceStateTransitionsRejectFakeConnections() {
        XCTAssertTrue(SourceConnectionState.notImplemented.canTransition(to: .available))
        XCTAssertTrue(SourceConnectionState.authorizationRequired.canTransition(to: .connected))
        XCTAssertTrue(SourceConnectionState.connected.canTransition(to: .disconnected))
        XCTAssertFalse(SourceConnectionState.notImplemented.canTransition(to: .connected))
    }

    func testProviderFoundationStates() {
        let ollama = FoundationCatalog.providers.first { $0.kind == .ollama }!
        XCTAssertEqual(ollama.state, .disabled)
        XCTAssertTrue(ollama.capabilities.contains(.localGeneration))
        XCTAssertEqual(FoundationCatalog.providers.map(\.kind), [.deterministic, .ollama])
        XCTAssertEqual(FoundationCatalog.providers.first { $0.kind == .deterministic }?.state, .available)
        XCTAssertFalse(FoundationCatalog.providers.contains { $0.state == .connected })
    }

    func testSourceConnectorReturnsBoundedSnapshot() async {
        let connector = FoundationConnector(source: FoundationCatalog.sources[0])
        let state = await connector.snapshot()
        XCTAssertEqual(state, .available)
    }

    func testDeferredProviderFailsWithoutExecution() async {
        let provider = DeferredProvider(provider: FoundationCatalog.providers[1])
        do { _ = try await provider.generate(.init(briefDate: .now, deterministicOnly: true)); XCTFail("Expected bounded failure") }
        catch let failure as GenerationFailure { XCTAssertEqual(failure.reasonCode, "provider_not_enabled_p1") }
        catch { XCTFail("Unexpected error: \(error)") }
    }
}

@MainActor
final class LokiBriefPersistenceTests: XCTestCase {
    func testEmptyStoreCreatesStableDefaults() throws {
        let store = try LocalStore(inMemory: true)
        XCTAssertTrue(try store.history().isEmpty)
        XCTAssertTrue(try store.settings().deterministicOnly)
    }

    func testSettingsPersistThroughContextReads() throws {
        let store = try LocalStore(inMemory: true)
        let settings = try store.settings(); settings.density = .compact; settings.notificationPreference = true; try store.save()
        XCTAssertEqual(try store.settings().density, .compact)
        XCTAssertTrue(try store.settings().notificationPreference)
    }

    func testReadUnreadPersistence() throws {
        let store = try LocalStore(inMemory: true)
        try store.setRead("fixture-item", isRead: true)
        XCTAssertEqual(try store.readStates()["fixture-item"], true)
        try store.setRead("fixture-item", isRead: false)
        XCTAssertEqual(try store.readStates()["fixture-item"], false)
    }

    func testBriefHistoryAndDuplicateSafety() throws {
        let store = try LocalStore(inMemory: true); let brief = DeterministicBriefingEngine().generatePreview(revision: 1)
        try store.record(brief); try store.record(brief)
        XCTAssertEqual(try store.history().count, 1)
    }

    func testDeleteAllLocalData() throws {
        let store = try LocalStore(inMemory: true); try store.record(DeterministicBriefingEngine().generatePreview(revision: 1)); try store.setRead("x", isRead: true); try store.seedFoundationSnapshots()
        try store.deleteAllLocalData()
        XCTAssertTrue(try store.history().isEmpty); XCTAssertTrue(try store.readStates().isEmpty)
        XCTAssertEqual(try store.settings().id, "primary")
    }

    func testApplicationDependencyConstruction() throws {
        let model = try AppModel(store: LocalStore(inMemory: true))
        XCTAssertNotEqual(model.brief.status, .preview)
        XCTAssertEqual(model.sources.count, 7)
        XCTAssertEqual(model.providers.count, 2)
    }

    func testHostedApplicationUsesIsolatedTestStore() {
        let model = AppModel.live(isTesting: true)
        XCTAssertTrue(model.store.isInMemory)
        XCTAssertTrue(model.vaultController.databaseIsInMemory)
    }

    func testHostedApplicationCanUseExplicitTemporaryDiskIsolation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "loki-brief-hosted-disk-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: directory) }

        let model = AppModel.live(
            isTesting: true,
            isolatedTestDataRoot: directory
        )
        XCTAssertFalse(model.store.isInMemory)
        XCTAssertTrue(model.store.usesExplicitStorageURL)
        XCTAssertTrue(
            model.vaultController.databaseURL.path.hasPrefix(directory.path + "/")
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("LokiBrief-v1.store").path
            )
        )
        await model.shutdownForApplicationTermination()
    }

    func testDensityUpdatesLayoutStateAndPersistence() throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store)
        model.updateDensity(.compact)
        XCTAssertEqual(model.density, .compact)
        XCTAssertEqual(try store.settings().density, .compact)
    }

    func testDeleteThenExplicitPreviewResetRestoresOnlyFoundationState() async throws {
        let store = try LocalStore(inMemory: true)
        let model = try AppModel(store: store)
        await model.deleteAllData()
        XCTAssertEqual(try store.history().count, 0)
        XCTAssertEqual(try ModelContext(store.container).fetch(FetchDescriptor<StoredStateSnapshot>()).count, 0)
        XCTAssertEqual(model.settings.id, "primary")

        model.previewReset()
        XCTAssertEqual(try store.history().count, 1)
        XCTAssertEqual(try ModelContext(store.container).fetch(FetchDescriptor<StoredStateSnapshot>()).count, FoundationCatalog.sources.count + FoundationCatalog.providers.count)
    }

    func testPersistenceClosesAndReopensOnDisk() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LokiBrief.store")

        do {
            let store = try LocalStore(url: url)
            let settings = try store.settings(); settings.density = .compact; try store.save()
            try store.record(DeterministicBriefingEngine().generatePreview(revision: 4))
            try store.setRead("preview-r4-review", isRead: true)
            try store.seedFoundationSnapshots(); try store.seedFoundationSnapshots()
        }

        do {
            let reopened = try LocalStore(url: url)
            XCTAssertEqual(try reopened.settings().density, .compact)
            XCTAssertEqual(try reopened.history().count, 1)
            let stored = try XCTUnwrap(try reopened.history().first)
            let decoded = try stored.decodedBrief()
            XCTAssertEqual(decoded.id, "preview-brief-r4")
            XCTAssertEqual(decoded.itemCount, 5)
            XCTAssertEqual(try reopened.readStates()["preview-r4-review"], true)
            XCTAssertEqual(try ModelContext(reopened.container).fetch(FetchDescriptor<StoredStateSnapshot>()).count, FoundationCatalog.sources.count + FoundationCatalog.providers.count)
        }
    }

    func testRelaunchDoesNotReseedAfterDeletion() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("LokiBrief.store")

        do {
            let model = try AppModel(store: LocalStore(url: url))
            XCTAssertTrue(model.vaultController.databaseURL.path.contains("agent-loki-vault-tests"))
            model.previewReset()
            await model.deleteAllData()
        }

        do {
            let reopened = try LocalStore(url: url)
            _ = try AppModel(store: reopened)
            XCTAssertEqual(try reopened.history().count, 0)
            XCTAssertEqual(try ModelContext(reopened.container).fetch(FetchDescriptor<StoredStateSnapshot>()).count, 0)
        }
    }
}

@MainActor
final class LokiLaunchStorageResolverTests: XCTestCase {
    private let fileManager = FileManager.default

    func testOrdinaryLaunchSelectsProductionOnlyWithoutIsolationSignals() {
        let plan = resolve(arguments: ["LokiBrief"], isXCTest: false)

        XCTAssertEqual(plan.classification, .production)
        XCTAssertEqual(plan.reasonCode, .productionSelected)
        XCTAssertNil(plan.rootURL)
        XCTAssertTrue(plan.evidence.swiftDataVaultPaired)
    }

    func testXCTestWithoutRootSelectsPairedInMemoryStorage() {
        let plan = resolve(arguments: ["LokiBrief"], isXCTest: true)

        XCTAssertEqual(plan.classification, .xctestInMemory)
        XCTAssertEqual(plan.reasonCode, .xctestInMemorySelected)
        XCTAssertNil(plan.swiftDataURL)
        XCTAssertNil(plan.vaultURL)
        XCTAssertTrue(plan.evidence.swiftDataVaultPaired)
    }

    func testXCTestWithValidRootSelectsPairedIsolatedDiskStorage() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("xctest-disk", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        XCTAssertEqual(plan.classification, .xctestIsolatedDisk)
        XCTAssertEqual(plan.reasonCode, .xctestIsolatedDiskSelected)
        assertPaired(plan, under: root)
    }

    func testSignedSmokeWithCommandRootDoesNotRequireXCTestMarker() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("signed-smoke", isDirectory: true)
        try createDisposablePair(at: root)

        let plan = resolve(
            arguments: signedSmokeArguments(root),
            isXCTest: false,
            policy: fixture.policy
        )

        XCTAssertEqual(plan.classification, .signedSmokeIsolatedDisk)
        XCTAssertEqual(plan.reasonCode, .signedSmokeIsolatedDiskSelected)
        assertPaired(plan, under: root)
    }

    func testSignedSmokeWithoutRootFailsClosed() {
        let plan = resolve(
            arguments: ["LokiBrief", LokiLaunchStorageResolver.signedSmokeSentinel],
            isXCTest: false
        )

        assertInvalid(plan, reason: .signedSmokeRootMissing)
    }

    func testRootWithoutRecognizedModeFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("orphan-root", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            environment: [LokiLaunchStorageResolver.isolatedRootEnvironment: root.path],
            isXCTest: false,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootWithoutMode)
    }

    func testConflictingXCTestAndSignedSmokeModesFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("mode-conflict", isDirectory: true)
        try createDisposablePair(at: root)

        let plan = resolve(
            arguments: signedSmokeArguments(root),
            isXCTest: true,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .conflictingLaunchModes)
    }

    func testConflictingRootValuesFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let commandRoot = fixture.approved.appendingPathComponent("command", isDirectory: true)
        let environmentRoot = fixture.approved.appendingPathComponent("environment", isDirectory: true)
        try createDisposablePair(at: commandRoot)

        let plan = resolve(
            arguments: signedSmokeArguments(commandRoot),
            environment: [
                LokiLaunchStorageResolver.isolatedRootEnvironment: environmentRoot.path,
            ],
            isXCTest: false,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .conflictingRoots)
    }

    func testRelativeRootFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        let plan = resolve(
            arguments: [
                "LokiBrief",
                LokiLaunchStorageResolver.signedSmokeSentinel,
                LokiLaunchStorageResolver.isolatedRootArgument,
                "relative/smoke-root",
            ],
            isXCTest: false,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootRelative)
    }

    func testProductionContainerRootFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        try fileManager.createDirectory(
            at: fixture.production,
            withIntermediateDirectories: true
        )
        let root = fixture.production.appendingPathComponent("forbidden", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootProductionContainer)
    }

    func testRecoveryRootDestinationFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        try fileManager.createDirectory(
            at: fixture.recovery,
            withIntermediateDirectories: true
        )

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: fixture.recovery,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootRecoverySource)
    }

    func testExternalVolumeRootFailsClosedBeforeFilesystemAccess() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        let plan = resolve(
            arguments: [
                "LokiBrief",
                LokiLaunchStorageResolver.isolatedRootArgument,
                "/Volumes/External/loki-smoke",
            ],
            isXCTest: true,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootExternalVolume)
    }

    func testBackupOrSnapshotRootFailsClosedBeforeFilesystemAccess() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved
            .appendingPathComponent("com.apple.TimeMachine.snapshot", isDirectory: true)
            .appendingPathComponent("loki-smoke", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootBackupOrSnapshot)
    }

    func testSymlinkEscapeFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let outside = fixture.parent.appendingPathComponent("outside", isDirectory: true)
        let link = fixture.approved.appendingPathComponent("escape", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: outside)
        let root = link.appendingPathComponent("smoke", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootSymlinkEscape)
    }

    func testMalformedArgumentsFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        let missingValue = resolve(
            arguments: [
                "LokiBrief",
                LokiLaunchStorageResolver.signedSmokeSentinel,
                LokiLaunchStorageResolver.isolatedRootArgument,
            ],
            isXCTest: false,
            policy: fixture.policy
        )
        let assignmentSyntax = resolve(
            arguments: [
                "LokiBrief",
                LokiLaunchStorageResolver.signedSmokeSentinel,
                LokiLaunchStorageResolver.isolatedRootArgument + "=/private/tmp/fixture",
            ],
            isXCTest: false,
            policy: fixture.policy
        )

        assertInvalid(missingValue, reason: .malformedArguments)
        assertInvalid(assignmentSyntax, reason: .malformedArguments)
    }

    func testMissingParentFailsClosedWithoutCreatingAnything() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let missingParent = fixture.approved
            .appendingPathComponent("missing-parent", isDirectory: true)
        let root = missingParent.appendingPathComponent("root", isDirectory: true)

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootParentMissing)
        XCTAssertFalse(fileManager.fileExists(atPath: missingParent.path))
    }

    func testExistingNonDirectoryRootFailsClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("regular-file")
        XCTAssertTrue(fileManager.createFile(atPath: root.path, contents: Data()))

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootNotDirectory)
    }

    func testProductionStoreFilenameCannotBeUsedAsRoot() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("LokiBrief-v1.store")

        let plan = resolve(
            arguments: ["LokiBrief"],
            isXCTest: true,
            explicitRoot: root,
            policy: fixture.policy
        )

        assertInvalid(plan, reason: .rootProductionStoreFilename)
    }

    func testSignedSmokeRequiresBothExistingOrdinaryPairMembers() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("incomplete", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let noStore = resolve(
            arguments: signedSmokeArguments(root),
            isXCTest: false,
            policy: fixture.policy
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: root.appendingPathComponent("LokiBrief-v1.store").path,
                contents: Data()
            )
        )
        let noVault = resolve(
            arguments: signedSmokeArguments(root),
            isXCTest: false,
            policy: fixture.policy
        )

        assertInvalid(noStore, reason: .signedSmokeStoreMissing)
        assertInvalid(noVault, reason: .signedSmokeVaultMissing)
    }

    func testEveryPartialOrInvalidCombinationRemainsNonProduction() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("partial", isDirectory: true)
        let plans = [
            resolve(
                arguments: ["LokiBrief", LokiLaunchStorageResolver.signedSmokeSentinel],
                isXCTest: false,
                policy: fixture.policy
            ),
            resolve(
                arguments: ["LokiBrief"],
                environment: [LokiLaunchStorageResolver.isolatedRootEnvironment: root.path],
                isXCTest: false,
                policy: fixture.policy
            ),
            resolve(
                arguments: [
                    "LokiBrief",
                    LokiLaunchStorageResolver.isolatedRootArgument,
                    "relative",
                ],
                isXCTest: true,
                policy: fixture.policy
            ),
            resolve(
                arguments: [
                    "LokiBrief",
                    LokiLaunchStorageResolver.signedSmokeSentinel,
                    LokiLaunchStorageResolver.signedSmokeSentinel,
                ],
                isXCTest: false,
                policy: fixture.policy
            ),
        ]

        XCTAssertTrue(plans.allSatisfy { !$0.isValid })
        XCTAssertTrue(
            plans.allSatisfy {
                $0.classification == .invalidIsolationIntent
                    && $0.classification != .production
                    && $0.swiftDataURL == nil
                    && $0.vaultURL == nil
            }
        )
    }

    func testReasonCodesAreStableAndEvidenceContainsNoRawPath() throws {
        XCTAssertEqual(
            LokiLaunchStorageReasonCode.signedSmokeIsolatedDiskSelected.rawValue,
            "persistence_signed_smoke_isolated_disk_selected"
        )
        XCTAssertEqual(
            LokiLaunchStorageReasonCode.rootWithoutMode.rawValue,
            "persistence_isolation_root_without_mode"
        )
        XCTAssertEqual(
            LokiLaunchStorageReasonCode.rootSymlinkEscape.rawValue,
            "persistence_isolation_root_symlink_escape"
        )

        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let privateRoot = fixture.approved
            .appendingPathComponent("private-name-that-must-not-log", isDirectory: true)
        try createDisposablePair(at: privateRoot)
        let plan = resolve(
            arguments: signedSmokeArguments(privateRoot),
            isXCTest: false,
            policy: fixture.policy
        )
        let encoded = try XCTUnwrap(
            LokiLaunchStorageResolver.encodedEvidence(plan.evidence)
        )

        XCTAssertTrue(encoded.contains("\"event\":\"persistence_store_selection\""))
        XCTAssertTrue(encoded.contains("\"swiftdata_vault_paired\":true"))
        XCTAssertFalse(encoded.contains(privateRoot.path))
        XCTAssertFalse(encoded.contains("private-name-that-must-not-log"))
        XCTAssertFalse(encoded.lowercased().contains("\"path\""))
    }

    func testXCTestInMemoryConstructionKeepsSwiftDataAndVaultInMemory() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        let model = try AppModel.makeLive(
            isTesting: true,
            arguments: ["LokiBrief"],
            environment: [:],
            pathPolicy: fixture.policy
        )

        XCTAssertTrue(model.store.isInMemory)
        XCTAssertNil(model.store.storageURL)
        XCTAssertTrue(model.vaultController.databaseIsInMemory)
        await model.shutdownForApplicationTermination()
    }

    func testXCTestDiskConstructionUsesOneAtomicRoot() async throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let root = fixture.approved.appendingPathComponent("constructed", isDirectory: true)

        let model = try AppModel.makeLive(
            isTesting: true,
            isolatedTestDataRoot: root,
            arguments: ["LokiBrief"],
            environment: [:],
            pathPolicy: fixture.policy
        )

        XCTAssertFalse(model.store.isInMemory)
        XCTAssertEqual(
            model.store.storageURL,
            root.appendingPathComponent("LokiBrief-v1.store").standardizedFileURL
        )
        XCTAssertEqual(
            model.vaultController.databaseURL,
            root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
                .standardizedFileURL
        )
        XCTAssertFalse(model.vaultController.databaseIsInMemory)
        await model.shutdownForApplicationTermination()
    }

    func testAuthorizedDisposableV8PairReopensIdempotentlyWhenConfigured() async throws {
        guard let rawRoot = ProcessInfo.processInfo.environment[
            "LOKI_P7_DISPOSABLE_V8_ROOT"
        ], !rawRoot.isEmpty else {
            throw XCTSkip("Authorized disposable V8/Vault root not supplied.")
        }
        let root = URL(fileURLWithPath: rawRoot, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let arguments = signedSmokeArguments(root)
        let livePolicy = LokiLaunchStoragePathPolicy.live()
        let compatibilityPolicy = LokiLaunchStoragePathPolicy(
            approvedTemporaryRoots: [root.deletingLastPathComponent()],
            productionApplicationSupportRoot: livePolicy.productionApplicationSupportRoot,
            recoveryRoots: livePolicy.recoveryRoots
        )

        var first: AppModel? = try AppModel.makeLive(
            isTesting: false,
            arguments: arguments,
            environment: [:],
            pathPolicy: compatibilityPolicy
        )
        let firstModel = try XCTUnwrap(first)
        XCTAssertEqual(
            firstModel.store.storageURL,
            root.appendingPathComponent("LokiBrief-v1.store")
        )
        XCTAssertEqual(
            firstModel.vaultController.databaseURL,
            root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
        )
        let firstSettingsID = try firstModel.store.settings().id
        let firstHistoryIDs = try firstModel.store.history().map(\.id).sorted()
        let firstPrivacy = try firstModel.store.lokiChatPrivacySettings()
        let firstConversationIDs = try firstModel.store.lokiConversationPage().map(\.id)
        await firstModel.vaultController.refresh()
        let firstVaultIntegrity = firstModel.vaultController.integrity
        let firstVaultRecordCount = firstModel.vaultController.storage?.recordCount
        await firstModel.shutdownForApplicationTermination()
        first = nil

        var second: AppModel? = try AppModel.makeLive(
            isTesting: false,
            arguments: arguments,
            environment: [:],
            pathPolicy: compatibilityPolicy
        )
        let secondModel = try XCTUnwrap(second)
        XCTAssertEqual(try secondModel.store.settings().id, firstSettingsID)
        XCTAssertEqual(try secondModel.store.history().map(\.id).sorted(), firstHistoryIDs)
        XCTAssertEqual(try secondModel.store.lokiChatPrivacySettings(), firstPrivacy)
        XCTAssertEqual(
            try secondModel.store.lokiConversationPage().map(\.id),
            firstConversationIDs
        )
        await secondModel.vaultController.refresh()
        XCTAssertEqual(secondModel.vaultController.integrity, firstVaultIntegrity)
        XCTAssertEqual(secondModel.vaultController.storage?.recordCount, firstVaultRecordCount)
        XCTAssertTrue(secondModel.store.usesExplicitStorageURL)
        XCTAssertFalse(secondModel.vaultController.databaseIsInMemory)
        await secondModel.shutdownForApplicationTermination()
        second = nil
    }

    private struct Fixture {
        let parent: URL
        let approved: URL
        let production: URL
        let recovery: URL
        let policy: LokiLaunchStoragePathPolicy
    }

    private func makeFixture() throws -> Fixture {
        let parent = fileManager.temporaryDirectory.appendingPathComponent(
            "loki-launch-storage-\(UUID().uuidString)",
            isDirectory: true
        )
        let approved = parent.appendingPathComponent("approved", isDirectory: true)
        let production = approved.appendingPathComponent(
            "production-application-support",
            isDirectory: true
        )
        let recovery = approved.appendingPathComponent(
            "established-recovery-source",
            isDirectory: true
        )
        try fileManager.createDirectory(at: approved, withIntermediateDirectories: true)
        return Fixture(
            parent: parent,
            approved: approved,
            production: production,
            recovery: recovery,
            policy: LokiLaunchStoragePathPolicy(
                approvedTemporaryRoots: [approved],
                productionApplicationSupportRoot: production,
                recoveryRoots: [recovery]
            )
        )
    }

    private func createDisposablePair(at root: URL) throws {
        let vaultDirectory = root
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try fileManager.createDirectory(at: vaultDirectory, withIntermediateDirectories: true)
        XCTAssertTrue(
            fileManager.createFile(
                atPath: root.appendingPathComponent("LokiBrief-v1.store").path,
                contents: Data()
            )
        )
        XCTAssertTrue(
            fileManager.createFile(
                atPath: vaultDirectory.appendingPathComponent("loki-vault.sqlite3").path,
                contents: Data()
            )
        )
    }

    private func signedSmokeArguments(_ root: URL) -> [String] {
        [
            "LokiBrief",
            LokiLaunchStorageResolver.signedSmokeSentinel,
            LokiLaunchStorageResolver.isolatedRootArgument,
            root.path,
        ]
    }

    private func resolve(
        arguments: [String],
        environment: [String: String] = [:],
        isXCTest: Bool,
        explicitRoot: URL? = nil,
        policy: LokiLaunchStoragePathPolicy = .live()
    ) -> LokiLaunchStoragePlan {
        LokiLaunchStorageResolver.resolve(
            arguments: arguments,
            environment: environment,
            isXCTest: isXCTest,
            explicitTestDataRoot: explicitRoot,
            pathPolicy: policy,
            fileManager: fileManager
        )
    }

    private func assertInvalid(
        _ plan: LokiLaunchStoragePlan,
        reason: LokiLaunchStorageReasonCode,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(plan.classification, .invalidIsolationIntent, file: file, line: line)
        XCTAssertEqual(plan.reasonCode, reason, file: file, line: line)
        XCTAssertFalse(plan.isValid, file: file, line: line)
        XCTAssertNil(plan.rootURL, file: file, line: line)
        XCTAssertNil(plan.swiftDataURL, file: file, line: line)
        XCTAssertNil(plan.vaultURL, file: file, line: line)
        XCTAssertFalse(plan.evidence.swiftDataVaultPaired, file: file, line: line)
    }

    private func assertPaired(
        _ plan: LokiLaunchStoragePlan,
        under root: URL,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        XCTAssertEqual(plan.rootURL?.path, resolvedRoot.path, file: file, line: line)
        XCTAssertEqual(
            plan.swiftDataURL?.path,
            resolvedRoot.appendingPathComponent("LokiBrief-v1.store").path,
            file: file,
            line: line
        )
        XCTAssertEqual(
            plan.vaultURL?.path,
            resolvedRoot
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
                .path,
            file: file,
            line: line
        )
        XCTAssertTrue(plan.evidence.swiftDataVaultPaired, file: file, line: line)
    }
}
