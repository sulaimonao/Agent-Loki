import Darwin
import Foundation

enum P8FSignedSmokeStorageBoundaryFailure: Error, Equatable, Sendable {
    case invalidRoot
    case escapedRoot
    case invalidDirectory
    case invalidFile
    case traversalLimitExceeded
    case ioFailure
}

/// A descriptor-anchored containment boundary for the signed-smoke storage
/// tree. Paths remain lexical descendants of the admitted root; symlink
/// resolution is never used to turn an untrusted path into an I/O target.
struct P8FSignedSmokeStorageBoundary: Sendable {
    private final class AdmissionIdentity: @unchecked Sendable {}

    struct DirectoryIdentitySnapshot: Sendable {
        fileprivate let directoryURL: URL
        fileprivate let device: Int64
        fileprivate let inode: UInt64
        fileprivate let owner: UInt32
        fileprivate let fileType: UInt32
        fileprivate let permissions: UInt32
        fileprivate let linkCount: UInt64

        fileprivate init(
            directoryURL: URL,
            information: stat
        ) {
            self.directoryURL = directoryURL
            device = Int64(information.st_dev)
            inode = UInt64(information.st_ino)
            owner = information.st_uid
            fileType = UInt32(information.st_mode & S_IFMT)
            permissions = UInt32(information.st_mode & 0o7777)
            linkCount = UInt64(information.st_nlink)
        }

        fileprivate func matches(_ information: stat) -> Bool {
            device == Int64(information.st_dev)
                && inode == UInt64(information.st_ino)
                && owner == information.st_uid
                && fileType == UInt32(information.st_mode & S_IFMT)
                && permissions == UInt32(information.st_mode & 0o7777)
                // A directory's link count changes when its admitted children
                // change. Device + inode is the stable same-object identity;
                // both observed link counts must remain live.
                && linkCount > 0
                && information.st_nlink > 0
        }
    }

    struct SQLiteIdentitySnapshot: Sendable {
        fileprivate struct Item: Equatable, Sendable {
            let device: Int64
            let inode: UInt64
            let owner: UInt32
            let fileType: UInt32
            let permissions: UInt32
            let linkCount: UInt64

            init(_ information: stat) {
                device = Int64(information.st_dev)
                inode = UInt64(information.st_ino)
                owner = information.st_uid
                fileType = UInt32(information.st_mode & S_IFMT)
                permissions = UInt32(information.st_mode & 0o7777)
                linkCount = UInt64(information.st_nlink)
            }

            /// Directory link counts change when an authorized child
            /// directory is created or removed. Freeze every security-relevant
            /// directory attribute while allowing that expected bookkeeping
            /// change; SQLite family members still compare the full Item,
            /// including link count.
            func matchesDirectory(_ other: Self) -> Bool {
                device == other.device
                    && inode == other.inode
                    && owner == other.owner
                    && fileType == other.fileType
                    && permissions == other.permissions
                    && linkCount > 0
                    && other.linkCount > 0
            }
        }

        fileprivate struct FamilyMember: Sendable {
            let name: String
            let item: Item?
        }

        fileprivate let databaseURL: URL
        fileprivate let parentDirectory: Item
        fileprivate let family: [FamilyMember]
        fileprivate let freezesSidecars: Bool
    }

    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    private static let maximumTreeDepth = 64
    private static let maximumTreeNodeCount = 50_000

    let rootURL: URL
    private let admissionIdentity: AdmissionIdentity
    private let rootDevice: Int32
    private let rootInode: UInt64
    private let rootOwner: UInt32

