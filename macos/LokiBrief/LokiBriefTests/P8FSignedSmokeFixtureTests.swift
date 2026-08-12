import Foundation
import XCTest
@testable import LokiBrief

@MainActor
final class P8FSignedSmokeFixtureTests: XCTestCase {
    func testCanonicalFixtureUsesRealAdaptersAndFreezesExactScope()
        async throws
    {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let seeded = try P8FSignedSmokeFixtureSeeder.seed(
            isolatedRoot: root
        )
        let manifest = seeded.manifest
        XCTAssertEqual(
            manifest.schemaVersion,
            P8FSignedSmokeFixtureManifest.currentSchemaVersion
        )
        XCTAssertEqual(
            manifest.fixtureIdentifier,
            P8FSignedSmokeFixtureManifest.fixtureIdentifier
        )
        XCTAssertEqual(
            manifest.canonicalSourceKinds,
            [.brief, .chatMessage, .schedule]
        )
        XCTAssertEqual(
            manifest.expectedSourceAllowlistSHA256,
            P8FSignedSmokeFixtureManifest
                .expectedSourceAllowlistSHA256
        )
        XCTAssertEqual(manifest.expectedPreparedRecordCount, 4)
        XCTAssertEqual(manifest.expectedChunkCount, 4)
        XCTAssertEqual(manifest.expectedSourceEmbeddingCount, 4)
        XCTAssertEqual(manifest.expectedIndexWriteCount, 4)
        XCTAssertEqual(manifest.sourceHashes.count, 4)
        XCTAssertTrue(
            P8FSignedSmokeDigest.isSHA256(
                manifest.canonicalSHA256
            )
        )
        XCTAssertEqual(
            manifest.canonicalSHA256,
            P8FSignedSmokeFixtureManifest
                .expectedCanonicalSHA256
        )

        let audit =
            try P8FSignedSmokeFixtureSeeder.auditClosedSourceDomain(
                fixtureDirectory: seeded.fixtureDirectory
            )
        XCTAssertEqual(audit.envelopeCount, 5)
        XCTAssertEqual(audit.excludedKnownKindCount, 3)
        XCTAssertEqual(audit.unknownRejectedCount, 1)
        XCTAssertEqual(audit.malformedRejectedCount, 1)
        XCTAssertEqual(audit.acceptedUnexpectedKindCount, 0)

        let registry = try P8FSignedSmokeDependencyPackage
            .makeXCTestSourceRegistry(
            store: seeded.store
        )
        let selected: Set<SemanticIndexSourceKind> = [
            .brief,
            .schedule,
            .chatMessage,
        ]
        for provider in registry.providers()
        where selected.contains(provider.sourceKind) {
            _ = try await provider.records()
        }
        let counters = registry.counters()
        for counter in counters {
            if selected.contains(counter.sourceKind) {
                XCTAssertEqual(counter.adapterInvocations, 1)
            } else {
                XCTAssertEqual(counter.adapterInvocations, 0)
                XCTAssertEqual(counter.recordsRead, 0)
            }
        }
        XCTAssertEqual(
            counters.reduce(0) { $0 + $1.recordsRead },
            4
        )
    }

    func testCanonicalFixtureSeedsOnceAndManifestReopens()
        throws
    {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = try P8FSignedSmokeFixtureSeeder.seed(
            isolatedRoot: root
        )
        XCTAssertThrowsError(
            try P8FSignedSmokeFixtureSeeder.seed(
                isolatedRoot: root
            )
        )
        let second = try P8FSignedSmokeFixtureSeeder.reopen(
            isolatedRoot: root
        )

        XCTAssertEqual(first.manifest, second.manifest)
        XCTAssertEqual(
            first.manifest.canonicalSHA256,
            second.manifest.canonicalSHA256
        )
        let attributes = try FileManager.default
            .attributesOfItem(
                atPath: second.fixtureDirectory
                    .appendingPathComponent(
                        P8FSignedSmokeFixtureSeeder
                            .manifestFilename
                    ).path
            )
        XCTAssertEqual(
            (attributes[.posixPermissions] as? NSNumber)?
                .intValue,
            0o600
        )
    }

    func testMissingFrozenManifestFailsClosedWithoutRecreation()
        throws
    {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let seeded = try P8FSignedSmokeFixtureSeeder.seed(
            isolatedRoot: root
        )
        let manifestURL = seeded.fixtureDirectory
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.manifestFilename,
                isDirectory: false
            )
        let storeURL = seeded.fixtureDirectory
            .appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.fixtureStoreFilename,
                isDirectory: false
            )
        try FileManager.default.removeItem(at: manifestURL)

        XCTAssertThrowsError(
            try P8FSignedSmokeFixtureSeeder.reopen(
                isolatedRoot: root
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: manifestURL.path
            )
        )
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: storeURL.path
            )
        )
        XCTAssertThrowsError(
            try P8FSignedSmokeFixtureSeeder.seed(
                isolatedRoot: root
            )
        )
    }

    func testAdapterKindDriftIsProducedOnlyByConstructorBoundMode()
        async throws
    {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let seeded = try P8FSignedSmokeFixtureSeeder.seed(
            isolatedRoot: root
        )
        let registry = try P8FSignedSmokeDependencyPackage
            .makeXCTestSourceRegistry(
                store: seeded.store,
                mode: .adapterKindDrift(
                    expected: .brief,
                    actual: .slackRecord
                )
            )
        let provider = try XCTUnwrap(
            registry.providers().first {
                $0.sourceKind == .brief
            }
        )
        let records = try await provider.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.sourceKind, .slackRecord)
        XCTAssertEqual(
            registry.counters().first {
                $0.sourceKind == .brief
            }?.adapterInvocations,
            1
        )
    }

    func testPreexistingControlSymlinkFailsBeforeFixtureWrites()
        throws
    {
        let root = try makeRoot()
        let outside = root.deletingLastPathComponent()
            .appendingPathComponent(
                "P8FSignedSmokeOutside-\(UUID().uuidString)",
                isDirectory: true
            )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }
        try FileManager.default.createDirectory(
            at: outside,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: outside.path
        )
        let canary = outside.appendingPathComponent("canary")
        let canaryData = Data("fixture-boundary-canary".utf8)
        try canaryData.write(to: canary)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: canary.path
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(
                P8FSignedSmokeFixtureSeeder.controlDirectoryName,
                isDirectory: true
            ),
            withDestinationURL: outside
        )

        XCTAssertThrowsError(
            try P8FSignedSmokeFixtureSeeder.seed(
                isolatedRoot: root
            )
        ) { error in
            XCTAssertEqual(
                error as? P8FSignedSmokeFixtureFailure,
                .fixtureDirectoryInvalid
            )
        }
        XCTAssertEqual(try Data(contentsOf: canary), canaryData)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(
                    P8FSignedSmokeFixtureSeeder.fixtureDirectoryName,
                    isDirectory: true
                ).path
            )
        )
    }

    private func makeRoot() throws -> URL {
        let temporaryDirectory = try XCTUnwrap(
            LokiCanonicalFileURL.existing(
                FileManager.default.temporaryDirectory,
                isDirectory: true
            )
        )
        let root = temporaryDirectory
            .appendingPathComponent(
                "P8FSignedSmokeFixture-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: root.path
        )
        return root
    }
}
