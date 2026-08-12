import Foundation
import SwiftData

private enum AttachedDataSourcePersistenceCoding {
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }
}

@Model final class StoredAttachedDataSource {
    @Attribute(.unique) var id: String
    var kindRaw: String
    var modeRaw: String
    var stateRaw: String
    var displayName: String
    var encodedRecord: Data
    private var securityScopedBookmark: Data?
    var updatedAt: Date
    var schemaVersion: Int

    init(
        _ value: AttachedDataSourceRecord,
        securityScopedBookmark: Data?
    ) throws {
        try value.validate()
        try Self.validateBookmark(
            securityScopedBookmark,
            for: value.access
        )
        id = value.id
        kindRaw = value.kind.rawValue
        modeRaw = value.mode.rawValue
        stateRaw = value.state.rawValue
        displayName = value.displayName
        encodedRecord = try AttachedDataSourcePersistenceCoding.encode(value)
        self.securityScopedBookmark = securityScopedBookmark
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    func update(with value: AttachedDataSourceRecord) throws {
        try apply(value, bookmark: securityScopedBookmark)
    }

    func update(
        with value: AttachedDataSourceRecord,
        replacingBookmarkWith bookmark: Data
    ) throws {
        try apply(value, bookmark: bookmark)
    }

    func updateRemovingBookmark(with value: AttachedDataSourceRecord) throws {
        try apply(value, bookmark: nil)
    }

    func bookmarkData() -> Data? {
        securityScopedBookmark
    }

    func domain() throws -> AttachedDataSourceRecord {
        do {
            let value = try AttachedDataSourcePersistenceCoding.decode(
                AttachedDataSourceRecord.self,
                from: encodedRecord
            )
            guard value.id == id,
                  value.kind.rawValue == kindRaw,
                  value.mode.rawValue == modeRaw,
                  value.state.rawValue == stateRaw,
                  value.displayName == displayName,
                  value.updatedAt == updatedAt
            else { throw AttachedDataSourceFailureCode.persistenceCorrupt }
            try value.validate()
            try Self.validateBookmark(securityScopedBookmark, for: value.access)
            return value
        } catch let failure as AttachedDataSourceFailureCode {
            throw failure
        } catch {
            throw AttachedDataSourceFailureCode.persistenceCorrupt
        }
    }

    private func apply(
        _ value: AttachedDataSourceRecord,
        bookmark: Data?
    ) throws {
        guard value.id == id else {
            throw AttachedDataSourceFailureCode.invalidIdentifier
        }
        try value.validate()
        try Self.validateBookmark(bookmark, for: value.access)
        let encoded = try AttachedDataSourcePersistenceCoding.encode(value)
        kindRaw = value.kind.rawValue
        modeRaw = value.mode.rawValue
        stateRaw = value.state.rawValue
        displayName = value.displayName
        encodedRecord = encoded
        securityScopedBookmark = bookmark
        updatedAt = value.updatedAt
        schemaVersion = 1
    }

    private static func validateBookmark(
        _ bookmark: Data?,
        for access: AttachedDataSourceAccess
    ) throws {
        try access.validate()
        if let bookmark {
            guard !bookmark.isEmpty,
                  bookmark.count <= AttachedDataSourceLimits.maximumBookmarkBytes
            else { throw AttachedDataSourceFailureCode.bookmarkTooLarge }
        }
        guard access.continuingAccessRetained == (bookmark != nil) else {
            throw access.continuingAccessRetained
                ? AttachedDataSourceFailureCode.bookmarkRequired
                : AttachedDataSourceFailureCode.invalidAccessState
        }
    }
}

@Model final class StoredAttachedDataSourceReceipt {
    @Attribute(.unique) var id: String
    var sourceIdentifier: String
    var operationRaw: String
    var outcomeRaw: String
    var encodedReceipt: Data
    var completedAt: Date
    var schemaVersion: Int

    init(_ value: AttachedDataSourceReceipt) throws {
        try value.validate()
        id = value.id
        sourceIdentifier = value.sourceIdentifier
        operationRaw = value.operation.rawValue
        outcomeRaw = value.outcome.rawValue
        encodedReceipt = try AttachedDataSourcePersistenceCoding.encode(value)
        completedAt = value.completedAt
        schemaVersion = 1
    }

    func domain() throws -> AttachedDataSourceReceipt {
        do {
            let value = try AttachedDataSourcePersistenceCoding.decode(
                AttachedDataSourceReceipt.self,
                from: encodedReceipt
            )
            guard value.id == id,
                  value.sourceIdentifier == sourceIdentifier,
                  value.operation.rawValue == operationRaw,
                  value.outcome.rawValue == outcomeRaw,
                  value.completedAt == completedAt
            else { throw AttachedDataSourceFailureCode.persistenceCorrupt }
            try value.validate()
            return value
        } catch let failure as AttachedDataSourceFailureCode {
            throw failure
        } catch {
            throw AttachedDataSourceFailureCode.persistenceCorrupt
        }
    }
}

enum LokiBriefSchemaV11: VersionedSchema {
    static let versionIdentifier = Schema.Version(11, 0, 0)

    static var models: [any PersistentModel.Type] {
        LokiBriefSchemaV10.models + [
            StoredAttachedDataSource.self,
            StoredAttachedDataSourceReceipt.self,
        ]
    }
}

enum LokiBriefMigrationPlanV11: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        LokiBriefMigrationPlanV10.schemas + [LokiBriefSchemaV11.self]
    }

    static var stages: [MigrationStage] {
        LokiBriefMigrationPlanV10.stages + [
            .lightweight(
                fromVersion: LokiBriefSchemaV10.self,
                toVersion: LokiBriefSchemaV11.self
            ),
        ]
    }
}
