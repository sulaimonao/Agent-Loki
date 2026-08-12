import CryptoKit
import CoreFoundation
import Darwin
import Foundation

enum P8FSignedSmokeReceiptStoreFailure: Error, Equatable, Sendable {
    case invalidIsolatedRoot
    case isolatedRootMissing
    case isolatedRootNotDirectory
    case isolatedRootSymbolicLink
    case directoryPermissionsInvalid
    case fixedArtifactEscapedRoot
    case fixedArtifactSymbolicLink
    case fixedArtifactNotRegularFile
    case fixedArtifactPermissionsInvalid
    case fixedArtifactTooLarge
    case fixedArtifactAlreadyExists
    case malformedBuildSourceSelection
    case malformedSourceAuthorityReceipts
    case unsafeSourceAuthorityReceipt
    case payloadIntegrityMismatch
    case noncanonicalEncoding
    case unknownReceiptArtifact
    case artifactSchemaInvalid
    case diagnosticManifestInvalid
    case invalidTraceIdentifier
    case eventSequenceInvalid
    case eventChainInvalid
    case eventGraphInvalid
    case eventMetadataInvalid
    case terminalReceiptAlreadyWritten
    case terminalReceiptInvalid
    case ioFailure
}

enum P8FSignedSmokeReceiptLayout {
    static let directoryName = "P8FSignedSmokeReceipts.v1"
    static let buildSourceSelectionFileName =
        "semantic-build-source-selection.v1.json"
    static let sourceAuthorityReceiptsFileName =
        "semantic-source-authority-receipts.v1.json"
    static let eventsDirectoryName = "events.v1"
    static let diagnosticManifestFileName =
        "diagnostic-artifact-manifest.v1.json"
    static let terminalReceiptFileName = "terminal-receipt.v1.json"

    static func eventFileName(sequence: UInt64) -> String {
        let digits = String(sequence)
        let padding = String(
            repeating: "0",
            count: max(0, 20 - digits.count)
        )
        return padding + digits + ".json"
    }
}

private enum P8FSignedSmokeFixedArtifact {
    case buildSourceSelection
    case sourceAuthorityReceipts
    case diagnosticManifest
    case terminalReceipt

    var fileName: String {
        switch self {
        case .buildSourceSelection:
            P8FSignedSmokeReceiptLayout
                .buildSourceSelectionFileName
        case .sourceAuthorityReceipts:
            P8FSignedSmokeReceiptLayout
                .sourceAuthorityReceiptsFileName
        case .diagnosticManifest:
            P8FSignedSmokeReceiptLayout
                .diagnosticManifestFileName
        case .terminalReceipt:
            P8FSignedSmokeReceiptLayout.terminalReceiptFileName
        }
    }
}

private struct P8FSignedSmokeFilesystemIdentity: Equatable {
    let device: Int32
    let inode: UInt64
    let owner: UInt32
}

private struct P8FSignedSmokeReceiptRoot {
    static let directoryPermissions = 0o700
    static let filePermissions = 0o600

    let fileManager: FileManager
    let isolatedRoot: URL
    let receiptsDirectory: URL
    private let rootDevice: Int32
    private let rootInode: UInt64
    private let rootOwner: UInt32
    private var receiptsDevice: Int32 = 0
    private var receiptsInode: UInt64 = 0
    private var receiptsOwner: UInt32 = 0
    private var eventsIdentity:
        P8FSignedSmokeFilesystemIdentity? = nil

    init(
        isolatedRoot inputRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        guard inputRoot.isFileURL,
              NSString(string: inputRoot.path).isAbsolutePath
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .invalidIsolatedRoot
        }

        let standardized = inputRoot.standardizedFileURL
        guard try Self.itemExists(at: standardized) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .isolatedRootMissing
        }
        let inputAttributes: [FileAttributeKey: Any]
        do {
            inputAttributes = try fileManager.attributesOfItem(
                atPath: standardized.path
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        guard inputAttributes[.type] as? FileAttributeType
                != .typeSymbolicLink
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .isolatedRootSymbolicLink
        }
        guard inputAttributes[.type] as? FileAttributeType
                == .typeDirectory
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .isolatedRootNotDirectory
        }
        guard Self.permissions(inputAttributes)
                == Self.directoryPermissions
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .directoryPermissionsInvalid
        }

        let canonicalRoot = standardized
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let rootIdentity = try Self.directoryIdentity(
            at: canonicalRoot
        )
        self.fileManager = fileManager
        isolatedRoot = canonicalRoot
        receiptsDirectory = canonicalRoot.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.directoryName,
            isDirectory: true
        )
        rootDevice = rootIdentity.device
        rootInode = rootIdentity.inode
        rootOwner = rootIdentity.owner
        try Self.requireDirectChild(
            receiptsDirectory,
            of: canonicalRoot
        )
        try ensureDirectory(receiptsDirectory)
        let receiptsIdentity = try Self.directoryIdentity(
            at: receiptsDirectory
        )
        receiptsDevice = receiptsIdentity.device
        receiptsInode = receiptsIdentity.inode
        receiptsOwner = receiptsIdentity.owner
        try validateKnownReceiptLayout()
    }

    func fixedURL(
        for artifact: P8FSignedSmokeFixedArtifact
    ) throws -> URL {
        let url = receiptsDirectory.appendingPathComponent(
            artifact.fileName,
            isDirectory: false
        )
        try Self.requireDirectChild(url, of: receiptsDirectory)
        return url
    }

    func ensureEventsDirectory() throws -> URL {
        try validateKnownReceiptLayout()
        let url = receiptsDirectory.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.eventsDirectoryName,
            isDirectory: true
        )
        try Self.requireDirectChild(url, of: receiptsDirectory)
        if let eventsIdentity {
            guard try Self.directoryIdentity(at: url)
                    == eventsIdentity
            else {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
        } else {
            try ensureDirectory(url)
        }
        return url
    }

    mutating func freezeEventsDirectory() throws -> URL {
        let url = try ensureEventsDirectory()
        let identity = try Self.directoryIdentity(at: url)
        if let eventsIdentity {
            guard identity == eventsIdentity else {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
        } else {
            eventsIdentity = identity
        }
        return url
    }

    func read(
        _ artifact: P8FSignedSmokeFixedArtifact,
        maximumBytes: Int
    ) throws -> Data? {
        try validateKnownReceiptLayout()
        let url = try fixedURL(for: artifact)
        return try readRegularFile(
            at: url,
            in: receiptsDirectory,
            maximumBytes: maximumBytes
        )
    }

    func mutableIdentity(
        for artifact: P8FSignedSmokeFixedArtifact,
        maximumBytes: Int
    ) throws -> P8FSignedSmokeFilesystemIdentity? {
        try validateKnownReceiptLayout()
        let url = try fixedURL(for: artifact)
        guard try Self.itemExists(at: url) else {
            return nil
        }
        return try Self.regularFileIdentity(
            at: url,
            maximumBytes: maximumBytes
        )
    }

    func readMutable(
        _ artifact: P8FSignedSmokeFixedArtifact,
        expectedIdentity:
            P8FSignedSmokeFilesystemIdentity?,
        maximumBytes: Int
    ) throws -> Data? {
        guard try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        ) == expectedIdentity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        let data = try read(
            artifact,
            maximumBytes: maximumBytes
        )
        guard try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        ) == expectedIdentity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return data
    }

    func writeMutable(
        _ data: Data,
        to artifact: P8FSignedSmokeFixedArtifact,
        expectedIdentity:
            P8FSignedSmokeFilesystemIdentity?,
        maximumBytes: Int
    ) throws -> P8FSignedSmokeFilesystemIdentity {
        guard data.count <= maximumBytes else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactTooLarge
        }
        let url = try fixedURL(for: artifact)
        let currentIdentity = try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        )
        guard currentIdentity == expectedIdentity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        let replacesExisting = currentIdentity != nil
        if replacesExisting {
            _ = try readRegularFile(
                at: url,
                in: receiptsDirectory,
                maximumBytes: maximumBytes
            )
            guard try mutableIdentity(
                for: artifact,
                maximumBytes: maximumBytes
            ) == expectedIdentity else {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
        }
        // A same-UID replacement between this final identity check and the
        // pathname rename remains outside the guarantees of this API.
        try write(
            data,
            to: url,
            in: receiptsDirectory,
            replaceExisting: replacesExisting
        )
        guard let writtenIdentity = try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        ) else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return writtenIdentity
    }

    func writeImmutable(
        _ data: Data,
        to artifact: P8FSignedSmokeFixedArtifact,
        maximumBytes: Int
    ) throws {
        try validateKnownReceiptLayout()
        guard data.count <= maximumBytes else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactTooLarge
        }
        let url = try fixedURL(for: artifact)
        try write(
            data,
            to: url,
            in: receiptsDirectory,
            replaceExisting: false
        )
    }

    func removeMutable(
        _ artifact: P8FSignedSmokeFixedArtifact,
        expectedIdentity:
            P8FSignedSmokeFilesystemIdentity?,
        maximumBytes: Int
    ) throws -> P8FSignedSmokeFilesystemIdentity? {
        let url = try fixedURL(for: artifact)
        let currentIdentity = try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        )
        guard currentIdentity == expectedIdentity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        guard currentIdentity != nil else {
            return nil
        }
        _ = try readRegularFile(
            at: url,
            in: receiptsDirectory,
            maximumBytes: maximumBytes
        )
        guard try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        ) == expectedIdentity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        // A same-UID replacement between this final identity check and the
        // pathname unlink remains outside the guarantees of this API.
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        try syncDirectory(receiptsDirectory)
        guard try mutableIdentity(
            for: artifact,
            maximumBytes: maximumBytes
        ) == nil else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return nil
    }

    func eventURLs() throws -> [URL] {
        try validateKnownReceiptLayout()
        let directory = try ensureEventsDirectory()
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return urls.sorted {
            $0.lastPathComponent < $1.lastPathComponent
        }
    }

    func validateKnownReceiptLayout() throws {
        try validateCurrentRootIdentity()
        try ensureReceiptDirectoryIsValid()
        if let eventsIdentity {
            let eventsDirectory = receiptsDirectory
                .appendingPathComponent(
                    P8FSignedSmokeReceiptLayout
                        .eventsDirectoryName,
                    isDirectory: true
                )
            try Self.requireDirectChild(
                eventsDirectory,
                of: receiptsDirectory
            )
            guard try Self.directoryIdentity(
                at: eventsDirectory
            ) == eventsIdentity else {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
        }
        let urls: [URL]
        do {
            urls = try fileManager.contentsOfDirectory(
                at: receiptsDirectory,
                includingPropertiesForKeys: nil,
                options: []
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        let allowedFiles: Set<String> = [
            P8FSignedSmokeReceiptLayout
                .buildSourceSelectionFileName,
            P8FSignedSmokeReceiptLayout
                .sourceAuthorityReceiptsFileName,
            P8FSignedSmokeReceiptLayout
                .diagnosticManifestFileName,
            P8FSignedSmokeReceiptLayout
                .terminalReceiptFileName,
        ]
        for url in urls {
            try Self.requireDirectChild(
                url,
                of: receiptsDirectory
            )
            let name = url.lastPathComponent
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(
                    atPath: url.path
                )
            } catch {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
            guard attributes[.type] as? FileAttributeType
                    != .typeSymbolicLink
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactSymbolicLink
            }
            if name
                == P8FSignedSmokeReceiptLayout
                    .eventsDirectoryName {
                guard attributes[.type] as? FileAttributeType
                        == .typeDirectory,
                      Self.permissions(attributes)
                        == Self.directoryPermissions
                else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .directoryPermissionsInvalid
                }
                continue
            }
            guard allowedFiles.contains(name) else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .unknownReceiptArtifact
            }
            guard attributes[.type] as? FileAttributeType
                    == .typeRegular
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactNotRegularFile
            }
            guard Self.permissions(attributes)
                    == Self.filePermissions
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactPermissionsInvalid
            }
        }
    }

    func readEvent(
        at url: URL,
        maximumBytes: Int
    ) throws -> Data {
        let directory = try ensureEventsDirectory()
        guard let data = try readRegularFile(
            at: url,
            in: directory,
            maximumBytes: maximumBytes
        ) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventSequenceInvalid
        }
        return data
    }

    func writeEvent(
        _ data: Data,
        sequence: UInt64,
        maximumBytes: Int
    ) throws {
        let directory = try ensureEventsDirectory()
        guard data.count <= maximumBytes else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactTooLarge
        }
        let url = directory.appendingPathComponent(
            P8FSignedSmokeReceiptLayout.eventFileName(
                sequence: sequence
            ),
            isDirectory: false
        )
        try Self.requireDirectChild(url, of: directory)
        try write(
            data,
            to: url,
            in: directory,
            replaceExisting: false
        )
    }

    private func ensureReceiptDirectoryIsValid() throws {
        try ensureDirectory(receiptsDirectory)
    }

    private func ensureDirectory(_ url: URL) throws {
        if try Self.itemExists(at: url) {
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(
                    atPath: url.path
                )
            } catch {
                throw P8FSignedSmokeReceiptStoreFailure.ioFailure
            }
            guard attributes[.type] as? FileAttributeType
                    != .typeSymbolicLink
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactSymbolicLink
            }
            guard attributes[.type] as? FileAttributeType
                    == .typeDirectory
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactNotRegularFile
            }
            guard Self.permissions(attributes)
                    == Self.directoryPermissions
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .directoryPermissionsInvalid
            }
            return
        }
        do {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [
                    .posixPermissions:
                        NSNumber(
                            value: Self.directoryPermissions
                        ),
                ]
            )
            try fileManager.setAttributes(
                [
                    .posixPermissions:
                        NSNumber(
                            value: Self.directoryPermissions
                        ),
                ],
                ofItemAtPath: url.path
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        try syncDirectory(url.deletingLastPathComponent())
        try ensureDirectory(url)
    }

    private func readRegularFile(
        at url: URL,
        in directory: URL,
        maximumBytes: Int
    ) throws -> Data? {
        try Self.requireDirectChild(url, of: directory)
        guard try Self.itemExists(at: url) else {
            return nil
        }
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try fileManager.attributesOfItem(
                atPath: url.path
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        guard attributes[.type] as? FileAttributeType
                != .typeSymbolicLink
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactSymbolicLink
        }
        guard attributes[.type] as? FileAttributeType
                == .typeRegular
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactNotRegularFile
        }
        guard Self.permissions(attributes)
                == Self.filePermissions
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactPermissionsInvalid
        }
        let byteCount =
            (attributes[.size] as? NSNumber)?.intValue ?? -1
        guard byteCount >= 0, byteCount <= maximumBytes else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactTooLarge
        }
        let identity = try Self.regularFileIdentity(
            at: url,
            maximumBytes: maximumBytes
        )
        let data: Data
        do {
            data = try Data(
                contentsOf: url,
                options: [.mappedIfSafe]
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        guard try Self.regularFileIdentity(
            at: url,
            maximumBytes: maximumBytes
        ) == identity else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return data
    }

    private func write(
        _ data: Data,
        to url: URL,
        in directory: URL,
        replaceExisting: Bool
    ) throws {
        try Self.requireDirectChild(url, of: directory)
        if try Self.itemExists(at: url) {
            guard replaceExisting else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactAlreadyExists
            }
            _ = try readRegularFile(
                at: url,
                in: directory,
                maximumBytes: Int.max
            )
        }
        try writeSecureTemporaryFile(
            data,
            replacing: replaceExisting,
            at: url,
            in: directory
        )
        guard try readRegularFile(
            at: url,
            in: directory,
            maximumBytes: data.count
        ) == data else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
    }

    private func writeSecureTemporaryFile(
        _ data: Data,
        replacing: Bool,
        at destination: URL,
        in directory: URL
    ) throws {
        let temporary = directory.appendingPathComponent(
            ".p8f-write-\(UUID().uuidString.lowercased()).tmp",
            isDirectory: false
        )
        try Self.requireDirectChild(temporary, of: directory)
        let descriptor = temporary.path.withCString {
            Darwin.open(
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC
                    | O_NOFOLLOW,
                mode_t(Self.filePermissions)
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        var descriptorIsOpen = true
        defer {
            if descriptorIsOpen {
                _ = Darwin.close(descriptor)
            }
            try? fileManager.removeItem(at: temporary)
        }

        guard Darwin.fchmod(
            descriptor,
            mode_t(Self.filePermissions)
        ) == 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                guard let baseAddress = bytes.baseAddress else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .ioFailure
                }
                let written = Darwin.write(
                    descriptor,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset
                )
                if written < 0, errno == EINTR {
                    continue
                }
                guard written > 0 else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .ioFailure
                }
                offset += written
            }
        }
        guard Darwin.fsync(descriptor) == 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        let closeResult = Darwin.close(descriptor)
        descriptorIsOpen = false
        guard closeResult == 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }

        let renameResult = temporary.path.withCString {
            temporaryPath in
            destination.path.withCString { destinationPath in
                if replacing {
                    Darwin.rename(
                        temporaryPath,
                        destinationPath
                    )
                } else {
                    Darwin.renamex_np(
                        temporaryPath,
                        destinationPath,
                        UInt32(RENAME_EXCL)
                    )
                }
            }
        }
        guard renameResult == 0 else {
            if !replacing, errno == EEXIST {
                throw P8FSignedSmokeReceiptStoreFailure
                    .fixedArtifactAlreadyExists
            }
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        try syncDirectory(directory)
    }

    private func syncDirectory(_ directory: URL) throws {
        let descriptor = directory.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
    }

    private static func requireDirectChild(
        _ candidate: URL,
        of directory: URL
    ) throws {
        let parent = candidate
            .deletingLastPathComponent()
            .standardizedFileURL
        guard parent == directory.standardizedFileURL,
              !candidate.lastPathComponent.isEmpty,
              candidate.lastPathComponent != ".",
              candidate.lastPathComponent != "..",
              !candidate.lastPathComponent.contains("/")
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactEscapedRoot
        }
    }

    private static func permissions(
        _ attributes: [FileAttributeKey: Any]
    ) -> Int {
        ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1)
            & 0o777
    }

    func matches(
        storageBoundary: P8FSignedSmokeStorageBoundary
    ) -> Bool {
        guard isolatedRoot == storageBoundary.rootURL else {
            return false
        }
        do {
            try storageBoundary.validateCurrentRoot(
                fileManager: fileManager
            )
            try validateCurrentRootIdentity()
            return true
        } catch {
            return false
        }
    }

    private func validateCurrentRootIdentity() throws {
        let rootIdentity = try Self.directoryIdentity(
            at: isolatedRoot
        )
        let receiptsIdentity = try Self.directoryIdentity(
            at: receiptsDirectory
        )
        guard rootIdentity.device == rootDevice,
              rootIdentity.inode == rootInode,
              rootIdentity.owner == rootOwner,
              receiptsIdentity.device == receiptsDevice,
              receiptsIdentity.inode == receiptsInode,
              receiptsIdentity.owner == receiptsOwner
        else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
    }

    private static func directoryIdentity(
        at url: URL
    ) throws -> P8FSignedSmokeFilesystemIdentity {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFDIR,
              Int(information.st_mode & 0o7777)
                == Self.directoryPermissions,
              information.st_uid == geteuid()
        else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return P8FSignedSmokeFilesystemIdentity(
            device: information.st_dev,
            inode: information.st_ino,
            owner: information.st_uid
        )
    }

    private static func regularFileIdentity(
        at url: URL,
        maximumBytes: Int
    ) throws -> P8FSignedSmokeFilesystemIdentity {
        let descriptor = url.path.withCString {
            Darwin.open(
                $0,
                O_RDONLY | O_CLOEXEC | O_NOFOLLOW
            )
        }
        guard descriptor >= 0 else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        defer { _ = Darwin.close(descriptor) }
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0,
              information.st_mode & S_IFMT == S_IFREG,
              Int(information.st_mode & 0o7777)
                == Self.filePermissions,
              information.st_uid == geteuid(),
              information.st_nlink == 1,
              information.st_size >= 0,
              information.st_size <= off_t(maximumBytes)
        else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return P8FSignedSmokeFilesystemIdentity(
            device: information.st_dev,
            inode: information.st_ino,
            owner: information.st_uid
        )
    }

    private static func itemExists(at url: URL) throws -> Bool {
        var information = stat()
        let result = url.path.withCString {
            Darwin.lstat($0, &information)
        }
        if result == 0 {
            return true
        }
        guard errno == ENOENT else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return false
    }
}

enum P8FSignedSmokeJSON {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [
            .sortedKeys,
            .withoutEscapingSlashes,
        ]
        do {
            return try encoder.encode(value)
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
    }

    static func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data
    ) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
    }
}

enum P8FSignedSmokeDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func sha256(_ value: String) -> String {
        sha256(Data(value.utf8))
    }

    static func isSHA256(_ value: String) -> Bool {
        value.count == 64
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }

    static func isSHA1(_ value: String) -> Bool {
        value.count == 40
            && value == value.lowercased()
            && value.allSatisfy(\.isHexDigit)
    }
}