    init(
        admitting rootURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let requestedRoot = LokiCanonicalFileURL.lexical(
            rootURL,
            isDirectory: true
        )
        guard let root = LokiCanonicalFileURL.existing(
                requestedRoot,
                isDirectory: true
              ),
              root == requestedRoot,
              root.isFileURL,
              let information = try Self.itemInformation(at: root),
              Self.fileType(information) == S_IFDIR,
              Self.permissions(information) == Self.directoryPermissions,
              information.st_uid == geteuid()
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidRoot
        }
        self.rootURL = root
        admissionIdentity = AdmissionIdentity()
        rootDevice = information.st_dev
        rootInode = information.st_ino
        rootOwner = information.st_uid
        try validateCurrentRoot(fileManager: fileManager)
    }

    /// Returns true only for value copies of the same descriptor-admitted
    /// boundary. Independently admitting the same pathname mints a different
    /// identity and therefore returns false.
    func sharesAdmissionIdentity(
        with other: P8FSignedSmokeStorageBoundary
    ) -> Bool {
        admissionIdentity === other.admissionIdentity
    }

    func validateCurrentRoot(
        fileManager _: FileManager = .default
    ) throws {
        let descriptor = rootURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidRoot
        }
        defer { _ = Darwin.close(descriptor) }
        try validateRootDescriptor(descriptor)
    }

    func auditExistingTree(
        fileManager: FileManager = .default
    ) throws {
        try withRootDescriptor { descriptor in
            var nodeCount = 1
            try validateTree(
                descriptor: descriptor,
                path: rootURL.path,
                depth: 0,
                nodeCount: &nodeCount,
                fileManager: fileManager
            )
        }
    }

    @discardableResult
    func ensurePrivateDirectory(
        at candidateURL: URL,
        fileManager _: FileManager = .default
    ) throws -> URL {
        let candidate = LokiCanonicalFileURL.lexical(
            candidateURL,
            isDirectory: true
        )
        let components = try relativeComponents(
            for: candidate,
            allowRoot: true
        )
        try withRootDescriptor { rootDescriptor in
            let descriptor = try openDirectory(
                components: components,
                rootDescriptor: rootDescriptor,
                createIfMissing: true
            )
            _ = Darwin.close(descriptor)
        }
        return candidate
    }

    func validatePrivateDirectory(
        at candidateURL: URL,
        fileManager _: FileManager = .default
    ) throws {
        let components = try relativeComponents(
            for: LokiCanonicalFileURL.lexical(
                candidateURL,
                isDirectory: true
            ),
            allowRoot: true
        )
        try withRootDescriptor { rootDescriptor in
            let descriptor = try openDirectory(
                components: components,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            _ = Darwin.close(descriptor)
        }
    }

    func validatePrivateFile(
        at candidateURL: URL,
        required: Bool,
        fileManager _: FileManager = .default
    ) throws {
        let candidate = LokiCanonicalFileURL.lexical(candidateURL)
        let parentComponents = try relativeComponents(
            for: candidate.deletingLastPathComponent(),
            allowRoot: true
        )
        let name = try Self.validatedName(candidate.lastPathComponent)
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            let information = try Self.itemInformation(
                named: name,
                in: parentDescriptor
            )
            guard let information else {
                if required {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
                return
            }
            try validatePrivateFileInformation(information)
        }
    }

    func validateSQLiteFamily(
        at databaseURL: URL,
        requireDatabase: Bool,
        fileManager _: FileManager = .default
    ) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let names = try Self.databaseFamilyNames(for: database)
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            for (index, name) in names.enumerated() {
                let information = try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                )
                guard let information else {
                    if index == 0, requireDatabase {
                        throw P8FSignedSmokeStorageBoundaryFailure
                            .invalidFile
                    }
                    continue
                }
                try validatePrivateFileInformation(information)
            }
        }
    }

    /// Applies the private-file mode through no-follow descriptors after a
    /// database open, then revalidates every existing family member.
    func secureSQLiteFamily(
        at databaseURL: URL,
        requireDatabase: Bool,
        fileManager: FileManager = .default
    ) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let names = try Self.databaseFamilyNames(for: database)
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            for (index, name) in names.enumerated() {
                guard let before = try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                ) else {
                    if index == 0, requireDatabase {
                        throw P8FSignedSmokeStorageBoundaryFailure
                            .invalidFile
                    }
                    continue
                }
                guard Self.fileType(before) == S_IFREG,
                      before.st_dev == rootDevice,
                      before.st_uid == rootOwner,
                      before.st_nlink == 1
                else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
                let descriptor = name.withCString {
                    Darwin.openat(
                        parentDescriptor,
                        $0,
                        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
                    )
                }
                guard descriptor >= 0 else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
                defer { _ = Darwin.close(descriptor) }
                var opened = stat()
                guard Darwin.fstat(descriptor, &opened) == 0,
                      opened.st_dev == before.st_dev,
                      opened.st_ino == before.st_ino,
                      Self.fileType(opened) == S_IFREG,
                      opened.st_uid == rootOwner,
                      opened.st_nlink == 1,
                      Darwin.fchmod(
                          descriptor,
                          mode_t(Self.filePermissions)
                      ) == 0
                else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
            }
        }
        try validateSQLiteFamily(
            at: database,
            requireDatabase: requireDatabase,
            fileManager: fileManager
        )
    }

    /// Freezes the exact descriptor-observed identity of the semantic parent
    /// directory and every present SQLite family member. Missing WAL/SHM files
    /// are frozen as absent, so later same-path creation is also detected.
    func captureSQLiteIdentity(
        at databaseURL: URL,
        freezeSidecars: Bool = true
    ) throws -> SQLiteIdentitySnapshot {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let familyNames = try Self.databaseFamilyNames(for: database)
        let names = freezeSidecars
            ? familyNames
            : [familyNames[0]]
        return try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            var parentInformation = stat()
            guard Darwin.fstat(
                parentDescriptor,
                &parentInformation
            ) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            try validatePrivateDirectoryInformation(parentInformation)

            let family = try names.map { name in
                let information = try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                )
                if let information {
                    try validatePrivateFileInformation(information)
                }
                return SQLiteIdentitySnapshot.FamilyMember(
                    name: name,
                    item: information.map(SQLiteIdentitySnapshot.Item.init)
                )
            }
            guard family.first?.item != nil else {
                throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
            }
            return SQLiteIdentitySnapshot(
                databaseURL: database,
                parentDirectory: .init(parentInformation),
                family: family,
                freezesSidecars: freezeSidecars
            )
        }
    }

    /// Reopens the admitted path through no-follow descriptors and compares
    /// exact device/inode/owner/type/mode/link-count identity with a frozen
    /// snapshot.
    func validateSQLiteIdentity(
        _ snapshot: SQLiteIdentitySnapshot,
        at databaseURL: URL
    ) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        guard database == snapshot.databaseURL else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let familyNames = try Self.databaseFamilyNames(for: database)
        let expectedNames = snapshot.freezesSidecars
            ? familyNames
            : [familyNames[0]]
        guard snapshot.family.map(\.name) == expectedNames else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            var parentInformation = stat()
            guard Darwin.fstat(
                parentDescriptor,
                &parentInformation
            ) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            try validatePrivateDirectoryInformation(parentInformation)
            guard snapshot.parentDirectory.matchesDirectory(
                    SQLiteIdentitySnapshot.Item(parentInformation)
                  )
            else {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .invalidDirectory
            }

            for expected in snapshot.family {
                let information = try Self.itemInformation(
                    named: expected.name,
                    in: parentDescriptor
                )
                if let information {
                    try validatePrivateFileInformation(information)
                }
                guard information.map(SQLiteIdentitySnapshot.Item.init)
                        == expected.item
                else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
            }
        }
    }

    /// After an authorized SQLite owner closes its connection, recapture the
    /// now-stable sidecars while proving that the primary database and parent
    /// directory are still the originally admitted objects.
    func captureClosedSQLiteIdentity(
        at databaseURL: URL,
        matchingPrimary snapshot: SQLiteIdentitySnapshot
    ) throws -> SQLiteIdentitySnapshot {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        guard database == snapshot.databaseURL,
              let expectedPrimary = snapshot.family.first,
              expectedPrimary.name == database.lastPathComponent,
              expectedPrimary.item != nil
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
        let closed = try captureSQLiteIdentity(
            at: database,
            freezeSidecars: true
        )
        guard snapshot.parentDirectory.matchesDirectory(
                closed.parentDirectory
              ),
              closed.family.first?.name == expectedPrimary.name,
              closed.family.first?.item == expectedPrimary.item
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
        return closed
    }

    func removeSQLiteFamily(
        at databaseURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        try validateSQLiteFamily(
            at: database,
            requireDatabase: false,
            fileManager: fileManager
        )
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let names = try Self.databaseFamilyNames(for: database)
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            for name in names {
                guard let information = try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                ) else {
                    continue
                }
                try validatePrivateFileInformation(information)
                let result = name.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, 0)
                }
                guard result == 0 else {
                    throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
                }
            }
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
        }
    }

    /// Removes only the exact SQLite family frozen in `identity`. The primary
    /// database must still be the admitted inode; WAL/SHM members may have
    /// disappeared as a consequence of closing SQLite, but a replacement at
    /// either sidecar pathname is never accepted. This is the signed-smoke
    /// cleanup route and prevents a same-path successor family from inheriting
    /// an older operation's deletion authority.
    func removeSQLiteFamily(
        at databaseURL: URL,
        matching identity: SQLiteIdentitySnapshot
    ) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        guard database == identity.databaseURL else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let names = try Self.databaseFamilyNames(for: database)
        guard identity.family.map(\.name) == names else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            var parentInformation = stat()
            guard Darwin.fstat(
                parentDescriptor,
                &parentInformation
            ) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            try validatePrivateDirectoryInformation(parentInformation)
            guard identity.parentDirectory.matchesDirectory(
                    SQLiteIdentitySnapshot.Item(parentInformation)
                  )
            else {
                throw P8FSignedSmokeStorageBoundaryFailure.invalidDirectory
            }

            for (index, expected) in identity.family.enumerated() {
                let information = try Self.itemInformation(
                    named: expected.name,
                    in: parentDescriptor
                )
                if let information {
                    try validatePrivateFileInformation(information)
                    guard expected.item
                            == SQLiteIdentitySnapshot.Item(information)
                    else {
                        throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                    }
                } else if index == 0 {
                    // The admitted primary database may never disappear before
                    // cleanup. Sidecars may legitimately disappear when the
                    // SQLite connection closes.
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
            }

            for expected in identity.family {
                guard try Self.itemInformation(
                    named: expected.name,
                    in: parentDescriptor
                ) != nil else {
                    continue
                }
                let result = expected.name.withCString {
                    Darwin.unlinkat(parentDescriptor, $0, 0)
                }
                guard result == 0 else {
                    throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
                }
            }
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            for name in names {
                guard try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                ) == nil else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
            }
        }
    }

    /// Proves that no member of the named SQLite family currently exists.
    /// Reset/recreation code uses this after an authority-bound deletion so it
    /// cannot silently delete or replace a successor family.
    func validateSQLiteFamilyAbsent(at databaseURL: URL) throws {
        let database = LokiCanonicalFileURL.lexical(databaseURL)
        let parentComponents = try relativeComponents(
            for: database.deletingLastPathComponent(),
            allowRoot: true
        )
        let names = try Self.databaseFamilyNames(for: database)
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            for name in names {
                guard try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                ) == nil else {
                    throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
                }
            }
        }
    }

    func validatePrivateTree(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = LokiCanonicalFileURL.lexical(
            directoryURL,
            isDirectory: true
        )
        let components = try relativeComponents(
            for: directory,
            allowRoot: true
        )
        try withRootDescriptor { rootDescriptor in
            let descriptor = try openDirectory(
                components: components,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(descriptor) }
            var nodeCount = 1
            try validateTree(
                descriptor: descriptor,
                path: directory.path,
                depth: 0,
                nodeCount: &nodeCount,
                fileManager: fileManager
            )
        }
    }

    /// Freezes the exact descriptor-observed directory object at an admitted
    /// path. The resulting capability is safe to retain across cancellation:
    /// a later same-path directory is a different inode and is not cleanup
    /// eligible.
    func captureDirectoryIdentity(
        at directoryURL: URL
    ) throws -> DirectoryIdentitySnapshot {
        guard let identity = try captureDirectoryIdentityIfPresent(
            at: directoryURL
        ) else {
            throw P8FSignedSmokeStorageBoundaryFailure
                .invalidDirectory
        }
        return identity
    }

    /// Descriptor-proves either exact directory identity or absence at an
    /// admitted path. Symlinks and non-directory entries are invalid rather
    /// than being treated as absence.
    func captureDirectoryIdentityIfPresent(
        at directoryURL: URL
    ) throws -> DirectoryIdentitySnapshot? {
        let directory = LokiCanonicalFileURL.lexical(
            directoryURL,
            isDirectory: true
        )
        let components = try relativeComponents(
            for: directory,
            allowRoot: false
        )
        guard let name = components.last else {
            throw P8FSignedSmokeStorageBoundaryFailure
                .escapedRoot
        }
        let parentComponents = Array(components.dropLast())
        return try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            guard let observed = try Self.itemInformation(
                named: name,
                in: parentDescriptor
            ) else {
                return nil
            }
            try validatePrivateDirectoryInformation(observed)
            let descriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .invalidDirectory
            }
            defer { _ = Darwin.close(descriptor) }
            var information = stat()
            guard Darwin.fstat(descriptor, &information) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            try validatePrivateDirectoryInformation(information)
            let identity = DirectoryIdentitySnapshot(
                directoryURL: directory,
                information: information
            )
            guard identity.matches(observed) else {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .invalidDirectory
            }
            return identity
        }
    }

    func validateDirectoryIdentity(
        _ identity: DirectoryIdentitySnapshot,
        at directoryURL: URL
    ) throws {
        let directory = LokiCanonicalFileURL.lexical(
            directoryURL,
            isDirectory: true
        )
        guard directory == identity.directoryURL else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        let current = try captureDirectoryIdentity(at: directory)
        guard current.device == identity.device,
              current.inode == identity.inode,
              current.owner == identity.owner,
              current.fileType == identity.fileType,
              current.permissions == identity.permissions,
              current.linkCount > 0,
              identity.linkCount > 0
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidDirectory
        }
    }

    func removePrivateTree(
        at directoryURL: URL,
        fileManager: FileManager = .default
    ) throws {
        let directory = LokiCanonicalFileURL.lexical(
            directoryURL,
            isDirectory: true
        )
        let components = try relativeComponents(
            for: directory,
            allowRoot: false
        )
        guard let name = components.last else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        let parentComponents = Array(components.dropLast())
        let exists = try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            return try Self.itemInformation(
                named: name,
                in: parentDescriptor
            ) != nil
        }
        guard exists else { return }
        try validatePrivateTree(
            at: directory,
            fileManager: fileManager
        )
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            try removeTreeEntry(
                named: name,
                path: directory.path,
                parentDescriptor: parentDescriptor,
                depth: 0,
                fileManager: fileManager
            )
            guard Darwin.fsync(parentDescriptor) == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
        }
    }

    /// Removes only the exact directory object represented by `identity`.
    /// Replacing the directory at the same path invalidates this cleanup
    /// authority and preserves the successor tree.
    func removePrivateTree(
        at directoryURL: URL,
        matching identity: DirectoryIdentitySnapshot,
        fileManager: FileManager = .default
    ) throws {
        let directory = LokiCanonicalFileURL.lexical(
            directoryURL,
            isDirectory: true
        )
        guard directory == identity.directoryURL else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        let components = try relativeComponents(
            for: directory,
            allowRoot: false
        )
        guard let name = components.last else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        try validateDirectoryIdentity(identity, at: directory)
        try validatePrivateTree(at: directory, fileManager: fileManager)
        let parentComponents = Array(components.dropLast())
        try withRootDescriptor { rootDescriptor in
            let parentDescriptor = try openDirectory(
                components: parentComponents,
                rootDescriptor: rootDescriptor,
                createIfMissing: false
            )
            defer { _ = Darwin.close(parentDescriptor) }
            try removeTreeEntry(
                named: name,
                path: directory.path,
                parentDescriptor: parentDescriptor,
                depth: 0,
                fileManager: fileManager,
                expectedRootIdentity: identity
            )
            guard Darwin.fsync(parentDescriptor) == 0,
                  try Self.itemInformation(
                    named: name,
                    in: parentDescriptor
                  ) == nil
            else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
        }
    }

    private func withRootDescriptor<T>(
        _ body: (Int32) throws -> T
    ) throws -> T {
        let descriptor = rootURL.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidRoot
        }
        defer { _ = Darwin.close(descriptor) }
        try validateRootDescriptor(descriptor)
        return try body(descriptor)
    }

    private func validateRootDescriptor(_ descriptor: Int32) throws {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              Self.fileType(information) == S_IFDIR,
              Self.permissions(information) == Self.directoryPermissions,
              information.st_dev == rootDevice,
              information.st_ino == rootInode,
              information.st_uid == rootOwner
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidRoot
        }
    }

    private func relativeComponents(
        for candidate: URL,
        allowRoot: Bool
    ) throws -> [String] {
        let rootComponents = rootURL.pathComponents
        let candidateComponents = LokiCanonicalFileURL.lexical(
            candidate,
            isDirectory: candidate.hasDirectoryPath
        ).pathComponents
        guard candidateComponents.starts(with: rootComponents),
              allowRoot
                ? candidateComponents.count >= rootComponents.count
                : candidateComponents.count > rootComponents.count
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        return try candidateComponents
            .dropFirst(rootComponents.count)
            .map(Self.validatedName)
    }

    private func openDirectory(
        components: [String],
        rootDescriptor: Int32,
        createIfMissing: Bool
    ) throws -> Int32 {
        var current = Darwin.dup(rootDescriptor)
        guard current >= 0 else {
            throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
        }
        do {
            for component in components {
                if createIfMissing {
                    let result = component.withCString {
                        Darwin.mkdirat(
                            current,
                            $0,
                            mode_t(Self.directoryPermissions)
                        )
                    }
                    guard result == 0 || errno == EEXIST else {
                        throw P8FSignedSmokeStorageBoundaryFailure
                            .ioFailure
                    }
                }
                let next = component.withCString {
                    Darwin.openat(
                        current,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC
                            | O_NOFOLLOW
                    )
                }
                guard next >= 0 else {
                    throw P8FSignedSmokeStorageBoundaryFailure
                        .invalidDirectory
                }
                var information = stat()
                guard Darwin.fstat(next, &information) == 0,
                      Self.fileType(information) == S_IFDIR,
                      Self.permissions(information)
                        == Self.directoryPermissions,
                      information.st_dev == rootDevice,
                      information.st_uid == rootOwner
                else {
                    _ = Darwin.close(next)
                    throw P8FSignedSmokeStorageBoundaryFailure
                        .invalidDirectory
                }
                _ = Darwin.close(current)
                current = next
            }
            return current
        } catch {
            _ = Darwin.close(current)
            throw error
        }
    }

    private func validateTree(
        descriptor: Int32,
        path: String,
        depth: Int,
        nodeCount: inout Int,
        fileManager: FileManager
    ) throws {
        guard depth <= Self.maximumTreeDepth else {
            throw P8FSignedSmokeStorageBoundaryFailure
                .traversalLimitExceeded
        }
        let names: [String]
        do {
            names = try fileManager.contentsOfDirectory(atPath: path)
                .sorted()
        } catch {
            throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
        }
        for rawName in names {
            let name = try Self.validatedName(rawName)
            nodeCount += 1
            guard nodeCount <= Self.maximumTreeNodeCount,
                  let information = try Self.itemInformation(
                      named: name,
                      in: descriptor
                  )
            else {
                throw P8FSignedSmokeStorageBoundaryFailure
                    .traversalLimitExceeded
            }
            switch Self.fileType(information) {
            case S_IFDIR:
                try validatePrivateDirectoryInformation(information)
                let childDescriptor = name.withCString {
                    Darwin.openat(
                        descriptor,
                        $0,
                        O_RDONLY | O_DIRECTORY | O_CLOEXEC
                            | O_NOFOLLOW
                    )
                }
                guard childDescriptor >= 0 else {
                    throw P8FSignedSmokeStorageBoundaryFailure
                        .invalidDirectory
                }
                let childPath = URL(
                    fileURLWithPath: path,
                    isDirectory: true
                ).appendingPathComponent(
                    name,
                    isDirectory: true
                ).path
                do {
                    try validateTree(
                        descriptor: childDescriptor,
                        path: childPath,
                        depth: depth + 1,
                        nodeCount: &nodeCount,
                        fileManager: fileManager
                    )
                    _ = Darwin.close(childDescriptor)
                } catch {
                    _ = Darwin.close(childDescriptor)
                    throw error
                }
            case S_IFREG:
                try validatePrivateFileInformation(information)
            default:
                throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
            }
        }
    }

    private func removeTreeEntry(
        named name: String,
        path: String,
        parentDescriptor: Int32,
        depth: Int,
        fileManager: FileManager,
        expectedRootIdentity: DirectoryIdentitySnapshot? = nil
    ) throws {
        guard depth <= Self.maximumTreeDepth,
              let information = try Self.itemInformation(
                  named: name,
                  in: parentDescriptor
              )
        else {
            throw P8FSignedSmokeStorageBoundaryFailure
                .traversalLimitExceeded
        }
        if let expectedRootIdentity,
           !expectedRootIdentity.matches(information) {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidDirectory
        }
        switch Self.fileType(information) {
        case S_IFREG:
            try validatePrivateFileInformation(information)
            let result = name.withCString {
                Darwin.unlinkat(parentDescriptor, $0, 0)
            }
            guard result == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
        case S_IFDIR:
            try validatePrivateDirectoryInformation(information)
            let descriptor = name.withCString {
                Darwin.openat(
                    parentDescriptor,
                    $0,
                    O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
                )
            }
            guard descriptor >= 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.invalidDirectory
            }
            let childNames: [String]
            do {
                childNames = try fileManager
                    .contentsOfDirectory(atPath: path)
                    .sorted()
            } catch {
                _ = Darwin.close(descriptor)
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
            do {
                for childName in childNames {
                    let validatedChildName = try Self.validatedName(
                        childName
                    )
                    let childPath = URL(
                        fileURLWithPath: path,
                        isDirectory: true
                    ).appendingPathComponent(validatedChildName).path
                    try removeTreeEntry(
                        named: validatedChildName,
                        path: childPath,
                        parentDescriptor: descriptor,
                        depth: depth + 1,
                        fileManager: fileManager,
                        expectedRootIdentity: nil
                    )
                }
                guard Darwin.fsync(descriptor) == 0,
                      Darwin.close(descriptor) == 0
                else {
                    throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
                }
            } catch {
                _ = Darwin.close(descriptor)
                throw error
            }
            let result = name.withCString {
                Darwin.unlinkat(parentDescriptor, $0, AT_REMOVEDIR)
            }
            guard result == 0 else {
                throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
            }
        default:
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
    }

    private func validatePrivateDirectoryInformation(
        _ information: stat
    ) throws {
        guard Self.fileType(information) == S_IFDIR,
              Self.permissions(information) == Self.directoryPermissions,
              information.st_dev == rootDevice,
              information.st_uid == rootOwner
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidDirectory
        }
    }

    private func validatePrivateFileInformation(
        _ information: stat
    ) throws {
        guard Self.fileType(information) == S_IFREG,
              Self.permissions(information) == Self.filePermissions,
              information.st_dev == rootDevice,
              information.st_uid == rootOwner,
              information.st_nlink == 1
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.invalidFile
        }
    }

    private static func databaseFamilyNames(
        for databaseURL: URL
    ) throws -> [String] {
        let name = try validatedName(databaseURL.lastPathComponent)
        return [name, name + "-wal", name + "-shm"]
    }

    private static func validatedName(_ name: String) throws -> String {
        guard !name.isEmpty,
              name != ".",
              name != "..",
              !name.contains("/")
        else {
            throw P8FSignedSmokeStorageBoundaryFailure.escapedRoot
        }
        return name
    }

    private static func itemInformation(at URL: URL) throws -> stat? {
        var information = stat()
        let result = URL.path.withCString {
            Darwin.lstat($0, &information)
        }
        if result == 0 {
            return information
        }
        guard errno == ENOENT else {
            throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
        }
        return nil
    }

    private static func itemInformation(
        named name: String,
        in descriptor: Int32
    ) throws -> stat? {
        var information = stat()
        let result = name.withCString {
            Darwin.fstatat(
                descriptor,
                $0,
                &information,
                AT_SYMLINK_NOFOLLOW
            )
        }
        if result == 0 {
            return information
        }
        guard errno == ENOENT else {
            throw P8FSignedSmokeStorageBoundaryFailure.ioFailure
        }
        return nil
    }

    private static func fileType(_ information: stat) -> mode_t {
        information.st_mode & S_IFMT
    }

    private static func permissions(_ information: stat) -> Int {
        Int(information.st_mode & 0o7777)
    }
}

