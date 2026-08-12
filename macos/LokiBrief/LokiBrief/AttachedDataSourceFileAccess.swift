import CryptoKit
import Darwin
import Foundation

enum AttachedDataFileFailureCode: String, Error, Codable, Hashable, Sendable,
    LocalizedError
{
    case authorizationFailed = "attached_data_file_authorization_failed"
    case bookmarkUnavailable = "attached_data_bookmark_unavailable"
    case bookmarkStale = "attached_data_bookmark_stale"
    case unavailable = "attached_data_file_unavailable"
    case unsupportedType = "attached_data_file_type_unsupported"
    case symbolicLinkDenied = "attached_data_symbolic_link_denied"
    case aliasDenied = "attached_data_alias_denied"
    case nonRegularFileDenied = "attached_data_non_regular_file_denied"
    case identityChanged = "attached_data_file_identity_changed"
    case tooLarge = "attached_data_file_too_large"
    case readFailed = "attached_data_file_read_failed"
    case coherentSnapshotUnavailable = "attached_data_coherent_snapshot_unavailable"
    case invalidJSONHeader = "attached_data_json_header_invalid"
    case sqliteHeaderMismatch = "attached_data_sqlite_header_mismatch"
    case cancelled = "attached_data_file_read_cancelled"
    case timedOut = "attached_data_file_read_timed_out"

    var errorDescription: String? { rawValue }
}

struct AttachedDataOperationDeadline: Hashable, Sendable {
    private let uptimeLimit: TimeInterval

    static let distantFuture = Self(
        uptimeLimit: .greatestFiniteMagnitude
    )

    init(secondsFromNow seconds: TimeInterval) {
        uptimeLimit = ProcessInfo.processInfo.systemUptime + seconds
    }

    var hasExpired: Bool {
        ProcessInfo.processInfo.systemUptime >= uptimeLimit
    }

    func limited(to seconds: TimeInterval) -> Self {
        let candidate = ProcessInfo.processInfo.systemUptime + seconds
        return .init(uptimeLimit: min(uptimeLimit, candidate))
    }

    private init(uptimeLimit: TimeInterval) {
        self.uptimeLimit = uptimeLimit
    }
}

struct AttachedDataFileObservation: Hashable, Sendable {
    let kind: AttachedDataSourceKind
    let displayName: String
    let originalFilename: String
    let locationDescriptor: String
    let identity: AttachedDataFileIdentity
    let sourceDigest: String
    let fileSize: Int64
    let modificationDate: Date
    let securityScopedBookmark: Data
    let bookmarkWasStale: Bool
}

struct AttachedSecurityScopedResourceAccess: @unchecked Sendable {
    let start: @Sendable (URL) -> Bool
    let stop: @Sendable (URL) -> Void
    let makeBookmark: @Sendable (URL) throws -> Data
    let resolveBookmark: @Sendable (Data) throws -> (URL, Bool)

    static let live = AttachedSecurityScopedResourceAccess(
        start: { $0.startAccessingSecurityScopedResource() },
        stop: { $0.stopAccessingSecurityScopedResource() },
        makeBookmark: { url in
            try url.bookmarkData(
                options: [
                    .withSecurityScope,
                    .securityScopeAllowOnlyReadAccess,
                ],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        },
        resolveBookmark: { bookmark in
            var stale = false
            let url = try URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            )
            return (url, stale)
        }
    )

    static let unscopedTesting = AttachedSecurityScopedResourceAccess(
        start: { _ in true },
        stop: { _ in },
        makeBookmark: { Data($0.standardizedFileURL.path.utf8) },
        resolveBookmark: { data in
            guard let path = String(data: data, encoding: .utf8) else {
                throw AttachedDataFileFailureCode.bookmarkUnavailable
            }
            return (URL(fileURLWithPath: path), false)
        }
    )
}