enum P8FSignedSmokeDiagnosticArtifactClassification:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case applicationDiagnostics =
        "application_diagnostics"
    case processIdentity = "process_identity"
    case transportObservation =
        "transport_observation"

    var approvedFieldsSchemaSHA256: String {
        P8FSignedSmokeDigest.sha256(
            approvedFieldsSchemaContract
        )
    }

    private var approvedFieldsSchemaContract: String {
        switch self {
        case .applicationDiagnostics:
            return
                "agent-loki.p8f.diagnostic.application-diagnostics.canonical-event-array.v2"
        case .processIdentity:
            return
                "agent-loki.p8f.diagnostic.process-identity.sequence-model-pid-executable-provider-request-interval-endpoint.v1"
        case .transportObservation:
            return
                "agent-loki.p8f.diagnostic.transport-observation.sequence-model-provider-request-watcher-interval-evidence-result-endpoint.v1"
        }
    }
}

enum P8FSignedSmokeDiagnosticValidationResult:
    String,
    Codable,
    Hashable,
    Sendable
{
    case approvedFieldsOnly = "approved_fields_only"
}

struct P8FSignedSmokeDiagnosticArtifactReceipt:
    Codable,
    Equatable,
    Sendable
{
    let artifactIdentifierSHA256: String
    let classification:
        P8FSignedSmokeDiagnosticArtifactClassification
    let artifactSHA256: String
    let approvedFieldsSchemaSHA256: String
    let capturedAt: Date
    let byteCount: Int
    let recordCount: Int
    let rejectedFieldCount: Int
    let rejectedValueCount: Int
    let rawPayloadEmbedded: Bool
    let validationResult:
        P8FSignedSmokeDiagnosticValidationResult

    enum CodingKeys: String, CodingKey {
        case artifactIdentifierSHA256 =
            "artifact_identifier_sha256"
        case classification
        case artifactSHA256 = "artifact_sha256"
        case approvedFieldsSchemaSHA256 =
            "approved_fields_schema_sha256"
        case capturedAt = "captured_at"
        case byteCount = "byte_count"
        case recordCount = "record_count"
        case rejectedFieldCount = "rejected_field_count"
        case rejectedValueCount = "rejected_value_count"
        case rawPayloadEmbedded = "raw_payload_embedded"
        case validationResult = "validation_result"
    }

    init(
        artifactIdentifierSHA256: String,
        classification:
            P8FSignedSmokeDiagnosticArtifactClassification,
        artifactSHA256: String,
        approvedFieldsSchemaSHA256: String,
        capturedAt: Date,
        byteCount: Int,
        recordCount: Int,
        rejectedFieldCount: Int = 0,
        rejectedValueCount: Int = 0,
        rawPayloadEmbedded: Bool = false,
        validationResult:
            P8FSignedSmokeDiagnosticValidationResult =
                .approvedFieldsOnly
    ) throws {
        self.artifactIdentifierSHA256 =
            artifactIdentifierSHA256
        self.classification = classification
        self.artifactSHA256 = artifactSHA256
        self.approvedFieldsSchemaSHA256 =
            approvedFieldsSchemaSHA256
        self.capturedAt = capturedAt
        self.byteCount = byteCount
        self.recordCount = recordCount
        self.rejectedFieldCount = rejectedFieldCount
        self.rejectedValueCount = rejectedValueCount
        self.rawPayloadEmbedded = rawPayloadEmbedded
        self.validationResult = validationResult
        guard Self.isValid(self) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
    }

    static func isValid(
        _ receipt: P8FSignedSmokeDiagnosticArtifactReceipt
    ) -> Bool {
        P8FSignedSmokeDigest.isSHA256(
            receipt.artifactIdentifierSHA256
        )
            && P8FSignedSmokeDigest.isSHA256(
                receipt.artifactSHA256
            )
            && P8FSignedSmokeDigest.isSHA256(
                receipt.approvedFieldsSchemaSHA256
            )
            && receipt.approvedFieldsSchemaSHA256
                == receipt.classification
                    .approvedFieldsSchemaSHA256
            && receipt.capturedAt
                .timeIntervalSinceReferenceDate.isFinite
            && (0...512 * 1_024 * 1_024)
                .contains(receipt.byteCount)
            && (0...10_000_000)
                .contains(receipt.recordCount)
            && receipt.rejectedFieldCount == 0
            && receipt.rejectedValueCount == 0
            && !receipt.rawPayloadEmbedded
            && receipt.validationResult
                == .approvedFieldsOnly
    }
}

struct P8FSignedSmokeDiagnosticManifestReceipt:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.diagnostic-artifact-manifest.v1"

    private struct Payload: Codable {
        let schemaVersion: String
        let traceID: String
        let createdAt: Date
        let artifacts:
            [P8FSignedSmokeDiagnosticArtifactReceipt]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case traceID = "trace_id"
            case createdAt = "created_at"
            case artifacts
        }
    }

    private struct ProcessIdentityProjection: Codable {
        let sequence: UInt64
        let model: P8FSignedSmokeApprovedModel
        let processIdentifier: Int
        let executableSHA256: String
        let providerRequestTraceSHA256: String
        let providerRequestIdentifierSHA256: String
        let providerIntervalStartedAt: Date
        let providerIntervalEndedAt: Date
        let providerIntervalDurationMilliseconds: Int
        let endpointClassification:
            P8FSignedSmokeEndpointClassification

        enum CodingKeys: String, CodingKey {
            case sequence
            case model
            case processIdentifier = "process_pid"
            case executableSHA256 = "executable_sha256"
            case providerRequestTraceSHA256 =
                "provider_request_trace_sha256"
            case providerRequestIdentifierSHA256 =
                "provider_request_id_sha256"
            case providerIntervalStartedAt =
                "provider_interval_started_at"
            case providerIntervalEndedAt =
                "provider_interval_ended_at"
            case providerIntervalDurationMilliseconds =
                "provider_interval_duration_ms"
            case endpointClassification =
                "endpoint_classification"
        }

        init?(event: P8FSignedSmokeEvent) {
            let metadata = event.metadata
            guard metadata.hasCompleteProviderCorrelation,
                  let model = metadata.model,
                  let processIdentifier =
                    metadata.processIdentifier,
                  let executableSHA256 =
                    metadata.executableSHA256,
                  let providerRequestTraceSHA256 =
                    metadata.providerRequestTraceSHA256,
                  let providerRequestIdentifierSHA256 =
                    metadata.providerRequestIdentifierSHA256,
                  let providerIntervalStartedAt =
                    metadata.providerIntervalStartedAt,
                  let providerIntervalEndedAt =
                    metadata.providerIntervalEndedAt,
                  let providerIntervalDurationMilliseconds =
                    metadata
                        .providerIntervalDurationMilliseconds,
                  let endpointClassification =
                    metadata.endpointClassification
            else {
                return nil
            }
            sequence = event.sequence
            self.model = model
            self.processIdentifier = processIdentifier
            self.executableSHA256 = executableSHA256
            self.providerRequestTraceSHA256 =
                providerRequestTraceSHA256
            self.providerRequestIdentifierSHA256 =
                providerRequestIdentifierSHA256
            self.providerIntervalStartedAt =
                providerIntervalStartedAt
            self.providerIntervalEndedAt =
                providerIntervalEndedAt
            self.providerIntervalDurationMilliseconds =
                providerIntervalDurationMilliseconds
            self.endpointClassification =
                endpointClassification
        }
    }

    private struct TransportObservationProjection: Codable {
        let sequence: UInt64
        let model: P8FSignedSmokeApprovedModel
        let providerRequestTraceSHA256: String
        let providerRequestIdentifierSHA256: String
        let externalWatcherIntervalStartedAt: Date
        let externalWatcherIntervalEndedAt: Date
        let externalWatcherIntervalDurationMilliseconds: Int
        let evidenceSource:
            P8FSignedSmokeTransportObservationEvidenceSource
        let observationClassification:
            P8FSignedSmokeTransportObservationClassification
        let observationResult:
            P8FSignedSmokeTransportObservationResult
        let observedEndpointClassification:
            P8FSignedSmokeEndpointClassification

        enum CodingKeys: String, CodingKey {
            case sequence
            case model
            case providerRequestTraceSHA256 =
                "provider_request_trace_sha256"
            case providerRequestIdentifierSHA256 =
                "provider_request_id_sha256"
            case externalWatcherIntervalStartedAt =
                "external_watcher_interval_started_at"
            case externalWatcherIntervalEndedAt =
                "external_watcher_interval_ended_at"
            case externalWatcherIntervalDurationMilliseconds =
                "external_watcher_interval_duration_ms"
            case evidenceSource = "evidence_source"
            case observationClassification =
                "observation_classification"
            case observationResult = "observation_result"
            case observedEndpointClassification =
                "observed_endpoint_classification"
        }

        init?(event: P8FSignedSmokeEvent) {
            let metadata = event.metadata
            guard metadata.hasCompleteProviderCorrelation,
                  metadata.hasCompleteExternalObservation,
                  let model = metadata.model,
                  let providerRequestTraceSHA256 =
                    metadata.providerRequestTraceSHA256,
                  let providerRequestIdentifierSHA256 =
                    metadata.providerRequestIdentifierSHA256,
                  let externalWatcherIntervalStartedAt =
                    metadata.externalWatcherIntervalStartedAt,
                  let externalWatcherIntervalEndedAt =
                    metadata.externalWatcherIntervalEndedAt,
                  let externalWatcherIntervalDurationMilliseconds =
                    metadata
                        .externalWatcherIntervalDurationMilliseconds,
                  let evidenceSource =
                    metadata.transportObservationEvidenceSource,
                  let observationClassification =
                    metadata.transportObservationClassification,
                  let observationResult =
                    metadata.transportObservationResult,
                  let observedEndpointClassification =
                    metadata.observedEndpointClassification
            else {
                return nil
            }
            sequence = event.sequence
            self.model = model
            self.providerRequestTraceSHA256 =
                providerRequestTraceSHA256
            self.providerRequestIdentifierSHA256 =
                providerRequestIdentifierSHA256
            self.externalWatcherIntervalStartedAt =
                externalWatcherIntervalStartedAt
            self.externalWatcherIntervalEndedAt =
                externalWatcherIntervalEndedAt
            self.externalWatcherIntervalDurationMilliseconds =
                externalWatcherIntervalDurationMilliseconds
            self.evidenceSource = evidenceSource
            self.observationClassification =
                observationClassification
            self.observationResult = observationResult
            self.observedEndpointClassification =
                observedEndpointClassification
        }
    }

    let schemaVersion: String
    let traceID: String
    let createdAt: Date
    let artifacts:
        [P8FSignedSmokeDiagnosticArtifactReceipt]
    let payloadSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case createdAt = "created_at"
        case artifacts
        case payloadSHA256 = "payload_sha256"
    }

    init(
        traceID: String,
        createdAt: Date = Date(),
        artifacts:
            [P8FSignedSmokeDiagnosticArtifactReceipt]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.traceID = traceID
        self.createdAt = createdAt
        self.artifacts = artifacts
        payloadSHA256 = P8FSignedSmokeDigest.sha256(
            try Self.encodedPayload(
                traceID: traceID,
                createdAt: createdAt,
                artifacts: artifacts
            )
        )
        try Self.validate(self)
    }

    static func canonical(
        traceID: String,
        events: [P8FSignedSmokeEvent]
    ) throws -> Self {
        guard let capturedAt = events.last?.timestamp,
              !events.isEmpty,
              events.allSatisfy({ $0.traceID == traceID })
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
        let processIdentities = events.compactMap {
            ProcessIdentityProjection(event: $0)
        }
        let transportObservations = events.compactMap {
            TransportObservationProjection(event: $0)
        }
        let payloads:
            [(
                P8FSignedSmokeDiagnosticArtifactClassification,
                Data,
                Int
            )] = [
                (
                    .applicationDiagnostics,
                    try P8FSignedSmokeJSON.encode(events),
                    events.count
                ),
                (
                    .processIdentity,
                    try P8FSignedSmokeJSON.encode(
                        processIdentities
                    ),
                    processIdentities.count
                ),
                (
                    .transportObservation,
                    try P8FSignedSmokeJSON.encode(
                        transportObservations
                    ),
                    transportObservations.count
                ),
            ]
        let artifacts = try payloads.map {
            classification,
            data,
            recordCount in
            try P8FSignedSmokeDiagnosticArtifactReceipt(
                artifactIdentifierSHA256:
                    P8FSignedSmokeDigest.sha256(
                        "\(Self.currentSchemaVersion)|\(traceID)|\(classification.rawValue)"
                    ),
                classification: classification,
                artifactSHA256:
                    P8FSignedSmokeDigest.sha256(data),
                approvedFieldsSchemaSHA256:
                    classification
                        .approvedFieldsSchemaSHA256,
                capturedAt: capturedAt,
                byteCount: data.count,
                recordCount: recordCount
            )
        }
        return try Self(
            traceID: traceID,
            createdAt: capturedAt,
            artifacts: artifacts
        )
    }

    static func validate(
        _ receipt: P8FSignedSmokeDiagnosticManifestReceipt
    ) throws {
        guard receipt.schemaVersion
                == Self.currentSchemaVersion,
              P8FSignedSmokeValueValidator
                .isGeneratedIdentifier(
                    receipt.traceID,
                    prefix: "trace_"
                ),
              receipt.createdAt.timeIntervalSinceReferenceDate
                .isFinite,
              receipt.artifacts.map(\.classification)
                == P8FSignedSmokeDiagnosticArtifactClassification
                    .allCases,
              Set(
                receipt.artifacts.map(
                    \.artifactIdentifierSHA256
                )
              ).count == receipt.artifacts.count,
              receipt.artifacts.allSatisfy(
                P8FSignedSmokeDiagnosticArtifactReceipt
                    .isValid
              ),
              receipt.artifacts.allSatisfy({
                  $0.capturedAt == receipt.createdAt
              }),
              receipt.payloadSHA256
                == P8FSignedSmokeDigest.sha256(
                    try encodedPayload(
                        traceID: receipt.traceID,
                        createdAt: receipt.createdAt,
                        artifacts: receipt.artifacts
                    )
                )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
    }

    static func validate(
        _ receipt: P8FSignedSmokeDiagnosticManifestReceipt,
        against events: [P8FSignedSmokeEvent]
    ) throws {
        try validate(receipt)
        guard receipt == (try canonical(
            traceID: receipt.traceID,
            events: events
        )) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
    }

    private static func encodedPayload(
        traceID: String,
        createdAt: Date,
        artifacts:
            [P8FSignedSmokeDiagnosticArtifactReceipt]
    ) throws -> Data {
        try P8FSignedSmokeJSON.encode(
            Payload(
                schemaVersion: currentSchemaVersion,
                traceID: traceID,
                createdAt: createdAt,
                artifacts: artifacts
            )
        )
    }
}

private enum P8FSignedSmokeValueValidator {
    static func isGeneratedIdentifier(
        _ value: String,
        prefix: String
    ) -> Bool {
        guard value.hasPrefix(prefix) else { return false }
        let suffix = String(value.dropFirst(prefix.count))
        guard let uuid = UUID(uuidString: suffix) else {
            return false
        }
        return suffix == uuid.uuidString.lowercased()
    }
}

enum P8FSignedSmokeReceiptArtifactKind:
    Hashable,
    Sendable
{
    case buildSourceSelection
    case sourceAuthorityReceipts
    case event
    case diagnosticManifest
    case terminalReceipt
}

private indirect enum P8FSignedSmokeJSONRule {
    case string
    case integer
    case number
    case boolean
    case array(P8FSignedSmokeJSONRule)
    case object(
        required: [String: P8FSignedSmokeJSONRule],
        optional: [String: P8FSignedSmokeJSONRule]
    )
}

enum P8FSignedSmokeReceiptArtifactValidator {
    private static let maximumValidationBytes =
        4 * 1_024 * 1_024

    static func validateEncodedArtifact(
        _ data: Data,
        as kind: P8FSignedSmokeReceiptArtifactKind
    ) throws {
        guard data.count <= maximumValidationBytes,
              let object = try? JSONSerialization.jsonObject(
                with: data,
                options: []
              )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .artifactSchemaInvalid
        }
        guard validate(object, against: rule(for: kind))
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .artifactSchemaInvalid
        }
    }

    @MainActor
    static func validateReceiptDirectory(
        isolatedRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let root = try P8FSignedSmokeReceiptRoot(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        )
        try validateExistingArtifacts(in: root)
        _ = try P8FSignedSmokeSemanticBuildSourceSelectionStore(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        ).load()
        _ = try P8FSignedSmokeSemanticSourceAuthorityReceiptStore(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        ).load()
        _ = try P8FSignedSmokeReceiptWriter(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        )
    }

    fileprivate static func validateExistingArtifacts(
        in root: P8FSignedSmokeReceiptRoot
    ) throws {
        try root.validateKnownReceiptLayout()
        let fixedArtifacts:
            [(
                P8FSignedSmokeFixedArtifact,
                P8FSignedSmokeReceiptArtifactKind
            )] = [
                (
                    .buildSourceSelection,
                    .buildSourceSelection
                ),
                (
                    .sourceAuthorityReceipts,
                    .sourceAuthorityReceipts
                ),
                (
                    .diagnosticManifest,
                    .diagnosticManifest
                ),
                (.terminalReceipt, .terminalReceipt),
            ]
        for (artifact, kind) in fixedArtifacts {
            guard let data = try root.read(
                artifact,
                maximumBytes: maximumValidationBytes
            ) else {
                continue
            }
            try validateEncodedArtifact(data, as: kind)
            if kind == .diagnosticManifest {
                let manifest:
                    P8FSignedSmokeDiagnosticManifestReceipt
                do {
                    manifest = try P8FSignedSmokeJSON.decode(
                        P8FSignedSmokeDiagnosticManifestReceipt
                            .self,
                        from: data
                    )
                } catch {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .diagnosticManifestInvalid
                }
                try P8FSignedSmokeDiagnosticManifestReceipt
                    .validate(manifest)
            }
        }

        let eventURLs = try root.eventURLs()
        for (index, url) in eventURLs.enumerated() {
            guard url.lastPathComponent
                    == P8FSignedSmokeReceiptLayout
                        .eventFileName(
                            sequence: UInt64(index + 1)
                        )
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .unknownReceiptArtifact
            }
            try validateEncodedArtifact(
                root.readEvent(
                    at: url,
                    maximumBytes: maximumValidationBytes
                ),
                as: .event
            )
        }
    }

    private static func validate(
        _ value: Any,
        against rule: P8FSignedSmokeJSONRule
    ) -> Bool {
        switch rule {
        case .string:
            return value is String
        case .integer:
            guard let number = jsonNumber(value) else {
                return false
            }
            let double = number.doubleValue
            return double.rounded(.towardZero) == double
        case .number:
            return jsonNumber(value) != nil
        case .boolean:
            guard let number = value as? NSNumber else {
                return false
            }
            return CFGetTypeID(number)
                == CFBooleanGetTypeID()
        case let .array(elementRule):
            guard let values = value as? [Any] else {
                return false
            }
            return values.allSatisfy {
                validate($0, against: elementRule)
            }
        case let .object(required, optional):
            guard let values = value as? [String: Any]
            else {
                return false
            }
            let allowed = Set(required.keys)
                .union(optional.keys)
            guard Set(required.keys).isSubset(
                    of: values.keys
                  ),
                  Set(values.keys).isSubset(of: allowed)
            else {
                return false
            }
            for (key, nestedRule) in required {
                guard let nested = values[key],
                      validate(nested, against: nestedRule)
                else {
                    return false
                }
            }
            for (key, nestedRule) in optional {
                if let nested = values[key],
                   !validate(nested, against: nestedRule) {
                    return false
                }
            }
            return true
        }
    }

    private static func jsonNumber(
        _ value: Any
    ) -> NSNumber? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else {
            return nil
        }
        return number
    }

    private static func rule(
        for kind: P8FSignedSmokeReceiptArtifactKind
    ) -> P8FSignedSmokeJSONRule {
        switch kind {
        case .buildSourceSelection:
            return .object(
                required: [
                    "schema_version": .string,
                    "source_kinds": .array(.string),
                    "payload_sha256": .string,
                ],
                optional: [:]
            )
        case .sourceAuthorityReceipts:
            return .object(
                required: [
                    "schema_version": .string,
                    "receipts": .array(
                        sourceAuthorityReceiptRule
                    ),
                    "payload_sha256": .string,
                ],
                optional: [:]
            )
        case .event:
            return eventRule
        case .diagnosticManifest:
            return diagnosticManifestRule
        case .terminalReceipt:
            return terminalReceiptEnvelopeRule
        }
    }

    private static var sourceAuthorityReceiptRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "eventIdentifier": .string,
                "occurredAt": .number,
                "name": .string,
                "sourceKinds": .array(.string),
                "preparedRecordCount": .integer,
                "chunkCount": .integer,
                "indexedCount": .integer,
                "excludedCount": .integer,
                "tombstoneCount": .integer,
                "skippedCount": .integer,
                "rejectedCount": .integer,
                "status": .string,
                "reasonCode": .string,
            ],
            optional: [
                "sourceAuthorityVersion": .string,
                "sourceAllowlistHash": .string,
                "authorizationReceiptIdentifier": .string,
                "buildInitiation": .string,
                "sourceKind": .string,
                "adapterContractVersion": .string,
                "generationIdentifier": .string,
            ]
        )
    }

    private static var countersRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "adapter_invocations": .integer,
                "records_read": .integer,
                "records_accepted": .integer,
                "records_rejected": .integer,
                "prepared_records": .integer,
                "chunks": .integer,
                "embedding_requests": .integer,
                "embeddings_accepted": .integer,
                "index_writes": .integer,
                "result_count": .integer,
                "leakage_canary_hits": .integer,
            ],
            optional: [:]
        )
    }

    private static var eventMetadataRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: ["scenario": .string],
            optional: [
                "source_kind": .string,
                "model": .string,
                "search_mode": .string,
                "artifact_classification": .string,
                "endpoint_classification": .string,
                "fixture_manifest_sha256": .string,
                "source_allowlist_sha256": .string,
                "generation_identifier_sha256": .string,
                "authorization_receipt_identifier_sha256":
                    .string,
                "model_digest": .string,
                "runtime_identity_sha256": .string,
                "request_profile_sha256": .string,
                "artifact_sha256": .string,
                "vector_dimension": .integer,
                "counters": countersRule,
                "process_pid": .integer,
                "executable_sha256": .string,
                "provider_request_trace_sha256": .string,
                "provider_request_id_sha256": .string,
                "provider_kind": .string,
                "provider_operation_kind": .string,
                "provider_outcome": .string,
                "provider_interval_started_at": .number,
                "provider_interval_ended_at": .number,
                "provider_interval_duration_ms": .integer,
                "external_watcher_interval_started_at":
                    .number,
                "external_watcher_interval_ended_at":
                    .number,
                "external_watcher_interval_duration_ms":
                    .integer,
                "transport_observation_evidence_source":
                    .string,
                "transport_observation_classification":
                    .string,
                "transport_observation_result": .string,
                "observed_endpoint_classification": .string,
            ]
        )
    }

    private static var eventRule: P8FSignedSmokeJSONRule {
        .object(
            required: [
                "schema_version": .string,
                "sequence": .integer,
                "ts": .number,
                "event": .string,
                "trace_id": .string,
                "span_id": .string,
                "component": .string,
                "status": .string,
                "reason_code": .string,
                "duration_ms": .integer,
                "metadata": eventMetadataRule,
            ],
            optional: [
                "parent_span_id": .string,
                "previous_event_sha256": .string,
            ]
        )
    }

    private static var diagnosticArtifactRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "artifact_identifier_sha256": .string,
                "classification": .string,
                "artifact_sha256": .string,
                "approved_fields_schema_sha256": .string,
                "captured_at": .number,
                "byte_count": .integer,
                "record_count": .integer,
                "rejected_field_count": .integer,
                "rejected_value_count": .integer,
                "raw_payload_embedded": .boolean,
                "validation_result": .string,
            ],
            optional: [:]
        )
    }

    private static var diagnosticManifestRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "schema_version": .string,
                "trace_id": .string,
                "created_at": .number,
                "artifacts": .array(diagnosticArtifactRule),
                "payload_sha256": .string,
            ],
            optional: [:]
        )
    }

    private static var applicationIdentityRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "bundle_identifier": .string,
                "marketing_version_major": .integer,
                "marketing_version_minor": .integer,
                "marketing_version_patch": .integer,
                "build_number": .integer,
                "executable_sha256": .string,
                "cdhash": .string,
                "storage_classification": .string,
            ],
            optional: [:]
        )
    }

    private static var privacySummaryRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "artifact_count": .integer,
                "forbidden_field_count": .integer,
                "forbidden_value_count": .integer,
                "raw_vector_count": .integer,
                "raw_content_count": .integer,
                "raw_prompt_count": .integer,
                "raw_response_count": .integer,
                "hidden_reasoning_count": .integer,
                "private_path_count": .integer,
                "credential_count": .integer,
            ],
            optional: [:]
        )
    }

    private static var terminalReceiptRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "scenario": .string,
                "status": .string,
                "reason_code": .string,
                "started_at": .number,
                "completed_at": .number,
                "application_identity":
                    applicationIdentityRule,
                "privacy_summary": privacySummaryRule,
                "artifact_ledger": artifactLedgerRule,
            ],
            optional: [
                "admission_accepted": .boolean,
                "fixture_accepted": .boolean,
                "fixture_manifest_sha256": .string,
                "source_allowlist_sha256": .string,
                "authorization_receipt_identifier_sha256":
                    .string,
                "semantic_outcome_state": .string,
                "generation_identifier_sha256": .string,
                "source_counters": countersRule,
                "model": .string,
                "model_digest_sha256": .string,
                "model_assessment_status": .string,
                "search_mode": .string,
                "search_passed": .boolean,
                "hydration_passed": .boolean,
                "cleanup_passed": .boolean,
            ]
        )
    }

    private static var artifactLedgerRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "schema_version": .string,
                "event_count": .integer,
                "event_chain_artifact_count": .integer,
                "source_authority_receipt_count": .integer,
                "diagnostic_manifest_count": .integer,
                "terminal_receipt_count": .integer,
                "provider_evidence_count": .integer,
                "candidate_generation_count": .integer,
                "published_generation_count": .integer,
                "discarded_generation_count": .integer,
                "prepared_record_count": .integer,
                "chunk_count": .integer,
                "embedding_request_count": .integer,
                "index_write_count": .integer,
                "publication_state": .string,
                "cleanup_state": .string,
                "abandoned_temporary_artifact_count": .integer,
            ],
            optional: [:]
        )
    }

    private static var terminalReceiptEnvelopeRule:
        P8FSignedSmokeJSONRule
    {
        .object(
            required: [
                "schema_version": .string,
                "trace_id": .string,
                "receipt": terminalReceiptRule,
                "event_count": .integer,
                "first_event_sha256": .string,
                "final_event_sha256": .string,
                "diagnostic_manifest_sha256": .string,
                "committed_final_event": eventRule,
                "committed_diagnostic_manifest":
                    diagnosticManifestRule,
            ],
            optional: [:]
        )
    }
}