enum P8FSignedSmokeControlScenario: String, Codable, CaseIterable, Sendable {
    case semanticSourceProof = "semantic_source_proof"
    case modelAssessment = "model_assessment"
    case search
    case hydration
    case cleanup
}

struct P8FSignedSmokeControlPlan: Codable, Equatable, Sendable {
    static let currentContractVersion =
        "agent-loki.p8f.signed-smoke-control.v1"

    let contractVersion: String
    let runIdentifier: String
    let scenario: P8FSignedSmokeControlScenario
    let expectedFixtureManifestSHA256: String
    let expectedExecutableSHA256: String?
    let modelIdentifier: String?
    let modelDigest: String?

    init(
        contractVersion: String = Self.currentContractVersion,
        runIdentifier: String,
        scenario: P8FSignedSmokeControlScenario,
        expectedFixtureManifestSHA256: String,
        expectedExecutableSHA256: String? = nil,
        modelIdentifier: String? = nil,
        modelDigest: String? = nil
    ) {
        self.contractVersion = contractVersion
        self.runIdentifier = runIdentifier
        self.scenario = scenario
        self.expectedFixtureManifestSHA256 =
            expectedFixtureManifestSHA256
        self.expectedExecutableSHA256 = expectedExecutableSHA256
        self.modelIdentifier = modelIdentifier
        self.modelDigest = modelDigest
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case contractVersion
        case runIdentifier
        case scenario
        case expectedFixtureManifestSHA256
        case expectedExecutableSHA256
        case modelIdentifier
        case modelDigest
    }

