import Foundation
import XCTest
@testable import LokiBrief

final class AttachedDataFileAuthorityTests: XCTestCase, @unchecked Sendable {
    func testAuthorizeAndResolvedReadBalanceEverySuccessfulSecurityScopeStart() async throws {
        let fixture = try makeFile(named: "records.json", contents: #"[{"id":1}]"#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SecurityScopeProbe(resolvedURL: fixture.file)
        let authority = AttachedDataFileAuthority(securityScope: probe.access())

        let observation = try await authority.authorize(fixture.file)
        XCTAssertEqual(observation.kind, .json)
        XCTAssertEqual(observation.originalFilename, "records.json")
        XCTAssertEqual(observation.locationDescriptor, "User-selected read-only JSON file")
        XCTAssertFalse(observation.locationDescriptor.contains(fixture.directory.path))
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertEqual(probe.stopCount, 1)

        let (digest, resolved) = try await authority.withResolvedSource(
            bookmark: observation.securityScopedBookmark,
            expectedIdentity: observation.identity
        ) { url, before in
            XCTAssertNotEqual(url.standardizedFileURL, fixture.file.standardizedFileURL)
            XCTAssertFalse(url.path.hasPrefix(fixture.directory.path + "/"))
            XCTAssertEqual(try Data(contentsOf: url), Data(#"[{"id":1}]"#.utf8))
            XCTAssertEqual(probe.startCount, 2)
            XCTAssertEqual(probe.stopCount, 1)
            return before.sourceDigest
        }
        XCTAssertEqual(digest, observation.sourceDigest)
        XCTAssertEqual(resolved.sourceDigest, observation.sourceDigest)
        XCTAssertEqual(probe.startCount, 2)
        XCTAssertEqual(probe.stopCount, 2)
    }

    func testResolvedOperationFailureStillBalancesSecurityScope() async throws {
        enum ExpectedFailure: Error { case operation }
        let fixture = try makeFile(named: "records.json", contents: "{}")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SecurityScopeProbe(resolvedURL: fixture.file)
        let authority = AttachedDataFileAuthority(securityScope: probe.access())
        let observation = try await authority.authorize(fixture.file)

        do {
            let _: (String, AttachedDataFileObservation) = try await authority
                .withResolvedSource(
                    bookmark: observation.securityScopedBookmark,
                    expectedIdentity: observation.identity
                ) { _, _ in
                    throw ExpectedFailure.operation
                }
            XCTFail("Expected operation failure")
        } catch ExpectedFailure.operation {}

        XCTAssertEqual(probe.startCount, 2)
        XCTAssertEqual(probe.stopCount, 2)
    }

    func testFailedScopeStartNeverCallsStop() async throws {
        let fixture = try makeFile(named: "records.json", contents: "{}")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SecurityScopeProbe(resolvedURL: fixture.file, allowsStart: false)
        let authority = AttachedDataFileAuthority(securityScope: probe.access())

        do {
            _ = try await authority.authorize(fixture.file)
            XCTFail("Expected authorization failure")
        } catch let failure as AttachedDataFileFailureCode {
            XCTAssertEqual(failure, .authorizationFailed)
        }
        XCTAssertEqual(probe.startCount, 1)
        XCTAssertEqual(probe.stopCount, 0)
    }

    func testStaleResolutionRefreshesBookmarkInsideBalancedScope() async throws {
        let fixture = try makeFile(named: "records.json", contents: "[]")
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let probe = SecurityScopeProbe(resolvedURL: fixture.file, resolvesStale: true)
        let authority = AttachedDataFileAuthority(securityScope: probe.access())
        let observation = try await authority.authorize(fixture.file)
        XCTAssertEqual(probe.bookmarkCount, 1)

        let (_, refreshed) = try await authority.withResolvedSource(
            bookmark: observation.securityScopedBookmark,
            expectedIdentity: observation.identity
        ) { _, _ in "ok" }

        XCTAssertTrue(refreshed.bookmarkWasStale)
        XCTAssertEqual(probe.bookmarkCount, 2)
        XCTAssertEqual(probe.startCount, 2)
        XCTAssertEqual(probe.stopCount, 2)
    }

    func testHeaderAndExtensionMismatchesFailClosed() async throws {
        let directory = try makeDirectory(named: "header-policy")
        defer { try? FileManager.default.removeItem(at: directory) }
        let invalidSQLite = directory.appendingPathComponent("not-database.sqlite")
        let disguisedSQLite = directory.appendingPathComponent("database.json")
        let invalidJSON = directory.appendingPathComponent("scalar.json")
        let unsupported = directory.appendingPathComponent("records.txt")
        try Data("{}".utf8).write(to: invalidSQLite)
        try (Data("SQLite format 3\0".utf8) + Data(repeating: 0, count: 64))
            .write(to: disguisedSQLite)
        try Data("true".utf8).write(to: invalidJSON)
        try Data("{}".utf8).write(to: unsupported)
        let authority = AttachedDataFileAuthority(securityScope: .unscopedTesting)

        await assertFailure(.sqliteHeaderMismatch) {
            try await authority.authorize(invalidSQLite)
        }
        await assertFailure(.sqliteHeaderMismatch) {
            try await authority.authorize(disguisedSQLite)
        }
        await assertFailure(.invalidJSONHeader) {
            try await authority.authorize(invalidJSON)
        }
        await assertFailure(.unsupportedType) {
            try await authority.authorize(unsupported)
        }
    }

    func testSymbolicLinksNonRegularFilesAndOversizedSourcesAreDenied() async throws {
        let directory = try makeDirectory(named: "filesystem-boundary")
        defer { try? FileManager.default.removeItem(at: directory) }
        let target = directory.appendingPathComponent("target.json")
        let link = directory.appendingPathComponent("link.json")
        let nestedDirectory = directory.appendingPathComponent("directory.json", isDirectory: true)
        let oversized = directory.appendingPathComponent("oversized.json")
        try Data("{}".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: false)
        try Data("[1]".utf8).write(to: oversized)
        let authority = AttachedDataFileAuthority(
            securityScope: .unscopedTesting,
            maximumJSONBytes: 2
        )

        await assertFailure(.symbolicLinkDenied) {
            try await authority.authorize(link)
        }
        await assertFailure(.nonRegularFileDenied) {
            try await authority.authorize(nestedDirectory)
        }
        await assertFailure(.tooLarge) {
            try await authority.authorize(oversized)
        }
    }

    func testReplacementBeforeResolutionAndMutationDuringReadAreDetected() async throws {
        let fixture = try makeFile(named: "records.json", contents: #"{"version":1}"#)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let authority = AttachedDataFileAuthority(securityScope: .unscopedTesting)
        let original = try await authority.authorize(fixture.file)

        try Data(#"{"version":2}"#.utf8).write(to: fixture.file, options: .atomic)
        await assertFailure(.identityChanged) {
            try await authority.withResolvedSource(
                bookmark: original.securityScopedBookmark,
                expectedIdentity: original.identity
            ) { _, _ in "unreachable" }
        }

        let replacement = try await authority.authorize(fixture.file)
        await assertFailure(.identityChanged) {
            try await authority.withResolvedSource(
                bookmark: replacement.securityScopedBookmark,
                expectedIdentity: replacement.identity
            ) { snapshotURL, _ in
                XCTAssertEqual(
                    try Data(contentsOf: snapshotURL),
                    Data(#"{"version":2}"#.utf8)
                )
                try Data(#"{"version":3}"#.utf8).write(
                    to: fixture.file,
                    options: .atomic
                )
                return "changed"
            }
        }
    }

    func testMonotonicDeadlineBoundsSnapshotDigestAndResolvedWork() async throws {
        let body = "{\"value\":\"" + String(repeating: "x", count: 2 * 1_024 * 1_024)
            + "\"}"
        let fixture = try makeFile(named: "deadline.json", contents: body)
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let baseline = AttachedDataFileAuthority(
            securityScope: .unscopedTesting
        )
        let observation = try await baseline.authorize(fixture.file)
        let bounded = AttachedDataFileAuthority(
            securityScope: .unscopedTesting,
            operationTimeSeconds: 0.000_001
        )

        await assertFailure(.timedOut) {
            try await bounded.authorize(fixture.file)
        }
        await assertFailure(.timedOut) {
            try await bounded.withResolvedSource(
                bookmark: observation.securityScopedBookmark,
                expectedIdentity: observation.identity
            ) { _, _, _ in
                XCTFail("Expired authority must not invoke the operation")
                return "unreachable"
            }
        }
    }

    private func assertFailure<T>(
        _ expected: AttachedDataFileFailureCode,
        operation: () async throws -> T
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let failure as AttachedDataFileFailureCode {
            XCTAssertEqual(failure, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeFile(
        named name: String,
        contents: String
    ) throws -> (directory: URL, file: URL) {
        let directory = try makeDirectory(named: "regular-file")
        let file = directory.appendingPathComponent(name)
        try Data(contents.utf8).write(to: file)
        return (directory, file)
    }

    private func makeDirectory(named name: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-loki-attached-file-tests-\(name)-\(UUID().uuidString.lowercased())",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}

private final class SecurityScopeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let resolvedURL: URL
    private let allowsStart: Bool
    private let resolvesStale: Bool
    private var starts = 0
    private var stops = 0
    private var bookmarks = 0

    init(
        resolvedURL: URL,
        allowsStart: Bool = true,
        resolvesStale: Bool = false
    ) {
        self.resolvedURL = resolvedURL
        self.allowsStart = allowsStart
        self.resolvesStale = resolvesStale
    }

    var startCount: Int { lock.withLock { starts } }
    var stopCount: Int { lock.withLock { stops } }
    var bookmarkCount: Int { lock.withLock { bookmarks } }

    func access() -> AttachedSecurityScopedResourceAccess {
        AttachedSecurityScopedResourceAccess(
            start: { [self] _ in
                lock.withLock { starts += 1 }
                return allowsStart
            },
            stop: { [self] _ in
                lock.withLock { stops += 1 }
            },
            makeBookmark: { [self] url in
                lock.withLock { bookmarks += 1 }
                return Data(url.standardizedFileURL.path.utf8)
            },
            resolveBookmark: { [self] _ in
                (resolvedURL, resolvesStale)
            }
        )
    }
}