private struct P8FSignedSmokeBuildSourceSelectionEnvelope:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.build-source-selection.v1"

    let schemaVersion: String
    let sourceKinds: [String]
    let payloadSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sourceKinds = "source_kinds"
        case payloadSHA256 = "payload_sha256"
    }

    init(sourceKinds: [String]) throws {
        schemaVersion = Self.currentSchemaVersion
        self.sourceKinds = sourceKinds
        payloadSHA256 = P8FSignedSmokeDigest.sha256(
            try P8FSignedSmokeJSON.encode(sourceKinds)
        )
    }
}

@MainActor
final class P8FSignedSmokeSemanticBuildSourceSelectionStore:
    P8SemanticBuildSourceSelectionStoring
{
    private static let maximumFileBytes = 64 * 1_024
    private let root: P8FSignedSmokeReceiptRoot
    private var artifactIdentity:
        P8FSignedSmokeFilesystemIdentity?

    init(
        isolatedRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let receiptRoot = try P8FSignedSmokeReceiptRoot(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        )
        root = receiptRoot
        artifactIdentity = try receiptRoot.mutableIdentity(
            for: .buildSourceSelection,
            maximumBytes: Self.maximumFileBytes
        )
    }

    func matchesSignedSmokeStorageBoundary(
        _ storageBoundary: P8FSignedSmokeStorageBoundary
    ) -> Bool {
        root.matches(storageBoundary: storageBoundary)
    }

    func load() throws -> Set<SemanticIndexSourceKind>? {
        guard let data = try root.readMutable(
            .buildSourceSelection,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        ) else {
            return nil
        }
        do {
            try P8FSignedSmokeReceiptArtifactValidator
                .validateEncodedArtifact(
                    data,
                    as: .buildSourceSelection
                )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedBuildSourceSelection
        }
        let envelope: P8FSignedSmokeBuildSourceSelectionEnvelope
        do {
            envelope = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeBuildSourceSelectionEnvelope.self,
                from: data
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedBuildSourceSelection
        }
        guard envelope.schemaVersion
                == P8FSignedSmokeBuildSourceSelectionEnvelope
                    .currentSchemaVersion,
              envelope.sourceKinds
                == envelope.sourceKinds.sorted(),
              Set(envelope.sourceKinds).count
                == envelope.sourceKinds.count
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedBuildSourceSelection
        }
        let kinds = envelope.sourceKinds.compactMap(
            SemanticIndexSourceKind.init(rawValue:)
        )
        guard kinds.count == envelope.sourceKinds.count
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedBuildSourceSelection
        }
        let payloadHash = P8FSignedSmokeDigest.sha256(
            try P8FSignedSmokeJSON.encode(envelope.sourceKinds)
        )
        guard envelope.payloadSHA256 == payloadHash else {
            throw P8FSignedSmokeReceiptStoreFailure
                .payloadIntegrityMismatch
        }
        guard try P8FSignedSmokeJSON.encode(envelope) == data
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .noncanonicalEncoding
        }
        return Set(kinds)
    }

    func save(
        _ sourceKinds: Set<SemanticIndexSourceKind>
    ) throws {
        if artifactIdentity != nil {
            _ = try load()
        }
        let values = sourceKinds.map(\.rawValue).sorted()
        let envelope =
            try P8FSignedSmokeBuildSourceSelectionEnvelope(
                sourceKinds: values
            )
        let data = try P8FSignedSmokeJSON.encode(envelope)
        artifactIdentity = try root.writeMutable(
            data,
            to: .buildSourceSelection,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        )
    }

    func clear() throws {
        artifactIdentity = try root.removeMutable(
            .buildSourceSelection,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        )
    }
}

private enum P8FSignedSmokeSourceAuthorityReceiptValidator {
    private static let allowedStatuses: Set<String> = [
        "authorized",
        "blocked",
        "bound",
        "cancelled",
        "failed",
        "indexed",
        "narrowed",
        "not_indexed",
        "prepared",
        "rejected",
        "requested",
        "skipped",
        "started",
        "success",
    ]

    static func validate(
        _ event: P8SemanticSourceAuthorityEvent
    ) throws {
        guard safeToken(
                event.eventIdentifier,
                maximumBytes: 256
              ),
              event.eventIdentifier.hasPrefix(
                "semantic_authority_event_"
              ),
              event.occurredAt.timeIntervalSinceReferenceDate
                .isFinite,
              safeOptionalToken(
                event.sourceAuthorityVersion,
                maximumBytes: 128
              ),
              event.sourceAllowlistHash.map(
                P8FSignedSmokeDigest.isSHA256
              ) ?? true,
              safeOptionalToken(
                event.authorizationReceiptIdentifier,
                maximumBytes: 256
              ),
              event.buildInitiation == .signedSmokeRunner,
              event.sourceKinds == event.sourceKinds.sorted(),
              Set(event.sourceKinds).count
                == event.sourceKinds.count,
              event.sourceKinds.allSatisfy({
                  SemanticIndexSourceKind(rawValue: $0) != nil
              }),
              event.sourceKind.map({
                  SemanticIndexSourceKind(rawValue: $0) != nil
              }) ?? true,
              safeOptionalToken(
                event.adapterContractVersion,
                maximumBytes: 128
              ),
              validCount(event.preparedRecordCount),
              validCount(event.chunkCount),
              validCount(event.indexedCount),
              validCount(event.excludedCount),
              validCount(event.tombstoneCount),
              validCount(event.skippedCount),
              validCount(event.rejectedCount),
              event.generationIdentifier.map({
                  P8FSignedSmokeDigest.isSHA256($0)
                      || safeToken($0, maximumBytes: 256)
              }) ?? true,
              allowedStatuses.contains(event.status),
              stableReasonCode(event.reasonCode)
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .unsafeSourceAuthorityReceipt
        }
    }

    private static func validCount(_ value: Int) -> Bool {
        (0...10_000_000).contains(value)
    }

    private static func safeOptionalToken(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map {
            safeToken($0, maximumBytes: maximumBytes)
        } ?? true
    }

    private static func safeToken(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        guard !bytes.isEmpty, bytes.count <= maximumBytes
        else { return false }
        return bytes.allSatisfy { byte in
            (48...57).contains(byte)
                || (65...90).contains(byte)
                || (97...122).contains(byte)
                || byte == 45
                || byte == 46
                || byte == 95
        }
    }

    private static func stableReasonCode(_ value: String) -> Bool {
        guard value == value.lowercased(),
              safeToken(value, maximumBytes: 128)
        else {
            return false
        }
        return value.hasPrefix("semantic_")
            || value.hasPrefix("ollama_embedding_")
            || value.hasPrefix("embedding_assessment_")
            || value.hasPrefix("p8_")
    }
}

private struct P8FSignedSmokeSourceAuthorityReceiptsEnvelope:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.source-authority-receipts.v1"

    let schemaVersion: String
    let receipts: [P8SemanticSourceAuthorityEvent]
    let payloadSHA256: String

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case receipts
        case payloadSHA256 = "payload_sha256"
    }

    init(
        receipts: [P8SemanticSourceAuthorityEvent]
    ) throws {
        schemaVersion = Self.currentSchemaVersion
        self.receipts = receipts
        payloadSHA256 = P8FSignedSmokeDigest.sha256(
            try P8FSignedSmokeJSON.encode(receipts)
        )
    }
}

struct P8FSignedSmokeSourceAuthorityReceiptArtifact:
    Equatable,
    Sendable
{
    let receipts: [P8SemanticSourceAuthorityEvent]
    let canonicalSHA256: String

    var receiptCount: Int { receipts.count }
}

@MainActor
final class P8FSignedSmokeSemanticSourceAuthorityReceiptStore:
    P8SemanticSourceAuthorityReceiptStoring
{
    private static let maximumReceiptCount = 4_096
    private static let maximumFileBytes = 4 * 1_024 * 1_024
    private let root: P8FSignedSmokeReceiptRoot
    private var artifactIdentity:
        P8FSignedSmokeFilesystemIdentity?

    init(
        isolatedRoot: URL,
        fileManager: FileManager = .default
    ) throws {
        let receiptRoot = try P8FSignedSmokeReceiptRoot(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        )
        root = receiptRoot
        artifactIdentity = try receiptRoot.mutableIdentity(
            for: .sourceAuthorityReceipts,
            maximumBytes: Self.maximumFileBytes
        )
    }

    func matchesSignedSmokeStorageBoundary(
        _ storageBoundary: P8FSignedSmokeStorageBoundary
    ) -> Bool {
        root.matches(storageBoundary: storageBoundary)
    }

    func load() throws -> [P8SemanticSourceAuthorityEvent] {
        try loadValidatedArtifact()?.receipts ?? []
    }

    func loadValidatedArtifact() throws
        -> P8FSignedSmokeSourceAuthorityReceiptArtifact?
    {
        guard let data = try root.readMutable(
            .sourceAuthorityReceipts,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        ) else {
            return nil
        }
        do {
            try P8FSignedSmokeReceiptArtifactValidator
                .validateEncodedArtifact(
                    data,
                    as: .sourceAuthorityReceipts
                )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedSourceAuthorityReceipts
        }
        let envelope:
            P8FSignedSmokeSourceAuthorityReceiptsEnvelope
        do {
            envelope = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeSourceAuthorityReceiptsEnvelope
                    .self,
                from: data
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedSourceAuthorityReceipts
        }
        guard envelope.schemaVersion
                == P8FSignedSmokeSourceAuthorityReceiptsEnvelope
                    .currentSchemaVersion,
              envelope.receipts.count
                <= Self.maximumReceiptCount,
              Set(envelope.receipts.map(\.eventIdentifier))
                .count == envelope.receipts.count
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedSourceAuthorityReceipts
        }
        for receipt in envelope.receipts {
            try P8FSignedSmokeSourceAuthorityReceiptValidator
                .validate(receipt)
        }
        let payloadHash = P8FSignedSmokeDigest.sha256(
            try P8FSignedSmokeJSON.encode(envelope.receipts)
        )
        guard envelope.payloadSHA256 == payloadHash else {
            throw P8FSignedSmokeReceiptStoreFailure
                .payloadIntegrityMismatch
        }
        guard try P8FSignedSmokeJSON.encode(envelope) == data
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .noncanonicalEncoding
        }
        return .init(
            receipts: envelope.receipts,
            canonicalSHA256:
                P8FSignedSmokeDigest.sha256(data)
        )
    }

    func save(
        _ receipts: [P8SemanticSourceAuthorityEvent]
    ) throws {
        guard receipts.count <= Self.maximumReceiptCount
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedSourceAuthorityReceipts
        }
        if artifactIdentity != nil {
            _ = try load()
        }
        guard Set(receipts.map(\.eventIdentifier)).count
                == receipts.count
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .malformedSourceAuthorityReceipts
        }
        for receipt in receipts {
            try P8FSignedSmokeSourceAuthorityReceiptValidator
                .validate(receipt)
        }
        let envelope =
            try P8FSignedSmokeSourceAuthorityReceiptsEnvelope(
                receipts: receipts
            )
        let data = try P8FSignedSmokeJSON.encode(envelope)
        artifactIdentity = try root.writeMutable(
            data,
            to: .sourceAuthorityReceipts,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        )
    }

    func clear() throws {
        artifactIdentity = try root.removeMutable(
            .sourceAuthorityReceipts,
            expectedIdentity: artifactIdentity,
            maximumBytes: Self.maximumFileBytes
        )
    }
}

enum P8FSignedSmokeStatus:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case started
    case success
    case degraded
    case failed
    case skipped
    case cancelled
}

enum P8FSignedSmokeEventName:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case run = "p8f.smoke.run"
    case admission = "p8f.smoke.admission"
    case storageIsolation = "p8f.smoke.storage_isolation"
    case fixture = "p8f.smoke.fixture"
    case sourceAuthority = "p8f.smoke.source_authority"
    case sourceAdapter = "p8f.smoke.source_adapter"
    case generation = "p8f.smoke.generation"
    case modelCapability = "p8f.smoke.model_capability"
    case search = "p8f.smoke.search"
    case privacy = "p8f.smoke.privacy"
    case network = "p8f.smoke.network"
    case cleanup = "p8f.smoke.cleanup"
    case receiptPersistence = "p8f.smoke.receipt_persistence"
}

enum P8FSignedSmokeComponent:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case runner = "p8f_signed_smoke_runner"
    case persistence = "p8f_signed_smoke_persistence"
    case semanticSourceAuthority =
        "p8f_semantic_source_authority"
    case semanticIndex = "p8f_semantic_index"
    case modelProvider = "p8f_model_provider"
    case retrieval = "p8f_retrieval"
    case privacyGuard = "p8f_privacy_guard"
    case networkGuard = "p8f_network_guard"
    case cleanup = "p8f_cleanup"
}

enum P8FSignedSmokeReasonCode:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case runStarted = "p8f_smoke_run_started"
    case runCancellationObserved =
        "p8f_smoke_run_cancellation_observed"
    case runCompleted = "p8f_smoke_run_completed"
    case runFailed = "p8f_smoke_run_failed"
    case runCancelled = "p8f_smoke_run_cancelled"
    case admissionAccepted =
        "p8f_smoke_admission_accepted"
    case admissionRejected =
        "p8f_smoke_admission_rejected"
    case storageSelected =
        "p8f_smoke_storage_selected"
    case storageRejected =
        "p8f_smoke_storage_rejected"
    case fixtureAccepted =
        "p8f_smoke_fixture_accepted"
    case fixtureRejected =
        "p8f_smoke_fixture_rejected"
    case sourceScopeAuthorized =
        "p8f_smoke_source_scope_authorized"
    case sourceScopeRejected =
        "p8f_smoke_source_scope_rejected"
    case adapterInvoked =
        "p8f_smoke_adapter_invoked"
    case adapterSkipped =
        "p8f_smoke_adapter_skipped"
    case adapterFailed =
        "p8f_smoke_adapter_failed"
    case excludedAdapterActivity =
        "p8f_smoke_excluded_adapter_activity"
    case counterReconciliationFailed =
        "p8f_smoke_counter_reconciliation_failed"
    case generationStaged =
        "p8f_smoke_generation_staged"
    case generationPublished =
        "p8f_smoke_generation_published"
    case generationDiscarded =
        "p8f_smoke_generation_discarded"
    case generationFailed =
        "p8f_smoke_generation_failed"
    case cancelledBeforePublication =
        "p8f_smoke_cancelled_before_publication"
    case scopeRevokedBeforePublication =
        "p8f_smoke_scope_revoked_before_publication"
    case modelProfileDrift =
        "p8f_smoke_model_profile_drift"
    case adapterContractDrift =
        "p8f_smoke_adapter_contract_drift"
    case transactionIntegrityFailed =
        "p8f_smoke_transaction_integrity_failed"
    case unknownSourceKindRejected =
        "p8f_smoke_unknown_source_kind_rejected"
    case modelCapabilityPassed =
        "p8f_smoke_model_capability_passed"
    case modelCapabilityFailed =
        "p8f_smoke_model_capability_failed"
    case roleSeparationPassed =
        "p8f_smoke_role_separation_passed"
    case visionRouteDecisionObserved =
        "p8f_smoke_vision_route_decision_observed"
    case visionTransportConfirmed =
        "p8f_smoke_vision_transport_confirmed"
    case webResearchDisabled =
        "p8f_smoke_web_research_disabled"
    case webResearchDisabledWithoutKey =
        "p8f_smoke_web_research_disabled_without_key"
    case providerTransportSucceeded =
        "p8f_smoke_provider_transport_succeeded"
    case providerTransportFailed =
        "p8f_smoke_provider_transport_failed"
    case providerTransportCancelled =
        "p8f_smoke_provider_transport_cancelled"
    case searchPassed = "p8f_smoke_search_passed"
    case searchFailed = "p8f_smoke_search_failed"
    case searchFilterNarrowed =
        "p8f_smoke_search_filter_narrowed"
    case excludedSourceFilterEmpty =
        "p8f_smoke_excluded_source_filter_empty"
    case legacyGenerationPreserved =
        "p8f_smoke_legacy_generation_preserved_nonqueryable"
    case staleIdentityRejected =
        "p8f_smoke_stale_identity_rejected"
    case malformedIdentityRejected =
        "p8f_smoke_malformed_identity_rejected"
    case privacyPassed = "p8f_smoke_privacy_passed"
    case privacyFailed = "p8f_smoke_privacy_failed"
    case nonLoopbackTransport =
        "p8f_smoke_non_loopback_transport"
    case credentialAccessAttempted =
        "p8f_smoke_credential_access_attempted"
    case cleanupPassed = "p8f_smoke_cleanup_passed"
    case cleanupFailed = "p8f_smoke_cleanup_failed"
    case receiptPersisted =
        "p8f_smoke_receipt_persisted"
    case receiptPersistenceFailed =
        "p8f_smoke_receipt_persistence_failed"
}