    init(from decoder: Decoder) throws {
        let rawContainer = try decoder.container(
            keyedBy: P8FSignedSmokeAnyCodingKey.self
        )
        let allowedKeys = Set(CodingKeys.allCases.map(\.rawValue))
        guard rawContainer.allKeys.allSatisfy({
            allowedKeys.contains($0.stringValue)
        }) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription:
                    "The P8F signed-smoke plan contains an unknown field."
            ))
        }

        let container = try decoder.container(keyedBy: CodingKeys.self)
        contractVersion = try container.decode(
            String.self,
            forKey: .contractVersion
        )
        runIdentifier = try container.decode(
            String.self,
            forKey: .runIdentifier
        )
        scenario = try container.decode(
            P8FSignedSmokeControlScenario.self,
            forKey: .scenario
        )
        expectedFixtureManifestSHA256 = try container.decode(
            String.self,
            forKey: .expectedFixtureManifestSHA256
        )
        expectedExecutableSHA256 = try container.decodeIfPresent(
            String.self,
            forKey: .expectedExecutableSHA256
        )
        modelIdentifier = try container.decodeIfPresent(
            String.self,
            forKey: .modelIdentifier
        )
        modelDigest = try container.decodeIfPresent(
            String.self,
            forKey: .modelDigest
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(contractVersion, forKey: .contractVersion)
        try container.encode(runIdentifier, forKey: .runIdentifier)
        try container.encode(scenario, forKey: .scenario)
        try container.encode(
            expectedFixtureManifestSHA256,
            forKey: .expectedFixtureManifestSHA256
        )
        try container.encodeIfPresent(
            expectedExecutableSHA256,
            forKey: .expectedExecutableSHA256
        )
        try container.encodeIfPresent(
            modelIdentifier,
            forKey: .modelIdentifier
        )
        try container.encodeIfPresent(
            modelDigest,
            forKey: .modelDigest
        )
    }

    func validate() throws {
        guard contractVersion == Self.currentContractVersion,
              Self.validRunIdentifier(runIdentifier),
              Self.validSHA256(expectedFixtureManifestSHA256),
              expectedExecutableSHA256.map(Self.validSHA256) ?? true
        else {
            throw P8FSignedSmokeAdmissionFailure.planContractInvalid
        }

        switch scenario {
        case .modelAssessment:
            guard let modelIdentifier,
                  Self.validModelIdentifier(modelIdentifier),
                  let modelDigest,
                  Self.validSHA256(modelDigest)
            else {
                throw P8FSignedSmokeAdmissionFailure.planContractInvalid
            }
        case .semanticSourceProof, .search, .hydration, .cleanup:
            guard modelIdentifier == nil, modelDigest == nil else {
                throw P8FSignedSmokeAdmissionFailure.planContractInvalid
            }
        }
    }

    private static func validSHA256(_ value: String) -> Bool {
        value.count == 64
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (97...102).contains($0.value)
            }
    }

    private static func validRunIdentifier(_ value: String) -> Bool {
        (1...128).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (97...122).contains($0.value)
                    || $0.value == 45
                    || $0.value == 95
            }
    }

    private static func validModelIdentifier(_ value: String) -> Bool {
        (1...256).contains(value.utf8.count)
            && value.unicodeScalars.allSatisfy {
                (48...57).contains($0.value)
                    || (65...90).contains($0.value)
                    || (97...122).contains($0.value)
                    || [45, 46, 47, 58, 95].contains($0.value)
            }
    }
}

