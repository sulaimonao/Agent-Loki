import Foundation
import XCTest
@testable import LokiBrief

final class P8FSignedSmokeAdmissionTests: XCTestCase {
    private let fileManager = FileManager.default
    private let manifestSHA256 = String(repeating: "a", count: 64)
    private let executableSHA256 = String(repeating: "b", count: 64)
    private let modelSHA256 = String(repeating: "c", count: 64)

    func testStorageBoundaryCopiesRetainIdentityButReadmissionDoesNot()
        throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let original = try P8FSignedSmokeStorageBoundary(
            admitting: fixture.root
        )
        let copy = original
        let independentlyAdmitted = try P8FSignedSmokeStorageBoundary(
            admitting: fixture.root
        )

        XCTAssertTrue(original.sharesAdmissionIdentity(with: copy))
        XCTAssertFalse(
            original.sharesAdmissionIdentity(
                with: independentlyAdmitted
            )
        )
    }

    @MainActor
    func testResolvedAuthorityBindsExactBoundaryAndIndexIdentity()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )
        let package = try makeSemanticPackage(admission: admission)
        let index = try package.makeAndBindSemanticIndex(
            at: semanticDatabase
        )
        XCTAssertNoThrow(
            try index.validateSignedSmokeRuntimeAuthority(
                admission.runtimeAuthority
            )
        )

        let independentAdmission = try resolve(fixture)
        XCTAssertFalse(
            admission.storageBoundary.sharesAdmissionIdentity(
                with: independentAdmission.storageBoundary
            )
        )
        XCTAssertThrowsError(
            try index.validateSignedSmokeRuntimeAuthority(
                independentAdmission.runtimeAuthority
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertThrowsError(
            try SemanticVaultIndex(
                url: semanticDatabase,
                signedSmokeStorageBoundary:
                    independentAdmission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        await index.close()
    }

    @MainActor
    func testBoundaryOnlyReopenCannotPublishSignedSmokeGeneration()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )
        let scope = try signedSmokeBuildScope(
            receiptIdentifier: "bound-file-authority"
        )
        let package = try makeSemanticPackage(admission: admission)
        let authorized = try package.makeAndBindSemanticIndex(
            at: semanticDatabase
        )
        _ = try await authorized.beginGeneration(
            spec: .lexicalOnly(
                sourceSchemaVersion: "signed-smoke-source-v1",
                buildScope: scope
            )
        )
        await authorized.close()

        XCTAssertThrowsError(
            try SemanticVaultIndex(
                url: semanticDatabase,
                signedSmokeStorageBoundary: admission.storageBoundary
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
    }

    @MainActor
    func testBoundIndexDetectsSamePathDirectoryAndSQLiteReplacement()
        async throws
    {
        for target in ["directory", "database", "wal", "shm"] {
            let fixture = try makeFixture()
            defer { try? fileManager.removeItem(at: fixture.parent) }
            let admission = try resolve(fixture)
            let semanticDatabase = try makeSemanticDatabaseURL(
                admission: admission
            )
            let package = try makeSemanticPackage(admission: admission)
            let index = try package.makeAndBindSemanticIndex(
                at: semanticDatabase
            )
            let targetURL: URL
            let isDirectory: Bool
            switch target {
            case "directory":
                targetURL = semanticDatabase
                    .deletingLastPathComponent()
                isDirectory = true
            case "database":
                targetURL = semanticDatabase
                isDirectory = false
            case "wal":
                targetURL = URL(
                    fileURLWithPath: semanticDatabase.path + "-wal"
                )
                isDirectory = false
            default:
                targetURL = URL(
                    fileURLWithPath: semanticDatabase.path + "-shm"
                )
                isDirectory = false
            }
            XCTAssertTrue(
                fileManager.fileExists(atPath: targetURL.path),
                "Expected bootstrap to materialize \(target)."
            )
            let replacementBackup = targetURL
                .deletingLastPathComponent()
                .appendingPathComponent(
                    targetURL.lastPathComponent + ".original"
                )
            try fileManager.moveItem(
                at: targetURL,
                to: replacementBackup
            )
            if isDirectory {
                try fileManager.createDirectory(
                    at: targetURL,
                    withIntermediateDirectories: false
                )
                try setPermissions(0o700, at: targetURL)
            } else {
                XCTAssertTrue(
                    fileManager.createFile(
                        atPath: targetURL.path,
                        contents: Data()
                    )
                )
                try setPermissions(0o600, at: targetURL)
            }

            do {
                _ = try await index.activeGeneration()
                XCTFail(
                    "Same-path \(target) replacement must fail closed."
                )
            } catch {
                XCTAssertEqual(
                    error as? SemanticIndexFailureCode,
                    .signedSmokeAuthorityInvalid,
                    "Unexpected replacement result for \(target)."
                )
            }
            await index.close()
        }
    }

    @MainActor
    func testFinalPublicationReplacementRollsBackAndPreservesPriorActive()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )
        let package = try makeSemanticPackage(admission: admission)
        let semanticDirectory = semanticDatabase
            .deletingLastPathComponent()
        let originalDirectory = semanticDirectory
            .deletingLastPathComponent()
            .appendingPathComponent(
                semanticDirectory.lastPathComponent
                    + ".publication-original",
                isDirectory: true
            )
        let index = try package.makeAndBindSemanticIndex(
            at: semanticDatabase,
            profile:
                .replaceDirectoryBeforeSuccessorPublicationForIntegrityDiagnostic
        )
        let scope = try signedSmokeBuildScope(
            receiptIdentifier: "publication-replacement-authority"
        )
        let priorGeneration = try await index.beginGeneration(
            spec: .lexicalOnly(
                sourceSchemaVersion: "signed-smoke-source-prior-v1",
                buildScope: scope
            )
        )
        try await completeEmptyGeneration(
            priorGeneration,
            scope: scope,
            index: index,
            runIdentifier: "publication-prior-run"
        )
        let prior = try await index.publishGeneration(
            priorGeneration.identifier
        )

        let candidate = try await index.beginGeneration(
            spec: .lexicalOnly(
                sourceSchemaVersion: "signed-smoke-source-candidate-v2",
                buildScope: scope
            ),
            rebuilding: true
        )
        try await completeEmptyGeneration(
            candidate,
            scope: scope,
            index: index,
            runIdentifier: "publication-candidate-run"
        )
        do {
            _ = try await index.publishGeneration(candidate.identifier)
            XCTFail(
                "Replacement inside the final validator must abort publish."
            )
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }

        try fileManager.removeItem(at: semanticDirectory)
        try fileManager.moveItem(
            at: originalDirectory,
            to: semanticDirectory
        )
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.identifier, prior.identifier)
        let rolledBackCandidate = try await index.generation(
            identifier: candidate.identifier
        )
        XCTAssertEqual(rolledBackCandidate?.state, .building)
        await index.close()
    }

    @MainActor
    func testRawFileBackedSemanticHooksCannotAcquireSignedSmokeAuthority()
        throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )

        XCTAssertThrowsError(
            try SemanticVaultIndex(
                url: semanticDatabase,
                signedSmokeStorageBoundary: admission.storageBoundary,
                signedSmokeRuntimeAuthority: admission.runtimeAuthority,
                now: { Date(timeIntervalSince1970: 0) },
                finalPublicationValidator: { _, _ in },
                publishLifecycleIsValid: { true }
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
    }

    @MainActor
    func testPackageIssuesOneBoundProfileAndRejectsCrossPackageReuse()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )
        let package = try makeSemanticPackage(admission: admission)
        let index = try package.makeAndBindSemanticIndex(
            at: semanticDatabase
        )

        XCTAssertEqual(
            index.signedSmokeIssuedConstructionProfile,
            .runtime
        )
        XCTAssertNoThrow(try package.validateSemanticIndex(index))
        XCTAssertThrowsError(
            try package.makeAndBindSemanticIndex(at: semanticDatabase)
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }

        let independentPackage = try P8FSignedSmokeDependencyPackage
            .makeAppOwned(
                store: package.admittedApplicationStore,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        XCTAssertThrowsError(
            try independentPackage.validateSemanticIndex(index)
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        await index.close()
    }

    @MainActor
    func testClosedIntegrityProfileRejectsSuccessorAndPreservesPriorActive()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let semanticDatabase = try makeSemanticDatabaseURL(
            admission: admission
        )
        let package = try makeSemanticPackage(admission: admission)
        let index = try package.makeAndBindSemanticIndex(
            at: semanticDatabase,
            profile:
                .rejectSuccessorPublicationForIntegrityDiagnostic
        )
        XCTAssertEqual(
            index.signedSmokeIssuedConstructionProfile,
            .rejectSuccessorPublicationForIntegrityDiagnostic
        )
        let scope = try signedSmokeBuildScope(
            receiptIdentifier: "closed-profile-authority"
        )
        let priorGeneration = try await index.beginGeneration(
            spec: .lexicalOnly(
                sourceSchemaVersion: "signed-smoke-closed-prior-v1",
                buildScope: scope
            )
        )
        try await completeEmptyGeneration(
            priorGeneration,
            scope: scope,
            index: index,
            runIdentifier: "closed-profile-prior"
        )
        let prior = try await index.publishGeneration(
            priorGeneration.identifier
        )
        let successor = try await index.beginGeneration(
            spec: .lexicalOnly(
                sourceSchemaVersion: "signed-smoke-closed-successor-v2",
                buildScope: scope
            ),
            rebuilding: true
        )
        try await completeEmptyGeneration(
            successor,
            scope: scope,
            index: index,
            runIdentifier: "closed-profile-successor"
        )

        do {
            _ = try await index.publishGeneration(
                successor.identifier
            )
            XCTFail("The closed diagnostic profile must reject a successor.")
        } catch {
            XCTAssertEqual(
                error as?
                    P8FSignedSmokeSemanticIndexDiagnosticFailure,
                .successorPublicationRejected
            )
        }
        let active = try await index.activeGeneration()
        let rejectedSuccessor = try await index.generation(
            identifier: successor.identifier
        )
        XCTAssertEqual(active?.identifier, prior.identifier)
        XCTAssertEqual(rejectedSuccessor?.state, .building)
        await index.close()
    }

    @MainActor
    func testOldControlCleanupPreservesValidSamePathSuccessor()
        throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let controlTree = fixture.root.appendingPathComponent(
            P8FSignedSmokeFixtureSeeder.controlDirectoryName,
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: controlTree,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let originalMarker = controlTree.appendingPathComponent(
            "original.marker"
        )
        try Data("original".utf8).write(to: originalMarker)
        try setPermissions(0o600, at: originalMarker)
        let admission = try resolve(fixture)
        let package = try makeSemanticPackage(admission: admission)
        let retainedOriginal = fixture.parent.appendingPathComponent(
            "retained-control-original",
            isDirectory: true
        )
        try fileManager.moveItem(
            at: controlTree,
            to: retainedOriginal
        )
        try fileManager.createDirectory(
            at: controlTree,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let successorMarker = controlTree.appendingPathComponent(
            "successor.marker"
        )
        let successorData = Data("successor".utf8)
        try successorData.write(to: successorMarker)
        try setPermissions(0o600, at: successorMarker)

        XCTAssertThrowsError(
            try package.removeBoundControlTree(
                fileManager: fileManager
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
        XCTAssertEqual(
            try Data(contentsOf: successorMarker),
            successorData
        )
        XCTAssertTrue(
            fileManager.fileExists(atPath: retainedOriginal.path)
        )
    }

    @MainActor
    func testVaultExportStagingCleanupPreservesSamePathSuccessor()
        throws
    {
        for stagingWasPresentAtAdmission in [true, false] {
            let fixture = try makeFixture()
            defer { try? fileManager.removeItem(at: fixture.parent) }
            let vaultDatabase = fixture.root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
            let staging = VaultPaths.exportStagingDirectory(
                for: vaultDatabase
            )
            if stagingWasPresentAtAdmission {
                try fileManager.createDirectory(
                    at: staging,
                    withIntermediateDirectories: false,
                    attributes: [.posixPermissions: 0o700]
                )
                let admittedMarker = staging.appendingPathComponent(
                    "admitted.marker"
                )
                try Data("admitted".utf8).write(to: admittedMarker)
                try setPermissions(0o600, at: admittedMarker)
            }
            let admission = try resolve(fixture)
            let storeURL = try XCTUnwrap(
                admission.storagePlan.swiftDataURL
            )
            let store = try LocalStore(url: storeURL)
            try admission.storageBoundary.secureSQLiteFamily(
                at: storeURL,
                requireDatabase: true,
                fileManager: fileManager
            )
            let package = try P8FSignedSmokeDependencyPackage
                .makeApplicationOwned(
                    store: store,
                    vaultDatabaseURL: vaultDatabase,
                    storageBoundary: admission.storageBoundary,
                    runtimeAuthority: admission.runtimeAuthority
                )
            let vaultController = try XCTUnwrap(
                package.applicationVaultController
            )
            if stagingWasPresentAtAdmission {
                try fileManager.moveItem(
                    at: staging,
                    to: fixture.parent.appendingPathComponent(
                        "retained-staging",
                        isDirectory: true
                    )
                )
            }
            try fileManager.createDirectory(
                at: staging,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            let successorMarker = staging.appendingPathComponent(
                "successor.marker"
            )
            let successorData = Data("successor".utf8)
            try successorData.write(to: successorMarker)
            try setPermissions(0o600, at: successorMarker)

            XCTAssertThrowsError(
                try package.removeVaultExportStagingIfPresent(
                    for: vaultController
                )
            ) {
                XCTAssertEqual(
                    $0 as? SemanticIndexFailureCode,
                    .signedSmokeAuthorityInvalid
                )
            }
            XCTAssertEqual(
                try Data(contentsOf: successorMarker),
                successorData
            )
        }
    }

    func testHasControlIntentRecognizesExactAndAssignmentFormsOnly() {
        let sentinel = P8FSignedSmokeAdmissionResolver.controlSentinel

        XCTAssertTrue(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief", sentinel]
            )
        )
        XCTAssertTrue(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief", sentinel + "="]
            )
        )
        XCTAssertTrue(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief", sentinel + "=unexpected"]
            )
        )
        XCTAssertFalse(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief"]
            )
        )
        XCTAssertFalse(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief", sentinel + "-suffix"]
            )
        )
        XCTAssertFalse(
            P8FSignedSmokeAdmissionResolver.hasControlIntent(
                arguments: ["LokiBrief", "prefix-" + sentinel]
            )
        )
    }

    func testEveryClosedScenarioAdmitsAtTheFixedPlanLocation() throws {
        for scenario in P8FSignedSmokeControlScenario.allCases {
            let fixture = try makeFixture(plan: validPlan(for: scenario))
            defer { try? fileManager.removeItem(at: fixture.parent) }

            let admission = try resolve(fixture)

            XCTAssertEqual(
                admission.storagePlan.classification,
                .signedSmokeIsolatedDisk
            )
            XCTAssertEqual(
                admission.storagePlan.rootURL,
                fixture.root
            )
            XCTAssertEqual(
                admission.controlPlanURL,
                fixture.root.appendingPathComponent(
                    P8FSignedSmokeAdmissionResolver.controlPlanFileName
                )
            )
            XCTAssertEqual(admission.controlPlan.scenario, scenario)
            XCTAssertEqual(
                admission.controlPlan.expectedFixtureManifestSHA256,
                manifestSHA256
            )
            XCTAssertEqual(
                admission.controlPlan.expectedExecutableSHA256,
                executableSHA256
            )
        }
    }

    @MainActor
    func testAdmittedSmokeModelSealsWebCredentialBeforeUIWork()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)

        let model = try AppModel.makeAdmittedSignedSmoke(
            admission,
            fileManager: fileManager
        )
        let features = try XCTUnwrap(
            model.chatController?.p8Features
        )
        let snapshot =
            features.signedSmokeWebCredentialSealSnapshot

        XCTAssertTrue(snapshot.isSealed)
        XCTAssertEqual(snapshot.storeAttemptCount, 0)
        XCTAssertEqual(snapshot.readAttemptCount, 0)
        XCTAssertEqual(snapshot.deleteAttemptCount, 0)
        XCTAssertFalse(
            features.shouldRefreshWebCredentialStatusOnAppear
        )
        XCTAssertEqual(features.webCredentialConfigured, false)
        XCTAssertNil(model.p5Controller)

        await model.shutdownForApplicationTermination()
    }

    @MainActor
    func testSignedSmokeChatRejectsRawAndNilDependencyBypasses()
        async throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let admission = try resolve(fixture)
        let swiftDataURL = try XCTUnwrap(
            admission.storagePlan.swiftDataURL
        )
        let vaultURL = try XCTUnwrap(
            admission.storagePlan.vaultURL
        )
        let store = try LocalStore(url: swiftDataURL)
        try admission.storageBoundary.secureSQLiteFamily(
            at: swiftDataURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        let dependencyPackage = try P8FSignedSmokeDependencyPackage
            .makeApplicationOwned(
                store: store,
                vaultDatabaseURL: vaultURL,
                storageBoundary: admission.storageBoundary,
                runtimeAuthority: admission.runtimeAuthority
            )
        let model = try AppModel.makeSignedSmokeApplication(
            using: dependencyPackage
        )
        let p8Features = try XCTUnwrap(model.chatController?.p8Features)
        let toolExecutor = AgentLokiReadOnlyToolExecutor(
            dataSource: dependencyPackage.inertToolDataSource
        )

        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                provider: NativeOllamaChatProvider(),
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                p8Features: p8Features,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage,
                toolExecutor: toolExecutor
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage,
                contextBuilder: AgentLokiContextBuilder()
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage,
                evidenceScrubPreflight: {}
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority,
                signedSmokeDependencyPackage:
                    dependencyPackage,
                traceSink: { _ in }
            )
        )
        XCTAssertThrowsError(
            try LokiChatController(
                model: model,
                store: store,
                signedSmokeStorageBoundary:
                    admission.storageBoundary,
                signedSmokeRuntimeAuthority:
                    admission.runtimeAuthority
            )
        )

        await model.shutdownForApplicationTermination()
    }

    @MainActor
    func testRawSignedSmokeStorageArgumentsCannotConstructRuntime()
        throws
    {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        XCTAssertThrowsError(
            try AppModel.makeLive(
                isTesting: false,
                arguments: [
                    "LokiBrief",
                    LokiLaunchStorageResolver.signedSmokeSentinel,
                    LokiLaunchStorageResolver.isolatedRootArgument,
                    fixture.root.path,
                ],
                environment: [:],
                pathPolicy: fixture.policy,
                fileManager: fileManager
            )
        ) {
            XCTAssertEqual(
                $0 as? LokiLaunchStorageReasonCode,
                .signedSmokePairInvalid
            )
        }
    }

    func testMalformedDuplicateAndPartialArgumentsFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        let control =
            P8FSignedSmokeAdmissionResolver.controlSentinel
        let signed = LokiLaunchStorageResolver.signedSmokeSentinel
        let root = LokiLaunchStorageResolver.isolatedRootArgument

        let cases: [(String, [String], P8FSignedSmokeAdmissionFailure)] = [
            (
                "no executable",
                [],
                .malformedArguments
            ),
            (
                "missing control",
                ["LokiBrief", signed, root, fixture.root.path],
                .controlSentinelMissing
            ),
            (
                "duplicate control",
                [
                    "LokiBrief",
                    control,
                    control,
                    signed,
                    root,
                    fixture.root.path,
                ],
                .duplicateControlSentinel
            ),
            (
                "missing signed storage",
                ["LokiBrief", control, root, fixture.root.path],
                .signedSmokeSentinelMissing
            ),
            (
                "duplicate signed storage",
                [
                    "LokiBrief",
                    control,
                    signed,
                    signed,
                    root,
                    fixture.root.path,
                ],
                .signedSmokeSentinelDuplicate
            ),
            (
                "missing root",
                ["LokiBrief", control, signed],
                .isolatedRootMissing
            ),
            (
                "duplicate root",
                [
                    "LokiBrief",
                    control,
                    signed,
                    root,
                    fixture.root.path,
                    root,
                    fixture.root.path,
                ],
                .isolatedRootDuplicate
            ),
            (
                "control assignment form",
                [
                    "LokiBrief",
                    control + "=true",
                    signed,
                    root,
                    fixture.root.path,
                ],
                .malformedArguments
            ),
            (
                "signed assignment form",
                [
                    "LokiBrief",
                    control,
                    signed + "=true",
                    root,
                    fixture.root.path,
                ],
                .malformedArguments
            ),
            (
                "root assignment form",
                [
                    "LokiBrief",
                    control,
                    signed,
                    root + "=" + fixture.root.path,
                ],
                .malformedArguments
            ),
            (
                "unknown argument",
                fixture.arguments + ["--unexpected"],
                .malformedArguments
            ),
        ]

        for testCase in cases {
            assertFailure(
                testCase.2,
                message: testCase.0
            ) {
                _ = try resolve(
                    fixture,
                    arguments: testCase.1
                )
            }
        }
    }

    func testEnvironmentXCTestCapabilityAndIdentityGatesFailClosed() throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }

        assertFailure(.environmentIsolationRejected) {
            _ = try resolve(
                fixture,
                environment: [
                    LokiLaunchStorageResolver.isolatedRootEnvironment:
                        fixture.root.path,
                ]
            )
        }
        assertFailure(.environmentIsolationRejected) {
            _ = try resolve(
                fixture,
                arguments: [
                    "LokiBrief",
                    P8FSignedSmokeAdmissionResolver.controlSentinel,
                    LokiLaunchStorageResolver.signedSmokeSentinel,
                ],
                environment: [
                    LokiLaunchStorageResolver.isolatedRootEnvironment:
                        fixture.root.path,
                ]
            )
        }
        assertFailure(.xctestRejected) {
            _ = try resolve(fixture, isXCTest: true)
        }
        assertFailure(.capabilityMissing) {
            _ = try resolve(fixture, capabilities: [])
        }

        let identities = [
            P8FSignedSmokeApplicationIdentity(
                bundleIdentifier: "com.agentloki.LokiBrief",
                marketingVersion: "1.0.0",
                buildVersion: "5"
            ),
            P8FSignedSmokeApplicationIdentity(
                bundleIdentifier:
                    "com.agentloki.LokiBrief.P8FResumeSmoke",
                marketingVersion: "1.0.1",
                buildVersion: "5"
            ),
            P8FSignedSmokeApplicationIdentity(
                bundleIdentifier:
                    "com.agentloki.LokiBrief.P8FResumeSmoke",
                marketingVersion: "1.0.0",
                buildVersion: "4"
            ),
        ]
        for identity in identities {
            assertFailure(.applicationIdentityMismatch) {
                _ = try resolve(
                    fixture,
                    applicationIdentity: identity
                )
            }
        }

        let incomplete = try makeFixture()
        defer { try? fileManager.removeItem(at: incomplete.parent) }
        try fileManager.removeItem(
            at: incomplete.root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
        )
        assertFailure(.storagePlanRejected) {
            _ = try resolve(incomplete)
        }
    }

    func testFixedControlPlanFileIntegrityFailsClosed() throws {
        try withFixture { fixture in
            try fileManager.removeItem(at: fixture.planURL)
            assertFailure(.planMissing) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let target = fixture.parent.appendingPathComponent(
                "outside-control-plan.json"
            )
            try encoded(validPlan()).write(to: target)
            try setPermissions(0o600, at: target)
            try fileManager.removeItem(at: fixture.planURL)
            try fileManager.createSymbolicLink(
                at: fixture.planURL,
                withDestinationURL: target
            )
            assertFailure(.planSymlinkRejected) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            try fileManager.removeItem(at: fixture.planURL)
            try fileManager.createDirectory(
                at: fixture.planURL,
                withIntermediateDirectories: false
            )
            assertFailure(.planNotRegular) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            try setPermissions(0o644, at: fixture.planURL)
            assertFailure(.planPermissionsInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            try setPermissions(0o755, at: fixture.root)
            assertFailure(.rootPermissionsInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            try Data(
                repeating: 0x41,
                count:
                    P8FSignedSmokeAdmissionResolver
                    .maximumControlPlanBytes + 1
            ).write(to: fixture.planURL)
            try setPermissions(0o600, at: fixture.planURL)
            assertFailure(.planTooLarge) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            try Data("{".utf8).write(to: fixture.planURL)
            try setPermissions(0o600, at: fixture.planURL)
            assertFailure(.planMalformed) {
                _ = try resolve(fixture)
            }
        }
    }

    func testStoragePairModesAndIntermediateSymlinksFailClosed()
        throws
    {
        try withFixture { fixture in
            let store = fixture.root.appendingPathComponent(
                "LokiBrief-v1.store"
            )
            try setPermissions(0o644, at: store)
            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let vaultRoot = fixture.root.appendingPathComponent(
                "Vault",
                isDirectory: true
            )
            try setPermissions(0o755, at: vaultRoot)
            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let vaultRoot = fixture.root.appendingPathComponent(
                "Vault",
                isDirectory: true
            )
            let outsideVault = fixture.parent.appendingPathComponent(
                "outside-vault",
                isDirectory: true
            )
            let outsideVersion = outsideVault.appendingPathComponent(
                "v1",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: outsideVersion,
                withIntermediateDirectories: true
            )
            try setPermissions(0o700, at: outsideVault)
            try setPermissions(0o700, at: outsideVersion)
            let outsideDatabase = outsideVersion
                .appendingPathComponent("loki-vault.sqlite3")
            guard fileManager.createFile(
                atPath: outsideDatabase.path,
                contents: Data()
            ) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try setPermissions(0o600, at: outsideDatabase)
            try fileManager.removeItem(at: vaultRoot)
            try fileManager.createSymbolicLink(
                at: vaultRoot,
                withDestinationURL: outsideVault
            )
            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let outside = fixture.parent.appendingPathComponent(
                "outside-semantic",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            try setPermissions(0o700, at: outside)
            let canary = outside.appendingPathComponent("canary")
            let canaryData = Data("semantic-canary".utf8)
            try canaryData.write(to: canary)
            try setPermissions(0o600, at: canary)
            let semantic = fixture.root.appendingPathComponent(
                "Semantic",
                isDirectory: true
            )
            try fileManager.createSymbolicLink(
                at: semantic,
                withDestinationURL: outside
            )

            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
            XCTAssertEqual(try Data(contentsOf: canary), canaryData)
        }

        try withFixture { fixture in
            let outside = fixture.parent.appendingPathComponent(
                "outside-control",
                isDirectory: true
            )
            try fileManager.createDirectory(
                at: outside,
                withIntermediateDirectories: false
            )
            try setPermissions(0o700, at: outside)
            let canary = outside.appendingPathComponent("canary")
            let canaryData = Data("control-canary".utf8)
            try canaryData.write(to: canary)
            try setPermissions(0o600, at: canary)
            try fileManager.createSymbolicLink(
                at: fixture.root.appendingPathComponent(
                    "P8FControl",
                    isDirectory: true
                ),
                withDestinationURL: outside
            )

            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
            XCTAssertEqual(try Data(contentsOf: canary), canaryData)
        }

        try withFixture { fixture in
            let outside = fixture.parent.appendingPathComponent(
                "outside-sidecar"
            )
            let canaryData = Data("sidecar-canary".utf8)
            try canaryData.write(to: outside)
            try setPermissions(0o600, at: outside)
            let sidecar = fixture.root.appendingPathComponent(
                "LokiBrief-v1.store-wal"
            )
            try fileManager.createSymbolicLink(
                at: sidecar,
                withDestinationURL: outside
            )

            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
            XCTAssertEqual(try Data(contentsOf: outside), canaryData)
        }

        try withFixture { fixture in
            let semanticVersion = fixture.root
                .appendingPathComponent("Semantic", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
            try fileManager.createDirectory(
                at: semanticVersion,
                withIntermediateDirectories: true
            )
            try setPermissions(
                0o700,
                at: semanticVersion.deletingLastPathComponent()
            )
            try setPermissions(0o700, at: semanticVersion)
            let semanticDatabase = semanticVersion
                .appendingPathComponent("loki-semantic.sqlite3")
            let insecureSidecar = URL(
                fileURLWithPath: semanticDatabase.path + "-shm"
            )
            try Data().write(to: semanticDatabase)
            try Data().write(to: insecureSidecar)
            try setPermissions(0o600, at: semanticDatabase)
            try setPermissions(0o644, at: insecureSidecar)

            assertFailure(.storagePairIntegrityInvalid) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let primary = fixture.root.appendingPathComponent(
                "LokiBrief-v1.store"
            )
            let vault = fixture.root
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent("loki-vault.sqlite3")
            for database in [primary, vault] {
                for suffix in ["-wal", "-shm"] {
                    let sidecar = URL(
                        fileURLWithPath: database.path + suffix
                    )
                    try Data().write(to: sidecar)
                    try setPermissions(0o600, at: sidecar)
                }
            }

            let boundary = try P8FSignedSmokeStorageBoundary(
                admitting: fixture.root
            )
            XCTAssertNoThrow(try boundary.auditExistingTree())
            XCTAssertNoThrow(
                try boundary.validateSQLiteFamily(
                    at: primary,
                    requireDatabase: true
                )
            )
            XCTAssertNoThrow(
                try boundary.validateSQLiteFamily(
                    at: vault,
                    requireDatabase: true
                )
            )

            XCTAssertNoThrow(try resolve(fixture))
        }
    }

    func testClosedSchemaRejectsUnknownFieldsAndUnknownScenarios() throws {
        try withFixture { fixture in
            let json = """
            {
              "contractVersion": "\(P8FSignedSmokeControlPlan.currentContractVersion)",
              "runIdentifier": "p8f-run-001",
              "scenario": "search",
              "expectedFixtureManifestSHA256": "\(manifestSHA256)",
              "outputPath": "/tmp/not-authorized"
            }
            """
            try write(Data(json.utf8), to: fixture.planURL)
            assertFailure(.planMalformed) {
                _ = try resolve(fixture)
            }
        }

        try withFixture { fixture in
            let json = """
            {
              "contractVersion": "\(P8FSignedSmokeControlPlan.currentContractVersion)",
              "runIdentifier": "p8f-run-001",
              "scenario": "arbitrary_action",
              "expectedFixtureManifestSHA256": "\(manifestSHA256)"
            }
            """
            try write(Data(json.utf8), to: fixture.planURL)
            assertFailure(.planMalformed) {
                _ = try resolve(fixture)
            }
        }
    }

    func testInvalidPlanContractsFailClosed() throws {
        let invalidPlans = [
            P8FSignedSmokeControlPlan(
                contractVersion: "agent-loki.p8f.signed-smoke-control.v2",
                runIdentifier: "p8f-run-001",
                scenario: .search,
                expectedFixtureManifestSHA256: manifestSHA256
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "P8F-RUN-001",
                scenario: .search,
                expectedFixtureManifestSHA256: manifestSHA256
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "p8f-run-001",
                scenario: .search,
                expectedFixtureManifestSHA256:
                    String(repeating: "A", count: 64)
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "p8f-run-001",
                scenario: .search,
                expectedFixtureManifestSHA256: manifestSHA256,
                expectedExecutableSHA256: "not-a-sha256"
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "p8f-run-001",
                scenario: .modelAssessment,
                expectedFixtureManifestSHA256: manifestSHA256
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "p8f-run-001",
                scenario: .modelAssessment,
                expectedFixtureManifestSHA256: manifestSHA256,
                modelIdentifier: "qwen3-embedding:4b"
            ),
            P8FSignedSmokeControlPlan(
                runIdentifier: "p8f-run-001",
                scenario: .hydration,
                expectedFixtureManifestSHA256: manifestSHA256,
                modelIdentifier: "qwen3-embedding:4b",
                modelDigest: modelSHA256
            ),
        ]

        for plan in invalidPlans {
            let fixture = try makeFixture(plan: plan)
            defer { try? fileManager.removeItem(at: fixture.parent) }
            assertFailure(.planContractInvalid) {
                _ = try resolve(fixture)
            }
        }
    }

    func testEncodedPlanIsPathlessAndUsesOnlyClosedFields() throws {
        let plan = validPlan(for: .modelAssessment)
        let data = try encoded(plan)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        )

        XCTAssertEqual(
            Set(object.keys),
            [
                "contractVersion",
                "runIdentifier",
                "scenario",
                "expectedFixtureManifestSHA256",
                "expectedExecutableSHA256",
                "modelIdentifier",
                "modelDigest",
            ]
        )
        XCTAssertFalse(
            object.keys.contains {
                $0.lowercased().contains("path")
                    || $0.lowercased().contains("url")
            }
        )
        XCTAssertEqual(
            Set(P8FSignedSmokeControlScenario.allCases),
            [
                .semanticSourceProof,
                .modelAssessment,
                .search,
                .hydration,
                .cleanup,
            ]
        )
    }

    private struct Fixture {
        let parent: URL
        let root: URL
        let policy: LokiLaunchStoragePathPolicy

        var planURL: URL {
            root.appendingPathComponent(
                P8FSignedSmokeAdmissionResolver.controlPlanFileName
            )
        }

        var arguments: [String] {
            [
                "LokiBrief",
                P8FSignedSmokeAdmissionResolver.controlSentinel,
                LokiLaunchStorageResolver.signedSmokeSentinel,
                LokiLaunchStorageResolver.isolatedRootArgument,
                root.path,
            ]
        }
    }

    private func validPlan(
        for scenario: P8FSignedSmokeControlScenario = .search
    ) -> P8FSignedSmokeControlPlan {
        let requiresModel = scenario == .modelAssessment
        return P8FSignedSmokeControlPlan(
            runIdentifier: "p8f-run-001",
            scenario: scenario,
            expectedFixtureManifestSHA256: manifestSHA256,
            expectedExecutableSHA256: executableSHA256,
            modelIdentifier:
                requiresModel ? "qwen3-embedding:4b" : nil,
            modelDigest: requiresModel ? modelSHA256 : nil
        )
    }

    private func makeFixture(
        plan: P8FSignedSmokeControlPlan? = nil
    ) throws -> Fixture {
        let temporaryDirectory = try XCTUnwrap(
            LokiCanonicalFileURL.existing(
                fileManager.temporaryDirectory,
                isDirectory: true
            )
        )
        let parent = temporaryDirectory
            .appendingPathComponent(
                "loki-p8f-admission-\(UUID().uuidString)",
                isDirectory: true
            )
        let approved = parent.appendingPathComponent(
            "approved",
            isDirectory: true
        )
        let root = approved.appendingPathComponent(
            "signed-smoke",
            isDirectory: true
        )
        let vaultDirectory = root
            .appendingPathComponent("Vault", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try fileManager.createDirectory(
            at: vaultDirectory,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, at: root)
        try setPermissions(
            0o700,
            at: root.appendingPathComponent(
                "Vault",
                isDirectory: true
            )
        )
        try setPermissions(0o700, at: vaultDirectory)
        let swiftDataURL = root.appendingPathComponent(
            "LokiBrief-v1.store"
        )
        let vaultURL = vaultDirectory
            .appendingPathComponent("loki-vault.sqlite3")
        guard fileManager.createFile(
            atPath: swiftDataURL.path,
            contents: Data()
        ),
        fileManager.createFile(
            atPath: vaultURL.path,
            contents: Data()
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try setPermissions(0o600, at: swiftDataURL)
        try setPermissions(0o600, at: vaultURL)

        let policy = LokiLaunchStoragePathPolicy(
            approvedTemporaryRoots: [approved],
            productionApplicationSupportRoot:
                parent.appendingPathComponent(
                    "production-application-support",
                    isDirectory: true
                ),
            recoveryRoots: [
                parent.appendingPathComponent(
                    "production-recovery",
                    isDirectory: true
                ),
            ]
        )
        let fixture = Fixture(
            parent: parent,
            root: root,
            policy: policy
        )
        try write(
            encoded(plan ?? validPlan()),
            to: fixture.planURL
        )
        return fixture
    }

    private func withFixture(
        _ body: (Fixture) throws -> Void
    ) throws {
        let fixture = try makeFixture()
        defer { try? fileManager.removeItem(at: fixture.parent) }
        try body(fixture)
    }

    private func makeSemanticDatabaseURL(
        admission: P8FSignedSmokeAdmission
    ) throws -> URL {
        let directory = admission.storageBoundary.rootURL
            .appendingPathComponent("Semantic", isDirectory: true)
            .appendingPathComponent("v1", isDirectory: true)
        try admission.storageBoundary.ensurePrivateDirectory(
            at: directory
        )
        return directory.appendingPathComponent(
            "loki-semantic.sqlite3"
        )
    }

    @MainActor
    private func makeSemanticPackage(
        admission: P8FSignedSmokeAdmission
    ) throws -> P8FSignedSmokeDependencyPackage {
        let storeURL = try XCTUnwrap(
            admission.storagePlan.swiftDataURL
        )
        let store = try LocalStore(url: storeURL)
        try admission.storageBoundary.secureSQLiteFamily(
            at: storeURL,
            requireDatabase: true,
            fileManager: fileManager
        )
        return try P8FSignedSmokeDependencyPackage.makeAppOwned(
            store: store,
            storageBoundary: admission.storageBoundary,
            runtimeAuthority: admission.runtimeAuthority
        )
    }

    private func signedSmokeBuildScope(
        receiptIdentifier: String
    ) throws -> SemanticIndexBuildScope {
        try .init(
            sourceKinds: [.brief],
            adapterContractVersions: [.brief: "p8f-brief-adapter-v1"],
            requestTimestamp: Date(timeIntervalSince1970: 1_800_000_000),
            initiation: .signedSmokeRunner,
            authorizationReceiptIdentifier: receiptIdentifier
        )
    }

    private func completeEmptyGeneration(
        _ generation: SemanticIndexGenerationMetadata,
        scope: SemanticIndexBuildScope,
        index: SemanticVaultIndex,
        runIdentifier: String
    ) async throws {
        let adapter = try XCTUnwrap(
            scope.adapterContractVersion(for: .brief)
        )
        let request = try SemanticIndexBatchRequest(
            runIdentifier: runIdentifier,
            streamIdentifier: "briefs",
            currentCursor: nil,
            nextCursor: nil,
            sourceHighWatermark: nil,
            isFinalBatch: true,
            sourceKind: .brief,
            adapterContractVersion: adapter,
            sourceAllowlistSHA256: scope.allowlistSHA256,
            authorizationReceiptIdentifier:
                scope.authorizationReceiptIdentifier,
            records: []
        )
        let prepared = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        _ = try await index.commit(
            prepared,
            embeddingsByChunkIdentifier: [:]
        )
    }

    private func encoded(
        _ plan: P8FSignedSmokeControlPlan
    ) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(plan)
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try setPermissions(0o600, at: url)
    }

    private func setPermissions(_ mode: Int, at url: URL) throws {
        try fileManager.setAttributes(
            [.posixPermissions: mode],
            ofItemAtPath: url.path
        )
    }

    private func resolve(
        _ fixture: Fixture,
        arguments: [String]? = nil,
        environment: [String: String] = [:],
        isXCTest: Bool = false,
        applicationIdentity:
            P8FSignedSmokeApplicationIdentity = .required,
        capabilities:
            Set<P8FSignedSmokeAdmissionCapability> = [.p8fControlV1]
    ) throws -> P8FSignedSmokeAdmission {
        try P8FSignedSmokeAdmissionResolver.resolveForXCTest(
            arguments: arguments ?? fixture.arguments,
            environment: environment,
            simulateXCTestRejection: isXCTest,
            applicationIdentity: applicationIdentity,
            capabilities: capabilities,
            pathPolicy: fixture.policy,
            fileManager: fileManager
        )
    }

    private func assertFailure(
        _ expected: P8FSignedSmokeAdmissionFailure,
        message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line,
        operation: () throws -> Void
    ) {
        do {
            try operation()
            XCTFail(
                "Expected \(expected.rawValue). \(message)",
                file: file,
                line: line
            )
        } catch {
            XCTAssertEqual(
                error as? P8FSignedSmokeAdmissionFailure,
                expected,
                message,
                file: file,
                line: line
            )
        }
    }
}