enum P8FSignedSmokeScenario:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case run
    case storageIsolation = "storage_isolation"
    case sourceAuthority = "source_authority"
    case cancellation
    case revocation
    case modelProfileDrift = "model_profile_drift"
    case adapterContractDrift = "adapter_contract_drift"
    case unknownSourceKind = "unknown_source_kind"
    case transactionIntegrity =
        "transaction_integrity"
    case successfulPublication =
        "successful_publication"
    case restartHydration = "restart_hydration"
    case legacyHydration = "legacy_hydration"
    case staleHydration = "stale_hydration"
    case malformedHydration = "malformed_hydration"
    case gemma4
    case gptOSS = "gpt_oss"
    case qwenEmbedding = "qwen_embedding"
    case roleSeparation = "role_separation"
    case visibleVisionRouting =
        "visible_vision_routing"
    case webResearchDisabled =
        "web_research_disabled"
    case lexicalSearch = "lexical_search"
    case semanticSearch = "semantic_search"
    case hybridSearch = "hybrid_search"
    case searchNarrowing = "search_narrowing"
    case excludedSourceSearch =
        "excluded_source_search"
    case receiptPrivacy = "receipt_privacy"
    case cleanup
}

enum P8FSignedSmokeApprovedModel:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case gemma4 = "gemma4:12b"
    case gptOSS = "gpt-oss:20b"
    case qwenEmbedding = "qwen3-embedding:0.6b"
}

enum P8FSignedSmokeArtifactClassification:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case fixtureManifest = "fixture_manifest"
    case sourceAuthorityReceipt =
        "source_authority_receipt"
    case eventChain = "event_chain"
    case terminalReceipt = "terminal_receipt"
    case diagnosticArtifactManifest =
        "diagnostic_artifact_manifest"
    case derivedSemanticIndex =
        "derived_semantic_index"
}

enum P8FSignedSmokeEndpointClassification:
    String,
    Codable,
    CaseIterable,
    Hashable,
    Sendable
{
    case ollamaIPv4Loopback =
        "ollama_ipv4_loopback_11434"
    case ollamaIPv6Loopback =
        "ollama_ipv6_loopback_11434"
    case ollamaModelIPv4Loopback =
        "ollama_model_ipv4_loopback_11434"
    case ollamaModelIPv6Loopback =
        "ollama_model_ipv6_loopback_11434"
    case nonLoopback = "non_loopback"
    case none
}

enum P8FSignedSmokeTransportObservationClassification:
    String,
    Codable,
    Hashable,
    Sendable
{
    case modelTransport = "model_transport"
}

enum P8FSignedSmokeTransportObservationEvidenceSource:
    String,
    Codable,
    Hashable,
    Sendable
{
    case externalContinuousSocketWatcher =
        "external_continuous_socket_watcher"
}

enum P8FSignedSmokeTransportObservationResult:
    String,
    Codable,
    Hashable,
    Sendable
{
    case loopbackOnly = "loopback_only"
    case noSocketObserved = "no_socket_observed"
    case nonLoopbackObserved = "non_loopback_observed"
}

struct P8FSignedSmokeCounters:
    Codable,
    Equatable,
    Sendable
{
    let adapterInvocations: Int
    let recordsRead: Int
    let recordsAccepted: Int
    let recordsRejected: Int
    let preparedRecords: Int
    let chunks: Int
    let embeddingRequests: Int
    let embeddingsAccepted: Int
    let indexWrites: Int
    let resultCount: Int
    let leakageCanaryHits: Int

    enum CodingKeys: String, CodingKey {
        case adapterInvocations = "adapter_invocations"
        case recordsRead = "records_read"
        case recordsAccepted = "records_accepted"
        case recordsRejected = "records_rejected"
        case preparedRecords = "prepared_records"
        case chunks
        case embeddingRequests = "embedding_requests"
        case embeddingsAccepted = "embeddings_accepted"
        case indexWrites = "index_writes"
        case resultCount = "result_count"
        case leakageCanaryHits = "leakage_canary_hits"
    }

    init(
        adapterInvocations: Int = 0,
        recordsRead: Int = 0,
        recordsAccepted: Int = 0,
        recordsRejected: Int = 0,
        preparedRecords: Int = 0,
        chunks: Int = 0,
        embeddingRequests: Int = 0,
        embeddingsAccepted: Int = 0,
        indexWrites: Int = 0,
        resultCount: Int = 0,
        leakageCanaryHits: Int = 0
    ) throws {
        let values = [
            adapterInvocations,
            recordsRead,
            recordsAccepted,
            recordsRejected,
            preparedRecords,
            chunks,
            embeddingRequests,
            embeddingsAccepted,
            indexWrites,
            resultCount,
            leakageCanaryHits,
        ]
        guard values.allSatisfy({
            (0...10_000_000).contains($0)
        }) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
        self.adapterInvocations = adapterInvocations
        self.recordsRead = recordsRead
        self.recordsAccepted = recordsAccepted
        self.recordsRejected = recordsRejected
        self.preparedRecords = preparedRecords
        self.chunks = chunks
        self.embeddingRequests = embeddingRequests
        self.embeddingsAccepted = embeddingsAccepted
        self.indexWrites = indexWrites
        self.resultCount = resultCount
        self.leakageCanaryHits = leakageCanaryHits
    }
}

struct P8FSignedSmokeEventMetadata:
    Codable,
    Equatable,
    Sendable
{
    let scenario: P8FSignedSmokeScenario
    let sourceKind: SemanticIndexSourceKind?
    let model: P8FSignedSmokeApprovedModel?
    let searchMode: SemanticSearchMode?
    let artifactClassification:
        P8FSignedSmokeArtifactClassification?
    let endpointClassification:
        P8FSignedSmokeEndpointClassification?
    let fixtureManifestSHA256: String?
    let sourceAllowlistSHA256: String?
    let generationIdentifierSHA256: String?
    let authorizationReceiptIdentifierSHA256: String?
    let modelDigest: String?
    let runtimeIdentitySHA256: String?
    let requestProfileSHA256: String?
    let artifactSHA256: String?
    let vectorDimension: Int?
    let counters: P8FSignedSmokeCounters?
    let processIdentifier: Int?
    let executableSHA256: String?
    let providerRequestTraceSHA256: String?
    let providerRequestIdentifierSHA256: String?
    let providerKind: P8FProviderRequestKind?
    let providerOperationKind: P8FProviderRequestOperation?
    let providerOutcome: P8FProviderRequestOutcome?
    let providerIntervalStartedAt: Date?
    let providerIntervalEndedAt: Date?
    let providerIntervalDurationMilliseconds: Int?
    let externalWatcherIntervalStartedAt: Date?
    let externalWatcherIntervalEndedAt: Date?
    let externalWatcherIntervalDurationMilliseconds: Int?
    let transportObservationEvidenceSource:
        P8FSignedSmokeTransportObservationEvidenceSource?
    let transportObservationClassification:
        P8FSignedSmokeTransportObservationClassification?
    let transportObservationResult:
        P8FSignedSmokeTransportObservationResult?
    let observedEndpointClassification:
        P8FSignedSmokeEndpointClassification?

    enum CodingKeys: String, CodingKey {
        case scenario
        case sourceKind = "source_kind"
        case model
        case searchMode = "search_mode"
        case artifactClassification =
            "artifact_classification"
        case endpointClassification =
            "endpoint_classification"
        case fixtureManifestSHA256 =
            "fixture_manifest_sha256"
        case sourceAllowlistSHA256 =
            "source_allowlist_sha256"
        case generationIdentifierSHA256 =
            "generation_identifier_sha256"
        case authorizationReceiptIdentifierSHA256 =
            "authorization_receipt_identifier_sha256"
        case modelDigest = "model_digest"
        case runtimeIdentitySHA256 =
            "runtime_identity_sha256"
        case requestProfileSHA256 =
            "request_profile_sha256"
        case artifactSHA256 = "artifact_sha256"
        case vectorDimension = "vector_dimension"
        case counters
        case processIdentifier = "process_pid"
        case executableSHA256 = "executable_sha256"
        case providerRequestTraceSHA256 =
            "provider_request_trace_sha256"
        case providerRequestIdentifierSHA256 =
            "provider_request_id_sha256"
        case providerKind = "provider_kind"
        case providerOperationKind = "provider_operation_kind"
        case providerOutcome = "provider_outcome"
        case providerIntervalStartedAt =
            "provider_interval_started_at"
        case providerIntervalEndedAt =
            "provider_interval_ended_at"
        case providerIntervalDurationMilliseconds =
            "provider_interval_duration_ms"
        case externalWatcherIntervalStartedAt =
            "external_watcher_interval_started_at"
        case externalWatcherIntervalEndedAt =
            "external_watcher_interval_ended_at"
        case externalWatcherIntervalDurationMilliseconds =
            "external_watcher_interval_duration_ms"
        case transportObservationEvidenceSource =
            "transport_observation_evidence_source"
        case transportObservationClassification =
            "transport_observation_classification"
        case transportObservationResult =
            "transport_observation_result"
        case observedEndpointClassification =
            "observed_endpoint_classification"
    }

    init(
        scenario: P8FSignedSmokeScenario,
        sourceKind: SemanticIndexSourceKind? = nil,
        model: P8FSignedSmokeApprovedModel? = nil,
        searchMode: SemanticSearchMode? = nil,
        artifactClassification:
            P8FSignedSmokeArtifactClassification? = nil,
        endpointClassification:
            P8FSignedSmokeEndpointClassification? = nil,
        fixtureManifestSHA256: String? = nil,
        sourceAllowlistSHA256: String? = nil,
        generationIdentifierSHA256: String? = nil,
        authorizationReceiptIdentifierSHA256: String? = nil,
        modelDigest: String? = nil,
        runtimeIdentitySHA256: String? = nil,
        requestProfileSHA256: String? = nil,
        artifactSHA256: String? = nil,
        vectorDimension: Int? = nil,
        counters: P8FSignedSmokeCounters? = nil,
        processIdentifier: Int? = nil,
        executableSHA256: String? = nil,
        providerRequestTraceSHA256: String? = nil,
        providerRequestIdentifierSHA256: String? = nil,
        providerKind: P8FProviderRequestKind? = nil,
        providerOperationKind:
            P8FProviderRequestOperation? = nil,
        providerOutcome: P8FProviderRequestOutcome? = nil,
        providerIntervalStartedAt: Date? = nil,
        providerIntervalEndedAt: Date? = nil,
        providerIntervalDurationMilliseconds: Int? = nil,
        externalWatcherIntervalStartedAt: Date? = nil,
        externalWatcherIntervalEndedAt: Date? = nil,
        externalWatcherIntervalDurationMilliseconds:
            Int? = nil,
        transportObservationEvidenceSource:
            P8FSignedSmokeTransportObservationEvidenceSource? =
                nil,
        transportObservationClassification:
            P8FSignedSmokeTransportObservationClassification? =
                nil,
        transportObservationResult:
            P8FSignedSmokeTransportObservationResult? = nil,
        observedEndpointClassification:
            P8FSignedSmokeEndpointClassification? = nil
    ) throws {
        let hashes = [
            fixtureManifestSHA256,
            sourceAllowlistSHA256,
            generationIdentifierSHA256,
            authorizationReceiptIdentifierSHA256,
            modelDigest,
            runtimeIdentitySHA256,
            requestProfileSHA256,
            artifactSHA256,
            executableSHA256,
            providerRequestTraceSHA256,
            providerRequestIdentifierSHA256,
        ]
        guard hashes.compactMap({ $0 }).allSatisfy(
                P8FSignedSmokeDigest.isSHA256
              ),
              vectorDimension.map({
                  (1...32_768).contains($0)
              }) ?? true,
              Self.correlationFieldsAreValid(
                processIdentifier: processIdentifier,
                executableSHA256: executableSHA256,
                providerRequestTraceSHA256:
                    providerRequestTraceSHA256,
                providerRequestIdentifierSHA256:
                    providerRequestIdentifierSHA256,
                providerKind: providerKind,
                providerOperationKind: providerOperationKind,
                providerOutcome: providerOutcome,
                providerIntervalStartedAt:
                    providerIntervalStartedAt,
                providerIntervalEndedAt:
                    providerIntervalEndedAt,
                providerIntervalDurationMilliseconds:
                    providerIntervalDurationMilliseconds,
                externalWatcherIntervalStartedAt:
                    externalWatcherIntervalStartedAt,
                externalWatcherIntervalEndedAt:
                    externalWatcherIntervalEndedAt,
                externalWatcherIntervalDurationMilliseconds:
                    externalWatcherIntervalDurationMilliseconds,
                transportObservationEvidenceSource:
                    transportObservationEvidenceSource,
                transportObservationClassification:
                    transportObservationClassification,
                transportObservationResult:
                    transportObservationResult,
                endpointClassification:
                    endpointClassification,
                observedEndpointClassification:
                    observedEndpointClassification
              )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
        self.scenario = scenario
        self.sourceKind = sourceKind
        self.model = model
        self.searchMode = searchMode
        self.artifactClassification =
            artifactClassification
        self.endpointClassification = endpointClassification
        self.fixtureManifestSHA256 =
            fixtureManifestSHA256
        self.sourceAllowlistSHA256 =
            sourceAllowlistSHA256
        self.generationIdentifierSHA256 =
            generationIdentifierSHA256
        self.authorizationReceiptIdentifierSHA256 =
            authorizationReceiptIdentifierSHA256
        self.modelDigest = modelDigest
        self.runtimeIdentitySHA256 =
            runtimeIdentitySHA256
        self.requestProfileSHA256 =
            requestProfileSHA256
        self.artifactSHA256 = artifactSHA256
        self.vectorDimension = vectorDimension
        self.counters = counters
        self.processIdentifier = processIdentifier
        self.executableSHA256 = executableSHA256
        self.providerRequestTraceSHA256 =
            providerRequestTraceSHA256
        self.providerRequestIdentifierSHA256 =
            providerRequestIdentifierSHA256
        self.providerKind = providerKind
        self.providerOperationKind = providerOperationKind
        self.providerOutcome = providerOutcome
        self.providerIntervalStartedAt =
            providerIntervalStartedAt
        self.providerIntervalEndedAt =
            providerIntervalEndedAt
        self.providerIntervalDurationMilliseconds =
            providerIntervalDurationMilliseconds
        self.externalWatcherIntervalStartedAt =
            externalWatcherIntervalStartedAt
        self.externalWatcherIntervalEndedAt =
            externalWatcherIntervalEndedAt
        self.externalWatcherIntervalDurationMilliseconds =
            externalWatcherIntervalDurationMilliseconds
        self.transportObservationEvidenceSource =
            transportObservationEvidenceSource
        self.transportObservationClassification =
            transportObservationClassification
        self.transportObservationResult =
            transportObservationResult
        self.observedEndpointClassification =
            observedEndpointClassification
    }

    var hasCompleteProviderCorrelation: Bool {
        processIdentifier != nil
            && executableSHA256 != nil
            && providerRequestTraceSHA256 != nil
            && providerRequestIdentifierSHA256 != nil
            && providerKind != nil
            && providerOperationKind != nil
            && providerOutcome != nil
            && providerIntervalStartedAt != nil
            && providerIntervalEndedAt != nil
            && providerIntervalDurationMilliseconds != nil
            && endpointClassification.map {
                Self.modelEndpointClassifications.contains($0)
            } == true
    }

    var hasCompleteExternalObservation: Bool {
        externalWatcherIntervalStartedAt != nil
            && externalWatcherIntervalEndedAt != nil
            && externalWatcherIntervalDurationMilliseconds
                != nil
            && transportObservationEvidenceSource != nil
            && transportObservationClassification != nil
            && transportObservationResult != nil
            && observedEndpointClassification != nil
    }

    static func eventContextIsValid(
        event: P8FSignedSmokeEventName,
        component: P8FSignedSmokeComponent,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        durationMilliseconds: Int,
        timestamp: Date,
        metadata: P8FSignedSmokeEventMetadata
    ) -> Bool {
        guard eventSemanticIsValid(
            event: event,
            component: component,
            status: status,
            reasonCode: reasonCode,
            metadata: metadata
        ) else {
            return false
        }
        if metadata.artifactClassification
            == .sourceAuthorityReceipt
        {
            guard event == .sourceAuthority,
                  component == .semanticSourceAuthority,
                  status == .success,
                  reasonCode == .sourceScopeAuthorized,
                  metadata.scenario == .sourceAuthority,
                  metadata.artifactSHA256 != nil
            else {
                return false
            }
        }
        let transportReason = [
            .providerTransportSucceeded,
            .providerTransportFailed,
            .providerTransportCancelled,
            .nonLoopbackTransport,
        ].contains(reasonCode)
        let requiresProviderCorrelation =
            (event == .network && metadata.model != nil)
                || transportReason
        guard !requiresProviderCorrelation
                || metadata.hasCompleteProviderCorrelation,
              !metadata.hasCompleteProviderCorrelation
                || (event == .network && metadata.model != nil)
        else {
            return false
        }
        if metadata.hasCompleteExternalObservation {
            return timestamp
                == metadata.externalWatcherIntervalEndedAt
                && durationMilliseconds
                    == metadata
                        .externalWatcherIntervalDurationMilliseconds
        }
        if metadata.hasCompleteProviderCorrelation {
            return timestamp == metadata.providerIntervalEndedAt
                && durationMilliseconds
                    == metadata
                        .providerIntervalDurationMilliseconds
        }
        return true
    }

    private static func eventSemanticIsValid(
        event: P8FSignedSmokeEventName,
        component: P8FSignedSmokeComponent,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        metadata: P8FSignedSmokeEventMetadata
    ) -> Bool {
        let expected: (
            P8FSignedSmokeEventName,
            Set<P8FSignedSmokeComponent>,
            Set<P8FSignedSmokeStatus>
        )
        switch reasonCode {
        case .runStarted:
            expected = (.run, [.runner], [.started])
        case .runCancellationObserved:
            expected = (.run, [.runner], [.started])
        case .runCompleted:
            expected = (.run, [.runner], [.success])
        case .runFailed:
            expected = (.run, [.runner], [.failed])
        case .runCancelled:
            expected = (.run, [.runner], [.cancelled])
        case .admissionAccepted:
            expected = (.admission, [.runner], [.success])
        case .admissionRejected:
            expected = (.admission, [.runner], [.failed])
        case .storageSelected:
            expected = (.storageIsolation, [.persistence], [.success])
        case .storageRejected:
            expected = (.storageIsolation, [.persistence], [.failed])
        case .fixtureAccepted:
            expected = (.fixture, [.persistence], [.success])
        case .fixtureRejected:
            expected = (.fixture, [.persistence], [.failed])
        case .sourceScopeAuthorized,
             .unknownSourceKindRejected:
            expected = (
                .sourceAuthority,
                [.semanticSourceAuthority],
                [.success]
            )
        case .sourceScopeRejected:
            expected = (
                .sourceAuthority,
                [.semanticSourceAuthority],
                [.failed]
            )
        case .adapterInvoked,
             .adapterSkipped,
             .adapterContractDrift:
            expected = (
                .sourceAdapter,
                [.semanticSourceAuthority],
                [.success]
            )
        case .adapterFailed,
             .excludedAdapterActivity,
             .counterReconciliationFailed:
            expected = (
                .sourceAdapter,
                [.semanticSourceAuthority],
                [.failed]
            )
        case .generationStaged:
            expected = (.generation, [.semanticIndex], [.started])
        case .generationPublished,
             .generationDiscarded,
             .legacyGenerationPreserved,
             .staleIdentityRejected,
             .malformedIdentityRejected,
             .transactionIntegrityFailed:
            expected = (.generation, [.semanticIndex], [.success])
        case .generationFailed:
            expected = (.generation, [.semanticIndex], [.failed])
        case .cancelledBeforePublication,
             .scopeRevokedBeforePublication,
             .modelProfileDrift:
            expected = (.generation, [.semanticIndex], [.cancelled])
        case .modelCapabilityPassed,
             .roleSeparationPassed,
             .visionRouteDecisionObserved,
             .visionTransportConfirmed:
            expected = (.modelCapability, [.modelProvider], [.success])
        case .modelCapabilityFailed:
            expected = (.modelCapability, [.modelProvider], [.failed])
        case .webResearchDisabled,
             .webResearchDisabledWithoutKey:
            expected = (.network, [.networkGuard], [.success])
        case .providerTransportSucceeded:
            guard metadata.providerOutcome == .succeeded else {
                return false
            }
            expected = (.network, [.modelProvider], [.success])
        case .providerTransportFailed:
            guard metadata.providerOutcome == .failed else {
                return false
            }
            expected = (.network, [.modelProvider], [.failed])
        case .providerTransportCancelled:
            guard metadata.providerOutcome == .cancelled else {
                return false
            }
            expected = (.network, [.modelProvider], [.cancelled])
        case .nonLoopbackTransport,
             .credentialAccessAttempted:
            expected = (.network, [.networkGuard], [.failed])
        case .searchPassed,
             .searchFilterNarrowed,
             .excludedSourceFilterEmpty:
            expected = (.search, [.retrieval], [.success])
        case .searchFailed:
            expected = (.search, [.retrieval], [.failed])
        case .privacyPassed:
            expected = (.privacy, [.privacyGuard], [.success])
        case .privacyFailed:
            expected = (
                event == .run ? .run : .privacy,
                event == .run ? [.runner] : [.privacyGuard],
                [.failed]
            )
        case .cleanupPassed:
            expected = (.cleanup, [.cleanup], [.success])
        case .cleanupFailed:
            expected = (
                event == .run ? .run : .cleanup,
                event == .run ? [.runner] : [.cleanup],
                [.failed]
            )
        case .receiptPersisted:
            expected = (
                .receiptPersistence,
                [.persistence],
                [.success]
            )
        case .receiptPersistenceFailed:
            expected = (
                event == .run ? .run : .receiptPersistence,
                event == .run ? [.runner] : [.persistence],
                [.failed]
            )
        }
        return event == expected.0
            && expected.1.contains(component)
            && expected.2.contains(status)
    }

    static func correlationFieldsAreValid(
        processIdentifier: Int?,
        executableSHA256: String?,
        providerRequestTraceSHA256: String?,
        providerRequestIdentifierSHA256: String?,
        providerKind: P8FProviderRequestKind?,
        providerOperationKind: P8FProviderRequestOperation?,
        providerOutcome: P8FProviderRequestOutcome?,
        providerIntervalStartedAt: Date?,
        providerIntervalEndedAt: Date?,
        providerIntervalDurationMilliseconds: Int?,
        externalWatcherIntervalStartedAt: Date?,
        externalWatcherIntervalEndedAt: Date?,
        externalWatcherIntervalDurationMilliseconds: Int?,
        transportObservationEvidenceSource:
            P8FSignedSmokeTransportObservationEvidenceSource?,
        transportObservationClassification:
            P8FSignedSmokeTransportObservationClassification?,
        transportObservationResult:
            P8FSignedSmokeTransportObservationResult?,
        endpointClassification:
            P8FSignedSmokeEndpointClassification?,
        observedEndpointClassification:
            P8FSignedSmokeEndpointClassification?
    ) -> Bool {
        let endpointRequiresProviderCorrelation =
            endpointClassification.map {
                modelEndpointClassifications.contains($0)
            } == true
        let providerCorrelationIsPresent =
            processIdentifier != nil
                || executableSHA256 != nil
                || providerRequestTraceSHA256 != nil
                || providerRequestIdentifierSHA256 != nil
                || providerKind != nil
                || providerOperationKind != nil
                || providerOutcome != nil
                || providerIntervalStartedAt != nil
                || providerIntervalEndedAt != nil
                || providerIntervalDurationMilliseconds != nil
                || endpointRequiresProviderCorrelation
        let externalObservationIsPresent =
            externalWatcherIntervalStartedAt != nil
                || externalWatcherIntervalEndedAt != nil
                || externalWatcherIntervalDurationMilliseconds
                    != nil
                || transportObservationEvidenceSource != nil
                || transportObservationClassification != nil
                || transportObservationResult != nil
                || observedEndpointClassification != nil
        guard providerCorrelationIsPresent else {
            return !externalObservationIsPresent
        }
        guard let processIdentifier,
              (1...Int(Int32.max)).contains(
                processIdentifier
              ),
              let executableSHA256,
              P8FSignedSmokeDigest.isSHA256(
                executableSHA256
              ),
              let providerRequestTraceSHA256,
              P8FSignedSmokeDigest.isSHA256(
                providerRequestTraceSHA256
              ),
              let providerRequestIdentifierSHA256,
              P8FSignedSmokeDigest.isSHA256(
                providerRequestIdentifierSHA256
              ),
              let providerKind,
              let providerOperationKind,
              providerOutcome != nil,
              providerOperationIsValid(
                providerKind: providerKind,
                operationKind: providerOperationKind
              ),
              let providerIntervalStartedAt,
              let providerIntervalEndedAt,
              providerIntervalStartedAt
                .timeIntervalSinceReferenceDate.isFinite,
              providerIntervalEndedAt
                .timeIntervalSinceReferenceDate.isFinite,
              providerIntervalEndedAt
                >= providerIntervalStartedAt,
              let providerIntervalDurationMilliseconds,
              (1...86_400_000).contains(
                providerIntervalDurationMilliseconds
              ),
              let endpointClassification,
              modelEndpointClassifications.contains(
                endpointClassification
              )
        else {
            return false
        }
        guard measuredDurationMilliseconds(
                from: providerIntervalStartedAt,
                through: providerIntervalEndedAt
              ) == providerIntervalDurationMilliseconds
        else {
            return false
        }
        guard externalObservationIsPresent else {
            return true
        }
        guard let externalWatcherIntervalStartedAt,
              let externalWatcherIntervalEndedAt,
              externalWatcherIntervalStartedAt
                .timeIntervalSinceReferenceDate.isFinite,
              externalWatcherIntervalEndedAt
                .timeIntervalSinceReferenceDate.isFinite,
              externalWatcherIntervalStartedAt
                <= providerIntervalStartedAt,
              externalWatcherIntervalEndedAt
                >= providerIntervalEndedAt,
              let externalWatcherIntervalDurationMilliseconds,
              (1...86_400_000).contains(
                externalWatcherIntervalDurationMilliseconds
              ),
              transportObservationEvidenceSource
                == .externalContinuousSocketWatcher,
              transportObservationClassification
                == .modelTransport,
              let transportObservationResult,
              let observedEndpointClassification
        else {
            return false
        }
        guard measuredDurationMilliseconds(
                from: externalWatcherIntervalStartedAt,
                through: externalWatcherIntervalEndedAt
              ) == externalWatcherIntervalDurationMilliseconds
        else {
            return false
        }
        switch transportObservationResult {
        case .loopbackOnly:
            return [
                .ollamaModelIPv4Loopback,
                .ollamaModelIPv6Loopback,
            ].contains(observedEndpointClassification)
        case .noSocketObserved:
            return observedEndpointClassification == .none
        case .nonLoopbackObserved:
            return observedEndpointClassification
                == .nonLoopback
        }
    }

    private static let modelEndpointClassifications:
        Set<P8FSignedSmokeEndpointClassification> = [
            .ollamaModelIPv4Loopback,
            .ollamaModelIPv6Loopback,
        ]

    private static func providerOperationIsValid(
        providerKind: P8FProviderRequestKind,
        operationKind: P8FProviderRequestOperation
    ) -> Bool {
        switch providerKind {
        case .native:
            return [
                .versionCheck,
                .modelDiscovery,
                .generation,
            ].contains(operationKind)
        case .chat:
            return [
                .modelInspect,
                .chatStream,
            ].contains(operationKind)
        case .embedding:
            return operationKind == .embedding
        }
    }

    private static func measuredDurationMilliseconds(
        from start: Date,
        through end: Date
    ) -> Int? {
        let seconds = end.timeIntervalSince(start)
        guard seconds.isFinite,
              seconds > 0,
              seconds <= 86_400
        else {
            return nil
        }
        let milliseconds = seconds * 1_000
        guard milliseconds.isFinite else {
            return nil
        }
        let roundedMilliseconds = Int(milliseconds.rounded())
        guard (1...86_400_000).contains(roundedMilliseconds)
        else {
            return nil
        }
        return roundedMilliseconds
    }
}