private struct P8FSignedSmokeAnyCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

struct P8FSignedSmokeApplicationIdentity: Equatable, Sendable {
    static let required = P8FSignedSmokeApplicationIdentity(
        bundleIdentifier: "com.agentloki.LokiBrief.P8FResumeSmoke",
        marketingVersion: "1.0.0",
        buildVersion: "5"
    )

    let bundleIdentifier: String
    let marketingVersion: String
    let buildVersion: String
}

enum P8FSignedSmokeAdmissionCapability: String, Hashable, Sendable {
    case p8fControlV1 = "agent-loki.p8f.signed-smoke-control.v1"
}

enum P8FSignedSmokeRuntimeAuthorityFailure:
    String,
    Error,
    Equatable,
    Sendable
{
    case xctestProcessRequired =
        "p8f_signed_smoke_runtime_authority_xctest_required"
}

/// Opaque capability minted only after complete signed-smoke admission. The
/// bound storage boundary is compared by reference identity, not pathname.
final class P8FSignedSmokeRuntimeAuthority: @unchecked Sendable {
    private let storageBoundary: P8FSignedSmokeStorageBoundary?
    private let permitsXCTestInMemoryIndex: Bool

    fileprivate init(
        admittedStorageBoundary: P8FSignedSmokeStorageBoundary
    ) {
        storageBoundary = admittedStorageBoundary
        permitsXCTestInMemoryIndex = false
    }

#if DEBUG
    private init(xctestInMemory: Void) {
        storageBoundary = nil
        permitsXCTestInMemoryIndex = true
    }