actor AttachedDataFileAuthority {
    private let securityScope: AttachedSecurityScopedResourceAccess
    private let maximumSQLiteBytes: Int64
    private let maximumJSONBytes: Int64
    private let operationTimeSeconds: TimeInterval

    init(
        securityScope: AttachedSecurityScopedResourceAccess = .live,
        maximumSQLiteBytes: Int64 = 2 * 1_024 * 1_024 * 1_024,
        maximumJSONBytes: Int64 = 32 * 1_024 * 1_024,
        operationTimeSeconds: TimeInterval = 15
    ) {
        self.securityScope = securityScope
        self.maximumSQLiteBytes = maximumSQLiteBytes
        self.maximumJSONBytes = maximumJSONBytes
        self.operationTimeSeconds = operationTimeSeconds.isFinite
            && operationTimeSeconds > 0
            && operationTimeSeconds <= 300
            ? operationTimeSeconds : 15
    }

    func authorize(_ url: URL) async throws -> AttachedDataFileObservation {
        let deadline = AttachedDataOperationDeadline(
            secondsFromNow: operationTimeSeconds
        )
        guard securityScope.start(url) else {
            throw AttachedDataFileFailureCode.authorizationFailed
        }
        defer { securityScope.stop(url) }
        let bookmark = try securityScope.makeBookmark(url)
        let opened = try openSource(url, expectedIdentity: nil)
        defer { Darwin.close(opened.descriptor) }
        let snapshot = try await makeSnapshot(of: opened, deadline: deadline)
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        let afterIdentity = try validateExternalSource(opened)
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        return observation(
            opened: opened,
            identity: afterIdentity,
            sourceDigest: snapshot.sourceDigest,
            bookmark: bookmark,
            bookmarkWasStale: false
        )
    }

    func withResolvedSource<T: Sendable>(
        bookmark: Data,
        expectedIdentity: AttachedDataFileIdentity,
        operation: @Sendable (
            URL,
            AttachedDataFileObservation
        ) async throws -> T
    ) async throws -> (T, AttachedDataFileObservation) {
        try await withResolvedSource(
            bookmark: bookmark,
            expectedIdentity: expectedIdentity
        ) { url, observation, _ in
            try await operation(url, observation)
        }
    }

    func withResolvedSource<T: Sendable>(
        bookmark: Data,
        expectedIdentity: AttachedDataFileIdentity,
        operation: @Sendable (
            URL,
            AttachedDataFileObservation,
            AttachedDataOperationDeadline
        ) async throws -> T
    ) async throws -> (T, AttachedDataFileObservation) {
        let deadline = AttachedDataOperationDeadline(
            secondsFromNow: operationTimeSeconds
        )
        let resolved: (URL, Bool)
        do {
            resolved = try securityScope.resolveBookmark(bookmark)
        } catch {
            throw AttachedDataFileFailureCode.bookmarkUnavailable
        }
        guard securityScope.start(resolved.0) else {
            throw AttachedDataFileFailureCode.authorizationFailed
        }
        defer { securityScope.stop(resolved.0) }
        let refreshedBookmark = resolved.1
            ? try securityScope.makeBookmark(resolved.0) : bookmark
        let opened = try openSource(
            resolved.0,
            expectedIdentity: expectedIdentity
        )
        defer { Darwin.close(opened.descriptor) }
        let snapshot = try await makeSnapshot(of: opened, deadline: deadline)
        defer { try? FileManager.default.removeItem(at: snapshot.directory) }
        let before = observation(
            opened: opened,
            identity: opened.identity,
            sourceDigest: snapshot.sourceDigest,
            bookmark: refreshedBookmark,
            bookmarkWasStale: resolved.1
        )
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        let value = try await operation(snapshot.url, before, deadline)
        try Task.checkCancellation()
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        guard try hashFile(at: snapshot.url, deadline: deadline)
                == snapshot.sourceDigest
        else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        let afterDigest = try await currentSourceDigest(
            opened,
            deadline: deadline
        )
        let afterIdentity = try validateExternalSource(opened)
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        guard afterIdentity.matchesSnapshot(before.identity),
              afterDigest == before.sourceDigest
        else { throw AttachedDataFileFailureCode.identityChanged }
        let after = observation(
            opened: opened,
            identity: afterIdentity,
            sourceDigest: afterDigest,
            bookmark: refreshedBookmark,
            bookmarkWasStale: resolved.1
        )
        return (value, after)
    }

    private func openSource(
        _ url: URL,
        expectedIdentity: AttachedDataFileIdentity?
    ) throws -> AttachedDataOpenedSource {
        try Task.checkCancellation()
        let canonical = url.standardizedFileURL
        var linkInformation = stat()
        guard canonical.path.withCString({ Darwin.lstat($0, &linkInformation) }) == 0
        else { throw AttachedDataFileFailureCode.unavailable }
        guard UInt32(linkInformation.st_mode & S_IFMT) != UInt32(S_IFLNK)
        else { throw AttachedDataFileFailureCode.symbolicLinkDenied }

        let resourceValues = try canonical.resourceValues(forKeys: [
            .isAliasFileKey,
            .isDirectoryKey,
            .isRegularFileKey,
        ])
        guard resourceValues.isAliasFile != true else {
            throw AttachedDataFileFailureCode.aliasDenied
        }
        guard resourceValues.isDirectory != true,
              resourceValues.isRegularFile == true
        else { throw AttachedDataFileFailureCode.nonRegularFileDenied }

        let descriptor = Darwin.open(
            canonical.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AttachedDataFileFailureCode.unavailable
        }
        var retainDescriptor = false
        defer {
            if !retainDescriptor { Darwin.close(descriptor) }
        }
        var opened = stat()
        guard Darwin.fstat(descriptor, &opened) == 0,
              UInt32(opened.st_mode & S_IFMT) == UInt32(S_IFREG),
              opened.st_nlink > 0
        else { throw AttachedDataFileFailureCode.nonRegularFileDenied }

        let identity = AttachedDataFileIdentity(
            deviceID: Int64(opened.st_dev),
            inode: UInt64(opened.st_ino),
            fileType: UInt32(opened.st_mode & S_IFMT),
            linkCount: UInt64(opened.st_nlink),
            fileSize: Int64(opened.st_size),
            modificationNanoseconds:
                Int64(opened.st_mtimespec.tv_sec) * 1_000_000_000
                + Int64(opened.st_mtimespec.tv_nsec)
        )
        try identity.validate()
        guard identity.deviceID == Int64(linkInformation.st_dev),
              identity.inode == UInt64(linkInformation.st_ino)
        else { throw AttachedDataFileFailureCode.identityChanged }
        if let expectedIdentity,
           !identity.matchesResource(expectedIdentity)
        {
            throw AttachedDataFileFailureCode.identityChanged
        }

        let header = try readPrefix(descriptor: descriptor, maximumCount: 64)
        let kind = try detectKind(url: canonical, header: header)
        let maximumBytes = kind == .sqlite ? maximumSQLiteBytes : maximumJSONBytes
        guard identity.fileSize >= 0, identity.fileSize <= maximumBytes else {
            throw AttachedDataFileFailureCode.tooLarge
        }

        let originalFilename = boundedFilename(canonical.lastPathComponent)
        let displayName = originalFilename.isEmpty
            ? kind.displayName : originalFilename
        retainDescriptor = true
        return AttachedDataOpenedSource(
            url: canonical,
            descriptor: descriptor,
            kind: kind,
            displayName: displayName,
            originalFilename: originalFilename,
            identity: identity,
            modificationDate: Date(
                timeIntervalSince1970: TimeInterval(opened.st_mtimespec.tv_sec)
                    + TimeInterval(opened.st_mtimespec.tv_nsec) / 1_000_000_000
            )
        )
    }

    private func makeSnapshot(
        of opened: AttachedDataOpenedSource,
        deadline: AttachedDataOperationDeadline
    ) async throws -> AttachedDataPreparedSnapshot {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "agent-loki-authorized-source-\(UUID().uuidString.lowercased())",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        do {
            let snapshotURL = directory.appendingPathComponent(
                opened.kind == .sqlite ? "snapshot.sqlite" : "snapshot.json"
            )
            let sourceDigest: String
            switch opened.kind {
            case .json:
                sourceDigest = try copyJSONSnapshot(
                    descriptor: opened.descriptor,
                    expectedByteCount: opened.identity.fileSize,
                    to: snapshotURL,
                    deadline: deadline
                )
            case .sqlite:
                do {
                    try await AttachedSQLiteSource.createStableSnapshot(
                        from: opened.url,
                        expectedIdentity: opened.identity,
                        to: snapshotURL,
                        maximumSourceBytes: maximumSQLiteBytes,
                        operationDeadline: deadline
                    )
                } catch let failure as AttachedSQLiteFailureCode {
                    switch failure {
                    case .sourceIdentityChanged:
                        throw AttachedDataFileFailureCode.identityChanged
                    case .sourceTooLarge:
                        throw AttachedDataFileFailureCode.tooLarge
                    case .cancelled:
                        throw AttachedDataFileFailureCode.cancelled
                    case .timedOut:
                        throw AttachedDataFileFailureCode.timedOut
                    default:
                        throw AttachedDataFileFailureCode.coherentSnapshotUnavailable
                    }
                }
                sourceDigest = try hashFile(
                    at: snapshotURL,
                    deadline: deadline
                )
            }
            return .init(
                directory: directory,
                url: snapshotURL,
                sourceDigest: sourceDigest
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func currentSourceDigest(
        _ opened: AttachedDataOpenedSource,
        deadline: AttachedDataOperationDeadline
    ) async throws -> String {
        switch opened.kind {
        case .json:
            return try hash(
                descriptor: opened.descriptor,
                expectedByteCount: opened.identity.fileSize,
                deadline: deadline
            )
        case .sqlite:
            let snapshot = try await makeSnapshot(
                of: opened,
                deadline: deadline
            )
            defer { try? FileManager.default.removeItem(at: snapshot.directory) }
            return snapshot.sourceDigest
        }
    }

    private func validateExternalSource(
        _ opened: AttachedDataOpenedSource
    ) throws -> AttachedDataFileIdentity {
        let descriptorIdentity = try identity(descriptor: opened.descriptor)
        guard descriptorIdentity.matchesSnapshot(opened.identity) else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        var linkInformation = stat()
        guard opened.url.path.withCString({ Darwin.lstat($0, &linkInformation) }) == 0,
              UInt32(linkInformation.st_mode & S_IFMT) != UInt32(S_IFLNK),
              Int64(linkInformation.st_dev) == descriptorIdentity.deviceID,
              UInt64(linkInformation.st_ino) == descriptorIdentity.inode
        else { throw AttachedDataFileFailureCode.identityChanged }
        let pathDescriptor = Darwin.open(
            opened.url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard pathDescriptor >= 0 else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        defer { Darwin.close(pathDescriptor) }
        let pathIdentity = try identity(descriptor: pathDescriptor)
        guard pathIdentity.matchesResource(descriptorIdentity) else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        return descriptorIdentity
    }

    private func observation(
        opened: AttachedDataOpenedSource,
        identity: AttachedDataFileIdentity,
        sourceDigest: String,
        bookmark: Data,
        bookmarkWasStale: Bool
    ) -> AttachedDataFileObservation {
        .init(
            kind: opened.kind,
            displayName: opened.displayName,
            originalFilename: opened.originalFilename,
            locationDescriptor:
                "User-selected read-only \(opened.kind.displayName) file",
            identity: identity,
            sourceDigest: sourceDigest,
            fileSize: identity.fileSize,
            modificationDate: opened.modificationDate,
            securityScopedBookmark: bookmark,
            bookmarkWasStale: bookmarkWasStale
        )
    }

    private func detectKind(url: URL, header: Data) throws
        -> AttachedDataSourceKind
    {
        let extensionValue = url.pathExtension.lowercased()
        let hasSQLiteHeader = AttachedSQLiteSource.hasSQLiteHeader(header)
        if ["db", "sqlite", "sqlite3"].contains(extensionValue) {
            guard hasSQLiteHeader else {
                throw AttachedDataFileFailureCode.sqliteHeaderMismatch
            }
            return .sqlite
        }
        guard extensionValue == "json" else {
            throw AttachedDataFileFailureCode.unsupportedType
        }
        guard !hasSQLiteHeader else {
            throw AttachedDataFileFailureCode.sqliteHeaderMismatch
        }
        let first = header.first(where: {
            ![0x20, 0x09, 0x0A, 0x0D].contains($0)
        })
        guard first == 0x7B || first == 0x5B else {
            throw AttachedDataFileFailureCode.invalidJSONHeader
        }
        return .json
    }

    private func readPrefix(descriptor: Int32, maximumCount: Int) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: maximumCount)
        let count = buffer.withUnsafeMutableBytes { storage in
            Darwin.pread(descriptor, storage.baseAddress, storage.count, 0)
        }
        guard count >= 0 else { throw AttachedDataFileFailureCode.readFailed }
        return Data(buffer.prefix(count))
    }

    private func copyJSONSnapshot(
        descriptor: Int32,
        expectedByteCount: Int64,
        to destinationURL: URL,
        deadline: AttachedDataOperationDeadline
    ) throws -> String {
        let destination = Darwin.open(
            destinationURL.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destination >= 0 else {
            throw AttachedDataFileFailureCode.readFailed
        }
        defer { Darwin.close(destination) }
        let before = try identity(descriptor: descriptor)
        guard before.fileSize == expectedByteCount else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        var offset: Int64 = 0
        while offset < expectedByteCount {
            if Task.isCancelled { throw AttachedDataFileFailureCode.cancelled }
            guard !deadline.hasExpired else {
                throw AttachedDataFileFailureCode.timedOut
            }
            let requested = min(buffer.count, Int(expectedByteCount - offset))
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.pread(
                    descriptor,
                    storage.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                throw AttachedDataFileFailureCode.identityChanged
            }
            var written = 0
            while written < count {
                guard !deadline.hasExpired else {
                    throw AttachedDataFileFailureCode.timedOut
                }
                let result = buffer.withUnsafeBytes { storage in
                    Darwin.write(
                        destination,
                        storage.baseAddress?.advanced(by: written),
                        count - written
                    )
                }
                guard result > 0 else {
                    throw AttachedDataFileFailureCode.readFailed
                }
                written += result
            }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        guard Darwin.fsync(destination) == 0 else {
            throw AttachedDataFileFailureCode.readFailed
        }
        let after = try identity(descriptor: descriptor)
        guard after.matchesSnapshot(before) else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func hashFile(
        at url: URL,
        deadline: AttachedDataOperationDeadline
    ) throws -> String {
        let descriptor = Darwin.open(
            url.path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw AttachedDataFileFailureCode.readFailed
        }
        defer { Darwin.close(descriptor) }
        let fileIdentity = try identity(descriptor: descriptor)
        return try hash(
            descriptor: descriptor,
            expectedByteCount: fileIdentity.fileSize,
            deadline: deadline
        )
    }

    private func hash(
        descriptor: Int32,
        expectedByteCount: Int64,
        deadline: AttachedDataOperationDeadline
    ) throws -> String {
        let before = try identity(descriptor: descriptor)
        guard before.fileSize == expectedByteCount else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
        var offset: Int64 = 0
        while offset < expectedByteCount {
            if Task.isCancelled { throw AttachedDataFileFailureCode.cancelled }
            guard !deadline.hasExpired else {
                throw AttachedDataFileFailureCode.timedOut
            }
            let requested = min(buffer.count, Int(expectedByteCount - offset))
            let count = buffer.withUnsafeMutableBytes { storage in
                Darwin.pread(
                    descriptor,
                    storage.baseAddress,
                    requested,
                    off_t(offset)
                )
            }
            guard count > 0 else {
                throw AttachedDataFileFailureCode.identityChanged
            }
            hasher.update(data: Data(buffer.prefix(count)))
            offset += Int64(count)
        }
        guard !deadline.hasExpired else {
            throw AttachedDataFileFailureCode.timedOut
        }
        let after = try identity(descriptor: descriptor)
        guard after.matchesSnapshot(before) else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func identity(descriptor: Int32) throws
        -> AttachedDataFileIdentity
    {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              UInt32(information.st_mode & S_IFMT) == UInt32(S_IFREG)
        else { throw AttachedDataFileFailureCode.nonRegularFileDenied }
        guard information.st_nlink > 0 else {
            throw AttachedDataFileFailureCode.identityChanged
        }
        let identity = AttachedDataFileIdentity(
            deviceID: Int64(information.st_dev),
            inode: UInt64(information.st_ino),
            fileType: UInt32(information.st_mode & S_IFMT),
            linkCount: UInt64(information.st_nlink),
            fileSize: Int64(information.st_size),
            modificationNanoseconds:
                Int64(information.st_mtimespec.tv_sec) * 1_000_000_000
                    + Int64(information.st_mtimespec.tv_nsec)
        )
        try identity.validate()
        return identity
    }

    private func boundedFilename(_ value: String) -> String {
        let scalars = value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(scalars).prefix(200))
    }
}

private struct AttachedDataOpenedSource {
    let url: URL
    let descriptor: Int32
    let kind: AttachedDataSourceKind
    let displayName: String
    let originalFilename: String
    let identity: AttachedDataFileIdentity
    let modificationDate: Date
}

private struct AttachedDataPreparedSnapshot {
    let directory: URL
    let url: URL
    let sourceDigest: String
}