struct P8FSignedSmokeEventDraft: Sendable {
    let event: P8FSignedSmokeEventName
    let parentSpanID: String?
    let component: P8FSignedSmokeComponent
    let status: P8FSignedSmokeStatus
    let reasonCode: P8FSignedSmokeReasonCode
    let durationMilliseconds: Int
    let metadata: P8FSignedSmokeEventMetadata
    let timestamp: Date

    init(
        event: P8FSignedSmokeEventName,
        parentSpanID: String? = nil,
        component: P8FSignedSmokeComponent,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        durationMilliseconds: Int = 0,
        metadata: P8FSignedSmokeEventMetadata,
        timestamp: Date = Date()
    ) throws {
        guard (0...3_600_000).contains(durationMilliseconds),
              timestamp.timeIntervalSinceReferenceDate.isFinite,
              P8FSignedSmokeEventMetadata
                .eventContextIsValid(
                    event: event,
                    component: component,
                    status: status,
                    reasonCode: reasonCode,
                    durationMilliseconds: durationMilliseconds,
                    timestamp: timestamp,
                    metadata: metadata
                )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
        self.event = event
        self.parentSpanID = parentSpanID
        self.component = component
        self.status = status
        self.reasonCode = reasonCode
        self.durationMilliseconds = durationMilliseconds
        self.metadata = metadata
        self.timestamp = timestamp
    }
}

struct P8FSignedSmokeEvent:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.signed-smoke-event.v2"

    let schemaVersion: String
    let sequence: UInt64
    let timestamp: Date
    let event: P8FSignedSmokeEventName
    let traceID: String
    let spanID: String
    let parentSpanID: String?
    let component: P8FSignedSmokeComponent
    let status: P8FSignedSmokeStatus
    let reasonCode: P8FSignedSmokeReasonCode
    let durationMilliseconds: Int
    let metadata: P8FSignedSmokeEventMetadata
    let previousEventSHA256: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case sequence
        case timestamp = "ts"
        case event
        case traceID = "trace_id"
        case spanID = "span_id"
        case parentSpanID = "parent_span_id"
        case component
        case status
        case reasonCode = "reason_code"
        case durationMilliseconds = "duration_ms"
        case metadata
        case previousEventSHA256 =
            "previous_event_sha256"
    }
}

enum P8FSignedSmokeReceiptBundleIdentity:
    String,
    Codable,
    Hashable,
    Sendable
{
    case p8fResumeSmoke =
        "com.agentloki.LokiBrief.P8FResumeSmoke"
}

enum P8FSignedSmokeStorageClassification:
    String,
    Codable,
    Hashable,
    Sendable
{
    case signedSmokeIsolatedDisk =
        "signed_smoke_isolated_disk"
}

struct P8FSignedSmokeReceiptApplicationIdentity:
    Codable,
    Equatable,
    Sendable
{
    let bundleIdentifier: P8FSignedSmokeReceiptBundleIdentity
    let marketingVersionMajor: Int
    let marketingVersionMinor: Int
    let marketingVersionPatch: Int
    let buildNumber: Int
    let executableSHA256: String
    let cdHash: String
    let storageClassification:
        P8FSignedSmokeStorageClassification

    enum CodingKeys: String, CodingKey {
        case bundleIdentifier = "bundle_identifier"
        case marketingVersionMajor =
            "marketing_version_major"
        case marketingVersionMinor =
            "marketing_version_minor"
        case marketingVersionPatch =
            "marketing_version_patch"
        case buildNumber = "build_number"
        case executableSHA256 = "executable_sha256"
        case cdHash = "cdhash"
        case storageClassification =
            "storage_classification"
    }

    init(
        bundleIdentifier:
            P8FSignedSmokeReceiptBundleIdentity =
                .p8fResumeSmoke,
        marketingVersionMajor: Int = 1,
        marketingVersionMinor: Int = 0,
        marketingVersionPatch: Int = 0,
        buildNumber: Int = 5,
        executableSHA256: String,
        cdHash: String,
        storageClassification:
            P8FSignedSmokeStorageClassification =
                .signedSmokeIsolatedDisk
    ) throws {
        guard marketingVersionMajor == 1,
              marketingVersionMinor == 0,
              marketingVersionPatch == 0,
              buildNumber == 5,
              P8FSignedSmokeDigest.isSHA256(
                executableSHA256
              ),
              P8FSignedSmokeDigest.isSHA1(cdHash)
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        self.bundleIdentifier = bundleIdentifier
        self.marketingVersionMajor =
            marketingVersionMajor
        self.marketingVersionMinor =
            marketingVersionMinor
        self.marketingVersionPatch =
            marketingVersionPatch
        self.buildNumber = buildNumber
        self.executableSHA256 = executableSHA256
        self.cdHash = cdHash
        self.storageClassification = storageClassification
    }
}

struct P8FSignedSmokePrivacySummary:
    Codable,
    Equatable,
    Sendable
{
    let artifactCount: Int
    let forbiddenFieldCount: Int
    let forbiddenValueCount: Int
    let rawVectorCount: Int
    let rawContentCount: Int
    let rawPromptCount: Int
    let rawResponseCount: Int
    let hiddenReasoningCount: Int
    let privatePathCount: Int
    let credentialCount: Int

    enum CodingKeys: String, CodingKey {
        case artifactCount = "artifact_count"
        case forbiddenFieldCount =
            "forbidden_field_count"
        case forbiddenValueCount =
            "forbidden_value_count"
        case rawVectorCount = "raw_vector_count"
        case rawContentCount = "raw_content_count"
        case rawPromptCount = "raw_prompt_count"
        case rawResponseCount = "raw_response_count"
        case hiddenReasoningCount =
            "hidden_reasoning_count"
        case privatePathCount = "private_path_count"
        case credentialCount = "credential_count"
    }

    var passed: Bool {
        forbiddenFieldCount == 0
            && forbiddenValueCount == 0
            && rawVectorCount == 0
            && rawContentCount == 0
            && rawPromptCount == 0
            && rawResponseCount == 0
            && hiddenReasoningCount == 0
            && privatePathCount == 0
            && credentialCount == 0
    }

    init(
        artifactCount: Int,
        forbiddenFieldCount: Int = 0,
        forbiddenValueCount: Int = 0,
        rawVectorCount: Int = 0,
        rawContentCount: Int = 0,
        rawPromptCount: Int = 0,
        rawResponseCount: Int = 0,
        hiddenReasoningCount: Int = 0,
        privatePathCount: Int = 0,
        credentialCount: Int = 0
    ) throws {
        let values = [
            artifactCount,
            forbiddenFieldCount,
            forbiddenValueCount,
            rawVectorCount,
            rawContentCount,
            rawPromptCount,
            rawResponseCount,
            hiddenReasoningCount,
            privatePathCount,
            credentialCount,
        ]
        guard values.allSatisfy({
            (0...10_000_000).contains($0)
        }) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        self.artifactCount = artifactCount
        self.forbiddenFieldCount = forbiddenFieldCount
        self.forbiddenValueCount = forbiddenValueCount
        self.rawVectorCount = rawVectorCount
        self.rawContentCount = rawContentCount
        self.rawPromptCount = rawPromptCount
        self.rawResponseCount = rawResponseCount
        self.hiddenReasoningCount = hiddenReasoningCount
        self.privatePathCount = privatePathCount
        self.credentialCount = credentialCount
    }
}

struct P8FSignedSmokeTerminalReceipt:
    Codable,
    Equatable,
    Sendable
{
    let scenario: P8FSignedSmokeScenario
    let status: P8FSignedSmokeStatus
    let reasonCode: P8FSignedSmokeReasonCode
    let startedAt: Date
    let completedAt: Date
    let applicationIdentity:
        P8FSignedSmokeReceiptApplicationIdentity
    let admissionAccepted: Bool?
    let fixtureAccepted: Bool?
    let fixtureManifestSHA256: String?
    let sourceAllowlistSHA256: String?
    let authorizationReceiptIdentifierSHA256: String?
    let semanticOutcomeState:
        P8SignedSmokeSemanticRebuildTerminalState?
    let generationIdentifierSHA256: String?
    let sourceCounters: P8FSignedSmokeCounters?
    let model: P8FSignedSmokeApprovedModel?
    let modelDigestSHA256: String?
    let modelAssessmentStatus: P8FSignedSmokeStatus?
    let searchMode: SemanticSearchMode?
    let searchPassed: Bool?
    let hydrationPassed: Bool?
    let cleanupPassed: Bool?
    let privacySummary: P8FSignedSmokePrivacySummary
    let artifactLedger: P8FSignedSmokeArtifactLedger?

    enum CodingKeys: String, CodingKey {
        case scenario
        case status
        case reasonCode = "reason_code"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case applicationIdentity =
            "application_identity"
        case admissionAccepted = "admission_accepted"
        case fixtureAccepted = "fixture_accepted"
        case fixtureManifestSHA256 =
            "fixture_manifest_sha256"
        case sourceAllowlistSHA256 =
            "source_allowlist_sha256"
        case authorizationReceiptIdentifierSHA256 =
            "authorization_receipt_identifier_sha256"
        case semanticOutcomeState =
            "semantic_outcome_state"
        case generationIdentifierSHA256 =
            "generation_identifier_sha256"
        case sourceCounters = "source_counters"
        case model
        case modelDigestSHA256 = "model_digest_sha256"
        case modelAssessmentStatus =
            "model_assessment_status"
        case searchMode = "search_mode"
        case searchPassed = "search_passed"
        case hydrationPassed = "hydration_passed"
        case cleanupPassed = "cleanup_passed"
        case privacySummary = "privacy_summary"
        case artifactLedger = "artifact_ledger"
    }

    init(
        scenario: P8FSignedSmokeScenario,
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode,
        startedAt: Date,
        completedAt: Date,
        applicationIdentity:
            P8FSignedSmokeReceiptApplicationIdentity,
        admissionAccepted: Bool? = nil,
        fixtureAccepted: Bool? = nil,
        fixtureManifestSHA256: String? = nil,
        sourceAllowlistSHA256: String? = nil,
        authorizationReceiptIdentifierSHA256:
            String? = nil,
        semanticOutcomeState:
            P8SignedSmokeSemanticRebuildTerminalState? = nil,
        generationIdentifierSHA256: String? = nil,
        sourceCounters: P8FSignedSmokeCounters? = nil,
        model: P8FSignedSmokeApprovedModel? = nil,
        modelDigestSHA256: String? = nil,
        modelAssessmentStatus:
            P8FSignedSmokeStatus? = nil,
        searchMode: SemanticSearchMode? = nil,
        searchPassed: Bool? = nil,
        hydrationPassed: Bool? = nil,
        cleanupPassed: Bool? = nil,
        privacySummary: P8FSignedSmokePrivacySummary,
        artifactLedger: P8FSignedSmokeArtifactLedger? = nil
    ) throws {
        let hashes = [
            fixtureManifestSHA256,
            sourceAllowlistSHA256,
            authorizationReceiptIdentifierSHA256,
            generationIdentifierSHA256,
            modelDigestSHA256,
        ]
        guard Self.terminalStatusAndReasonAreValid(
                status: status,
                reasonCode: reasonCode
              ),
              startedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt.timeIntervalSinceReferenceDate.isFinite,
              completedAt >= startedAt,
              hashes.compactMap({ $0 }).allSatisfy(
                P8FSignedSmokeDigest.isSHA256
              ),
              modelDigestSHA256 == nil || model != nil,
              modelAssessmentStatus == nil || model != nil,
              searchPassed == nil || searchMode != nil,
              status != .cancelled
                || (
                    privacySummary.passed
                        && cleanupPassed == true
                        && semanticOutcomeState != .published
                        && generationIdentifierSHA256 == nil
                  ),
              status != .success
                || (
                    scenario == .cleanup
                        && privacySummary.passed
                        && admissionAccepted == true
                        && fixtureAccepted == true
                        && fixtureManifestSHA256 != nil
                        && sourceAllowlistSHA256 != nil
                        && authorizationReceiptIdentifierSHA256
                            != nil
                        && semanticOutcomeState == .published
                        && generationIdentifierSHA256 != nil
                        && sourceCounters != nil
                        && model != nil
                        && modelDigestSHA256 != nil
                        && modelAssessmentStatus == .success
                        && searchMode != nil
                        && searchPassed == true
                        && hydrationPassed == true
                        && cleanupPassed == true
                  )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        self.scenario = scenario
        self.status = status
        self.reasonCode = reasonCode
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.applicationIdentity = applicationIdentity
        self.admissionAccepted = admissionAccepted
        self.fixtureAccepted = fixtureAccepted
        self.fixtureManifestSHA256 =
            fixtureManifestSHA256
        self.sourceAllowlistSHA256 =
            sourceAllowlistSHA256
        self.authorizationReceiptIdentifierSHA256 =
            authorizationReceiptIdentifierSHA256
        self.semanticOutcomeState = semanticOutcomeState
        self.generationIdentifierSHA256 =
            generationIdentifierSHA256
        self.sourceCounters = sourceCounters
        self.model = model
        self.modelDigestSHA256 = modelDigestSHA256
        self.modelAssessmentStatus = modelAssessmentStatus
        self.searchMode = searchMode
        self.searchPassed = searchPassed
        self.hydrationPassed = hydrationPassed
        self.cleanupPassed = cleanupPassed
        self.privacySummary = privacySummary
        self.artifactLedger = artifactLedger
    }

    func bindingArtifactLedger(
        _ ledger: P8FSignedSmokeArtifactLedger
    ) throws -> Self {
        try .init(
            scenario: scenario,
            status: status,
            reasonCode: reasonCode,
            startedAt: startedAt,
            completedAt: completedAt,
            applicationIdentity: applicationIdentity,
            admissionAccepted: admissionAccepted,
            fixtureAccepted: fixtureAccepted,
            fixtureManifestSHA256: fixtureManifestSHA256,
            sourceAllowlistSHA256: sourceAllowlistSHA256,
            authorizationReceiptIdentifierSHA256:
                authorizationReceiptIdentifierSHA256,
            semanticOutcomeState: semanticOutcomeState,
            generationIdentifierSHA256:
                generationIdentifierSHA256,
            sourceCounters: sourceCounters,
            model: model,
            modelDigestSHA256: modelDigestSHA256,
            modelAssessmentStatus: modelAssessmentStatus,
            searchMode: searchMode,
            searchPassed: searchPassed,
            hydrationPassed: hydrationPassed,
            cleanupPassed: cleanupPassed,
            privacySummary: privacySummary,
            artifactLedger: ledger
        )
    }

    static func terminalStatusAndReasonAreValid(
        status: P8FSignedSmokeStatus,
        reasonCode: P8FSignedSmokeReasonCode
    ) -> Bool {
        switch status {
        case .success:
            reasonCode == .runCompleted
        case .failed:
            [
                .runFailed,
                .cleanupFailed,
                .privacyFailed,
                .receiptPersistenceFailed,
            ].contains(reasonCode)
        case .cancelled:
            reasonCode == .runCancelled
        case .started, .degraded, .skipped:
            false
        }
    }
}