    /// Explicit test-only authority for focused in-memory index tests. The
    /// construction route remains gated by the actual XCTest host process;
    /// normal app and signed-smoke runtime processes cannot mint it.
    static func makeXCTestInMemory() throws -> Self {
        guard ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil,
        NSClassFromString("XCTestCase") != nil,
        Bundle.allBundles.contains(where: {
            $0.bundleURL.pathExtension == "xctest"
        }) else {
            throw P8FSignedSmokeRuntimeAuthorityFailure
                .xctestProcessRequired
        }
        return .init(xctestInMemory: ())
    }
#endif

    func matches(
        storageBoundary candidate: P8FSignedSmokeStorageBoundary
    ) -> Bool {
        guard let storageBoundary else { return false }
        return storageBoundary.sharesAdmissionIdentity(with: candidate)
    }

    var permitsInMemoryIndex: Bool {
        permitsXCTestInMemoryIndex
    }
}

enum P8FSignedSmokeAdmissionFailure:
    String,
    Codable,
    Error,
    Equatable,
    Sendable
{
    case malformedArguments =
        "p8f_signed_smoke_admission_arguments_malformed"
    case duplicateControlSentinel =
        "p8f_signed_smoke_admission_control_duplicate"
    case controlSentinelMissing =
        "p8f_signed_smoke_admission_control_missing"
    case signedSmokeSentinelMissing =
        "p8f_signed_smoke_admission_storage_sentinel_missing"
    case signedSmokeSentinelDuplicate =
        "p8f_signed_smoke_admission_storage_sentinel_duplicate"
    case isolatedRootMissing =
        "p8f_signed_smoke_admission_root_missing"
    case isolatedRootDuplicate =
        "p8f_signed_smoke_admission_root_duplicate"
    case environmentIsolationRejected =
        "p8f_signed_smoke_admission_environment_isolation_rejected"
    case xctestRejected =
        "p8f_signed_smoke_admission_xctest_rejected"
    case capabilityMissing =
        "p8f_signed_smoke_admission_capability_missing"
    case applicationIdentityMismatch =
        "p8f_signed_smoke_admission_application_identity_mismatch"
    case storagePlanRejected =
        "p8f_signed_smoke_admission_storage_plan_rejected"
    case storageClassificationMismatch =
        "p8f_signed_smoke_admission_storage_classification_mismatch"
    case storagePairIntegrityInvalid =
        "p8f_signed_smoke_admission_storage_pair_integrity_invalid"
    case rootPermissionsInvalid =
        "p8f_signed_smoke_admission_root_permissions_invalid"
    case planMissing =
        "p8f_signed_smoke_admission_plan_missing"
    case planSymlinkRejected =
        "p8f_signed_smoke_admission_plan_symlink_rejected"
    case planNotRegular =
        "p8f_signed_smoke_admission_plan_not_regular"
    case planPermissionsInvalid =
        "p8f_signed_smoke_admission_plan_permissions_invalid"
    case planTooLarge =
        "p8f_signed_smoke_admission_plan_too_large"
    case planMalformed =
        "p8f_signed_smoke_admission_plan_malformed"
    case planContractInvalid =
        "p8f_signed_smoke_admission_plan_contract_invalid"
}

struct P8FSignedSmokeAdmission: Sendable {
    let storagePlan: LokiLaunchStoragePlan
    let storageBoundary: P8FSignedSmokeStorageBoundary
    let controlPlanURL: URL
    let controlPlan: P8FSignedSmokeControlPlan
    let runtimeAuthority: P8FSignedSmokeRuntimeAuthority

