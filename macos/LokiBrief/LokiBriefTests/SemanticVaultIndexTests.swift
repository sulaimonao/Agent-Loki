import Foundation
import SQLite3
import XCTest
@testable import LokiBrief

final class SemanticVaultIndexTests: XCTestCase, @unchecked Sendable {
    private let anchor = Date(timeIntervalSince1970: 1_800_000_000)

    private struct LegacyStorageSnapshot: Equatable {
        let userVersion: Int
        let generationIdentifier: String
        let sourceCount: Int
        let chunkCount: Int
        let ftsCount: Int
        let vectorBlobs: [Data]
        let generationColumns: [String]
    }

    private final class PublishLifecycleProbe:
        @unchecked Sendable
    {
        private let lock = NSLock()
        private var successfulChecksBeforeFailure: Int?

        func failAfterSuccessfulChecks(_ count: Int) {
            lock.lock()
            successfulChecksBeforeFailure = count
            lock.unlock()
        }

        func isValid() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard let remaining = successfulChecksBeforeFailure else {
                return true
            }
            if remaining == 0 {
                return false
            }
            successfulChecksBeforeFailure = remaining - 1
            return true
        }
    }

    private enum InjectedFinalPublicationFailure:
        Error,
        Equatable
    {
        case vetoed
    }

    func testRawInMemoryIndexRejectsSignedSmokeRunnerAuthority()
        async throws
    {
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "raw-signed-smoke-rejected",
            initiation: .signedSmokeRunner
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            now: fixedClock()
        )

        do {
            _ = try await index.beginGeneration(
                spec: generationSpec(buildScope: scope)
            )
            XCTFail("A raw in-memory index must not gain smoke authority.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }
    }

    func testExplicitXCTestInMemoryAuthorityAllowsSignedSmokeRunner()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let unrelatedAuthority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "xctest-signed-smoke-authorized",
            initiation: .signedSmokeRunner
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority,
            now: fixedClock()
        )
        XCTAssertNoThrow(
            try index.validateSignedSmokeRuntimeAuthority(authority)
        )
        XCTAssertThrowsError(
            try index.validateSignedSmokeRuntimeAuthority(
                unrelatedAuthority
            )
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .signedSmokeAuthorityInvalid
            )
        }

        let generation = try await index.beginGeneration(
            spec: generationSpec(buildScope: scope)
        )
        let request = try batchRequest(
            run: "xctest-signed-smoke-run",
            stream: "briefs",
            final: true,
            records: [],
            sourceKind: .brief,
            buildScope: scope
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: [:]
        )
        let published = try await index.publishGeneration(
            generation.identifier
        )
        XCTAssertEqual(published.state, .ready)
    }

    func testCommittedPublicationHealthRequiresNoPostCommitDatabaseRead()
        async throws
    {
        let authority = try P8FSignedSmokeRuntimeAuthority
            .makeXCTestInMemory()
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "post-commit-health",
            initiation: .signedSmokeRunner
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            signedSmokeRuntimeAuthority: authority,
            now: fixedClock()
        )
        let generation = try await index.beginGeneration(
            spec: generationSpec(buildScope: scope)
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: try batchRequest(
                run: "post-commit-health-run",
                stream: "briefs",
                final: true,
                records: [],
                sourceKind: .brief,
                buildScope: scope
            )
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: [:]
        )
        let published = try await index.publishGeneration(
            generation.identifier
        )

        await index.close()
        let health = await index.committedPublicationHealth(
            for: published
        )
        XCTAssertEqual(health.state, .ready)
        XCTAssertEqual(
            health.activeGeneration?.identifier,
            generation.identifier
        )
    }

    func testBuildScopeAllowlistHashIsCanonicalAndClosedDomainRejectsUnknownKinds()
        throws
    {
        let sourceKinds: Set<SemanticIndexSourceKind> = [
            .brief,
            .schedule,
            .chatMessage,
        ]
        let adapters = Dictionary(
            uniqueKeysWithValues: sourceKinds.map {
                ($0, "adapter-\($0.rawValue)-v1")
            }
        )
        let lhs = try SemanticIndexBuildScope(
            sourceKinds: sourceKinds,
            adapterContractVersions: adapters,
            requestTimestamp: anchor,
            authorizationReceiptIdentifier: "canonical-lhs"
        )
        let rhs = try SemanticIndexBuildScope(
            sourceKinds: Set([
                SemanticIndexSourceKind.chatMessage,
                .schedule,
                .brief,
            ]),
            adapterContractVersions: adapters,
            requestTimestamp: anchor,
            authorizationReceiptIdentifier: "canonical-rhs"
        )
        let different = try defaultBuildScope(
            sourceKinds: [.brief, .schedule],
            receiptIdentifier: "canonical-different"
        )

        XCTAssertEqual(lhs.allowlistSHA256, rhs.allowlistSHA256)
        XCTAssertEqual(
            lhs.allowlistSHA256,
            "616d0c91529087a1b4fbb12e066a010bef35113a6b34eb9a6cd11fd98bcb0e1c"
        )
        XCTAssertEqual(
            different.allowlistSHA256,
            "9674fcdf7124ff4c58d431075b4dc0d9796e8ec5acf4da842838df998e17a256"
        )
        XCTAssertNotEqual(
            lhs.allowlistSHA256,
            different.allowlistSHA256
        )
        XCTAssertThrowsError(
            try JSONDecoder().decode(
                SemanticIndexSourceKind.self,
                from: Data(#""futureRecords""#.utf8)
            )
        )
    }

    func testExcludedIncrementalSourceFailsBeforeWritesAndPreservesBinding()
        async throws
    {
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "brief-only-authority"
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            now: fixedClock()
        )
        let generation = try await index.beginGeneration(
            spec: generationSpec(buildScope: scope)
        )
        let brief = try sourceRecord(
            identifier: "authority-brief",
            kind: .brief,
            text: "Authorized brief"
        )
        let request = try batchRequest(
            run: "authority-brief-run",
            stream: "briefs",
            final: true,
            records: [brief],
            buildScope: scope
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: embeddings(
                for: plan,
                vector: [1, 0, 0]
            )
        )
        let ready = try await publishGenerationForTests(
            generation,
            in: index
        )
        let boundScope = try XCTUnwrap(ready.spec.buildScope)
        XCTAssertEqual(boundScope.sourceKinds, [.brief])
        XCTAssertEqual(
            boundScope.allowlistSHA256,
            scope.allowlistSHA256
        )
        XCTAssertEqual(
            boundScope.adapterContractVersions,
            scope.adapterContractVersions
        )
        XCTAssertEqual(
            boundScope.authorizationReceiptIdentifier,
            "brief-only-authority"
        )

        let before = ready
        let slack = try sourceRecord(
            identifier: "excluded-slack",
            kind: .slackRecord,
            text: "Must never be prepared"
        )
        let unauthorized = try SemanticIndexBatchRequest(
            runIdentifier: "excluded-slack-run",
            streamIdentifier: "slack",
            currentCursor: nil,
            nextCursor: nil,
            sourceHighWatermark: nil,
            isFinalBatch: true,
            sourceKind: .slackRecord,
            adapterContractVersion: "slack-adapter-v1",
            sourceAllowlistSHA256: scope.allowlistSHA256,
            authorizationReceiptIdentifier:
                scope.authorizationReceiptIdentifier,
            records: [slack]
        )
        do {
            _ = try await index.prepareBatch(
                generationIdentifier: ready.identifier,
                request: unauthorized
            )
            XCTFail("An excluded source event must fail before preparation.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .sourceScopeViolation
            )
        }
        let activeAfter = try await index.activeGeneration()
        let after = try XCTUnwrap(activeAfter)
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.chunkCount, before.chunkCount)
        XCTAssertEqual(
            after.sourceManifestDigest,
            before.sourceManifestDigest
        )
        let unauthorizedProgress = try await index.progress(
            runIdentifier: "excluded-slack-run"
        )
        XCTAssertNil(unauthorizedProgress)
    }

    func testPublishRejectsCandidateCorruptionAndPreservesPriorActive()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SemanticPublishCorruption-\(UUID().uuidString)",
                isDirectory: true
            )
        let url = directory.appendingPathComponent(
            "derived-semantic.sqlite3"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "corruption-authority"
        )
        let index = try SemanticVaultIndex(
            url: url,
            now: fixedClock()
        )
        let pair = try await readyPriorAndCandidate(
            in: index,
            scope: scope,
            suffix: "corruption"
        )
        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(
                database,
                sql: """
                    UPDATE semantic_chunks
                    SET normalized_text = 'tampered candidate text'
                    WHERE generation_id = ?
                    """,
                textBinds: [pair.candidate.identifier]
            )
        }

        do {
            _ = try await index.publishGeneration(
                pair.candidate.identifier
            )
            XCTFail("Corrupted candidate content must not publish.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .databaseCorrupt
            )
        }
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.identifier, pair.prior.identifier)
        let candidate = try await index.generation(
            identifier: pair.candidate.identifier
        )
        XCTAssertEqual(candidate?.state, .building)
    }

    func testPublishRejectsCheckpointCountMismatchAndPreservesPriorActive()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SemanticPublishCounts-\(UUID().uuidString)",
                isDirectory: true
            )
        let url = directory.appendingPathComponent(
            "derived-semantic.sqlite3"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "count-authority"
        )
        let index = try SemanticVaultIndex(
            url: url,
            now: fixedClock()
        )
        let pair = try await readyPriorAndCandidate(
            in: index,
            scope: scope,
            suffix: "counts"
        )
        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(
                database,
                sql: """
                    UPDATE semantic_checkpoints
                    SET records_committed = records_committed + 1
                    WHERE generation_id = ?
                      AND source_kind = 'brief'
                    """,
                textBinds: [pair.candidate.identifier]
            )
        }

        do {
            _ = try await index.publishGeneration(
                pair.candidate.identifier
            )
            XCTFail("Mismatched checkpoint counts must not publish.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .checkpointMismatch
            )
        }
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.identifier, pair.prior.identifier)
    }

    func testFinalPublishLifecycleCancellationPreservesPriorActive()
        async throws
    {
        let probe = PublishLifecycleProbe()
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "lifecycle-authority"
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            now: fixedClock(),
            publishLifecycleIsValid: { probe.isValid() }
        )
        let pair = try await readyPriorAndCandidate(
            in: index,
            scope: scope,
            suffix: "lifecycle"
        )
        probe.failAfterSuccessfulChecks(1)

        do {
            _ = try await index.publishGeneration(
                pair.candidate.identifier
            )
            XCTFail("Final lifecycle cancellation must abort publication.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .cancelled
            )
        }
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.identifier, pair.prior.identifier)
        let candidate = try await index.generation(
            identifier: pair.candidate.identifier
        )
        XCTAssertEqual(candidate?.state, .building)
    }

    func testFinalPublicationValidatorFailurePreservesPriorActive()
        async throws
    {
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "final-validator-authority"
        )
        let index = try SemanticVaultIndex(
            inMemory: true,
            now: fixedClock(),
            finalPublicationValidator: {
                _,
                priorActiveIdentifier in
                guard priorActiveIdentifier == nil else {
                    throw InjectedFinalPublicationFailure.vetoed
                }
            }
        )
        let pair = try await readyPriorAndCandidate(
            in: index,
            scope: scope,
            suffix: "final-validator"
        )

        do {
            _ = try await index.publishGeneration(
                pair.candidate.identifier
            )
            XCTFail(
                "An injected final publication veto must abort publication."
            )
        } catch {
            XCTAssertEqual(
                error as? InjectedFinalPublicationFailure,
                .vetoed
            )
        }
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.identifier, pair.prior.identifier)
        let candidate = try await index.generation(
            identifier: pair.candidate.identifier
        )
        XCTAssertEqual(candidate?.state, .building)
    }

    func testCorruptedStoredAllowlistHashFailsClosedOnReopen()
        async throws
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SemanticAllowlistCorruption-\(UUID().uuidString)",
                isDirectory: true
            )
        let url = directory.appendingPathComponent(
            "derived-semantic.sqlite3"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let scope = try defaultBuildScope(
            sourceKinds: [.brief],
            receiptIdentifier: "stored-authority"
        )
        let index = try SemanticVaultIndex(
            url: url,
            now: fixedClock()
        )
        let pair = try await readyPriorAndCandidate(
            in: index,
            scope: scope,
            suffix: "stored"
        )
        try await index.discardIncompleteGeneration(
            pair.candidate.identifier
        )
        await index.close()

        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(
                database,
                sql: """
                    UPDATE semantic_generations
                    SET source_allowlist_hash = ?
                    WHERE id = ?
                    """,
                textBinds: [
                    String(repeating: "0", count: 64),
                    pair.prior.identifier,
                ]
            )
        }
        XCTAssertThrowsError(
            try SemanticVaultIndex(url: url, now: fixedClock())
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .databaseCorrupt
            )
        }
    }

    func testNormalizationChunkingAndPreparedHashesReplayDeterministically() async throws {
        let raw = "  Café\u{202E}\n\tlaunch   review  "
        XCTAssertEqual(SemanticTextNormalizer.normalize(raw), "Café launch review")
        XCTAssertEqual(
            SemanticTextNormalizer.lexicalTokens(raw),
            ["cafe", "launch", "review"]
        )

        let longText = (0..<220).map { "token-\($0)" }.joined(separator: " ")
        let firstChunks = SemanticTextChunker.chunks(normalizedText: longText)
        let secondChunks = SemanticTextChunker.chunks(normalizedText: longText)
        XCTAssertEqual(firstChunks, secondChunks)
        XCTAssertEqual(firstChunks.count, 2)
        XCTAssertEqual(firstChunks[0].text.split(separator: " ").count, 160)
        XCTAssertTrue(firstChunks[1].text.hasPrefix("token-136 "))

        let clock: @Sendable () -> Date = { Date(timeIntervalSince1970: 1_800_000_000) }
        let lhs = try SemanticVaultIndex(inMemory: true, now: clock)
        let rhs = try SemanticVaultIndex(inMemory: true, now: clock)
        let spec = try generationSpec()
        let lhsGeneration = try await lhs.beginGeneration(spec: spec)
        let rhsGeneration = try await rhs.beginGeneration(spec: spec)
        let record = try sourceRecord(
            identifier: "brief-1",
            kind: .brief,
            text: longText
        )
        let request = try batchRequest(
            run: "run-1",
            stream: "briefs",
            final: true,
            records: [record]
        )
        let lhsPlan = try await lhs.prepareBatch(
            generationIdentifier: lhsGeneration.identifier,
            request: request
        )
        let rhsPlan = try await rhs.prepareBatch(
            generationIdentifier: rhsGeneration.identifier,
            request: request
        )
        XCTAssertEqual(lhsGeneration.identifier, rhsGeneration.identifier)
        XCTAssertEqual(lhsPlan.planDigest, rhsPlan.planDigest)
        XCTAssertEqual(
            lhsPlan.chunksRequiringEmbeddings.map(\.chunkIdentifier),
            rhsPlan.chunksRequiringEmbeddings.map(\.chunkIdentifier)
        )
        XCTAssertTrue(lhsPlan.resourceForecast.isAdvisory)
    }

    func testEmbeddingWorkBatchesPreserveOrderAndValidateDoubleConversion() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let longText = (0..<220).map { "token-\($0)" }.joined(separator: " ")
        let request = try batchRequest(
            run: "embedding-work-run",
            stream: "briefs",
            final: true,
            records: [
                try sourceRecord(
                    identifier: "embedding-work-brief",
                    kind: .brief,
                    text: longText
                ),
            ]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )

        let workBatches = try plan.embeddingWorkBatches(maximumBatchSize: 1)
        XCTAssertEqual(workBatches.count, 2)
        XCTAssertEqual(workBatches.map(\.ordinal), [0, 1])
        XCTAssertEqual(
            workBatches.flatMap(\.items).map(\.chunkIdentifier),
            plan.chunksRequiringEmbeddings.map(\.chunkIdentifier)
        )
        XCTAssertEqual(workBatches[0].inputs, workBatches[0].items.map(\.normalizedText))

        let mapped = try workBatches[0].keyedFloatVectors(
            from: [[1.0, 0.25, -0.5]]
        )
        XCTAssertEqual(
            mapped[workBatches[0].items[0].chunkIdentifier],
            [Float(1.0), Float(0.25), Float(-0.5)]
        )

        XCTAssertThrowsError(
            try workBatches[0].keyedFloatVectors(from: [[1.0, 0.0]])
        ) {
            XCTAssertEqual(
                $0 as? SemanticIndexFailureCode,
                .vectorDimensionMismatch
            )
        }
        XCTAssertThrowsError(
            try workBatches[0].keyedFloatVectors(
                from: [[Double.greatestFiniteMagnitude, 0.0, 0.0]]
            )
        ) {
            XCTAssertEqual($0 as? SemanticIndexFailureCode, .invalidEmbedding)
        }
        XCTAssertThrowsError(try plan.embeddingWorkBatches(maximumBatchSize: 17)) {
            XCTAssertEqual($0 as? SemanticIndexFailureCode, .invalidBatch)
        }
    }

    func testDynamicDimensionAndMixedGenerationVectorsAreRejected() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let firstSpec = try generationSpec(dimension: 3)
        let firstGeneration = try await index.beginGeneration(spec: firstSpec)
        let record = try sourceRecord(
            identifier: "chat-1",
            kind: .chatMessage,
            text: "A final assistant response"
        )
        let request = try batchRequest(
            run: "dimension-run",
            stream: "chat",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: firstGeneration.identifier,
            request: request
        )

        do {
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: embeddings(for: plan, vector: [1, 0])
            )
            XCTFail("A two-dimensional vector must not enter a three-dimensional generation.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .vectorDimensionMismatch)
        }

        let secondSpec = try generationSpec(
            digestSeed: "different-model-digest",
            dimension: 4
        )
        let secondGeneration = try await index.beginGeneration(
            spec: secondSpec,
            rebuilding: true
        )
        XCTAssertEqual(secondGeneration.spec.vectorDimension, 4)
        do {
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: embeddings(for: plan, vector: [1, 0, 0])
            )
            XCTFail("A prepared batch cannot cross generation boundaries.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .noActiveGeneration
            )
        }
    }

    func testIncrementalResumeDedupUpdateAndTombstonePropagation() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let first = try sourceRecord(
            identifier: "vault-record-1",
            kind: .vaultRecord,
            text: "Original launch checklist"
        )
        let duplicateOlder = try sourceRecord(
            identifier: "vault-record-1",
            kind: .vaultRecord,
            text: "Older duplicate",
            timestamp: anchor.addingTimeInterval(-100)
        )
        let pageOne = try batchRequest(
            run: "resume-run",
            stream: "vault",
            currentCursor: nil,
            nextCursor: "cursor-1",
            highWatermark: "watermark-1",
            final: false,
            records: [duplicateOlder, first]
        )
        let firstPlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: pageOne
        )
        XCTAssertEqual(firstPlan.sources.count, 1)
        let firstCommit = try await index.commit(
            firstPlan,
            embeddingsByChunkIdentifier: embeddings(for: firstPlan, vector: [1, 0, 0])
        )
        XCTAssertEqual(firstCommit.progress.state, .running)
        XCTAssertEqual(firstCommit.progress.nextCursor, "cursor-1")

        let second = try sourceRecord(
            identifier: "vault-record-2",
            kind: .vaultRecord,
            text: "Budget review notes"
        )
        let pageTwo = try batchRequest(
            run: "resume-run",
            stream: "vault",
            currentCursor: "cursor-1",
            nextCursor: nil,
            highWatermark: "watermark-2",
            final: true,
            records: [first, second]
        )
        let secondPlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: pageTwo
        )
        XCTAssertEqual(
            secondPlan.sources.first(where: {
                $0.record.stableSourceIdentifier == first.stableSourceIdentifier
            })?.action,
            .unchanged
        )
        let secondCommit = try await index.commit(
            secondPlan,
            embeddingsByChunkIdentifier: embeddingsByText(
                for: secondPlan,
                mapping: [
                    "launch": [1, 0, 0],
                    "budget": [0, 1, 0],
                ]
            )
        )
        XCTAssertEqual(secondCommit.progress.state, .complete)
        XCTAssertEqual(secondCommit.recordsUnchanged, 1)
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )
        let initialMetadata = try await index.activeGeneration()
        var metadata = try XCTUnwrap(initialMetadata)
        XCTAssertEqual(metadata.sourceHighWatermarks["vault"], "watermark-2")
        XCTAssertEqual(metadata.sourceCount, 2)

        let updated = try sourceRecord(
            identifier: "vault-record-1",
            kind: .vaultRecord,
            text: "Revised shipping checklist",
            timestamp: anchor.addingTimeInterval(10)
        )
        let updateRequest = try batchRequest(
            run: "update-run",
            stream: "vault-updates",
            final: true,
            records: [updated]
        )
        let updatePlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: updateRequest
        )
        _ = try await index.commit(
            updatePlan,
            embeddingsByChunkIdentifier: embeddings(for: updatePlan, vector: [0, 0, 1])
        )
        let oldResults = try await index.search(
            query: "launch",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertFalse(
            oldResults.contains {
                $0.provenance.stableSourceIdentifier == "vault-record-1"
            }
        )
        let newResults = try await index.search(
            query: "shipping",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertEqual(newResults.first?.provenance.stableSourceIdentifier, "vault-record-1")

        let tombstone = try sourceRecord(
            identifier: "vault-record-1",
            kind: .vaultRecord,
            text: "",
            timestamp: anchor.addingTimeInterval(20),
            tombstone: true
        )
        let tombstoneRequest = try batchRequest(
            run: "tombstone-run",
            stream: "vault-deletions",
            final: true,
            records: [tombstone]
        )
        let tombstonePlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: tombstoneRequest
        )
        let tombstoneCommit = try await index.commit(
            tombstonePlan,
            embeddingsByChunkIdentifier: [:]
        )
        XCTAssertEqual(tombstoneCommit.tombstonesApplied, 1)
        let tombstonedMetadata = try await index.activeGeneration()
        metadata = try XCTUnwrap(tombstonedMetadata)
        XCTAssertEqual(metadata.tombstoneCount, 1)
        XCTAssertEqual(metadata.sourceRecordHashes["vault-record-1"], tombstone.sourceHash)
        let deletedResults = try await index.search(
            query: "shipping",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertTrue(deletedResults.isEmpty)
    }

    func testLexicalSemanticHybridAndDeterministicFallbackSearch() async throws {
        for forceFallback in [false, true] {
            let index = try SemanticVaultIndex(
                inMemory: true,
                now: fixedClock(),
                forceLexicalFallback: forceFallback
            )
            let generation = try await index.beginGeneration(spec: generationSpec())
            let launch = try sourceRecord(
                identifier: "brief-launch",
                kind: .brief,
                text: "Launch readiness checklist",
                provider: "briefs"
            )
            let budget = try sourceRecord(
                identifier: "schedule-budget",
                kind: .schedule,
                text: "Quarterly budget review",
                provider: "schedules"
            )
            let briefRequest = try batchRequest(
                run: "search-brief-run",
                stream: "briefs",
                final: true,
                records: [launch]
            )
            let briefPlan = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: briefRequest
            )
            _ = try await index.commit(
                briefPlan,
                embeddingsByChunkIdentifier: embeddings(
                    for: briefPlan,
                    vector: [1, 0, 0]
                )
            )
            let scheduleRequest = try batchRequest(
                run: "search-schedule-run",
                stream: "schedules",
                final: true,
                records: [budget]
            )
            let schedulePlan = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: scheduleRequest
            )
            _ = try await index.commit(
                schedulePlan,
                embeddingsByChunkIdentifier: embeddings(
                    for: schedulePlan,
                    vector: [0, 1, 0]
                )
            )
            _ = try await publishGenerationForTests(
                generation,
                in: index
            )

            let lexical = try await index.search(
                query: "launch",
                queryVector: nil,
                mode: .lexical
            )
            XCTAssertEqual(lexical.first?.provenance.stableSourceIdentifier, "brief-launch")
            XCTAssertEqual(lexical.first?.similarityClassification, .lexicalOnly)

            let semantic = try await index.search(
                query: "financial planning",
                queryVector: [0, 1, 0],
                mode: .semantic
            )
            XCTAssertEqual(
                semantic.first?.provenance.stableSourceIdentifier,
                "schedule-budget"
            )
            XCTAssertEqual(semantic.first?.similarityClassification, .strong)

            let hybrid = try await index.search(
                query: "launch",
                queryVector: [1, 0, 0],
                mode: .hybrid,
                filters: .init(sourceKinds: [.brief])
            )
            XCTAssertEqual(hybrid.count, 1)
            XCTAssertEqual(hybrid[0].provenance.provider, "briefs")
            XCTAssertNil(hybrid[0].provenance.pseudonymousAccountIdentifier)
            XCTAssertTrue(hybrid[0].score > 0)

            let health = try await index.health()
            XCTAssertEqual(health.state, forceFallback ? .degraded : .ready)
        }
    }

    func testCosineRerankingIsBoundedToTheHardCandidateLimit()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let recordCount = SemanticIndexLimits.maximumCandidateCount + 1
        let records = try (0..<recordCount).map { index in
            try sourceRecord(
                identifier: String(format: "candidate-%03d", index),
                kind: .brief,
                text: index == 0
                    ? "bounded perfect candidate"
                    : "bounded ordinary candidate \(index)",
                timestamp: anchor.addingTimeInterval(TimeInterval(index))
            )
        }
        let batchSize = SemanticIndexLimits.maximumRecordsPerBatch
        var cursor: String?
        for offset in stride(from: 0, to: records.count, by: batchSize) {
            let end = min(offset + batchSize, records.count)
            let nextCursor = end < records.count ? String(end) : nil
            let request = try batchRequest(
                run: "candidate-cap-run",
                stream: "candidate-cap-stream",
                currentCursor: cursor,
                nextCursor: nextCursor,
                final: nextCursor == nil,
                records: Array(records[offset..<end])
            )
            let plan = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: request
            )
            let vectors = Dictionary(
                uniqueKeysWithValues: plan.chunksRequiringEmbeddings.map {
                    (
                        $0.chunkIdentifier,
                        $0.normalizedText.contains("perfect")
                            ? [Float(1), 0, 0]
                            : [Float(0), 1, 0]
                    )
                }
            )
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: vectors
            )
            cursor = nextCursor
        }
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )

        let searchResults = try await index.search(
            query: "bounded candidate",
            queryVector: [1, 0, 0],
            mode: .semantic,
            limit: 1,
            candidateLimit: 10_000
        )
        let result = try XCTUnwrap(searchResults.first)
        XCTAssertEqual(
            SemanticIndexLimits.maximumCandidateCount,
            512
        )
        XCTAssertNotEqual(
            result.provenance.stableSourceIdentifier,
            "candidate-000",
            "The 513th deterministic candidate must not enter cosine reranking."
        )
        XCTAssertEqual(
            try XCTUnwrap(result.cosineSimilarity),
            0,
            accuracy: 0.000_001
        )
    }

    func testMissingEmbeddingModelKeepsTruthfulLexicalOnlyRetrievalWithoutPlaceholderVectors() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let spec = try SemanticIndexGenerationSpec.lexicalOnly(
            sourceSchemaVersion: "loki-source-v1",
            buildScope: defaultBuildScope()
        )
        let generation = try await index.beginGeneration(spec: spec)
        XCTAssertEqual(generation.spec.retrievalCapability, .lexicalOnly)
        XCTAssertNil(generation.spec.embeddingModelIdentifier)
        XCTAssertNil(generation.spec.embeddingModelDigest)
        XCTAssertNil(generation.spec.vectorDimension)

        let record = try sourceRecord(
            identifier: "brief-lexical-only",
            kind: .brief,
            text: "Embedding model absent but lexical search remains available"
        )
        let request = try batchRequest(
            run: "lexical-only-run",
            stream: "briefs",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        XCTAssertFalse(plan.sources.flatMap(\.chunks).isEmpty)
        XCTAssertTrue(plan.chunksRequiringEmbeddings.isEmpty)
        XCTAssertEqual(plan.resourceForecast.vectorCount, 0)
        XCTAssertEqual(plan.resourceForecast.estimatedVectorBytes, 0)
        let lexicalChunk = try XCTUnwrap(plan.sources.flatMap(\.chunks).first)
        do {
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: [
                    lexicalChunk.chunkIdentifier: [0, 0, 0],
                ]
            )
            XCTFail("Lexical-only generations must reject placeholder vectors.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .invalidEmbedding)
        }
        let commit = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: [:]
        )
        XCTAssertGreaterThan(commit.chunksStored, 0)
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )

        let health = try await index.health()
        XCTAssertEqual(health.state, .lexicalOnly)
        XCTAssertEqual(
            health.reasonCode,
            SemanticIndexFailureCode.embeddingModelRequired.rawValue
        )
        let lexical = try await index.search(
            query: "lexical search",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertEqual(
            lexical.first?.provenance.stableSourceIdentifier,
            "brief-lexical-only"
        )
        XCTAssertNil(lexical.first?.cosineSimilarity)

        for mode in [SemanticSearchMode.semantic, .hybrid] {
            do {
                _ = try await index.search(
                    query: "lexical search",
                    queryVector: [1, 0, 0],
                    mode: mode
                )
                XCTFail("Semantic retrieval must remain unavailable without real vectors.")
            } catch {
                XCTAssertEqual(
                    error as? SemanticIndexFailureCode,
                    .embeddingModelRequired
                )
            }
        }
    }

    func testGenerationIdentityPersistsRuntimeRequestProfileAndExplicitDimensions() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let spec = try generationSpec(
            runtimeVersion: "0.11.7",
            requestProfileVersion: "loki-embedding-request-v2",
            requestProfileSeed: "request-profile-v2",
            embeddingDimensions: 3,
            embeddingTruncate: true,
            embeddingNormalizationVersion:
                "agent-loki.embedding-input.nfc-lf.v2"
        )
        let generation = try await index.beginGeneration(spec: spec)

        XCTAssertEqual(generation.spec.ollamaRuntimeVersion, "0.11.7")
        XCTAssertEqual(
            generation.spec.embeddingRequestProfileVersion,
            "loki-embedding-request-v2"
        )
        XCTAssertEqual(
            generation.spec.embeddingRequestProfileHash,
            SemanticIndexDigest.sha256("request-profile-v2")
        )
        XCTAssertEqual(generation.spec.embeddingDimensions, 3)
        XCTAssertEqual(generation.spec.embeddingTruncate, true)
        XCTAssertEqual(
            generation.spec.embeddingNormalizationVersion,
            "agent-loki.embedding-input.nfc-lf.v2"
        )
        XCTAssertNil(generation.staleReason)

        let modelDefaultDimensions = try generationSpec(
            runtimeVersion: "0.11.7",
            requestProfileVersion: "loki-embedding-request-v2",
            requestProfileSeed: "request-profile-v2",
            embeddingDimensions: nil,
            embeddingTruncate: true
        )
        XCTAssertNotEqual(
            spec.configurationFingerprint,
            modelDefaultDimensions.configurationFingerprint,
            "An explicit dimensions request must not alias the model-default request."
        )
    }

    func testEmbeddingRuntimeProfileChangesPermitOnlyLexicalFallback() async throws {
        let base = try generationSpec()
        let changedSpecs: [(String, SemanticIndexGenerationSpec)] = [
            ("runtime", try generationSpec(runtimeVersion: "0.11.7")),
            ("digest", try generationSpec(digestSeed: "replacement-digest")),
            ("dimension", try generationSpec(dimension: 4)),
            (
                "profile-version",
                try generationSpec(requestProfileVersion: "loki-embedding-request-v2")
            ),
            (
                "profile-hash",
                try generationSpec(requestProfileSeed: "replacement-request-profile")
            ),
            ("request-dimensions", try generationSpec(embeddingDimensions: 3)),
            ("truncate", try generationSpec(embeddingTruncate: true)),
            (
                "embedding-normalization",
                try generationSpec(
                    embeddingNormalizationVersion:
                        "agent-loki.embedding-input.nfc-lf.v2"
                )
            ),
        ]

        for (label, expected) in changedSpecs {
            let (index, _) = try await readyHybridIndex(spec: base, suffix: label)
            let markedStale = try await index.markStaleIfNeeded(for: expected)
            XCTAssertTrue(
                markedStale,
                "Expected \(label) to invalidate the active generation."
            )
            let activeGeneration = try await index.activeGeneration()
            let active = try XCTUnwrap(activeGeneration)
            XCTAssertEqual(active.state, .stale, label)
            XCTAssertEqual(active.staleReason, .embeddingRuntimeProfile, label)
            let health = try await index.health(expectedSpec: expected)
            XCTAssertEqual(health.state, .stale, label)
            XCTAssertEqual(
                health.reasonCode,
                SemanticIndexStaleReason.embeddingRuntimeProfile.rawValue,
                label
            )

            let lexical = try await index.search(
                query: "stable lexical",
                queryVector: nil,
                mode: .lexical
            )
            XCTAssertEqual(
                lexical.first?.provenance.stableSourceIdentifier,
                "stale-source-\(label)",
                label
            )
            for mode in [SemanticSearchMode.semantic, .hybrid] {
                do {
                    _ = try await index.search(
                        query: "stable lexical",
                        queryVector: [1, 0, 0],
                        mode: mode
                    )
                    XCTFail("\(label) must block \(mode.rawValue) retrieval.")
                } catch {
                    XCTAssertEqual(
                        error as? SemanticIndexFailureCode,
                        .generationStale,
                        label
                    )
                }
            }
        }
    }

    func testEmbeddingRuntimeProfileStalenessBlocksEveryIncrementalWritePath() async throws {
        let spec = try generationSpec()
        let (index, generation) = try await readyHybridIndex(
            spec: spec,
            suffix: "write-block"
        )
        let update = try sourceRecord(
            identifier: "stale-source-write-block",
            kind: .brief,
            text: "Stable lexical content with a changed source revision",
            timestamp: anchor.addingTimeInterval(60)
        )
        let request = try batchRequest(
            run: "stale-write-run",
            stream: "briefs",
            final: true,
            records: [update]
        )
        let prepared = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        let markedStale = try await index.markActiveGenerationStale(
            reason: .embeddingRuntimeProfile
        )
        XCTAssertTrue(markedStale)

        do {
            _ = try await index.commit(
                prepared,
                embeddingsByChunkIdentifier: embeddings(
                    for: prepared,
                    vector: [1, 0, 0]
                )
            )
            XCTFail("A prepared batch must not commit after profile staleness.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }
        do {
            _ = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: request
            )
            XCTFail("Profile-stale generations must reject new incremental work.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }
        do {
            try await index.cancel(runIdentifier: request.runIdentifier)
            XCTFail("A stale generation must not mutate checkpoint state.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }
        do {
            _ = try await index.completeGeneration(generation.identifier)
            XCTFail("Completion must not revive a stale generation.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }
    }

    func testStaleGenerationRequiresExplicitAtomicRebuild() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let firstSpec = try generationSpec()
        let first = try await index.beginGeneration(spec: firstSpec)
        let record = try sourceRecord(
            identifier: "brief-1",
            kind: .brief,
            text: "Semantic source"
        )
        let request = try batchRequest(
            run: "stale-run",
            stream: "briefs",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: first.identifier,
            request: request
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: embeddings(for: plan, vector: [1, 0, 0])
        )
        _ = try await publishGenerationForTests(first, in: index)

        let changed = try generationSpec(digestSeed: "changed-digest")
        let markedStale = try await index.markStaleIfNeeded(for: changed)
        XCTAssertTrue(markedStale)
        let staleHealth = try await index.health(expectedSpec: changed)
        XCTAssertEqual(staleHealth.state, .stale)
        XCTAssertEqual(
            staleHealth.activeGeneration?.staleReason,
            .embeddingRuntimeProfile
        )
        XCTAssertEqual(
            staleHealth.reasonCode,
            SemanticIndexStaleReason.embeddingRuntimeProfile.rawValue
        )
        do {
            _ = try await index.beginGeneration(spec: changed)
            XCTFail("A stale generation requires an explicit rebuild.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }

        let rebuilt = try await index.beginGeneration(spec: changed, rebuilding: true)
        XCTAssertNotEqual(rebuilt.identifier, first.identifier)
        XCTAssertEqual(rebuilt.sourceCount, 0)
        XCTAssertEqual(rebuilt.chunkCount, 0)
        XCTAssertEqual(rebuilt.state, .building)
        let rebuildingHealth = try await index.health()
        XCTAssertEqual(rebuildingHealth.state, .stale)
        XCTAssertEqual(
            rebuildingHealth.activeGeneration?.identifier,
            first.identifier
        )
    }

    func testCanonicalSourceInvalidationMarksActiveGenerationStaleBeforeRetrieval() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let record = try sourceRecord(
            identifier: "revoked-source",
            kind: .vaultRecord,
            text: "Permission-scoped source content"
        )
        let request = try batchRequest(
            run: "revocation-run",
            stream: "vault",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: embeddings(
                for: plan,
                vector: [1, 0, 0]
            )
        )
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )

        let firstInvalidation = try await index.markActiveGenerationStale()
        let secondInvalidation = try await index.markActiveGenerationStale()
        let invalidatedHealth = try await index.health()
        XCTAssertTrue(firstInvalidation)
        XCTAssertFalse(secondInvalidation)
        XCTAssertEqual(invalidatedHealth.state, .stale)
        XCTAssertEqual(
            invalidatedHealth.activeGeneration?.staleReason,
            .canonicalSourcePolicy
        )
        XCTAssertEqual(
            invalidatedHealth.reasonCode,
            SemanticIndexStaleReason.canonicalSourcePolicy.rawValue
        )
        for mode in SemanticSearchMode.allCases {
            do {
                _ = try await index.search(
                    query: "permission",
                    queryVector: mode == .lexical ? nil : [1, 0, 0],
                    mode: mode
                )
                XCTFail("Canonical-source staleness must block \(mode.rawValue).")
            } catch {
                XCTAssertEqual(
                    error as? SemanticIndexFailureCode,
                    .generationStale
                )
            }
        }
    }

    func testCanonicalSourceIdentityChangeIsClassifiedFailClosed() async throws {
        let base = try generationSpec()
        let (index, _) = try await readyHybridIndex(
            spec: base,
            suffix: "source-schema"
        )
        let changed = try generationSpec(sourceSchemaVersion: "loki-source-v2")

        let markedStale = try await index.markStaleIfNeeded(for: changed)
        XCTAssertTrue(markedStale)
        let health = try await index.health(expectedSpec: changed)
        XCTAssertEqual(health.state, .stale)
        XCTAssertEqual(
            health.activeGeneration?.staleReason,
            .canonicalSourcePolicy
        )
        XCTAssertEqual(
            health.reasonCode,
            SemanticIndexStaleReason.canonicalSourcePolicy.rawValue
        )
        do {
            _ = try await index.search(
                query: "stable lexical",
                queryVector: nil,
                mode: .lexical
            )
            XCTFail("A source-schema change must block lexical retrieval too.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .generationStale)
        }
    }

    func testPrivacyExclusionPurgesPreviouslyIndexedContentWithoutRetainingText() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let ordinary = try sourceRecord(
            identifier: "chat-sensitive-transition",
            kind: .chatMessage,
            text: "Final response later classified private"
        )
        let firstRequest = try batchRequest(
            run: "privacy-first",
            stream: "chat",
            final: true,
            records: [ordinary]
        )
        let firstPlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: firstRequest
        )
        _ = try await index.commit(
            firstPlan,
            embeddingsByChunkIdentifier: embeddings(for: firstPlan, vector: [1, 0, 0])
        )
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )

        let reasoning = try sourceRecord(
            identifier: ordinary.stableSourceIdentifier,
            kind: .chatMessage,
            text: "RAW_REASONING_SENTINEL_MUST_NOT_BE_STORED",
            timestamp: anchor.addingTimeInterval(5),
            privacy: .hiddenReasoning
        )
        let exclusionRequest = try batchRequest(
            run: "privacy-exclude",
            stream: "chat-privacy",
            final: true,
            records: [reasoning]
        )
        let exclusionPlan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: exclusionRequest
        )
        XCTAssertEqual(exclusionPlan.sources.first?.action, .exclude)
        XCTAssertEqual(exclusionPlan.sources.first?.record.text, "")
        XCTAssertEqual(exclusionPlan.request.records.first?.text, "")
        XCTAssertTrue(exclusionPlan.chunksRequiringEmbeddings.isEmpty)
        let encodedPlan = try JSONEncoder().encode(exclusionPlan)
        XCTAssertFalse(
            String(decoding: encodedPlan, as: UTF8.self)
                .contains("RAW_REASONING_SENTINEL_MUST_NOT_BE_STORED")
        )
        let exclusionCommit = try await index.commit(
            exclusionPlan,
            embeddingsByChunkIdentifier: [:]
        )
        XCTAssertEqual(exclusionCommit.recordsExcluded, 1)
        let active = try await index.activeGeneration()
        XCTAssertEqual(active?.sourceCount, 0)
        let results = try await index.search(
            query: "classified",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertTrue(results.isEmpty)
    }

    func testEverySecretAndCredentialClassificationIsExcludedWithoutRetainingSentinels()
        async throws
    {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let prohibited = SemanticIndexPrivacyClassification.allCases.filter {
            !$0.mayEnterIndex
        }
        let sentinels = prohibited.map {
            "PRIVATE_\($0.rawValue.uppercased())_SENTINEL"
        }
        let records = try zip(prohibited, sentinels).enumerated().map {
            index, pair in
            try sourceRecord(
                identifier: "excluded-\(index)",
                kind: .connectorRecord,
                text: pair.1,
                timestamp: anchor.addingTimeInterval(TimeInterval(index)),
                privacy: pair.0
            )
        }
        let request = try batchRequest(
            run: "all-privacy-exclusions",
            stream: "prohibited-derived-inputs",
            final: true,
            records: records
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )

        XCTAssertEqual(plan.sources.count, prohibited.count)
        XCTAssertTrue(plan.sources.allSatisfy { $0.action == .exclude })
        XCTAssertTrue(plan.sources.allSatisfy { $0.record.text.isEmpty })
        XCTAssertTrue(plan.request.records.allSatisfy { $0.text.isEmpty })
        XCTAssertTrue(plan.chunksRequiringEmbeddings.isEmpty)
        let encodedPlan = String(
            decoding: try JSONEncoder().encode(plan),
            as: UTF8.self
        )
        for sentinel in sentinels {
            XCTAssertFalse(encodedPlan.contains(sentinel))
        }

        let commit = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: [:]
        )
        XCTAssertEqual(commit.recordsExcluded, prohibited.count)
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )
        let activeGeneration = try await index.activeGeneration()
        XCTAssertEqual(activeGeneration?.sourceCount, 0)
        let results = try await index.search(
            query: "private sentinel",
            queryVector: nil,
            mode: .lexical
        )
        XCTAssertTrue(results.isEmpty)
        let encodedResults = String(
            decoding: try JSONEncoder().encode(results),
            as: UTF8.self
        )
        for sentinel in sentinels {
            XCTAssertFalse(encodedResults.contains(sentinel))
        }
    }

    func testCancellationProgressAndBatteryPolicyAreTruthfulAndResumable() async throws {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: generationSpec())
        let record = try sourceRecord(
            identifier: "schedule-1",
            kind: .schedule,
            text: "Schedule indexing"
        )
        let automatic = try batchRequest(
            run: "automatic-run",
            stream: "schedules",
            final: true,
            trigger: .automatic(isOnBattery: true),
            records: [record]
        )
        do {
            _ = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: automatic
            )
            XCTFail("Automatic indexing is disabled by default.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .indexingNotPermitted)
        }

        let manual = try batchRequest(
            run: "cancel-run",
            stream: "schedules",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: manual
        )
        let awaitingProgress = try await index.progress(runIdentifier: "cancel-run")
        var progress = try XCTUnwrap(awaitingProgress)
        XCTAssertEqual(progress.state, .awaitingEmbeddings)
        XCTAssertEqual(progress.pendingChunkCount, plan.chunksRequiringEmbeddings.count)

        try await index.cancel(runIdentifier: "cancel-run")
        let cancelledProgress = try await index.progress(runIdentifier: "cancel-run")
        progress = try XCTUnwrap(cancelledProgress)
        XCTAssertEqual(progress.state, .cancelled)
        do {
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: embeddings(for: plan, vector: [1, 0, 0])
            )
            XCTFail("A cancelled prepared batch must not commit.")
        } catch {
            XCTAssertEqual(error as? SemanticIndexFailureCode, .cancelled)
        }

        let resumed = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: manual
        )
        let result = try await index.commit(
            resumed,
            embeddingsByChunkIdentifier: embeddings(for: resumed, vector: [1, 0, 0])
        )
        XCTAssertEqual(result.progress.state, .complete)
        let ready = try await publishGenerationForTests(
            generation,
            in: index
        )
        let incomplete = try await index.beginGeneration(
            spec: generationSpec(
                digestSeed: "delete-all-incomplete"
            ),
            rebuilding: true
        )
        let incompleteRequest = try batchRequest(
            run: "delete-all-incomplete-run",
            stream: "schedules",
            final: true,
            records: [record]
        )
        _ = try await index.prepareBatch(
            generationIdentifier: incomplete.identifier,
            request: incompleteRequest
        )
        let storedReady = try await index.generation(
            identifier: ready.identifier
        )
        let storedIncomplete = try await index.generation(
            identifier: incomplete.identifier
        )
        XCTAssertNotNil(storedReady)
        XCTAssertNotNil(storedIncomplete)
        let pendingProgress = try await index.progress(
            runIdentifier: "delete-all-incomplete-run"
        )
        XCTAssertNotNil(pendingProgress)

        try await index.deleteAllDerivedData()
        let emptyHealth = try await index.health()
        XCTAssertEqual(emptyHealth.state, .empty)
        XCTAssertNil(emptyHealth.activeGeneration)
        let deletedReady = try await index.generation(
            identifier: ready.identifier
        )
        let deletedIncomplete = try await index.generation(
            identifier: incomplete.identifier
        )
        XCTAssertNil(deletedReady)
        XCTAssertNil(deletedIncomplete)
        let deletedProgress = try await index.progress(
            runIdentifier: "delete-all-incomplete-run"
        )
        XCTAssertNil(deletedProgress)
    }

    func testFileBackedCorruptionFailsClosedUsingOnlyTemporaryData() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SemanticVaultIndexTests-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("derived-semantic.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = try SemanticVaultIndex(url: url, now: fixedClock())
        _ = try await index.beginGeneration(spec: generationSpec())
        await index.close()
        try Data("not-a-sqlite-database".utf8).write(to: url, options: .atomic)

        XCTAssertThrowsError(try SemanticVaultIndex(url: url, now: fixedClock())) { error in
            XCTAssertEqual(error as? SemanticIndexFailureCode, .databaseCorrupt)
        }
    }

    func testReadyHybridSchemaV1MigratesUnknownAndBlocksEverySearchMode() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SemanticVaultIndexLegacyHybrid-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = directory.appendingPathComponent("derived-semantic.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeLegacySchemaV1Fixture(
            url: url,
            retrievalCapability: .hybrid
        )
        let before = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(before.userVersion, 1)
        XCTAssertEqual(before.generationIdentifier, fixture.generationIdentifier)
        XCTAssertEqual(before.sourceCount, 1)
        XCTAssertEqual(before.chunkCount, 1)
        XCTAssertEqual(before.ftsCount, 1)
        XCTAssertEqual(before.vectorBlobs.count, 1)
        XCTAssertFalse(before.vectorBlobs[0].isEmpty)

        let index = try SemanticVaultIndex(url: url, now: fixedClock())
        let activeValue = try await index.activeGeneration()
        let active = try XCTUnwrap(activeValue)
        XCTAssertEqual(active.identifier, fixture.generationIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(active.staleReason, .sourceScopeUnknown)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeUnknown
        )
        XCTAssertNil(active.spec.buildScope)
        XCTAssertEqual(active.spec.retrievalCapability, .hybrid)
        XCTAssertEqual(
            active.spec.embeddingModelIdentifier,
            fixture.currentSpec.embeddingModelIdentifier
        )
        XCTAssertEqual(
            active.spec.embeddingModelDigest,
            fixture.currentSpec.embeddingModelDigest
        )
        XCTAssertEqual(
            active.spec.vectorDimension,
            fixture.currentSpec.vectorDimension
        )
        XCTAssertEqual(active.spec.ollamaRuntimeVersion, "legacy-unbound")
        XCTAssertEqual(
            active.spec.embeddingRequestProfileVersion,
            "agent-loki.embedding-request-profile.legacy-unbound"
        )
        XCTAssertEqual(
            active.spec.embeddingRequestProfileHash,
            SemanticIndexDigest.sha256(
                "agent-loki.semantic-index.v1.unbound-request-profile"
            )
        )
        XCTAssertNil(active.spec.embeddingDimensions)
        XCTAssertEqual(active.spec.embeddingTruncate, false)
        XCTAssertEqual(
            active.spec.embeddingNormalizationVersion,
            "legacy-unbound"
        )
        XCTAssertNotEqual(
            active.spec.configurationFingerprint,
            fixture.currentSpec.configurationFingerprint,
            "An unbound legacy request profile must never match a current accepted binding."
        )

        let health = try await index.health(expectedSpec: fixture.currentSpec)
        XCTAssertEqual(health.state, .stale)
        XCTAssertEqual(
            health.reasonCode,
            SemanticIndexStaleReason.sourceScopeUnknown.rawValue
        )
        for mode in SemanticSearchMode.allCases {
            do {
                _ = try await index.search(
                    query: "preserved lexical migration",
                    queryVector: mode == .lexical
                        ? nil
                        : [1, 0, 0],
                    mode: mode
                )
                XCTFail(
                    "Unknown legacy source authority must block \(mode.rawValue)."
                )
            } catch {
                XCTAssertEqual(
                    error as? SemanticIndexFailureCode,
                    .sourceScopeUnknown
                )
            }
        }
        do {
            _ = try await index.prepareBatch(
                generationIdentifier: active.identifier,
                request: try batchRequest(
                    run: "legacy-migration-write",
                    stream: "briefs",
                    final: true,
                    records: [
                        try sourceRecord(
                            identifier: fixture.sourceIdentifier,
                            kind: .brief,
                            text: "A write that must remain blocked"
                        ),
                    ]
                )
            )
            XCTFail("A migrated unbound generation must reject incremental writes.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .sourceScopeUnknown
            )
        }
        do {
            _ = try await index.completeGeneration(active.identifier)
            XCTFail("A migrated unbound generation must not become ready without rebuild.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .sourceScopeUnknown
            )
        }
        await index.close()

        let after = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(after.userVersion, SemanticIndexLimits.schemaVersion)
        XCTAssertEqual(after.generationIdentifier, before.generationIdentifier)
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.chunkCount, before.chunkCount)
        XCTAssertEqual(after.ftsCount, before.ftsCount)
        XCTAssertEqual(after.vectorBlobs, before.vectorBlobs)
        XCTAssertTrue(after.generationColumns.contains("stale_reason"))
    }

    func testReadyLexicalSchemaV1MigratesUnknownAndNonqueryable() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SemanticVaultIndexLegacyLexical-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = directory.appendingPathComponent("derived-semantic.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        let fixture = try await makeLegacySchemaV1Fixture(
            url: url,
            retrievalCapability: .lexicalOnly
        )
        let before = try legacyStorageSnapshot(url: url)
        let index = try SemanticVaultIndex(url: url, now: fixedClock())
        let activeValue = try await index.activeGeneration()
        let active = try XCTUnwrap(activeValue)
        XCTAssertEqual(active.identifier, fixture.generationIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(active.staleReason, .sourceScopeUnknown)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeUnknown
        )
        XCTAssertNil(active.spec.buildScope)
        XCTAssertEqual(active.spec.retrievalCapability, .lexicalOnly)
        XCTAssertNil(active.spec.embeddingModelIdentifier)
        XCTAssertNil(active.spec.embeddingRequestProfileHash)

        let health = try await index.health()
        XCTAssertEqual(health.state, .stale)
        XCTAssertEqual(
            health.reasonCode,
            SemanticIndexStaleReason.sourceScopeUnknown.rawValue
        )
        do {
            _ = try await index.search(
                query: "preserved lexical migration",
                queryVector: nil,
                mode: .lexical
            )
            XCTFail("Legacy lexical data must not bypass unknown authority.")
        } catch {
            XCTAssertEqual(
                error as? SemanticIndexFailureCode,
                .sourceScopeUnknown
            )
        }
        await index.close()

        let after = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(after.userVersion, SemanticIndexLimits.schemaVersion)
        XCTAssertEqual(after.generationIdentifier, before.generationIdentifier)
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.chunkCount, before.chunkCount)
        XCTAssertEqual(after.ftsCount, before.ftsCount)
        XCTAssertEqual(after.vectorBlobs, before.vectorBlobs)
    }

    func testReadyHybridSchemaV2MigratesUnknownWithoutRowOrByteLoss()
        async throws
    {
        try await assertSchemaV2Migration(
            retrievalCapability: .hybrid
        )
    }

    func testReadyLexicalSchemaV2MigratesUnknownWithoutRowOrByteLoss()
        async throws
    {
        try await assertSchemaV2Migration(
            retrievalCapability: .lexicalOnly
        )
    }

    func testMalformedSchemaV2MetadataAndActiveReferenceRollBackAtomically()
        async throws
    {
        for mutation in ["fingerprint", "active-reference"] {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent(
                    "SemanticV2Rollback-\(mutation)-\(UUID().uuidString)",
                    isDirectory: true
                )
            let url = directory.appendingPathComponent(
                "derived-semantic.sqlite3"
            )
            defer { try? FileManager.default.removeItem(at: directory) }
            _ = try await makeLegacySchemaV2Fixture(
                url: url,
                retrievalCapability: .hybrid
            )
            try withSQLiteDatabase(url: url) { database in
                if mutation == "fingerprint" {
                    try executeSQLite(
                        database,
                        sql: """
                            UPDATE semantic_generations
                            SET configuration_fingerprint = ?
                            """,
                        textBinds: [
                            String(repeating: "0", count: 64),
                        ]
                    )
                } else {
                    try executeSQLite(
                        database,
                        sql: """
                            UPDATE semantic_metadata
                            SET value = 'missing-generation'
                            WHERE key = 'active_generation'
                            """
                    )
                }
            }
            let before = try legacyStorageSnapshot(url: url)
            XCTAssertThrowsError(
                try SemanticVaultIndex(url: url, now: fixedClock())
            ) {
                XCTAssertEqual(
                    $0 as? SemanticIndexFailureCode,
                    .databaseCorrupt,
                    mutation
                )
            }
            let after = try legacyStorageSnapshot(url: url)
            XCTAssertEqual(after, before, mutation)
            XCTAssertEqual(after.userVersion, 2, mutation)
            XCTAssertFalse(
                after.generationColumns.contains(
                    "source_authority_state"
                ),
                mutation
            )
        }
    }

    func testCorruptSchemaV1IdentityRollsBackMigrationAtomically() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SemanticVaultIndexLegacyCorrupt-\(UUID().uuidString)",
            isDirectory: true
        )
        let url = directory.appendingPathComponent("derived-semantic.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        _ = try await makeLegacySchemaV1Fixture(
            url: url,
            retrievalCapability: .hybrid
        )
        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(
                database,
                sql: """
                    UPDATE semantic_generations
                    SET configuration_fingerprint = ?
                    """,
                textBinds: [String(repeating: "0", count: 64)]
            )
        }
        let before = try legacyStorageSnapshot(url: url)
        XCTAssertThrowsError(
            try SemanticVaultIndex(url: url, now: fixedClock())
        ) {
            XCTAssertEqual($0 as? SemanticIndexFailureCode, .databaseCorrupt)
        }
        let after = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(after, before)
        XCTAssertEqual(after.userVersion, 1)
        XCTAssertFalse(after.generationColumns.contains("stale_reason"))
    }

    func testMalformedLegacyDerivedSchemaRemainsUnsupported() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SemanticVaultIndexLegacy-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        let url = directory.appendingPathComponent("derived-semantic.sqlite3")
        defer { try? FileManager.default.removeItem(at: directory) }

        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        guard let database else {
            XCTFail("The temporary SQLite fixture must open.")
            return
        }
        XCTAssertEqual(
            sqlite3_exec(database, "PRAGMA user_version = 1", nil, nil, nil),
            SQLITE_OK
        )
        XCTAssertEqual(sqlite3_close_v2(database), SQLITE_OK)

        XCTAssertThrowsError(try SemanticVaultIndex(url: url, now: fixedClock())) {
            XCTAssertEqual($0 as? SemanticIndexFailureCode, .unsupportedSchema)
        }
    }

    private func assertSchemaV2Migration(
        retrievalCapability: SemanticIndexRetrievalCapability
    ) async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "SemanticV2-\(retrievalCapability.rawValue)-\(UUID().uuidString)",
                isDirectory: true
            )
        let url = directory.appendingPathComponent(
            "derived-semantic.sqlite3"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try await makeLegacySchemaV2Fixture(
            url: url,
            retrievalCapability: retrievalCapability
        )
        let before = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(before.userVersion, 2)

        let index = try SemanticVaultIndex(
            url: url,
            now: fixedClock()
        )
        let activeValue = try await index.activeGeneration()
        let active = try XCTUnwrap(activeValue)
        XCTAssertEqual(active.identifier, fixture.generationIdentifier)
        XCTAssertEqual(active.state, .stale)
        XCTAssertEqual(active.staleReason, .sourceScopeUnknown)
        XCTAssertEqual(
            active.sourceAuthorityState,
            .sourceScopeUnknown
        )
        XCTAssertNil(active.spec.buildScope)
        XCTAssertEqual(
            active.spec.retrievalCapability,
            retrievalCapability
        )
        XCTAssertEqual(
            active.spec.embeddingModelDigest,
            fixture.currentSpec.embeddingModelDigest
        )
        XCTAssertEqual(
            active.spec.ollamaRuntimeVersion,
            fixture.currentSpec.ollamaRuntimeVersion
        )
        XCTAssertEqual(
            active.spec.embeddingRequestProfileHash,
            fixture.currentSpec.embeddingRequestProfileHash
        )
        for mode in SemanticSearchMode.allCases {
            do {
                _ = try await index.search(
                    query: "preserved v2 migration",
                    queryVector: mode == .lexical
                        ? nil
                        : [1, 0, 0],
                    mode: mode
                )
                XCTFail(
                    "Unknown v2 scope must block \(mode.rawValue)."
                )
            } catch {
                XCTAssertEqual(
                    error as? SemanticIndexFailureCode,
                    .sourceScopeUnknown
                )
            }
        }
        await index.close()

        let after = try legacyStorageSnapshot(url: url)
        XCTAssertEqual(
            after.userVersion,
            SemanticIndexLimits.schemaVersion
        )
        XCTAssertEqual(
            after.generationIdentifier,
            before.generationIdentifier
        )
        XCTAssertEqual(after.sourceCount, before.sourceCount)
        XCTAssertEqual(after.chunkCount, before.chunkCount)
        XCTAssertEqual(after.ftsCount, before.ftsCount)
        XCTAssertEqual(after.vectorBlobs, before.vectorBlobs)
        XCTAssertTrue(
            after.generationColumns.contains(
                "source_authority_state"
            )
        )
    }

    private func makeLegacySchemaV2Fixture(
        url: URL,
        retrievalCapability: SemanticIndexRetrievalCapability
    ) async throws -> (
        generationIdentifier: String,
        sourceIdentifier: String,
        currentSpec: SemanticIndexGenerationSpec
    ) {
        let spec: SemanticIndexGenerationSpec
        switch retrievalCapability {
        case .hybrid:
            spec = try generationSpec()
        case .lexicalOnly:
            spec = try .lexicalOnly(
                sourceSchemaVersion: "loki-source-v1",
                buildScope: defaultBuildScope()
            )
        }
        let index = try SemanticVaultIndex(
            url: url,
            now: fixedClock()
        )
        let generation = try await index.beginGeneration(spec: spec)
        let sourceIdentifier =
            "legacy-v2-\(retrievalCapability.rawValue)-source"
        let record = try sourceRecord(
            identifier: sourceIdentifier,
            kind: .brief,
            text: "Preserved v2 migration evidence"
        )
        let highWatermark = "legacy-v2-watermark"
        let request = try batchRequest(
            run: "legacy-v2-\(retrievalCapability.rawValue)-run",
            stream: "briefs",
            highWatermark: highWatermark,
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier:
                retrievalCapability == .hybrid
                    ? embeddings(
                        for: plan,
                        vector: [1, 0, 0]
                    )
                    : [:]
        )
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )
        await index.close()

        let legacyFingerprint = legacySchemaV2Fingerprint(spec)
        let legacyManifest = legacyBindingDigest(
            configurationFingerprint: legacyFingerprint,
            sourceBindings: [
                record.stableSourceIdentifier:
                    "\(record.sourceHash)|available",
            ],
            highWatermarks: ["briefs": highWatermark]
        )
        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(database, sql: "PRAGMA foreign_keys = OFF")
            try executeSQLite(database, sql: "BEGIN IMMEDIATE")
            do {
                try executeSQLite(
                    database,
                    sql: """
                        CREATE TABLE semantic_generations_v2(
                            id TEXT PRIMARY KEY,
                            index_schema_version INTEGER NOT NULL,
                            retrieval_capability TEXT NOT NULL
                                CHECK(retrieval_capability IN (
                                    'lexical_only','hybrid'
                                )),
                            embedding_model_identifier TEXT,
                            embedding_model_digest TEXT,
                            vector_dimension INTEGER,
                            ollama_runtime_version TEXT,
                            embedding_request_profile_version TEXT,
                            embedding_request_profile_hash TEXT,
                            embedding_dimensions INTEGER,
                            embedding_truncate INTEGER,
                            embedding_normalization_version TEXT,
                            chunker_version TEXT NOT NULL,
                            normalization_version TEXT NOT NULL,
                            source_schema_version TEXT NOT NULL,
                            configuration_fingerprint TEXT NOT NULL,
                            created_at INTEGER NOT NULL,
                            state TEXT NOT NULL,
                            stale_reason TEXT,
                            source_manifest_digest TEXT NOT NULL
                        ) STRICT
                        """
                )
                try executeSQLite(
                    database,
                    sql: """
                        INSERT INTO semantic_generations_v2(
                            id, index_schema_version,
                            retrieval_capability,
                            embedding_model_identifier,
                            embedding_model_digest, vector_dimension,
                            ollama_runtime_version,
                            embedding_request_profile_version,
                            embedding_request_profile_hash,
                            embedding_dimensions, embedding_truncate,
                            embedding_normalization_version,
                            chunker_version, normalization_version,
                            source_schema_version,
                            configuration_fingerprint, created_at,
                            state, stale_reason,
                            source_manifest_digest
                        )
                        SELECT id, 2, retrieval_capability,
                               embedding_model_identifier,
                               embedding_model_digest, vector_dimension,
                               ollama_runtime_version,
                               embedding_request_profile_version,
                               embedding_request_profile_hash,
                               embedding_dimensions, embedding_truncate,
                               embedding_normalization_version,
                               chunker_version, normalization_version,
                               source_schema_version, ?, created_at,
                               state, stale_reason, ?
                        FROM semantic_generations
                        """,
                    textBinds: [
                        legacyFingerprint,
                        legacyManifest,
                    ]
                )
                try createLegacyCheckpointTable(
                    database,
                    name: "semantic_checkpoints_v2",
                    generationTable: "semantic_generations"
                )
                try copyLegacyCheckpointRows(
                    database,
                    destination: "semantic_checkpoints_v2"
                )
                try executeSQLite(
                    database,
                    sql: "DROP TABLE semantic_checkpoints"
                )
                try executeSQLite(
                    database,
                    sql: "DROP TABLE semantic_generations"
                )
                try executeSQLite(
                    database,
                    sql: """
                        ALTER TABLE semantic_generations_v2
                        RENAME TO semantic_generations
                        """
                )
                try executeSQLite(
                    database,
                    sql: """
                        ALTER TABLE semantic_checkpoints_v2
                        RENAME TO semantic_checkpoints
                        """
                )
                try executeSQLite(
                    database,
                    sql: "PRAGMA user_version = 2"
                )
                try executeSQLite(database, sql: "COMMIT")
            } catch {
                try? executeSQLite(database, sql: "ROLLBACK")
                throw error
            }
            try executeSQLite(database, sql: "PRAGMA foreign_keys = ON")
        }
        return (
            generation.identifier,
            sourceIdentifier,
            spec
        )
    }

    private func makeLegacySchemaV1Fixture(
        url: URL,
        retrievalCapability: SemanticIndexRetrievalCapability
    ) async throws -> (
        generationIdentifier: String,
        sourceIdentifier: String,
        currentSpec: SemanticIndexGenerationSpec
    ) {
        let spec: SemanticIndexGenerationSpec
        switch retrievalCapability {
        case .hybrid:
            spec = try generationSpec()
        case .lexicalOnly:
            spec = try .lexicalOnly(
                sourceSchemaVersion: "loki-source-v1",
                buildScope: defaultBuildScope()
            )
        }
        let index = try SemanticVaultIndex(url: url, now: fixedClock())
        let generation = try await index.beginGeneration(spec: spec)
        let sourceIdentifier = "legacy-\(retrievalCapability.rawValue)-source"
        let record = try sourceRecord(
            identifier: sourceIdentifier,
            kind: .brief,
            text: "Preserved lexical migration evidence"
        )
        let highWatermark = "legacy-watermark-1"
        let request = try batchRequest(
            run: "legacy-\(retrievalCapability.rawValue)-run",
            stream: "briefs",
            highWatermark: highWatermark,
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        let vectors: [String: [Float]]
        switch retrievalCapability {
        case .hybrid:
            vectors = embeddings(for: plan, vector: [1, 0, 0])
        case .lexicalOnly:
            vectors = [:]
        }
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: vectors
        )
        _ = try await publishGenerationForTests(
            generation,
            in: index
        )
        await index.close()

        let legacyFingerprint = legacySchemaV1Fingerprint(spec)
        let legacyManifest = legacyBindingDigest(
            configurationFingerprint: legacyFingerprint,
            sourceBindings: [
                record.stableSourceIdentifier:
                    "\(record.sourceHash)|available",
            ],
            highWatermarks: ["briefs": highWatermark]
        )
        try withSQLiteDatabase(url: url) { database in
            try executeSQLite(database, sql: "PRAGMA foreign_keys = OFF")
            try executeSQLite(database, sql: "BEGIN IMMEDIATE")
            do {
                try executeSQLite(
                    database,
                    sql: """
                        CREATE TABLE semantic_generations_v1(
                            id TEXT PRIMARY KEY,
                            index_schema_version INTEGER NOT NULL,
                            retrieval_capability TEXT NOT NULL
                                CHECK(retrieval_capability IN ('lexical_only','hybrid')),
                            embedding_model_identifier TEXT,
                            embedding_model_digest TEXT,
                            vector_dimension INTEGER CHECK(
                                vector_dimension IS NULL OR vector_dimension > 0
                            ),
                            chunker_version TEXT NOT NULL,
                            normalization_version TEXT NOT NULL,
                            source_schema_version TEXT NOT NULL,
                            configuration_fingerprint TEXT NOT NULL,
                            created_at INTEGER NOT NULL,
                            state TEXT NOT NULL CHECK(
                                state IN ('building','ready','stale','paused','corrupt')
                            ),
                            source_manifest_digest TEXT NOT NULL,
                            CHECK(
                                (
                                    retrieval_capability = 'lexical_only'
                                    AND embedding_model_identifier IS NULL
                                    AND embedding_model_digest IS NULL
                                    AND vector_dimension IS NULL
                                )
                                OR
                                (
                                    retrieval_capability = 'hybrid'
                                    AND embedding_model_identifier IS NOT NULL
                                    AND embedding_model_digest IS NOT NULL
                                    AND vector_dimension IS NOT NULL
                                )
                            )
                        ) STRICT
                        """
                )
                try executeSQLite(
                    database,
                    sql: """
                        INSERT INTO semantic_generations_v1(
                            id, index_schema_version, retrieval_capability,
                            embedding_model_identifier, embedding_model_digest,
                            vector_dimension, chunker_version,
                            normalization_version, source_schema_version,
                            configuration_fingerprint, created_at, state,
                            source_manifest_digest
                        )
                        SELECT id, 1, retrieval_capability,
                               embedding_model_identifier,
                               embedding_model_digest, vector_dimension,
                               chunker_version, normalization_version,
                               source_schema_version, ?, created_at, state, ?
                        FROM semantic_generations
                    """,
                    textBinds: [legacyFingerprint, legacyManifest]
                )
                try executeSQLite(
                    database,
                    sql: """
                        CREATE TABLE semantic_checkpoints_v1(
                            run_id TEXT PRIMARY KEY,
                            generation_id TEXT NOT NULL
                                REFERENCES semantic_generations(id)
                                ON DELETE CASCADE,
                            stream_id TEXT NOT NULL,
                            state TEXT NOT NULL CHECK(state IN (
                                'preparing','awaiting_embeddings','running',
                                'paused','cancelled','complete'
                            )),
                            current_cursor TEXT,
                            next_cursor TEXT,
                            source_high_watermark TEXT,
                            batches_committed INTEGER NOT NULL
                                CHECK(batches_committed >= 0),
                            records_seen INTEGER NOT NULL
                                CHECK(records_seen >= 0),
                            records_committed INTEGER NOT NULL
                                CHECK(records_committed >= 0),
                            records_unchanged INTEGER NOT NULL
                                CHECK(records_unchanged >= 0),
                            records_excluded INTEGER NOT NULL
                                CHECK(records_excluded >= 0),
                            tombstones_committed INTEGER NOT NULL
                                CHECK(tombstones_committed >= 0),
                            chunks_committed INTEGER NOT NULL
                                CHECK(chunks_committed >= 0),
                            pending_chunk_count INTEGER NOT NULL
                                CHECK(pending_chunk_count >= 0),
                            updated_at INTEGER NOT NULL
                        ) STRICT
                        """
                )
                try executeSQLite(
                    database,
                    sql: """
                        INSERT INTO semantic_checkpoints_v1(
                            run_id, generation_id, stream_id, state,
                            current_cursor, next_cursor,
                            source_high_watermark, batches_committed,
                            records_seen, records_committed,
                            records_unchanged, records_excluded,
                            tombstones_committed, chunks_committed,
                            pending_chunk_count, updated_at
                        )
                        SELECT run_id, generation_id, stream_id, state,
                               current_cursor, next_cursor,
                               source_high_watermark, batches_committed,
                               records_seen, records_committed,
                               records_unchanged, records_excluded,
                               tombstones_committed, chunks_committed,
                               pending_chunk_count, updated_at
                        FROM semantic_checkpoints
                        """
                )
                try executeSQLite(
                    database,
                    sql: "DROP TABLE semantic_checkpoints"
                )
                try executeSQLite(
                    database,
                    sql: "DROP TABLE semantic_generations"
                )
                try executeSQLite(
                    database,
                    sql: """
                        ALTER TABLE semantic_generations_v1
                        RENAME TO semantic_generations
                        """
                )
                try executeSQLite(
                    database,
                    sql: """
                        ALTER TABLE semantic_checkpoints_v1
                        RENAME TO semantic_checkpoints
                        """
                )
                try executeSQLite(database, sql: "PRAGMA user_version = 1")
                try executeSQLite(database, sql: "COMMIT")
            } catch {
                try? executeSQLite(database, sql: "ROLLBACK")
                throw error
            }
            try executeSQLite(database, sql: "PRAGMA foreign_keys = ON")
            var foreignKeyViolations: [String] = []
            try querySQLite(database, sql: "PRAGMA foreign_key_check") {
                foreignKeyViolations.append(
                    [
                        sqliteText($0, column: 0),
                        String(sqlite3_column_int64($0, 1)),
                        sqliteText($0, column: 2),
                        String(sqlite3_column_int64($0, 3)),
                    ].joined(separator: "|")
                )
            }
            XCTAssertTrue(
                foreignKeyViolations.isEmpty,
                "Legacy fixture must retain valid foreign keys: \(foreignKeyViolations)"
            )
        }
        return (generation.identifier, sourceIdentifier, spec)
    }

    private func legacySchemaV1Fingerprint(
        _ spec: SemanticIndexGenerationSpec
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "1",
                spec.retrievalCapability.rawValue,
                spec.embeddingModelIdentifier ?? "",
                spec.embeddingModelDigest ?? "",
                spec.vectorDimension.map(String.init) ?? "",
                spec.chunkerVersion,
                spec.normalizationVersion,
                spec.sourceSchemaVersion,
            ])
        )
    }

    private func legacySchemaV2Fingerprint(
        _ spec: SemanticIndexGenerationSpec
    ) -> String {
        SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "2",
                spec.retrievalCapability.rawValue,
                spec.embeddingModelIdentifier ?? "",
                spec.embeddingModelDigest ?? "",
                spec.vectorDimension.map(String.init) ?? "",
                spec.ollamaRuntimeVersion ?? "",
                spec.embeddingRequestProfileVersion ?? "",
                spec.embeddingRequestProfileHash ?? "",
                spec.embeddingDimensions.map(String.init)
                    ?? "model_default",
                spec.embeddingTruncate.map {
                    $0 ? "true" : "false"
                } ?? "",
                spec.embeddingNormalizationVersion ?? "",
                spec.chunkerVersion,
                spec.normalizationVersion,
                spec.sourceSchemaVersion,
            ])
        )
    }

    private func legacyBindingDigest(
        configurationFingerprint: String,
        sourceBindings: [String: String],
        highWatermarks: [String: String]
    ) -> String {
        func manifest(_ values: [String: String]) -> String {
            SemanticIndexDigest.sha256(
                values.sorted { $0.key < $1.key }.map {
                    SemanticIndexDigest.lengthPrefixed([$0.key, $0.value])
                }.joined()
            )
        }
        return SemanticIndexDigest.sha256(
            SemanticIndexDigest.lengthPrefixed([
                "configuration",
                configurationFingerprint,
                "source_bindings",
                manifest(sourceBindings),
                "source_high_watermarks",
                manifest(highWatermarks),
            ])
        )
    }

    private func legacyStorageSnapshot(
        url: URL
    ) throws -> LegacyStorageSnapshot {
        try withSQLiteDatabase(url: url) { database in
            var generationColumns: [String] = []
            try querySQLite(
                database,
                sql: "PRAGMA table_info(semantic_generations)"
            ) {
                generationColumns.append(sqliteText($0, column: 1))
            }
            var vectorBlobs: [Data] = []
            try querySQLite(
                database,
                sql: """
                    SELECT vector FROM semantic_chunks
                    ORDER BY generation_id, chunk_id
                    """
            ) { statement in
                let count = Int(sqlite3_column_bytes(statement, 0))
                guard count > 0,
                      let bytes = sqlite3_column_blob(statement, 0)
                else {
                    vectorBlobs.append(Data())
                    return
                }
                vectorBlobs.append(Data(bytes: bytes, count: count))
            }
            return .init(
                userVersion: Int(try XCTUnwrap(
                    scalarSQLiteInt(database, sql: "PRAGMA user_version")
                )),
                generationIdentifier: try XCTUnwrap(
                    scalarSQLiteText(
                        database,
                        sql: "SELECT id FROM semantic_generations ORDER BY id LIMIT 1"
                    )
                ),
                sourceCount: Int(try XCTUnwrap(
                    scalarSQLiteInt(
                        database,
                        sql: "SELECT count(*) FROM semantic_sources"
                    )
                )),
                chunkCount: Int(try XCTUnwrap(
                    scalarSQLiteInt(
                        database,
                        sql: "SELECT count(*) FROM semantic_chunks"
                    )
                )),
                ftsCount: Int(try XCTUnwrap(
                    scalarSQLiteInt(
                        database,
                        sql: "SELECT count(*) FROM semantic_chunks_fts"
                    )
                )),
                vectorBlobs: vectorBlobs,
                generationColumns: generationColumns
            )
        }
    }

    private func createLegacyCheckpointTable(
        _ database: OpaquePointer,
        name: String,
        generationTable: String
    ) throws {
        let permittedPair =
            (
                name == "semantic_checkpoints_v1" &&
                    generationTable == "semantic_generations_v1"
            ) ||
            (
                name == "semantic_checkpoints_v2" &&
                    generationTable == "semantic_generations"
            )
        guard permittedPair else {
            throw SemanticIndexFailureCode.sqliteFailure
        }
        try executeSQLite(
            database,
            sql: """
                CREATE TABLE \(name)(
                    run_id TEXT PRIMARY KEY,
                    generation_id TEXT NOT NULL
                        REFERENCES \(generationTable)(id)
                        ON DELETE CASCADE,
                    stream_id TEXT NOT NULL,
                    state TEXT NOT NULL CHECK(state IN (
                        'preparing','awaiting_embeddings','running',
                        'paused','cancelled','complete'
                    )),
                    current_cursor TEXT,
                    next_cursor TEXT,
                    source_high_watermark TEXT,
                    batches_committed INTEGER NOT NULL
                        CHECK(batches_committed >= 0),
                    records_seen INTEGER NOT NULL
                        CHECK(records_seen >= 0),
                    records_committed INTEGER NOT NULL
                        CHECK(records_committed >= 0),
                    records_unchanged INTEGER NOT NULL
                        CHECK(records_unchanged >= 0),
                    records_excluded INTEGER NOT NULL
                        CHECK(records_excluded >= 0),
                    tombstones_committed INTEGER NOT NULL
                        CHECK(tombstones_committed >= 0),
                    chunks_committed INTEGER NOT NULL
                        CHECK(chunks_committed >= 0),
                    pending_chunk_count INTEGER NOT NULL
                        CHECK(pending_chunk_count >= 0),
                    updated_at INTEGER NOT NULL
                ) STRICT
                """
        )
    }

    private func copyLegacyCheckpointRows(
        _ database: OpaquePointer,
        destination: String
    ) throws {
        guard destination == "semantic_checkpoints_v1" ||
                destination == "semantic_checkpoints_v2"
        else {
            throw SemanticIndexFailureCode.sqliteFailure
        }
        try executeSQLite(
            database,
            sql: """
                INSERT INTO \(destination)(
                    run_id, generation_id, stream_id, state,
                    current_cursor, next_cursor,
                    source_high_watermark, batches_committed,
                    records_seen, records_committed,
                    records_unchanged, records_excluded,
                    tombstones_committed, chunks_committed,
                    pending_chunk_count, updated_at
                )
                SELECT run_id, generation_id, stream_id, state,
                       current_cursor, next_cursor,
                       source_high_watermark, batches_committed,
                       records_seen, records_committed,
                       records_unchanged, records_excluded,
                       tombstones_committed, chunks_committed,
                       pending_chunk_count, updated_at
                FROM semantic_checkpoints
                """
        )
    }

    private func withSQLiteDatabase<T>(
        url: URL,
        body: (OpaquePointer) throws -> T
    ) throws -> T {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK,
              let database
        else {
            if let database { sqlite3_close_v2(database) }
            throw SemanticIndexFailureCode.databaseOpenFailed
        }
        defer { sqlite3_close_v2(database) }
        return try body(database)
    }

    private func executeSQLite(
        _ database: OpaquePointer,
        sql: String,
        textBinds: [String] = []
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SemanticIndexFailureCode.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (offset, value) in textBinds.enumerated() {
            guard sqlite3_bind_text(
                statement,
                Int32(offset + 1),
                value,
                -1,
                transient
            ) == SQLITE_OK else {
                throw SemanticIndexFailureCode.sqliteFailure
            }
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SemanticIndexFailureCode.sqliteFailure
        }
    }

    private func querySQLite(
        _ database: OpaquePointer,
        sql: String,
        row: (OpaquePointer) throws -> Void
    ) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else { throw SemanticIndexFailureCode.sqliteFailure }
        defer { sqlite3_finalize(statement) }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                try row(statement)
            case SQLITE_DONE:
                return
            default:
                throw SemanticIndexFailureCode.sqliteFailure
            }
        }
    }

    private func scalarSQLiteInt(
        _ database: OpaquePointer,
        sql: String
    ) throws -> Int64? {
        var value: Int64?
        try querySQLite(database, sql: sql) {
            value = sqlite3_column_int64($0, 0)
        }
        return value
    }

    private func scalarSQLiteText(
        _ database: OpaquePointer,
        sql: String
    ) throws -> String? {
        var value: String?
        try querySQLite(database, sql: sql) {
            value = sqliteText($0, column: 0)
        }
        return value
    }

    private func sqliteText(
        _ statement: OpaquePointer,
        column: Int32
    ) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else {
            return ""
        }
        return String(cString: pointer)
    }

    private func readyHybridIndex(
        spec: SemanticIndexGenerationSpec,
        suffix: String
    ) async throws -> (SemanticVaultIndex, SemanticIndexGenerationMetadata) {
        let index = try SemanticVaultIndex(inMemory: true, now: fixedClock())
        let generation = try await index.beginGeneration(spec: spec)
        let record = try sourceRecord(
            identifier: "stale-source-\(suffix)",
            kind: .brief,
            text: "Stable lexical content for \(suffix)"
        )
        let request = try batchRequest(
            run: "stale-ready-\(suffix)",
            stream: "briefs",
            final: true,
            records: [record]
        )
        let plan = try await index.prepareBatch(
            generationIdentifier: generation.identifier,
            request: request
        )
        let dimension = try XCTUnwrap(spec.vectorDimension)
        var vector = Array(repeating: Float(0), count: dimension)
        vector[0] = 1
        _ = try await index.commit(
            plan,
            embeddingsByChunkIdentifier: embeddings(for: plan, vector: vector)
        )
        let ready = try await publishGenerationForTests(
            generation,
            in: index
        )
        return (index, ready)
    }

    private func readyPriorAndCandidate(
        in index: SemanticVaultIndex,
        scope: SemanticIndexBuildScope,
        suffix: String
    ) async throws -> (
        prior: SemanticIndexGenerationMetadata,
        candidate: SemanticIndexGenerationMetadata
    ) {
        let priorGeneration = try await index.beginGeneration(
            spec: generationSpec(
                digestSeed: "prior-\(suffix)",
                buildScope: scope
            )
        )
        let priorRecord = try sourceRecord(
            identifier: "prior-\(suffix)",
            kind: .brief,
            text: "Prior active \(suffix)"
        )
        let priorRequest = try batchRequest(
            run: "prior-\(suffix)-run",
            stream: "briefs",
            final: true,
            records: [priorRecord],
            buildScope: scope
        )
        let priorPlan = try await index.prepareBatch(
            generationIdentifier: priorGeneration.identifier,
            request: priorRequest
        )
        _ = try await index.commit(
            priorPlan,
            embeddingsByChunkIdentifier: embeddings(
                for: priorPlan,
                vector: [1, 0, 0]
            )
        )
        let prior = try await index.publishGeneration(
            priorGeneration.identifier
        )

        let candidate = try await index.beginGeneration(
            spec: generationSpec(
                digestSeed: "candidate-\(suffix)",
                buildScope: scope
            ),
            rebuilding: true
        )
        let candidateRecord = try sourceRecord(
            identifier: "candidate-\(suffix)",
            kind: .brief,
            text: "Candidate \(suffix)"
        )
        let candidateRequest = try batchRequest(
            run: "candidate-\(suffix)-run",
            stream: "briefs",
            final: true,
            records: [candidateRecord],
            buildScope: scope
        )
        let candidatePlan = try await index.prepareBatch(
            generationIdentifier: candidate.identifier,
            request: candidateRequest
        )
        _ = try await index.commit(
            candidatePlan,
            embeddingsByChunkIdentifier: embeddings(
                for: candidatePlan,
                vector: [0, 1, 0]
            )
        )
        return (prior, candidate)
    }

    private func generationSpec(
        digestSeed: String = "qwen3-embedding-test-digest",
        dimension: Int = 3,
        runtimeVersion: String = "0.11.6",
        requestProfileVersion: String = "loki-embedding-request-v1",
        requestProfileSeed: String = "loki-embedding-request-profile",
        embeddingDimensions: Int? = nil,
        embeddingTruncate: Bool = false,
        embeddingNormalizationVersion: String =
            OllamaEmbeddingRequestProfile.currentNormalizationVersion,
        chunkerVersion: String = SemanticTextChunker.version,
        normalizationVersion: String = SemanticTextNormalizer.version,
        sourceSchemaVersion: String = "loki-source-v1",
        buildScope: SemanticIndexBuildScope? = nil
    ) throws -> SemanticIndexGenerationSpec {
        let scope = try buildScope ?? defaultBuildScope()
        return try .init(
            embeddingModelIdentifier: "qwen3-embedding:0.6b",
            embeddingModelDigest: SemanticIndexDigest.sha256(digestSeed),
            vectorDimension: dimension,
            ollamaRuntimeVersion: runtimeVersion,
            embeddingRequestProfileVersion: requestProfileVersion,
            embeddingRequestProfileHash: SemanticIndexDigest.sha256(requestProfileSeed),
            embeddingDimensions: embeddingDimensions,
            embeddingTruncate: embeddingTruncate,
            embeddingNormalizationVersion:
                embeddingNormalizationVersion,
            chunkerVersion: chunkerVersion,
            normalizationVersion: normalizationVersion,
            sourceSchemaVersion: sourceSchemaVersion,
            buildScope: scope
        )
    }

    private func sourceRecord(
        identifier: String,
        kind: SemanticIndexSourceKind,
        text: String,
        timestamp: Date? = nil,
        tombstone: Bool = false,
        privacy: SemanticIndexPrivacyClassification = .indexable,
        provider: String = "local"
    ) throws -> SemanticIndexSourceRecord {
        let date = timestamp ?? anchor
        return try .init(
            stableSourceIdentifier: identifier,
            sourceKind: kind,
            sourceTimestamp: date,
            text: text,
            sourceHash: SemanticIndexSourceRecord.deterministicSourceHash(
                stableSourceIdentifier: identifier,
                sourceKind: kind,
                sourceTimestamp: date,
                text: text
            ),
            isTombstone: tombstone,
            privacyClassification: privacy,
            provenance: try .init(
                provider: provider,
                provenanceReceiptHash: SemanticIndexDigest.sha256(
                    "\(identifier)|\(provider)|\(date.timeIntervalSince1970)"
                )
            )
        )
    }

    private func batchRequest(
        run: String,
        stream: String,
        currentCursor: String? = nil,
        nextCursor: String? = nil,
        highWatermark: String? = nil,
        final: Bool,
        trigger: SemanticIndexTrigger = .manual,
        records: [SemanticIndexSourceRecord],
        sourceKind: SemanticIndexSourceKind? = nil,
        buildScope: SemanticIndexBuildScope? = nil
    ) throws -> SemanticIndexBatchRequest {
        let scope = try buildScope ?? defaultBuildScope()
        guard let declaredSourceKind =
            sourceKind ?? records.first?.sourceKind,
              let adapterContractVersion =
                scope.adapterContractVersion(
                    for: declaredSourceKind
                )
        else {
            throw SemanticIndexFailureCode.sourceScopeMissing
        }
        return try .init(
            runIdentifier: run,
            streamIdentifier: stream,
            currentCursor: currentCursor,
            nextCursor: nextCursor,
            sourceHighWatermark: highWatermark,
            isFinalBatch: final,
            sourceKind: declaredSourceKind,
            adapterContractVersion: adapterContractVersion,
            sourceAllowlistSHA256: scope.allowlistSHA256,
            authorizationReceiptIdentifier:
                scope.authorizationReceiptIdentifier,
            trigger: trigger,
            records: records
        )
    }

    private func defaultBuildScope(
        sourceKinds: Set<SemanticIndexSourceKind> =
            Set(SemanticIndexSourceKind.allCases),
        receiptIdentifier: String = "p8f-test-authority",
        initiation: SemanticIndexBuildInitiation = .manualOperator
    ) throws -> SemanticIndexBuildScope {
        try .init(
            sourceKinds: sourceKinds,
            adapterContractVersions: Dictionary(
                uniqueKeysWithValues: sourceKinds.map {
                    ($0, "p8f-test-\($0.rawValue)-adapter-v1")
                }
            ),
            requestTimestamp: anchor,
            initiation: initiation,
            authorizationReceiptIdentifier: receiptIdentifier
        )
    }

    private func publishGenerationForTests(
        _ generation: SemanticIndexGenerationMetadata,
        in index: SemanticVaultIndex
    ) async throws -> SemanticIndexGenerationMetadata {
        let scope = try XCTUnwrap(generation.spec.buildScope)
        for kind in scope.canonicalSourceKinds {
            let request = try batchRequest(
                run: "publish-\(generation.identifier)-\(kind.rawValue)",
                stream: "publish-\(kind.rawValue)",
                final: true,
                records: [],
                sourceKind: kind,
                buildScope: scope
            )
            let plan = try await index.prepareBatch(
                generationIdentifier: generation.identifier,
                request: request
            )
            _ = try await index.commit(
                plan,
                embeddingsByChunkIdentifier: [:]
            )
        }
        return try await index.publishGeneration(
            generation.identifier
        )
    }

    private func embeddings(
        for batch: SemanticIndexPreparedBatch,
        vector: [Float]
    ) -> [String: [Float]] {
        Dictionary(
            uniqueKeysWithValues: batch.chunksRequiringEmbeddings.map {
                ($0.chunkIdentifier, vector)
            }
        )
    }

    private func embeddingsByText(
        for batch: SemanticIndexPreparedBatch,
        mapping: [String: [Float]]
    ) -> [String: [Float]] {
        Dictionary(
            uniqueKeysWithValues: batch.chunksRequiringEmbeddings.map { chunk in
                let selected = mapping.first {
                    chunk.normalizedText.localizedCaseInsensitiveContains($0.key)
                }?.value ?? [0, 0, 1]
                return (chunk.chunkIdentifier, selected)
            }
        )
    }

    private func fixedClock() -> @Sendable () -> Date {
        { Date(timeIntervalSince1970: 1_800_000_000) }
    }
}