enum P8FSignedSmokeArtifactPublicationState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case none
    case priorRetained = "prior_retained"
    case published
}

enum P8FSignedSmokeArtifactCleanupState:
    String,
    Codable,
    Equatable,
    Sendable
{
    case notReached = "not_reached"
    case passed
    case failed
}

struct P8FSignedSmokeArtifactLedger:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.signed-smoke-artifact-ledger.v2"

    let schemaVersion: String
    let eventCount: Int
    let eventChainArtifactCount: Int
    let sourceAuthorityReceiptCount: Int
    let diagnosticManifestCount: Int
    let terminalReceiptCount: Int
    let providerEvidenceCount: Int
    let candidateGenerationCount: Int
    let publishedGenerationCount: Int
    let discardedGenerationCount: Int
    let preparedRecordCount: Int
    let chunkCount: Int
    let embeddingRequestCount: Int
    let indexWriteCount: Int
    let publicationState:
        P8FSignedSmokeArtifactPublicationState
    let cleanupState: P8FSignedSmokeArtifactCleanupState
    let abandonedTemporaryArtifactCount: Int

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventCount = "event_count"
        case eventChainArtifactCount =
            "event_chain_artifact_count"
        case sourceAuthorityReceiptCount =
            "source_authority_receipt_count"
        case diagnosticManifestCount =
            "diagnostic_manifest_count"
        case terminalReceiptCount = "terminal_receipt_count"
        case providerEvidenceCount = "provider_evidence_count"
        case candidateGenerationCount =
            "candidate_generation_count"
        case publishedGenerationCount =
            "published_generation_count"
        case discardedGenerationCount =
            "discarded_generation_count"
        case preparedRecordCount = "prepared_record_count"
        case chunkCount = "chunk_count"
        case embeddingRequestCount =
            "embedding_request_count"
        case indexWriteCount = "index_write_count"
        case publicationState = "publication_state"
        case cleanupState = "cleanup_state"
        case abandonedTemporaryArtifactCount =
            "abandoned_temporary_artifact_count"
    }

    static func canonical(
        events: [P8FSignedSmokeEvent]
    ) throws -> Self {
        guard !events.isEmpty else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        let counters = events.compactMap(\.metadata.counters)
        let generationEvents = events.filter {
            $0.event == .generation
        }
        let publishedCount = generationEvents.filter {
            $0.status == .success
                && $0.reasonCode == .generationPublished
        }.count
        let discardedCount = generationEvents.filter {
            $0.reasonCode == .generationDiscarded
                || $0.reasonCode == .cancelledBeforePublication
                || $0.reasonCode
                    == .scopeRevokedBeforePublication
                || $0.reasonCode == .modelProfileDrift
        }.count
        let publicationState:
            P8FSignedSmokeArtifactPublicationState =
                if publishedCount > 0 {
                    .published
                } else if generationEvents.contains(where: {
                    $0.metadata.generationIdentifierSHA256 != nil
                }) {
                    .priorRetained
                } else {
                    .none
                }
        let cleanupState:
            P8FSignedSmokeArtifactCleanupState =
                if events.contains(where: {
                    $0.event == .cleanup
                        && $0.status == .failed
                        && $0.reasonCode == .cleanupFailed
                }) {
                    .failed
                } else if events.contains(where: {
                    $0.event == .cleanup
                        && $0.status == .success
                        && $0.reasonCode == .cleanupPassed
                }) {
                    .passed
                } else {
                    .notReached
                }
        return .init(
            schemaVersion: currentSchemaVersion,
            eventCount: events.count,
            eventChainArtifactCount: 1,
            sourceAuthorityReceiptCount: events.filter {
                $0.metadata.artifactClassification
                    == .sourceAuthorityReceipt
            }.count,
            diagnosticManifestCount: 1,
            terminalReceiptCount: 1,
            providerEvidenceCount: events.filter {
                $0.metadata.hasCompleteProviderCorrelation
            }.count,
            candidateGenerationCount:
                generationEvents.count,
            publishedGenerationCount: publishedCount,
            discardedGenerationCount: discardedCount,
            preparedRecordCount:
                counters.map(\.preparedRecords).max() ?? 0,
            chunkCount: counters.map(\.chunks).max() ?? 0,
            embeddingRequestCount:
                counters.map(\.embeddingRequests).max() ?? 0,
            indexWriteCount:
                counters.map(\.indexWrites).max() ?? 0,
            publicationState: publicationState,
            cleanupState: cleanupState,
            abandonedTemporaryArtifactCount: discardedCount
        )
    }

    static func validate(
        _ ledger: Self,
        events: [P8FSignedSmokeEvent]
    ) throws {
        guard ledger.schemaVersion == currentSchemaVersion,
              ledger == (try canonical(events: events))
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
    }
}

private struct P8FSignedSmokeTerminalReceiptEnvelope:
    Codable,
    Equatable,
    Sendable
{
    static let currentSchemaVersion =
        "agent-loki.p8f.signed-smoke-terminal-receipt.v4"

    let schemaVersion: String
    let traceID: String
    let receipt: P8FSignedSmokeTerminalReceipt
    let eventCount: UInt64
    let firstEventSHA256: String
    let finalEventSHA256: String
    let diagnosticManifestSHA256: String
    let committedFinalEvent: P8FSignedSmokeEvent
    let committedDiagnosticManifest:
        P8FSignedSmokeDiagnosticManifestReceipt

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case traceID = "trace_id"
        case receipt
        case eventCount = "event_count"
        case firstEventSHA256 =
            "first_event_sha256"
        case finalEventSHA256 =
            "final_event_sha256"
        case diagnosticManifestSHA256 =
            "diagnostic_manifest_sha256"
        case committedFinalEvent = "committed_final_event"
        case committedDiagnosticManifest =
            "committed_diagnostic_manifest"
    }
}

#if DEBUG
enum P8FSignedSmokeTerminalCommitBoundary:
    Equatable,
    Sendable
{
    case beforeCommitMarker
    case afterCommitMarker
    case afterFinalEventReplica
}

struct P8FSignedSmokeTerminalCommitXCTestHooks {
    private let hook:
        (P8FSignedSmokeTerminalCommitBoundary) throws -> Void

    private init(
        hook: @escaping
            (P8FSignedSmokeTerminalCommitBoundary) throws -> Void
    ) {
        self.hook = hook
    }

    static func make(
        _ hook: @escaping
            (P8FSignedSmokeTerminalCommitBoundary) throws -> Void
    ) throws -> Self {
        let environment = ProcessInfo.processInfo.environment
        guard environment["XCTestConfigurationFilePath"] != nil,
              NSClassFromString("XCTestCase") != nil,
              Bundle.allBundles.contains(where: {
                  $0.bundleURL.pathExtension == "xctest"
              })
        else {
            throw P8FSignedSmokeReceiptStoreFailure.ioFailure
        }
        return Self(hook: hook)
    }

    fileprivate func call(
        _ boundary: P8FSignedSmokeTerminalCommitBoundary
    ) throws {
        try hook(boundary)
    }
}
#endif

@MainActor
final class P8FSignedSmokeReceiptWriter {
    private static let maximumEventCount = 10_000
    private static let maximumEventBytes = 128 * 1_024
    private static let maximumDiagnosticManifestBytes =
        256 * 1_024
    private static let maximumTerminalReceiptBytes =
        256 * 1_024

    private struct StoredEvent {
        let event: P8FSignedSmokeEvent
        let sha256: String
    }

    private let root: P8FSignedSmokeReceiptRoot
#if DEBUG
    private var terminalCommitXCTestHooks:
        P8FSignedSmokeTerminalCommitXCTestHooks? = nil
#endif
    let traceID: String
    private var storedEvents: [StoredEvent] = []
    private(set) var diagnosticManifestReceipt:
        P8FSignedSmokeDiagnosticManifestReceipt?
    private(set) var terminalReceipt:
        P8FSignedSmokeTerminalReceipt?

    init(
        isolatedRoot: URL,
        traceID requestedTraceID: String? = nil,
        fileManager: FileManager = .default
    ) throws {
        var receiptRoot = try P8FSignedSmokeReceiptRoot(
            isolatedRoot: isolatedRoot,
            fileManager: fileManager
        )
        _ = try receiptRoot.freezeEventsDirectory()
        root = receiptRoot
        try Self.recoverCommittedArtifacts(in: root)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateExistingArtifacts(in: root)
        storedEvents = try Self.loadEvents(from: root)
        if let first = storedEvents.first {
            if let requestedTraceID,
               requestedTraceID != first.event.traceID {
                throw P8FSignedSmokeReceiptStoreFailure
                    .invalidTraceIdentifier
            }
            traceID = first.event.traceID
        } else if let requestedTraceID {
            guard P8FSignedSmokeValueValidator
                .isGeneratedIdentifier(
                requestedTraceID,
                prefix: "trace_"
                ) else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .invalidTraceIdentifier
            }
            traceID = requestedTraceID
        } else {
            traceID =
                "trace_\(UUID().uuidString.lowercased())"
        }
        let loadedDiagnosticManifest =
            try Self.loadDiagnosticManifest(
                from: root,
                traceID: traceID,
                events: storedEvents.map(\.event)
            )
        diagnosticManifestReceipt =
            loadedDiagnosticManifest
        terminalReceipt = try Self.loadTerminalReceipt(
            from: root,
            traceID: traceID,
            events: storedEvents,
            diagnosticManifest: loadedDiagnosticManifest
        )
    }

#if DEBUG
    convenience init(
        isolatedRoot: URL,
        traceID requestedTraceID: String? = nil,
        fileManager: FileManager = .default,
        testHooks: P8FSignedSmokeTerminalCommitXCTestHooks
    ) throws {
        try self.init(
            isolatedRoot: isolatedRoot,
            traceID: requestedTraceID,
            fileManager: fileManager
        )
        terminalCommitXCTestHooks = testHooks
    }
#endif

    var events: [P8FSignedSmokeEvent] {
        storedEvents.map(\.event)
    }

    var finalEventSHA256: String? {
        storedEvents.last?.sha256
    }

    @discardableResult
    func append(
        _ draft: P8FSignedSmokeEventDraft
    ) throws -> P8FSignedSmokeEvent {
        guard terminalReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptAlreadyWritten
        }
        guard diagnosticManifestReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactAlreadyExists
        }
        guard storedEvents.count < Self.maximumEventCount
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventSequenceInvalid
        }
        let knownSpanIDs = Set(
            storedEvents.map(\.event.spanID)
        )
        if storedEvents.isEmpty {
            guard draft.parentSpanID == nil else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventGraphInvalid
            }
        } else {
            guard let parent = draft.parentSpanID,
                  knownSpanIDs.contains(parent)
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventGraphInvalid
            }
        }
        let sequence = UInt64(storedEvents.count + 1)
        let event = P8FSignedSmokeEvent(
            schemaVersion:
                P8FSignedSmokeEvent.currentSchemaVersion,
            sequence: sequence,
            timestamp: draft.timestamp,
            event: draft.event,
            traceID: traceID,
            spanID:
                "span_\(UUID().uuidString.lowercased())",
            parentSpanID: draft.parentSpanID,
            component: draft.component,
            status: draft.status,
            reasonCode: draft.reasonCode,
            durationMilliseconds:
                draft.durationMilliseconds,
            metadata: draft.metadata,
            previousEventSHA256:
                storedEvents.last?.sha256
        )
        try Self.validateEvent(event)
        let data = try P8FSignedSmokeJSON.encode(event)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(data, as: .event)
        let canonicalEvent = try P8FSignedSmokeJSON.decode(
            P8FSignedSmokeEvent.self,
            from: data
        )
        try root.writeEvent(
            data,
            sequence: sequence,
            maximumBytes: Self.maximumEventBytes
        )
        storedEvents.append(.init(
            event: canonicalEvent,
            sha256: P8FSignedSmokeDigest.sha256(data)
        ))
        return canonicalEvent
    }

    @discardableResult
    func writeCanonicalDiagnosticManifestReceipt()
        throws -> P8FSignedSmokeDiagnosticManifestReceipt
    {
        guard terminalReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptAlreadyWritten
        }
        guard diagnosticManifestReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .fixedArtifactAlreadyExists
        }
        let receipt =
            try P8FSignedSmokeDiagnosticManifestReceipt
                .canonical(
                    traceID: traceID,
                    events: storedEvents.map(\.event)
                )
        try P8FSignedSmokeDiagnosticManifestReceipt
            .validate(
                receipt,
                against: storedEvents.map(\.event)
            )
        let data = try P8FSignedSmokeJSON.encode(receipt)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                data,
                as: .diagnosticManifest
            )
        try root.writeImmutable(
            data,
            to: .diagnosticManifest,
            maximumBytes:
                Self.maximumDiagnosticManifestBytes
        )
        diagnosticManifestReceipt = receipt
        return receipt
    }

    @discardableResult
    func writeTerminalReceipt(
        _ receipt: P8FSignedSmokeTerminalReceipt
    ) throws -> P8FSignedSmokeTerminalReceipt {
        guard terminalReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptAlreadyWritten
        }
        guard let first = storedEvents.first,
              let last = storedEvents.last
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        let diagnosticManifest =
            if let diagnosticManifestReceipt {
                diagnosticManifestReceipt
            } else {
                try P8FSignedSmokeDiagnosticManifestReceipt
                    .canonical(
                        traceID: traceID,
                        events: storedEvents.map(\.event)
                    )
            }
        try P8FSignedSmokeDiagnosticManifestReceipt.validate(
            diagnosticManifest,
            against: storedEvents.map(\.event)
        )
        let diagnosticManifestData =
            try P8FSignedSmokeJSON.encode(diagnosticManifest)
        let diagnosticManifestSHA256 =
            P8FSignedSmokeDigest.sha256(
                diagnosticManifestData
            )
        let boundReceipt = try receipt.bindingArtifactLedger(
            try .canonical(events: storedEvents.map(\.event))
        )
        let envelope = P8FSignedSmokeTerminalReceiptEnvelope(
            schemaVersion:
                P8FSignedSmokeTerminalReceiptEnvelope
                    .currentSchemaVersion,
            traceID: traceID,
            receipt: boundReceipt,
            eventCount: UInt64(storedEvents.count),
            firstEventSHA256: first.sha256,
            finalEventSHA256: last.sha256,
            diagnosticManifestSHA256:
                diagnosticManifestSHA256,
            committedFinalEvent: last.event,
            committedDiagnosticManifest:
                diagnosticManifest
        )
        try Self.validateTerminalReceiptEnvelope(
            envelope,
            traceID: traceID,
            events: storedEvents,
            diagnosticManifest:
                diagnosticManifest
        )
        let data = try P8FSignedSmokeJSON.encode(envelope)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                data,
                as: .terminalReceipt
            )
        try root.writeImmutable(
            data,
            to: .terminalReceipt,
            maximumBytes:
                Self.maximumTerminalReceiptBytes
        )
        terminalReceipt = boundReceipt
        if diagnosticManifestReceipt == nil {
            do {
                try root.writeImmutable(
                    diagnosticManifestData,
                    to: .diagnosticManifest,
                    maximumBytes:
                        Self.maximumDiagnosticManifestBytes
                )
                diagnosticManifestReceipt = diagnosticManifest
            } catch {
                // The terminal envelope is the durable commit marker and
                // contains the exact manifest needed for deterministic
                // recovery on the next open.
            }
        }
        return boundReceipt
    }

    @discardableResult
    func commitTerminalReceipt(
        _ receipt: P8FSignedSmokeTerminalReceipt,
        finalEventDraft: P8FSignedSmokeEventDraft
    ) throws -> P8FSignedSmokeTerminalReceipt {
        guard terminalReceipt == nil else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptAlreadyWritten
        }
        guard diagnosticManifestReceipt == nil,
              let first = storedEvents.first,
              storedEvents.count < Self.maximumEventCount
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        let knownSpanIDs = Set(
            storedEvents.map(\.event.spanID)
        )
        guard let parent = finalEventDraft.parentSpanID,
              knownSpanIDs.contains(parent)
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventGraphInvalid
        }
        let finalEvent = P8FSignedSmokeEvent(
            schemaVersion:
                P8FSignedSmokeEvent.currentSchemaVersion,
            sequence: UInt64(storedEvents.count + 1),
            timestamp: finalEventDraft.timestamp,
            event: finalEventDraft.event,
            traceID: traceID,
            spanID:
                "span_\(UUID().uuidString.lowercased())",
            parentSpanID: finalEventDraft.parentSpanID,
            component: finalEventDraft.component,
            status: finalEventDraft.status,
            reasonCode: finalEventDraft.reasonCode,
            durationMilliseconds:
                finalEventDraft.durationMilliseconds,
            metadata: finalEventDraft.metadata,
            previousEventSHA256:
                storedEvents.last?.sha256
        )
        try Self.validateEvent(finalEvent)
        let finalEventData = try P8FSignedSmokeJSON.encode(
            finalEvent
        )
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(finalEventData, as: .event)
        let canonicalFinalEvent = try P8FSignedSmokeJSON.decode(
            P8FSignedSmokeEvent.self,
            from: finalEventData
        )
        let finalStoredEvent = StoredEvent(
            event: canonicalFinalEvent,
            sha256: P8FSignedSmokeDigest.sha256(finalEventData)
        )
        let committedEvents = storedEvents + [finalStoredEvent]
        let diagnosticManifest =
            try P8FSignedSmokeDiagnosticManifestReceipt
                .canonical(
                    traceID: traceID,
                    events: committedEvents.map(\.event)
                )
        try P8FSignedSmokeDiagnosticManifestReceipt.validate(
            diagnosticManifest,
            against: committedEvents.map(\.event)
        )
        let diagnosticManifestData =
            try P8FSignedSmokeJSON.encode(diagnosticManifest)
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                diagnosticManifestData,
                as: .diagnosticManifest
            )
        let boundReceipt = try receipt.bindingArtifactLedger(
            try .canonical(events: committedEvents.map(\.event))
        )
        let envelope = P8FSignedSmokeTerminalReceiptEnvelope(
            schemaVersion:
                P8FSignedSmokeTerminalReceiptEnvelope
                    .currentSchemaVersion,
            traceID: traceID,
            receipt: boundReceipt,
            eventCount: UInt64(committedEvents.count),
            firstEventSHA256: first.sha256,
            finalEventSHA256: finalStoredEvent.sha256,
            diagnosticManifestSHA256:
                P8FSignedSmokeDigest.sha256(
                    diagnosticManifestData
                ),
            committedFinalEvent: canonicalFinalEvent,
            committedDiagnosticManifest:
                diagnosticManifest
        )
        try Self.validateTerminalReceiptEnvelope(
            envelope,
            traceID: traceID,
            events: committedEvents,
            diagnosticManifest: diagnosticManifest
        )
        let envelopeData = try P8FSignedSmokeJSON.encode(
            envelope
        )
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                envelopeData,
                as: .terminalReceipt
            )
#if DEBUG
        try terminalCommitXCTestHooks?.call(
            .beforeCommitMarker
        )