    fileprivate init(
        storagePlan: LokiLaunchStoragePlan,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        controlPlanURL: URL,
        controlPlan: P8FSignedSmokeControlPlan,
        runtimeAuthority: P8FSignedSmokeRuntimeAuthority
    ) {
        self.storagePlan = storagePlan
        self.storageBoundary = storageBoundary
        self.controlPlanURL = controlPlanURL
        self.controlPlan = controlPlan
        self.runtimeAuthority = runtimeAuthority
    }
}

enum P8FSignedSmokeAdmissionResolver {
    static let controlSentinel =
        "--loki-p8f-signed-smoke-control"
    static let controlPlanFileName =
        "p8f-signed-smoke-control.json"
    static let maximumControlPlanBytes = 32 * 1_024

    static func hasControlIntent(arguments: [String]) -> Bool {
        arguments.contains {
            $0 == controlSentinel
                || $0.hasPrefix(controlSentinel + "=")
        }
    }

    /// The sole production admission entrypoint. Identity, capability,
    /// arguments, environment, XCTest state, and path policy all come from the
    /// live process; callers cannot substitute values that mint authority.
    static func resolveProcessAdmission(
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeAdmission {
        let bundle = Bundle.main
        let identity = P8FSignedSmokeApplicationIdentity(
            bundleIdentifier: bundle.bundleIdentifier ?? "",
            marketingVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String ?? "",
            buildVersion: bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? ""
        )
        let capability = bundle.object(
            forInfoDictionaryKey:
                "LOKI_P8F_SIGNED_SMOKE_CONTROL_CAPABILITY"
        ) as? String
        return try resolveInjectedInputs(
            arguments: CommandLine.arguments,
            environment: ProcessInfo.processInfo.environment,
            isXCTest: actualXCTestProcess,
            applicationIdentity: identity,
            capabilities: capability
                == P8FSignedSmokeAdmissionCapability.p8fControlV1.rawValue
                ? [.p8fControlV1]
                : [],
            pathPolicy: .live(),
            fileManager: fileManager
        )
    }

#if DEBUG
    /// Raw admission inputs exist only for tests and still require the actual
    /// XCTest host. A Debug app process cannot use this route merely by passing
    /// XCTest-shaped values.
    static func resolveForXCTest(
        arguments: [String],
        environment: [String: String],
        simulateXCTestRejection: Bool = false,
        applicationIdentity: P8FSignedSmokeApplicationIdentity,
        capabilities: Set<P8FSignedSmokeAdmissionCapability>,
        pathPolicy: LokiLaunchStoragePathPolicy,
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeAdmission {
        guard actualXCTestProcess else {
            throw P8FSignedSmokeRuntimeAuthorityFailure
                .xctestProcessRequired
        }
        return try resolveInjectedInputs(
            arguments: arguments,
            environment: environment,
            isXCTest: simulateXCTestRejection,
            applicationIdentity: applicationIdentity,
            capabilities: capabilities,
            pathPolicy: pathPolicy,
            fileManager: fileManager
        )
    }
#endif

    private struct ParsedArguments {
        var controlSentinelCount = 0
        var signedSmokeSentinelCount = 0
        var isolatedRootValues: [String] = []
        var malformed = false
    }

    private static func resolveInjectedInputs(
        arguments: [String],
        environment: [String: String],
        isXCTest: Bool,
        applicationIdentity: P8FSignedSmokeApplicationIdentity,
        capabilities: Set<P8FSignedSmokeAdmissionCapability>,
        pathPolicy: LokiLaunchStoragePathPolicy = .live(),
        fileManager: FileManager = .default
    ) throws -> P8FSignedSmokeAdmission {
        guard !isXCTest else {
            throw P8FSignedSmokeAdmissionFailure.xctestRejected
        }
        guard environment.keys.contains(
            LokiLaunchStorageResolver.isolatedRootEnvironment
        ) == false else {
            throw P8FSignedSmokeAdmissionFailure
                .environmentIsolationRejected
        }
        guard capabilities.contains(.p8fControlV1) else {
            throw P8FSignedSmokeAdmissionFailure.capabilityMissing
        }
        guard applicationIdentity == .required else {
            throw P8FSignedSmokeAdmissionFailure
                .applicationIdentityMismatch
        }

        let parsed = parse(arguments: arguments)
        guard !parsed.malformed else {
            throw P8FSignedSmokeAdmissionFailure.malformedArguments
        }
        guard parsed.controlSentinelCount <= 1 else {
            throw P8FSignedSmokeAdmissionFailure
                .duplicateControlSentinel
        }
        guard parsed.controlSentinelCount == 1 else {
            throw P8FSignedSmokeAdmissionFailure
                .controlSentinelMissing
        }
        guard parsed.signedSmokeSentinelCount <= 1 else {
            throw P8FSignedSmokeAdmissionFailure
                .signedSmokeSentinelDuplicate
        }
        guard parsed.signedSmokeSentinelCount == 1 else {
            throw P8FSignedSmokeAdmissionFailure
                .signedSmokeSentinelMissing
        }
        guard parsed.isolatedRootValues.count <= 1 else {
            throw P8FSignedSmokeAdmissionFailure
                .isolatedRootDuplicate
        }
        guard parsed.isolatedRootValues.count == 1 else {
            throw P8FSignedSmokeAdmissionFailure.isolatedRootMissing
        }

        let resolvedStoragePlan = LokiLaunchStorageResolver.resolve(
            arguments: arguments,
            environment: environment,
            isXCTest: false,
            pathPolicy: pathPolicy,
            fileManager: fileManager
        )
        guard resolvedStoragePlan.isValid else {
            throw P8FSignedSmokeAdmissionFailure.storagePlanRejected
        }
        guard resolvedStoragePlan.classification
                == .signedSmokeIsolatedDisk,
              let resolvedRootURL = resolvedStoragePlan.rootURL,
              let rootURL = LokiCanonicalFileURL.existing(
                resolvedRootURL,
                isDirectory: true
              )
        else {
            throw P8FSignedSmokeAdmissionFailure
                .storageClassificationMismatch
        }
        let storagePlan = LokiLaunchStoragePlan(
            classification: resolvedStoragePlan.classification,
            rootURL: rootURL,
            swiftDataURL: rootURL.appendingPathComponent(
                "LokiBrief-v1.store",
                isDirectory: false
            ),
            vaultURL: rootURL
                .appendingPathComponent("Vault", isDirectory: true)
                .appendingPathComponent("v1", isDirectory: true)
                .appendingPathComponent(
                    "loki-vault.sqlite3",
                    isDirectory: false
                ),
            reasonCode: resolvedStoragePlan.reasonCode,
            evidence: resolvedStoragePlan.evidence
        )

        let rootAttributes: [FileAttributeKey: Any]
        do {
            rootAttributes = try fileManager.attributesOfItem(
                atPath: rootURL.path
            )
        } catch {
            throw P8FSignedSmokeAdmissionFailure.storagePlanRejected
        }
        guard rootAttributes[.type] as? FileAttributeType
                == .typeDirectory,
              permissions(rootAttributes) == 0o700
        else {
            throw P8FSignedSmokeAdmissionFailure
                .rootPermissionsInvalid
        }
        let storageBoundary: P8FSignedSmokeStorageBoundary
        do {
            storageBoundary = try P8FSignedSmokeStorageBoundary(
                admitting: rootURL,
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeAdmissionFailure
                .storagePairIntegrityInvalid
        }
        guard storagePairIntegrityIsValid(
            storagePlan,
            storageBoundary: storageBoundary,
            fileManager: fileManager
        ) else {
            throw P8FSignedSmokeAdmissionFailure
                .storagePairIntegrityInvalid
        }

        let planURL = rootURL.appendingPathComponent(
            controlPlanFileName,
            isDirectory: false
        )
        let planAttributes: [FileAttributeKey: Any]
        do {
            planAttributes = try fileManager.attributesOfItem(
                atPath: planURL.path
            )
        } catch {
            throw P8FSignedSmokeAdmissionFailure.planMissing
        }
        let planType = planAttributes[.type] as? FileAttributeType
        guard planType != .typeSymbolicLink else {
            throw P8FSignedSmokeAdmissionFailure.planSymlinkRejected
        }
        guard planType == .typeRegular else {
            throw P8FSignedSmokeAdmissionFailure.planNotRegular
        }
        guard permissions(planAttributes) == 0o600 else {
            throw P8FSignedSmokeAdmissionFailure
                .planPermissionsInvalid
        }
        guard let planSize = (planAttributes[.size] as? NSNumber)?
                .intValue,
              (1...maximumControlPlanBytes).contains(planSize)
        else {
            throw P8FSignedSmokeAdmissionFailure.planTooLarge
        }

        let data: Data
        do {
            data = try Data(contentsOf: planURL)
        } catch {
            throw P8FSignedSmokeAdmissionFailure.planMalformed
        }
        guard data.count == planSize else {
            throw P8FSignedSmokeAdmissionFailure.planMalformed
        }
        let plan: P8FSignedSmokeControlPlan
        do {
            plan = try JSONDecoder().decode(
                P8FSignedSmokeControlPlan.self,
                from: data
            )
        } catch {
            throw P8FSignedSmokeAdmissionFailure.planMalformed
        }
        try plan.validate()
        do {
            try storageBoundary.auditExistingTree(
                fileManager: fileManager
            )
        } catch {
            throw P8FSignedSmokeAdmissionFailure
                .storagePairIntegrityInvalid
        }

        return P8FSignedSmokeAdmission(
            storagePlan: storagePlan,
            storageBoundary: storageBoundary,
            controlPlanURL: planURL,
            controlPlan: plan,
            runtimeAuthority: P8FSignedSmokeRuntimeAuthority(
                admittedStorageBoundary: storageBoundary
            )
        )
    }

    private static var actualXCTestProcess: Bool {
        ProcessInfo.processInfo.environment[
            "XCTestConfigurationFilePath"
        ] != nil
            && NSClassFromString("XCTestCase") != nil
            && Bundle.allBundles.contains(where: {
                $0.bundleURL.pathExtension == "xctest"
            })
    }

    private static func parse(
        arguments: [String]
    ) -> ParsedArguments {
        var parsed = ParsedArguments()
        guard let executable = arguments.first,
              !executable.isEmpty,
              !executable.hasPrefix("--")
        else {
            parsed.malformed = true
            return parsed
        }

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case controlSentinel:
                parsed.controlSentinelCount += 1
            case LokiLaunchStorageResolver.signedSmokeSentinel:
                parsed.signedSmokeSentinelCount += 1
            case LokiLaunchStorageResolver.isolatedRootArgument:
                let valueIndex = index + 1
                guard valueIndex < arguments.count,
                      !arguments[valueIndex].hasPrefix("--")
                else {
                    parsed.malformed = true
                    index += 1
                    continue
                }
                parsed.isolatedRootValues.append(
                    arguments[valueIndex]
                )
                index = valueIndex
            default:
                parsed.malformed = true
            }
            index += 1
        }
        return parsed
    }

    private static func permissions(
        _ attributes: [FileAttributeKey: Any]
    ) -> Int? {
        if let number = attributes[.posixPermissions] as? NSNumber {
            return number.intValue & 0o7777
        }
        if let value = attributes[.posixPermissions] as? Int {
            return value & 0o7777
        }
        return nil
    }

    private static func storagePairIntegrityIsValid(
        _ storagePlan: LokiLaunchStoragePlan,
        storageBoundary: P8FSignedSmokeStorageBoundary,
        fileManager: FileManager
    ) -> Bool {
        guard let rawRoot = storagePlan.rootURL,
              let rawSwiftDataURL = storagePlan.swiftDataURL,
              let rawVaultURL = storagePlan.vaultURL
        else {
            return false
        }
        let root = LokiCanonicalFileURL.lexical(
            rawRoot,
            isDirectory: true
        )
        let swiftDataURL = LokiCanonicalFileURL.lexical(
            rawSwiftDataURL
        )
        let vaultURL = LokiCanonicalFileURL.lexical(rawVaultURL)
        let vaultRoot = root.appendingPathComponent(
            "Vault",
            isDirectory: true
        )
        let vaultVersion = vaultRoot.appendingPathComponent(
            "v1",
            isDirectory: true
        )
        let expectedSwiftData = root.appendingPathComponent(
            "LokiBrief-v1.store",
            isDirectory: false
        )
        let expectedVault = vaultVersion.appendingPathComponent(
            "loki-vault.sqlite3",
            isDirectory: false
        )
        guard swiftDataURL == expectedSwiftData,
              vaultURL == expectedVault,
              root == storageBoundary.rootURL
        else {
            return false
        }
        do {
            try storageBoundary.validatePrivateDirectory(
                at: vaultRoot,
                fileManager: fileManager
            )
            try storageBoundary.validatePrivateDirectory(
                at: vaultVersion,
                fileManager: fileManager
            )
            try storageBoundary.validateSQLiteFamily(
                at: swiftDataURL,
                requireDatabase: true,
                fileManager: fileManager
            )
            try storageBoundary.validateSQLiteFamily(
                at: vaultURL,
                requireDatabase: true,
                fileManager: fileManager
            )
            return true
        } catch {
            return false
        }
    }
}