#endif
        if receipt.status == .success {
            try Task.checkCancellation()
        }
        try root.writeImmutable(
            envelopeData,
            to: .terminalReceipt,
            maximumBytes: Self.maximumTerminalReceiptBytes
        )
        terminalReceipt = boundReceipt
        do {
#if DEBUG
            try terminalCommitXCTestHooks?.call(
                .afterCommitMarker
            )
#endif
        } catch {
            return boundReceipt
        }
        do {
            try root.writeEvent(
                finalEventData,
                sequence: finalEvent.sequence,
                maximumBytes: Self.maximumEventBytes
            )
            storedEvents.append(finalStoredEvent)
#if DEBUG
            try terminalCommitXCTestHooks?.call(
                .afterFinalEventReplica
            )
#endif
        } catch {
            return boundReceipt
        }
        do {
            try root.writeImmutable(
                diagnosticManifestData,
                to: .diagnosticManifest,
                maximumBytes:
                    Self.maximumDiagnosticManifestBytes
            )
            diagnosticManifestReceipt = diagnosticManifest
        } catch {
            // The commit marker remains self-contained and recoverable.
        }
        return boundReceipt
    }

    private static func recoverCommittedArtifacts(
        in root: P8FSignedSmokeReceiptRoot
    ) throws {
        guard let terminalData = try root.read(
            .terminalReceipt,
            maximumBytes: maximumTerminalReceiptBytes
        ) else {
            if try root.read(
                .diagnosticManifest,
                maximumBytes: maximumDiagnosticManifestBytes
            ) != nil {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
            let events = try loadEvents(from: root)
            if let final = events.last?.event,
               final.event == .run,
               [.success, .failed, .cancelled]
                .contains(final.status) {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
            return
        }
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                terminalData,
                as: .terminalReceipt
            )
        let envelope: P8FSignedSmokeTerminalReceiptEnvelope
        do {
            envelope = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeTerminalReceiptEnvelope.self,
                from: terminalData
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        guard envelope.schemaVersion
                == P8FSignedSmokeTerminalReceiptEnvelope
                    .currentSchemaVersion,
              try P8FSignedSmokeJSON.encode(envelope)
                == terminalData,
              envelope.traceID
                == envelope.committedFinalEvent.traceID,
              envelope.finalEventSHA256
                == P8FSignedSmokeDigest.sha256(
                    try P8FSignedSmokeJSON.encode(
                        envelope.committedFinalEvent
                    )
                ),
              envelope.diagnosticManifestSHA256
                == P8FSignedSmokeDigest.sha256(
                    try P8FSignedSmokeJSON.encode(
                        envelope.committedDiagnosticManifest
                    )
                )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        try validateEvent(envelope.committedFinalEvent)
        let events = try loadEvents(from: root)
        let expectedCount = Int(envelope.eventCount)
        guard expectedCount > 0,
              events.count == expectedCount
                || events.count == expectedCount - 1
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        let finalEventData = try P8FSignedSmokeJSON.encode(
            envelope.committedFinalEvent
        )
        let finalStoredEvent = StoredEvent(
            event: envelope.committedFinalEvent,
            sha256: P8FSignedSmokeDigest.sha256(finalEventData)
        )
        let finalEventReplicaMissing =
            events.count == expectedCount - 1
        let committedEvents: [StoredEvent]
        if events.count == expectedCount - 1 {
            guard let first = events.first,
                  first.sha256 == envelope.firstEventSHA256,
                  envelope.committedFinalEvent.sequence
                    == envelope.eventCount,
                  envelope.committedFinalEvent
                    .previousEventSHA256 == events.last?.sha256,
                  envelope.committedFinalEvent.parentSpanID.map({
                      Set(events.map(\.event.spanID)).contains($0)
                  }) == true
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
            committedEvents = events + [finalStoredEvent]
        } else {
            guard events.last?.event
                    == envelope.committedFinalEvent,
                  events.last?.sha256
                    == envelope.finalEventSHA256
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
            committedEvents = events
        }
        let manifestData = try P8FSignedSmokeJSON.encode(
            envelope.committedDiagnosticManifest
        )
        let existingManifest = try root.read(
            .diagnosticManifest,
            maximumBytes: maximumDiagnosticManifestBytes
        )
        if let existingManifest {
            guard existingManifest == manifestData else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        }
        try P8FSignedSmokeDiagnosticManifestReceipt.validate(
            envelope.committedDiagnosticManifest,
            against: committedEvents.map(\.event)
        )
        guard envelope.committedDiagnosticManifest.traceID
                == envelope.traceID
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        try validateTerminalReceiptEnvelope(
            envelope,
            traceID: envelope.traceID,
            events: committedEvents,
            diagnosticManifest:
                envelope.committedDiagnosticManifest
        )

        // Recovery writes are deliberately last: no replica is materialized
        // until the self-contained commit marker, exact hypothetical chain,
        // embedded manifest, artifact ledger, and semantic claims all pass.
        if finalEventReplicaMissing {
            try root.writeEvent(
                finalEventData,
                sequence: envelope.committedFinalEvent.sequence,
                maximumBytes: maximumEventBytes
            )
        }
        if existingManifest == nil {
            try root.writeImmutable(
                manifestData,
                to: .diagnosticManifest,
                maximumBytes: maximumDiagnosticManifestBytes
            )
        }
        let recoveredEvents = try loadEvents(from: root)
        let loadedManifest = try loadDiagnosticManifest(
            from: root,
            traceID: envelope.traceID,
            events: recoveredEvents.map(\.event)
        )
        guard let loadedManifest else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        try validateTerminalReceiptEnvelope(
            envelope,
            traceID: envelope.traceID,
            events: recoveredEvents,
            diagnosticManifest: loadedManifest
        )
    }

    private static func loadEvents(
        from root: P8FSignedSmokeReceiptRoot
    ) throws -> [StoredEvent] {
        let urls = try root.eventURLs()
        guard urls.count <= maximumEventCount else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventSequenceInvalid
        }
        var result: [StoredEvent] = []
        var knownSpanIDs: Set<String> = []
        var expectedTraceID: String?
        var previousHash: String?
        for (index, url) in urls.enumerated() {
            let sequence = UInt64(index + 1)
            guard url.lastPathComponent
                    == P8FSignedSmokeReceiptLayout
                        .eventFileName(sequence: sequence)
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventSequenceInvalid
            }
            let data = try root.readEvent(
                at: url,
                maximumBytes: maximumEventBytes
            )
            try P8FSignedSmokeReceiptArtifactValidator
                .validateEncodedArtifact(data, as: .event)
            let event: P8FSignedSmokeEvent
            do {
                event = try P8FSignedSmokeJSON.decode(
                    P8FSignedSmokeEvent.self,
                    from: data
                )
            } catch {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventChainInvalid
            }
            try validateEvent(event)
            guard try P8FSignedSmokeJSON.encode(event) == data
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .noncanonicalEncoding
            }
            guard event.sequence == sequence,
                  event.previousEventSHA256 == previousHash
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventChainInvalid
            }
            if let expectedTraceID {
                guard event.traceID == expectedTraceID else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .invalidTraceIdentifier
                }
            } else {
                expectedTraceID = event.traceID
            }
            if index == 0 {
                guard event.parentSpanID == nil else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .eventGraphInvalid
                }
            } else {
                guard let parent = event.parentSpanID,
                      knownSpanIDs.contains(parent)
                else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .eventGraphInvalid
                }
            }
            guard knownSpanIDs.insert(event.spanID).inserted
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .eventGraphInvalid
            }
            let hash = P8FSignedSmokeDigest.sha256(data)
            result.append(.init(event: event, sha256: hash))
            previousHash = hash
        }
        return result
    }

    private static func loadDiagnosticManifest(
        from root: P8FSignedSmokeReceiptRoot,
        traceID: String,
        events: [P8FSignedSmokeEvent]
    ) throws -> P8FSignedSmokeDiagnosticManifestReceipt? {
        guard let data = try root.read(
            .diagnosticManifest,
            maximumBytes: maximumDiagnosticManifestBytes
        ) else {
            return nil
        }
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                data,
                as: .diagnosticManifest
            )
        let receipt:
            P8FSignedSmokeDiagnosticManifestReceipt
        do {
            receipt = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeDiagnosticManifestReceipt.self,
                from: data
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
        try P8FSignedSmokeDiagnosticManifestReceipt
            .validate(receipt, against: events)
        guard receipt.traceID == traceID else {
            throw P8FSignedSmokeReceiptStoreFailure
                .diagnosticManifestInvalid
        }
        guard try P8FSignedSmokeJSON.encode(receipt) == data
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .noncanonicalEncoding
        }
        return receipt
    }

    private static func loadTerminalReceipt(
        from root: P8FSignedSmokeReceiptRoot,
        traceID: String,
        events: [StoredEvent],
        diagnosticManifest:
            P8FSignedSmokeDiagnosticManifestReceipt?
    ) throws -> P8FSignedSmokeTerminalReceipt? {
        guard let data = try root.read(
            .terminalReceipt,
            maximumBytes: maximumTerminalReceiptBytes
        ) else {
            return nil
        }
        try P8FSignedSmokeReceiptArtifactValidator
            .validateEncodedArtifact(
                data,
                as: .terminalReceipt
            )
        let envelope: P8FSignedSmokeTerminalReceiptEnvelope
        do {
            envelope = try P8FSignedSmokeJSON.decode(
                P8FSignedSmokeTerminalReceiptEnvelope.self,
                from: data
            )
        } catch {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        guard try P8FSignedSmokeJSON.encode(envelope) == data
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .noncanonicalEncoding
        }
        try validateTerminalReceiptEnvelope(
            envelope,
            traceID: traceID,
            events: events,
            diagnosticManifest: diagnosticManifest
        )
        return envelope.receipt
    }

    private static func validateEvent(
        _ event: P8FSignedSmokeEvent
    ) throws {
        guard event.schemaVersion
                == P8FSignedSmokeEvent.currentSchemaVersion,
              event.sequence > 0,
              validGeneratedIdentifier(
                event.traceID,
                prefix: "trace_"
              ),
              validGeneratedIdentifier(
                event.spanID,
                prefix: "span_"
              ),
              event.parentSpanID.map({
                  validGeneratedIdentifier($0, prefix: "span_")
              }) ?? true,
              event.timestamp.timeIntervalSinceReferenceDate
                .isFinite,
              (0...3_600_000).contains(
                event.durationMilliseconds
              ),
              event.previousEventSHA256.map(
                P8FSignedSmokeDigest.isSHA256
              ) ?? true
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
        try validateEventMetadata(event.metadata)
        guard P8FSignedSmokeEventMetadata
                .eventContextIsValid(
                    event: event.event,
                    component: event.component,
                    status: event.status,
                    reasonCode: event.reasonCode,
                    durationMilliseconds:
                        event.durationMilliseconds,
                    timestamp: event.timestamp,
                    metadata: event.metadata
                )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
    }

    private static func validateEventMetadata(
        _ metadata: P8FSignedSmokeEventMetadata
    ) throws {
        let hashes = [
            metadata.fixtureManifestSHA256,
            metadata.sourceAllowlistSHA256,
            metadata.generationIdentifierSHA256,
            metadata.authorizationReceiptIdentifierSHA256,
            metadata.modelDigest,
            metadata.runtimeIdentitySHA256,
            metadata.requestProfileSHA256,
            metadata.artifactSHA256,
            metadata.executableSHA256,
            metadata.providerRequestTraceSHA256,
            metadata.providerRequestIdentifierSHA256,
        ]
        guard hashes.compactMap({ $0 }).allSatisfy(
                P8FSignedSmokeDigest.isSHA256
              ),
              metadata.vectorDimension.map({
                  (1...32_768).contains($0)
              }) ?? true,
              metadata.counters.map(countersAreValid) ?? true,
              P8FSignedSmokeEventMetadata
                .correlationFieldsAreValid(
                    processIdentifier:
                        metadata.processIdentifier,
                    executableSHA256:
                        metadata.executableSHA256,
                    providerRequestTraceSHA256:
                        metadata.providerRequestTraceSHA256,
                    providerRequestIdentifierSHA256:
                        metadata
                            .providerRequestIdentifierSHA256,
                    providerKind: metadata.providerKind,
                    providerOperationKind:
                        metadata.providerOperationKind,
                    providerOutcome: metadata.providerOutcome,
                    providerIntervalStartedAt:
                        metadata.providerIntervalStartedAt,
                    providerIntervalEndedAt:
                        metadata.providerIntervalEndedAt,
                    providerIntervalDurationMilliseconds:
                        metadata
                            .providerIntervalDurationMilliseconds,
                    externalWatcherIntervalStartedAt:
                        metadata
                            .externalWatcherIntervalStartedAt,
                    externalWatcherIntervalEndedAt:
                        metadata
                            .externalWatcherIntervalEndedAt,
                    externalWatcherIntervalDurationMilliseconds:
                        metadata
                            .externalWatcherIntervalDurationMilliseconds,
                    transportObservationEvidenceSource:
                        metadata
                            .transportObservationEvidenceSource,
                    transportObservationClassification:
                        metadata
                            .transportObservationClassification,
                    transportObservationResult:
                        metadata.transportObservationResult,
                    endpointClassification:
                        metadata.endpointClassification,
                    observedEndpointClassification:
                        metadata
                            .observedEndpointClassification
                )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .eventMetadataInvalid
        }
    }

    private static func validateTerminalReceiptEnvelope(
        _ envelope: P8FSignedSmokeTerminalReceiptEnvelope,
        traceID: String,
        events: [StoredEvent],
        diagnosticManifest:
            P8FSignedSmokeDiagnosticManifestReceipt?
    ) throws {
        let expectedDiagnosticManifestSHA256 =
            try diagnosticManifest.map {
                P8FSignedSmokeDigest.sha256(
                    try P8FSignedSmokeJSON.encode($0)
                )
            }
        guard let first = events.first,
              let last = events.last,
              let diagnosticManifest,
              let expectedDiagnosticManifestSHA256,
              envelope.schemaVersion
                == P8FSignedSmokeTerminalReceiptEnvelope
                    .currentSchemaVersion,
              envelope.traceID == traceID,
              envelope.eventCount == UInt64(events.count),
              envelope.firstEventSHA256 == first.sha256,
              envelope.finalEventSHA256 == last.sha256,
              envelope.diagnosticManifestSHA256
                == expectedDiagnosticManifestSHA256,
              envelope.committedFinalEvent == last.event,
              envelope.committedDiagnosticManifest
                == diagnosticManifest,
              let artifactLedger =
                envelope.receipt.artifactLedger
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
        try validateTerminalReceiptPayload(envelope.receipt)
        try P8FSignedSmokeArtifactLedger.validate(
            artifactLedger,
            events: events.map(\.event)
        )
        try validateTerminalReceiptEvents(
            envelope.receipt,
            events: events.map(\.event)
        )
        try validateTerminalReceiptSemanticClaims(
            envelope.receipt,
            artifactLedger: artifactLedger,
            events: events.map(\.event)
        )
    }

    private static func validateTerminalReceiptEvents(
        _ receipt: P8FSignedSmokeTerminalReceipt,
        events: [P8FSignedSmokeEvent]
    ) throws {
        let runEvents = events.filter { $0.event == .run }
        guard let finalRunEvent = runEvents.last,
              events.last == finalRunEvent,
              finalRunEvent.metadata.scenario == .run,
              finalRunEvent.status == receipt.status,
              finalRunEvent.reasonCode == receipt.reasonCode,
              runEvents.filter({
                  $0.status == receipt.status
                      && $0.reasonCode == receipt.reasonCode
              }).count == 1
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }

        let terminalRunEvents = runEvents.filter {
            [.success, .failed, .cancelled].contains($0.status)
        }
        let cancelledRunEvents = runEvents.filter {
            $0.status == .cancelled
                && $0.reasonCode == .runCancelled
        }
        let cancellationCausalEvents = runEvents.filter {
            $0.status == .started
                && $0.reasonCode
                    == .runCancellationObserved
        }
        let terminalCleanupEvents = events.filter {
            $0.event == .cleanup
                && (
                    ($0.status == .success
                        && $0.reasonCode == .cleanupPassed)
                    || ($0.status == .failed
                        && $0.reasonCode == .cleanupFailed)
                )
        }

        switch receipt.status {
        case .success:
            guard terminalRunEvents.count == 1,
                  cancelledRunEvents.isEmpty,
                  cancellationCausalEvents.isEmpty,
                  terminalCleanupEvents.count == 1,
                  let cleanup = terminalCleanupEvents.first,
                  cleanup.status == .success,
                  cleanup.sequence < finalRunEvent.sequence
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        case .cancelled:
            guard terminalRunEvents.count == 1,
                  cancelledRunEvents.count == 1,
                  cancellationCausalEvents.count == 1,
                  terminalCleanupEvents.count == 1,
                  let causal = cancellationCausalEvents.first,
                  let cleanup = terminalCleanupEvents.first,
                  cleanup.status == .success,
                  causal.sequence < cleanup.sequence,
                  cleanup.sequence < finalRunEvent.sequence
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        case .failed:
            guard cancelledRunEvents.isEmpty,
                  cancellationCausalEvents.count <= 1,
                  terminalRunEvents.count == 1
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
            if let cancellation = cancellationCausalEvents.first {
                guard cancellation.sequence
                        < finalRunEvent.sequence,
                      terminalCleanupEvents.allSatisfy({
                          cancellation.sequence < $0.sequence
                              && $0.sequence
                                < finalRunEvent.sequence
                      })
                else {
                    throw P8FSignedSmokeReceiptStoreFailure
                        .terminalReceiptInvalid
                }
                switch receipt.reasonCode {
                case .cleanupFailed:
                    guard terminalCleanupEvents.count == 1,
                          terminalCleanupEvents.first?.status
                            == .failed
                    else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                case .privacyFailed,
                     .runFailed:
                    guard terminalCleanupEvents.count == 1,
                          terminalCleanupEvents.first?.status
                            == .success
                    else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                case .receiptPersistenceFailed:
                    guard terminalCleanupEvents.isEmpty
                            || (
                                terminalCleanupEvents.count == 1
                                    && terminalCleanupEvents
                                        .first?.status == .success
                            )
                    else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                default:
                    throw P8FSignedSmokeReceiptStoreFailure
                        .terminalReceiptInvalid
                }
            } else {
                switch receipt.reasonCode {
                case .cleanupFailed:
                    guard terminalCleanupEvents.count == 1,
                          let cleanup = terminalCleanupEvents.first,
                          cleanup.status == .failed,
                          cleanup.sequence < finalRunEvent.sequence
                    else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                case .privacyFailed:
                    guard terminalCleanupEvents.count == 1,
                          let cleanup = terminalCleanupEvents.first,
                          cleanup.status == .success,
                          cleanup.sequence < finalRunEvent.sequence
                    else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                default:
                    guard terminalCleanupEvents.allSatisfy({
                        $0.sequence < finalRunEvent.sequence
                    }) else {
                        throw P8FSignedSmokeReceiptStoreFailure
                            .terminalReceiptInvalid
                    }
                }
            }
        case .started, .degraded, .skipped:
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
    }

    /// Reconstructs every asserted terminal outcome from the committed event
    /// chain. The terminal envelope already binds hashes and counts; this
    /// second boundary prevents a structurally valid receipt from claiming a
    /// fixture, publication, model, search, hydration, or cleanup result that
    /// the exact committed events do not prove.
    private static func validateTerminalReceiptSemanticClaims(
        _ receipt: P8FSignedSmokeTerminalReceipt,
        artifactLedger: P8FSignedSmokeArtifactLedger,
        events: [P8FSignedSmokeEvent]
    ) throws {
        if receipt.status == .success {
            do {
                try P8FSignedSmokePrerequisiteValidator.validate(
                    .cleanup,
                    events: events
                )
            } catch {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        }
        let acceptedAdmission = events.filter {
            $0.event == .admission
                && $0.status == .success
                && $0.reasonCode == .admissionAccepted
        }
        let rejectedAdmission = events.filter {
            $0.event == .admission
                && $0.status == .failed
                && $0.reasonCode == .admissionRejected
        }
        let acceptedFixtures = events.filter {
            $0.event == .fixture
                && $0.status == .success
                && $0.reasonCode == .fixtureAccepted
        }
        let rejectedFixtures = events.filter {
            $0.event == .fixture
                && $0.status == .failed
                && $0.reasonCode == .fixtureRejected
        }
        let authorizedSources = events.filter {
            $0.event == .sourceAuthority
                && $0.status == .success
                && $0.reasonCode == .sourceScopeAuthorized
                && $0.metadata.scenario == .sourceAuthority
        }
        let publications = events.filter {
            $0.event == .generation
                && $0.status == .success
                && $0.reasonCode == .generationPublished
                && $0.metadata.scenario == .successfulPublication
        }
        let qwenAssessments = events.filter {
            $0.event == .modelCapability
                && $0.status == .success
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.scenario == .qwenEmbedding
                && $0.metadata.model == .qwenEmbedding
        }
        let gemmaAssessments = events.filter {
            $0.event == .modelCapability
                && $0.status == .success
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.scenario == .gemma4
                && $0.metadata.model == .gemma4
        }
        let gptAssessments = events.filter {
            $0.event == .modelCapability
                && $0.status == .success
                && $0.reasonCode == .modelCapabilityPassed
                && $0.metadata.scenario == .gptOSS
                && $0.metadata.model == .gptOSS
        }
        let hybridSearches = events.filter {
            $0.event == .search
                && $0.metadata.searchMode == .hybrid
                && $0.metadata.scenario == .hybridSearch
        }
        let successfulCleanup = events.filter {
            $0.event == .cleanup
                && $0.status == .success
                && $0.reasonCode == .cleanupPassed
                && $0.metadata.scenario == .cleanup
        }
        let failedCleanup = events.filter {
            $0.event == .cleanup
                && $0.status == .failed
                && $0.reasonCode == .cleanupFailed
                && $0.metadata.scenario == .cleanup
        }
        let durableSourceAuthorityArtifacts =
            authorizedSources.filter {
                $0.metadata.artifactClassification
                    == .sourceAuthorityReceipt
                    && $0.metadata.artifactSHA256 != nil
            }

        if receipt.status == .success {
            guard durableSourceAuthorityArtifacts.count == 1,
                  artifactLedger.sourceAuthorityReceiptCount == 1,
                  let durableAuthority =
                    durableSourceAuthorityArtifacts.first,
                  durableAuthority.metadata.fixtureManifestSHA256
                    == receipt.fixtureManifestSHA256,
                  durableAuthority.metadata.sourceAllowlistSHA256
                    == receipt.sourceAllowlistSHA256,
                  durableAuthority.metadata
                    .authorizationReceiptIdentifierSHA256
                        == receipt
                            .authorizationReceiptIdentifierSHA256,
                  durableAuthority.metadata.counters
                    == receipt.sourceCounters
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        }

        func assertedBoolean(
            _ assertion: Bool?,
            trueEvidence: Bool,
            falseEvidence: Bool
        ) -> Bool {
            switch assertion {
            case true:
                trueEvidence && !falseEvidence
            case false:
                falseEvidence && !trueEvidence
            case nil:
                true
            }
        }

        guard assertedBoolean(
                receipt.admissionAccepted,
                trueEvidence: !acceptedAdmission.isEmpty,
                falseEvidence: !rejectedAdmission.isEmpty
              ),
              assertedBoolean(
                receipt.fixtureAccepted,
                trueEvidence: !acceptedFixtures.isEmpty,
                falseEvidence: !rejectedFixtures.isEmpty
              ),
              receipt.fixtureManifestSHA256.map({ claimed in
                  acceptedFixtures.contains {
                      $0.metadata.fixtureManifestSHA256 == claimed
                  }
              }) ?? true,
              receipt.sourceAllowlistSHA256.map({ claimed in
                  authorizedSources.contains {
                      $0.metadata.sourceAllowlistSHA256 == claimed
                  }
              }) ?? true,
              receipt.authorizationReceiptIdentifierSHA256.map({ claimed in
                  authorizedSources.contains {
                      $0.metadata
                        .authorizationReceiptIdentifierSHA256
                            == claimed
                  }
              }) ?? true,
              receipt.semanticOutcomeState.map({ claimed in
                  claimed == .published && !publications.isEmpty
              }) ?? true,
              receipt.generationIdentifierSHA256.map({ claimed in
                  publications.contains {
                      $0.metadata.generationIdentifierSHA256
                        == claimed
                  }
              }) ?? true,
              receipt.sourceCounters.map({ claimed in
                  authorizedSources.contains {
                      $0.metadata.counters == claimed
                  }
              }) ?? true,
              receipt.model.map({ claimed in
                  qwenAssessments.contains {
                      $0.metadata.model == claimed
                  }
              }) ?? true,
              receipt.modelDigestSHA256.map({ claimed in
                  qwenAssessments.contains {
                      $0.metadata.modelDigest == claimed
                  }
              }) ?? true,
              receipt.modelAssessmentStatus.map({ claimed in
                  qwenAssessments.contains { $0.status == claimed }
              }) ?? true,
              receipt.searchMode.map({ claimed in
                  hybridSearches.contains {
                      $0.metadata.searchMode == claimed
                  }
              }) ?? true,
              assertedBoolean(
                receipt.searchPassed,
                trueEvidence: hybridSearches.contains {
                    $0.status == .success
                        && $0.reasonCode == .searchPassed
                        && ($0.metadata.counters?.resultCount ?? 0) > 0
                        && $0.metadata.counters?.leakageCanaryHits == 0
                },
                falseEvidence: hybridSearches.contains {
                    $0.status == .failed
                        && $0.reasonCode == .searchFailed
                }
              ),
              assertedBoolean(
                receipt.cleanupPassed,
                trueEvidence: !successfulCleanup.isEmpty,
                falseEvidence: !failedCleanup.isEmpty
              )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }

        if receipt.status == .cancelled {
            guard publications.isEmpty,
                  receipt.semanticOutcomeState != .published,
                  receipt.generationIdentifierSHA256 == nil,
                  artifactLedger.publicationState != .published,
                  artifactLedger.publishedGenerationCount == 0
            else {
                throw P8FSignedSmokeReceiptStoreFailure
                    .terminalReceiptInvalid
            }
        }

        let hydrationExpectations: [
            (P8FSignedSmokeScenario, P8FSignedSmokeReasonCode)
        ] = [
            (.restartHydration, .generationPublished),
            (.legacyHydration, .legacyGenerationPreserved),
            (.staleHydration, .staleIdentityRejected),
            (.malformedHydration, .malformedIdentityRejected),
        ]
        let hydrationEvidenceExists = events.contains {
            hydrationExpectations.map(\.0).contains(
                $0.metadata.scenario
            )
        }
        let hydrationPassed = hydrationExpectations.allSatisfy {
            expected in
            events.contains {
                $0.status == .success
                    && $0.metadata.scenario == expected.0
                    && $0.reasonCode == expected.1
            }
        }
        guard assertedBoolean(
            receipt.hydrationPassed,
            trueEvidence: hydrationPassed,
            falseEvidence:
                hydrationEvidenceExists && !hydrationPassed
        ) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }

        let fixtureBoundScenarios: Set<P8FSignedSmokeScenario> = [
            .sourceAuthority,
            .cancellation,
            .revocation,
            .modelProfileDrift,
            .adapterContractDrift,
            .unknownSourceKind,
            .transactionIntegrity,
            .successfulPublication,
            .restartHydration,
            .legacyHydration,
            .staleHydration,
            .malformedHydration,
            .gemma4,
            .gptOSS,
            .qwenEmbedding,
            .roleSeparation,
            .visibleVisionRouting,
            .webResearchDisabled,
            .lexicalSearch,
            .semanticSearch,
            .hybridSearch,
            .searchNarrowing,
            .excludedSourceSearch,
            .receiptPrivacy,
            .cleanup,
        ]
        let exactFixtureHashBinding =
            receipt.fixtureManifestSHA256.map { fixtureHash in
                events.filter {
                    fixtureBoundScenarios.contains(
                        $0.metadata.scenario
                    )
                }.allSatisfy {
                    $0.metadata.fixtureManifestSHA256
                        == fixtureHash
                }
            } ?? false
        func searchCountersAreExact(
            _ counters: P8FSignedSmokeCounters?,
            requiresPositiveResult: Bool
        ) -> Bool {
            guard let counters,
                  counters.adapterInvocations == 0,
                  counters.recordsRead == 0,
                  counters.recordsAccepted == 0,
                  counters.recordsRejected == 0,
                  counters.preparedRecords == 0,
                  counters.chunks == 0,
                  counters.embeddingRequests == 0,
                  counters.embeddingsAccepted == 0,
                  counters.indexWrites == 0,
                  counters.leakageCanaryHits == 0
            else {
                return false
            }
            return requiresPositiveResult
                ? counters.resultCount > 0
                : counters.resultCount == 0
        }
        let exactSearchMatrix: Bool = {
            guard let generationHash =
                    receipt.generationIdentifierSHA256,
                  let fixtureHash =
                    receipt.fixtureManifestSHA256,
                  receipt.searchMode == .hybrid,
                  receipt.searchPassed == true
            else {
                return false
            }
            let searchEvents = events.filter {
                $0.event == .search
            }
            guard searchEvents.count == 5 else {
                return false
            }
            let normalSearchExpectations: [
                (P8FSignedSmokeScenario, SemanticSearchMode)
            ] = [
                (.lexicalSearch, .lexical),
                (.semanticSearch, .semantic),
                (.hybridSearch, .hybrid),
            ]
            guard normalSearchExpectations.allSatisfy({ expected in
                let matching = searchEvents.filter {
                    $0.metadata.scenario == expected.0
                }
                guard matching.count == 1 else {
                    return false
                }
                let event = matching[0]
                return event.status == .success
                    && event.reasonCode == .searchPassed
                    && event.metadata.searchMode == expected.1
                    && event.metadata.fixtureManifestSHA256
                        == fixtureHash
                    && event.metadata
                        .generationIdentifierSHA256
                        == generationHash
                    && event.metadata.artifactClassification == nil
                    && event.metadata.artifactSHA256 != nil
                    && searchCountersAreExact(
                        event.metadata.counters,
                        requiresPositiveResult: true
                    )
            }) else {
                return false
            }
            let narrowed = searchEvents.filter {
                $0.metadata.scenario == .searchNarrowing
            }
            guard let lexicalResultCount = searchEvents.first(where: {
                    $0.metadata.scenario == .lexicalSearch
                  })?.metadata.counters?.resultCount,
                  narrowed.count == 1,
                  narrowed[0].status == .success,
                  narrowed[0].reasonCode
                    == .searchFilterNarrowed,
                  narrowed[0].metadata.searchMode == .lexical,
                  narrowed[0].metadata.fixtureManifestSHA256
                    == fixtureHash,
                  narrowed[0].metadata
                    .generationIdentifierSHA256
                    == generationHash,
                  narrowed[0].metadata.artifactClassification == nil,
                  narrowed[0].metadata.artifactSHA256 != nil,
                  searchCountersAreExact(
                    narrowed[0].metadata.counters,
                    requiresPositiveResult: true
                  ),
                  let narrowedResultCount =
                    narrowed[0].metadata.counters?.resultCount,
                  narrowedResultCount < lexicalResultCount
            else {
                return false
            }
            let excluded = searchEvents.filter {
                $0.metadata.scenario == .excludedSourceSearch
            }
            guard excluded.count == 1,
                  excluded[0].status == .success,
                  excluded[0].reasonCode
                    == .excludedSourceFilterEmpty,
                  excluded[0].metadata.searchMode == .lexical,
                  excluded[0].metadata.fixtureManifestSHA256
                    == fixtureHash,
                  excluded[0].metadata
                    .generationIdentifierSHA256
                    == generationHash,
                  excluded[0].metadata.artifactClassification == nil,
                  excluded[0].metadata.artifactSHA256 == nil,
                  searchCountersAreExact(
                    excluded[0].metadata.counters,
                    requiresPositiveResult: false
                  )
            else {
                return false
            }
            return true
        }()
        let exactHydrationMatrix: Bool = {
            guard let terminalGeneration =
                    receipt.generationIdentifierSHA256,
                  let fixtureHash =
                    receipt.fixtureManifestSHA256,
                  let allowlistHash =
                    receipt.sourceAllowlistSHA256,
                  let sourceCounters = receipt.sourceCounters
            else {
                return false
            }
            let hydrationScenarios: Set<
                P8FSignedSmokeScenario
            > = [
                .restartHydration,
                .legacyHydration,
                .staleHydration,
                .malformedHydration,
            ]
            let hydrationEvents = events.filter {
                $0.event == .generation
                    && hydrationScenarios.contains(
                        $0.metadata.scenario
                    )
            }
            guard hydrationEvents.count == 4 else {
                return false
            }
            func exact(
                _ scenario: P8FSignedSmokeScenario,
                reason: P8FSignedSmokeReasonCode
            ) -> P8FSignedSmokeEvent? {
                let matching = hydrationEvents.filter {
                    $0.metadata.scenario == scenario
                        && $0.status == .success
                        && $0.reasonCode == reason
                }
                return matching.count == 1 ? matching[0] : nil
            }
            guard let restart = exact(
                    .restartHydration,
                    reason: .generationPublished
                  ),
                  let legacy = exact(
                    .legacyHydration,
                    reason: .legacyGenerationPreserved
                  ),
                  let stale = exact(
                    .staleHydration,
                    reason: .staleIdentityRejected
                  ),
                  let malformed = exact(
                    .malformedHydration,
                    reason: .malformedIdentityRejected
                  ),
                  restart.metadata.fixtureManifestSHA256
                    == fixtureHash,
                  restart.metadata.sourceAllowlistSHA256
                    == allowlistHash,
                  restart.metadata.generationIdentifierSHA256
                    == terminalGeneration,
                  restart.metadata.counters == nil,
                  restart.metadata.artifactClassification == nil,
                  restart.metadata.artifactSHA256 == nil
            else {
                return false
            }
            let probes = [legacy, stale, malformed]
            guard probes.allSatisfy({ event in
                event.metadata.fixtureManifestSHA256
                        == fixtureHash
                    && event.metadata.sourceAllowlistSHA256 == nil
                    && event.metadata
                        .authorizationReceiptIdentifierSHA256 == nil
                    && event.metadata.artifactClassification == nil
                    && event.metadata.artifactSHA256 == nil
                    && event.metadata
                        .generationIdentifierSHA256 != nil
              }),
              stale.metadata.counters == nil,
              malformed.metadata.counters == nil,
              let legacyCounters = legacy.metadata.counters,
              legacyCounters.adapterInvocations == 0,
              legacyCounters.recordsRead == 0,
              legacyCounters.recordsAccepted
                == sourceCounters.recordsAccepted,
              legacyCounters.recordsRejected == 0,
              legacyCounters.preparedRecords == 0,
              legacyCounters.chunks == sourceCounters.chunks,
              legacyCounters.embeddingRequests == 0,
              legacyCounters.embeddingsAccepted == 0,
              legacyCounters.indexWrites
                == sourceCounters.indexWrites,
              legacyCounters.resultCount == 0,
              legacyCounters.leakageCanaryHits == 0
            else {
                return false
            }
            let probeGenerations = probes.compactMap {
                $0.metadata.generationIdentifierSHA256
            }
            guard probeGenerations.count == 3,
                  Set(probeGenerations).count == 3,
                  !probeGenerations.contains(terminalGeneration),
                  artifactLedger.publicationState == .published,
                  artifactLedger.publishedGenerationCount == 2,
                  artifactLedger.eventChainArtifactCount == 1,
                  artifactLedger.diagnosticManifestCount == 1,
                  artifactLedger.terminalReceiptCount == 1
            else {
                return false
            }
            return true
        }()
        let sourceCountersAreCanonical =
            receipt.sourceCounters.map {
                $0.adapterInvocations == 3
                    && $0.recordsRead == 4
                    && $0.recordsAccepted == 4
                    && $0.recordsRejected == 0
                    && $0.preparedRecords == 4
                    && $0.chunks == 4
                    && $0.embeddingRequests == 4
                    && $0.embeddingsAccepted == 4
                    && $0.indexWrites == 4
                    && $0.leakageCanaryHits == 0
            } ?? false

        guard receipt.status != .success || (
            !acceptedAdmission.isEmpty
                && rejectedAdmission.isEmpty
                && !acceptedFixtures.isEmpty
                && rejectedFixtures.isEmpty
                && !authorizedSources.isEmpty
                && publications.count == 1
                && qwenAssessments.count == 1
                && gemmaAssessments.count == 1
                && gptAssessments.count == 1
                && exactFixtureHashBinding
                && exactSearchMatrix
                && exactHydrationMatrix
                && sourceCountersAreCanonical
                && acceptedFixtures.contains {
                    $0.metadata.fixtureManifestSHA256
                        == receipt.fixtureManifestSHA256
                }
                && authorizedSources.contains {
                    $0.metadata.fixtureManifestSHA256
                            == receipt.fixtureManifestSHA256
                        && $0.metadata.sourceAllowlistSHA256
                            == receipt.sourceAllowlistSHA256
                        && $0.metadata
                            .authorizationReceiptIdentifierSHA256
                            == receipt
                                .authorizationReceiptIdentifierSHA256
                        && $0.metadata.counters
                            == receipt.sourceCounters
                }
                && publications[0].metadata
                    .fixtureManifestSHA256
                    == receipt.fixtureManifestSHA256
                && publications[0].metadata
                    .sourceAllowlistSHA256
                    == receipt.sourceAllowlistSHA256
                && publications[0].metadata
                    .authorizationReceiptIdentifierSHA256
                    == receipt
                        .authorizationReceiptIdentifierSHA256
                && publications[0].metadata
                    .generationIdentifierSHA256
                    == receipt.generationIdentifierSHA256
                && publications[0].metadata.counters
                    == receipt.sourceCounters
                && gemmaAssessments[0].metadata.modelDigest
                    != nil
                && gptAssessments[0].metadata.modelDigest
                    != nil
                && qwenAssessments[0].metadata.modelDigest
                    == receipt.modelDigestSHA256
                && qwenAssessments[0].metadata
                    .vectorDimension == 1_024
                && qwenAssessments[0].metadata
                    .runtimeIdentitySHA256 != nil
                && qwenAssessments[0].metadata
                    .requestProfileSHA256 != nil
                && hydrationPassed
                && successfulCleanup.count == 1
                && failedCleanup.isEmpty
                && events.contains {
                    $0.event == .privacy
                        && $0.status == .success
                        && $0.reasonCode == .privacyPassed
                        && $0.metadata.scenario == .receiptPrivacy
                }
                && artifactLedger.providerEvidenceCount > 0
                && events.filter {
                    $0.event == .network && $0.metadata.model != nil
                }.allSatisfy {
                    $0.metadata.hasCompleteProviderCorrelation
                        && $0.metadata.executableSHA256
                            == receipt.applicationIdentity
                                .executableSHA256
                        && $0.metadata.endpointClassification
                            == .ollamaModelIPv4Loopback
                        && $0.metadata.artifactSHA256 != nil
                }
                && receipt.privacySummary.passed
        ) else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
    }

    private static func validateTerminalReceiptPayload(
        _ receipt: P8FSignedSmokeTerminalReceipt
    ) throws {
        let hashes = [
            receipt.fixtureManifestSHA256,
            receipt.sourceAllowlistSHA256,
            receipt.authorizationReceiptIdentifierSHA256,
            receipt.generationIdentifierSHA256,
            receipt.modelDigestSHA256,
        ]
        guard P8FSignedSmokeTerminalReceipt
                .terminalStatusAndReasonAreValid(
                    status: receipt.status,
                    reasonCode: receipt.reasonCode
                ),
              receipt.completedAt >= receipt.startedAt,
              receipt.startedAt.timeIntervalSinceReferenceDate
                .isFinite,
              receipt.completedAt.timeIntervalSinceReferenceDate
                .isFinite,
              receipt.applicationIdentity.bundleIdentifier
                == .p8fResumeSmoke,
              receipt.applicationIdentity
                .marketingVersionMajor == 1,
              receipt.applicationIdentity
                .marketingVersionMinor == 0,
              receipt.applicationIdentity
                .marketingVersionPatch == 0,
              receipt.applicationIdentity.buildNumber == 5,
              P8FSignedSmokeDigest.isSHA256(
                receipt.applicationIdentity.executableSHA256
              ),
              P8FSignedSmokeDigest.isSHA1(
                receipt.applicationIdentity.cdHash
              ),
              receipt.applicationIdentity
                .storageClassification
                == .signedSmokeIsolatedDisk,
              hashes.compactMap({ $0 }).allSatisfy(
                P8FSignedSmokeDigest.isSHA256
              ),
              receipt.modelDigestSHA256 == nil
                || receipt.model != nil,
              receipt.modelAssessmentStatus == nil
                || receipt.model != nil,
              receipt.searchPassed == nil
                || receipt.searchMode != nil,
              receipt.sourceCounters.map(countersAreValid)
                ?? true,
              receipt.artifactLedger?.schemaVersion
                == P8FSignedSmokeArtifactLedger
                    .currentSchemaVersion,
              privacySummaryIsValid(receipt.privacySummary),
              receipt.status != .cancelled
                || (
                    receipt.privacySummary.passed
                        && receipt.cleanupPassed == true
                        && receipt.semanticOutcomeState
                            != .published
                        && receipt.generationIdentifierSHA256
                            == nil
                  ),
              receipt.status != .success
                || (
                    receipt.scenario == .cleanup
                        && receipt.privacySummary.passed
                        && receipt.admissionAccepted == true
                        && receipt.fixtureAccepted == true
                        && receipt.fixtureManifestSHA256 != nil
                        && receipt.sourceAllowlistSHA256 != nil
                        && receipt
                            .authorizationReceiptIdentifierSHA256
                            != nil
                        && receipt.semanticOutcomeState
                            == .published
                        && receipt.generationIdentifierSHA256
                            != nil
                        && receipt.sourceCounters != nil
                        && receipt.model != nil
                        && receipt.modelDigestSHA256 != nil
                        && receipt.modelAssessmentStatus
                            == .success
                        && receipt.searchMode != nil
                        && receipt.searchPassed == true
                        && receipt.hydrationPassed == true
                        && receipt.cleanupPassed == true
                  )
        else {
            throw P8FSignedSmokeReceiptStoreFailure
                .terminalReceiptInvalid
        }
    }

    private static func countersAreValid(
        _ counters: P8FSignedSmokeCounters
    ) -> Bool {
        [
            counters.adapterInvocations,
            counters.recordsRead,
            counters.recordsAccepted,
            counters.recordsRejected,
            counters.preparedRecords,
            counters.chunks,
            counters.embeddingRequests,
            counters.embeddingsAccepted,
            counters.indexWrites,
            counters.resultCount,
            counters.leakageCanaryHits,
        ].allSatisfy {
            (0...10_000_000).contains($0)
        }
    }

    private static func privacySummaryIsValid(
        _ summary: P8FSignedSmokePrivacySummary
    ) -> Bool {
        [
            summary.artifactCount,
            summary.forbiddenFieldCount,
            summary.forbiddenValueCount,
            summary.rawVectorCount,
            summary.rawContentCount,
            summary.rawPromptCount,
            summary.rawResponseCount,
            summary.hiddenReasoningCount,
            summary.privatePathCount,
            summary.credentialCount,
        ].allSatisfy {
            (0...10_000_000).contains($0)
        }
    }

    private static func validGeneratedIdentifier(
        _ value: String,
        prefix: String
    ) -> Bool {
        P8FSignedSmokeValueValidator
            .isGeneratedIdentifier(value, prefix: prefix)
    }
}
