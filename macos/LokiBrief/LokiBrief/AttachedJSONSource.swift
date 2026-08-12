import CryptoKit
import Foundation

struct AttachedJSONLimits: Hashable, Sendable {
    static let standard = AttachedJSONLimits()

    let maximumInputBytes: Int
    let maximumNestingDepth: Int
    let maximumNodes: Int
    let maximumKeysPerObject: Int
    let maximumRecords: Int
    let maximumStringBytes: Int
    let maximumNumberBytes: Int
    let maximumAggregateMaterializationBytes: Int
    let maximumNormalizedTextBytes: Int
    let maximumSelectedFields: Int
    let cancellationCheckIntervalBytes: Int

    init(
        maximumInputBytes: Int = 32 * 1_024 * 1_024,
        maximumNestingDepth: Int = 64,
        maximumNodes: Int = 1_000_000,
        maximumKeysPerObject: Int = 10_000,
        maximumRecords: Int = 100_000,
        maximumStringBytes: Int = 1 * 1_024 * 1_024,
        maximumNumberBytes: Int = 64 * 1_024,
        maximumAggregateMaterializationBytes: Int = 32 * 1_024 * 1_024,
        maximumNormalizedTextBytes: Int = 1_500_000,
        maximumSelectedFields: Int = 128,
        cancellationCheckIntervalBytes: Int = 4_096
    ) {
        self.maximumInputBytes = maximumInputBytes
        self.maximumNestingDepth = maximumNestingDepth
        self.maximumNodes = maximumNodes
        self.maximumKeysPerObject = maximumKeysPerObject
        self.maximumRecords = maximumRecords
        self.maximumStringBytes = maximumStringBytes
        self.maximumNumberBytes = maximumNumberBytes
        self.maximumAggregateMaterializationBytes = maximumAggregateMaterializationBytes
        self.maximumNormalizedTextBytes = maximumNormalizedTextBytes
        self.maximumSelectedFields = maximumSelectedFields
        self.cancellationCheckIntervalBytes = cancellationCheckIntervalBytes
    }

    fileprivate var isValid: Bool {
        maximumInputBytes > 0
            && maximumNestingDepth > 0
            && maximumNodes > 0
            && maximumKeysPerObject > 0
            && maximumRecords > 0
            && maximumStringBytes > 0
            && maximumNumberBytes > 0
            && maximumAggregateMaterializationBytes > 0
            && maximumNormalizedTextBytes > 0
            && maximumSelectedFields > 0
            && cancellationCheckIntervalBytes > 0
    }
}

enum AttachedJSONFailureCode: String, Error, Codable, CaseIterable, Hashable, Sendable {
    case invalidLimits = "attached_json_limits_invalid"
    case inputTooLarge = "attached_json_input_too_large"
    case invalidUTF8 = "attached_json_utf8_invalid"
    case byteOrderMarkUnsupported = "attached_json_bom_unsupported"
    case malformedDocument = "attached_json_document_malformed"
    case truncatedDocument = "attached_json_document_truncated"
    case trailingContent = "attached_json_trailing_content"
    case duplicateObjectKey = "attached_json_duplicate_object_key"
    case maximumDepthExceeded = "attached_json_depth_exceeded"
    case maximumNodeCountExceeded = "attached_json_node_count_exceeded"
    case maximumKeysPerObjectExceeded = "attached_json_object_key_count_exceeded"
    case maximumRecordCountExceeded = "attached_json_record_count_exceeded"
    case maximumStringBytesExceeded = "attached_json_string_bytes_exceeded"
    case maximumNumberBytesExceeded = "attached_json_number_bytes_exceeded"
    case maximumAggregateBytesExceeded = "attached_json_aggregate_bytes_exceeded"
    case maximumSelectedFieldsExceeded = "attached_json_selected_field_count_exceeded"
    case cancelled = "attached_json_cancelled"
    case invalidJSONPointer = "attached_json_pointer_invalid"
    case jsonPointerNotFound = "attached_json_pointer_not_found"
    case recordRootNotContainer = "attached_json_record_root_not_container"
    case invalidIDField = "attached_json_id_field_invalid"
    case duplicateRecordIdentifier = "attached_json_record_identifier_duplicate"
}

extension AttachedJSONFailureCode: LocalizedError {
    var errorDescription: String? { rawValue }
}

struct AttachedJSONNumber: Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
        case integer
        case floatingPoint = "floating_point"
    }

    let kind: Kind
    let canonicalLexeme: String

    fileprivate init(token: String, hasFractionOrExponent: Bool) {
        kind = hasFractionOrExponent ? .floatingPoint : .integer
        canonicalLexeme = hasFractionOrExponent
            ? Self.canonicalFloatingPoint(token)
            : Self.canonicalInteger(token)
    }

    private static func canonicalInteger(_ token: String) -> String {
        token == "-0" ? "0" : token
    }

    /// Floating-point tokens are retained as exact base-10 values. They are not
    /// coerced through Double or Decimal, so large coefficients and exponents do
    /// not round or overflow. The representation is one normalized significant
    /// digit, an optional fractional coefficient, and an exact decimal exponent.
    private static func canonicalFloatingPoint(_ token: String) -> String {
        var body = token[...]
        let isNegative = body.first == "-"
        if isNegative { body = body.dropFirst() }

        let exponentSeparator = body.firstIndex(where: { $0 == "e" || $0 == "E" })
        let coefficient = exponentSeparator.map { body[..<$0] } ?? body
        let exponentToken = exponentSeparator.map { body[body.index(after: $0)...] }
        let decimalPoint = coefficient.firstIndex(of: ".")
        let integerDigits = decimalPoint.map { coefficient[..<$0] } ?? coefficient
        let fractionalDigits = decimalPoint.map { coefficient[coefficient.index(after: $0)...] } ?? ""[...]
        let combined = String(integerDigits) + String(fractionalDigits)
        let withoutLeadingZeros = combined.drop(while: { $0 == "0" })

        guard !withoutLeadingZeros.isEmpty else { return "0e0" }

        let originalSignificantCount = withoutLeadingZeros.count
        var significant = String(withoutLeadingZeros)
        while significant.count > 1, significant.last == "0" {
            significant.removeLast()
        }

        let rawExponent = exponentToken.map(String.init) ?? "0"
        let exponent = AttachedJSONSignedDecimal(rawExponent)
        let exponentDelta = originalSignificantCount - 1 - fractionalDigits.count
        let normalizedExponent = exponent.adding(exponentDelta)
        let first = significant.removeFirst()
        let mantissa = significant.isEmpty ? String(first) : "\(first).\(significant)"
        return (isNegative ? "-" : "") + mantissa + "e" + normalizedExponent
    }
}

indirect enum AttachedJSONValue: Hashable, Sendable {
    case null
    case boolean(Bool)
    case number(AttachedJSONNumber)
    case string(String)
    case array([AttachedJSONValue])
    case object([AttachedJSONObjectMember])

    var kind: AttachedJSONValueKind {
        switch self {
        case .null: .null
        case .boolean: .boolean
        case let .number(number): number.kind == .integer ? .integer : .floatingPoint
        case .string: .string
        case .array: .array
        case .object: .object
        }
    }

    func member(named name: String) -> AttachedJSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first(where: { $0.key == name })?.value
    }

    func value(atJSONPointer pointer: String) throws -> AttachedJSONValue {
        try AttachedJSONPointer.resolve(pointer, in: self)
    }

    func canonicalData(limits: AttachedJSONLimits = .standard) throws -> Data {
        guard limits.isValid else { throw AttachedJSONFailureCode.invalidLimits }
        return try AttachedJSONCanonical.data(
            for: self,
            limits: limits,
            isCancelled: { Task.isCancelled }
        )
    }

    func canonicalString(limits: AttachedJSONLimits = .standard) throws -> String {
        guard let value = String(data: try canonicalData(limits: limits), encoding: .utf8) else {
            throw AttachedJSONFailureCode.invalidUTF8
        }
        return value
    }
}

struct AttachedJSONObjectMember: Hashable, Sendable {
    let key: String
    let value: AttachedJSONValue
}

enum AttachedJSONValueKind: String, Codable, CaseIterable, Hashable, Sendable {
    case null
    case boolean
    case integer
    case floatingPoint = "floating_point"
    case string
    case object
    case array
}

struct AttachedJSONDocument: Hashable, Sendable {
    let root: AttachedJSONValue
    let inputByteCount: Int
    let inputSHA256: String
    let canonicalByteCount: Int
    let canonicalSHA256: String
    let nodeCount: Int
    let resourceMetrics: AttachedJSONResourceMetrics

    fileprivate let limits: AttachedJSONLimits

    func value(atJSONPointer pointer: String) throws -> AttachedJSONValue {
        try root.value(atJSONPointer: pointer)
    }

    func recordRoot(
        atJSONPointer pointer: String = "",
        explicitIDPointer: String? = nil
    ) throws -> AttachedJSONRecordRoot {
        let selected = try value(atJSONPointer: pointer)
        let values: [AttachedJSONValue]
        let pointers: [String]
        let isArrayRoot: Bool

        switch selected {
        case let .array(records):
            guard records.count <= limits.maximumRecords else {
                throw AttachedJSONFailureCode.maximumRecordCountExceeded
            }
            values = records
            pointers = records.indices.map { AttachedJSONPointer.appending(String($0), to: pointer) }
            isArrayRoot = true
        case .object:
            guard limits.maximumRecords >= 1 else {
                throw AttachedJSONFailureCode.maximumRecordCountExceeded
            }
            values = [selected]
            pointers = [pointer]
            isArrayRoot = false
        default:
            throw AttachedJSONFailureCode.recordRootNotContainer
        }

        let identityField: (pointer: String, strategy: AttachedJSONRecordIdentityStrategy)?
        if let explicitIDPointer {
            try AttachedJSONPointer.validate(explicitIDPointer)
            try AttachedJSONIdentity.validateExplicitID(
                pointer: explicitIDPointer,
                records: values,
                limits: limits
            )
            identityField = (explicitIDPointer, .explicitIDField)
        } else if let recognized = try AttachedJSONIdentity.unambiguousRecognizedIDPointer(
            records: values,
            limits: limits
        ) {
            identityField = (recognized, .recognizedIDField)
        } else {
            identityField = nil
        }

        var records: [AttachedJSONRecord] = []
        records.reserveCapacity(values.count)
        var aggregateBytes = 0
        for (index, value) in values.enumerated() {
            let canonical = try AttachedJSONCanonical.data(
                for: value,
                limits: limits,
                isCancelled: { Task.isCancelled }
            )
            guard aggregateBytes <= limits.maximumAggregateMaterializationBytes - canonical.count else {
                throw AttachedJSONFailureCode.maximumAggregateBytesExceeded
            }
            aggregateBytes += canonical.count
            let recordDigest = AttachedJSONDigest.sha256(canonical)
            let identity: String
            let strategy: AttachedJSONRecordIdentityStrategy
            let identityPointer: String?
            if let identityField {
                let identityValue = try AttachedJSONPointer.resolve(identityField.pointer, in: value)
                let identityCanonical = try AttachedJSONIdentity.canonicalIdentityValue(
                    identityValue,
                    limits: limits
                )
                identity = AttachedJSONDigest.domainSeparated(
                    domain: "agent-loki.attached-json.id-field.v1",
                    fields: [identityField.pointer, String(decoding: identityCanonical, as: UTF8.self)]
                )
                strategy = identityField.strategy
                identityPointer = identityField.pointer
            } else {
                strategy = isArrayRoot ? .pointerAndDigest : .sourceRelativePointerAndDigest
                identityPointer = nil
                identity = AttachedJSONDigest.domainSeparated(
                    domain: "agent-loki.attached-json.pointer-digest.v1",
                    fields: [pointers[index], recordDigest]
                )
            }
            records.append(AttachedJSONRecord(
                jsonPointer: pointers[index],
                value: value,
                canonicalSHA256: recordDigest,
                stableIdentifier: identity,
                identityStrategy: strategy,
                identityFieldPointer: identityPointer,
                limits: limits
            ))
        }

        return AttachedJSONRecordRoot(
            jsonPointer: pointer,
            selectedValueKind: selected.kind,
            records: records,
            inferredFields: AttachedJSONFieldInference.fields(for: values),
            estimatedCanonicalRecordBytes: aggregateBytes,
            limits: limits
        )
    }
}

struct AttachedJSONResourceMetrics: Hashable, Sendable {
    let peakExplicitByteBufferCount: Int
    let peakExplicitByteBufferBytes: Int
    let inputByteBufferBytes: Int
    let canonicalByteBufferBytes: Int
}

enum AttachedJSONRecordIdentityStrategy: String, Codable, CaseIterable, Hashable, Sendable {
    case explicitIDField = "explicit_id_field"
    case recognizedIDField = "recognized_id_field"
    case pointerAndDigest = "pointer_and_digest"
    case sourceRelativePointerAndDigest = "source_relative_pointer_and_digest"
}

struct AttachedJSONRecord: Hashable, Sendable {
    let jsonPointer: String
    let value: AttachedJSONValue
    let canonicalSHA256: String
    let stableIdentifier: String
    let identityStrategy: AttachedJSONRecordIdentityStrategy
    let identityFieldPointer: String?

    fileprivate let limits: AttachedJSONLimits

    func normalizedSelectedFieldText(
        selectedFieldPointers: [String]
    ) throws -> AttachedJSONNormalizedText {
        try AttachedJSONPreview.normalizedSelectedFieldText(
            for: self,
            selectedFieldPointers: selectedFieldPointers,
            limits: limits
        )
    }
}

struct AttachedJSONRecordRoot: Hashable, Sendable {
    let jsonPointer: String
    let selectedValueKind: AttachedJSONValueKind
    let records: [AttachedJSONRecord]
    let inferredFields: [AttachedJSONInferredField]
    let estimatedCanonicalRecordBytes: Int

    fileprivate let limits: AttachedJSONLimits
}

struct AttachedJSONInferredField: Hashable, Sendable {
    let jsonPointer: String
    let boundedLabel: String
    let valueKinds: [AttachedJSONValueKind]
    let presentRecordCount: Int
    let nullRecordCount: Int
    let isPresentInEveryRecord: Bool
}

struct AttachedJSONNormalizedText: Hashable, Sendable {
    let text: String
    let selectedFieldPointers: [String]
    let wasTruncated: Bool
}

enum AttachedJSONPreview {
    static func normalizedSelectedFieldText(
        for record: AttachedJSONRecord,
        selectedFieldPointers: [String],
        limits: AttachedJSONLimits = .standard
    ) throws -> AttachedJSONNormalizedText {
        guard limits.isValid else { throw AttachedJSONFailureCode.invalidLimits }
        let pointers = Array(Set(selectedFieldPointers)).sorted(by: AttachedJSONOrdering.less)
        guard pointers.count <= limits.maximumSelectedFields else {
            throw AttachedJSONFailureCode.maximumSelectedFieldsExceeded
        }

        var output = Data()
        output.reserveCapacity(min(limits.maximumNormalizedTextBytes, 64 * 1_024))
        var wasTruncated = false

        for (index, pointer) in pointers.enumerated() {
            try AttachedJSONPointer.validate(pointer)
            let value = try AttachedJSONPointer.resolve(pointer, in: record.value)
            let rendered: String
            switch value {
            case let .string(string):
                rendered = normalizeString(string)
            case .null, .boolean, .number, .array, .object:
                let canonical = try AttachedJSONCanonical.data(
                    for: value,
                    limits: limits,
                    isCancelled: { Task.isCancelled }
                )
                rendered = String(decoding: canonical, as: UTF8.self)
            }
            let prefix = index == 0 ? "" : "\n"
            let label = pointer.isEmpty ? "$" : pointer
            if !append(prefix + label + ": " + rendered, to: &output, maximumBytes: limits.maximumNormalizedTextBytes) {
                wasTruncated = true
                break
            }
        }

        return AttachedJSONNormalizedText(
            text: String(decoding: output, as: UTF8.self),
            selectedFieldPointers: pointers,
            wasTruncated: wasTruncated
        )
    }

    private static func normalizeString(_ value: String) -> String {
        var output = String()
        output.reserveCapacity(value.count)
        var pendingSpace = false
        for scalar in value.unicodeScalars {
            let scalarValue = scalar.value
            let isWhitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let isControl = scalarValue < 0x20 || (0x7F...0x9F).contains(scalarValue)
            let isBidiControl = (0x202A...0x202E).contains(scalarValue)
                || (0x2066...0x2069).contains(scalarValue)
            let isZeroWidthControl = scalarValue == 0x200B || scalarValue == 0xFEFF
            if isWhitespace {
                pendingSpace = !output.isEmpty
            } else if !isControl, !isBidiControl, !isZeroWidthControl {
                if pendingSpace { output.append(" ") }
                output.unicodeScalars.append(scalar)
                pendingSpace = false
            }
        }
        return output
    }

    private static func append(_ value: String, to output: inout Data, maximumBytes: Int) -> Bool {
        for scalar in value.unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            guard output.count <= maximumBytes - bytes.count else { return false }
            output.append(contentsOf: bytes)
        }
        return true
    }
}

struct AttachedJSONParser: Sendable {
    static let supportsNDJSON = false

    let limits: AttachedJSONLimits

    init(limits: AttachedJSONLimits = .standard) {
        self.limits = limits
    }

    func parse(
        _ data: Data,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> AttachedJSONDocument {
        guard limits.isValid else { throw AttachedJSONFailureCode.invalidLimits }
        guard data.count <= limits.maximumInputBytes else {
            throw AttachedJSONFailureCode.inputTooLarge
        }
        let bytes = Array(data)
        try AttachedJSONUTF8.validate(
            bytes,
            checkInterval: limits.cancellationCheckIntervalBytes,
            isCancelled: isCancelled
        )
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            throw AttachedJSONFailureCode.byteOrderMarkUnsupported
        }

        var state = AttachedJSONParseState(
            bytes: bytes,
            limits: limits,
            isCancelled: isCancelled
        )
        try state.skipWhitespace()
        guard !state.isAtEnd else { throw AttachedJSONFailureCode.truncatedDocument }
        let root = try state.parseValue(containerDepth: 0)
        try state.skipWhitespace()
        guard state.isAtEnd else { throw AttachedJSONFailureCode.trailingContent }
        try state.checkCancellation(force: true)

        let canonical = try AttachedJSONCanonical.data(
            for: root,
            limits: limits,
            isCancelled: isCancelled
        )
        return AttachedJSONDocument(
            root: root,
            inputByteCount: data.count,
            inputSHA256: AttachedJSONDigest.sha256(data),
            canonicalByteCount: canonical.count,
            canonicalSHA256: AttachedJSONDigest.sha256(canonical),
            nodeCount: state.nodeCount,
            resourceMetrics: .init(
                peakExplicitByteBufferCount: 2,
                peakExplicitByteBufferBytes: bytes.count + canonical.count,
                inputByteBufferBytes: bytes.count,
                canonicalByteBufferBytes: canonical.count
            ),
            limits: limits
        )
    }
}

private struct AttachedJSONParseState {
    let bytes: [UInt8]
    let limits: AttachedJSONLimits
    let isCancelled: @Sendable () -> Bool
    var index = 0
    var nodeCount = 0
    var aggregateDecodedBytes = 0
    var nextCancellationIndex = 0

    var isAtEnd: Bool { index >= bytes.count }

    mutating func checkCancellation(force: Bool = false) throws {
        guard force || index >= nextCancellationIndex else { return }
        if Task.isCancelled || isCancelled() { throw AttachedJSONFailureCode.cancelled }
        nextCancellationIndex = index + limits.cancellationCheckIntervalBytes
    }

    mutating func skipWhitespace() throws {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D:
                index += 1
                try checkCancellation()
            default:
                return
            }
        }
    }

    mutating func parseValue(containerDepth: Int) throws -> AttachedJSONValue {
        try checkCancellation()
        guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
        nodeCount += 1
        guard nodeCount <= limits.maximumNodes else {
            throw AttachedJSONFailureCode.maximumNodeCountExceeded
        }

        switch bytes[index] {
        case 0x6E:
            try consumeLiteral([0x6E, 0x75, 0x6C, 0x6C])
            try addAggregateBytes(4)
            return .null
        case 0x74:
            try consumeLiteral([0x74, 0x72, 0x75, 0x65])
            try addAggregateBytes(4)
            return .boolean(true)
        case 0x66:
            try consumeLiteral([0x66, 0x61, 0x6C, 0x73, 0x65])
            try addAggregateBytes(5)
            return .boolean(false)
        case 0x22:
            return .string(try parseString())
        case 0x5B:
            return try parseArray(containerDepth: containerDepth)
        case 0x7B:
            return try parseObject(containerDepth: containerDepth)
        case 0x2D, 0x30...0x39:
            return .number(try parseNumber())
        default:
            throw AttachedJSONFailureCode.malformedDocument
        }
    }

    mutating func parseArray(containerDepth: Int) throws -> AttachedJSONValue {
        guard containerDepth < limits.maximumNestingDepth else {
            throw AttachedJSONFailureCode.maximumDepthExceeded
        }
        index += 1
        try addAggregateBytes(2)
        try skipWhitespace()
        if consumeIf(0x5D) { return .array([]) }

        var values: [AttachedJSONValue] = []
        while true {
            values.append(try parseValue(containerDepth: containerDepth + 1))
            try skipWhitespace()
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            if consumeIf(0x5D) { return .array(values) }
            guard consumeIf(0x2C) else { throw AttachedJSONFailureCode.malformedDocument }
            try addAggregateBytes(1)
            try skipWhitespace()
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
        }
    }

    mutating func parseObject(containerDepth: Int) throws -> AttachedJSONValue {
        guard containerDepth < limits.maximumNestingDepth else {
            throw AttachedJSONFailureCode.maximumDepthExceeded
        }
        index += 1
        try addAggregateBytes(2)
        try skipWhitespace()
        if consumeIf(0x7D) { return .object([]) }

        var members: [AttachedJSONObjectMember] = []
        var keys = Set<String>()
        while true {
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            guard bytes[index] == 0x22 else { throw AttachedJSONFailureCode.malformedDocument }
            let key = try parseString()
            guard keys.insert(key).inserted else {
                throw AttachedJSONFailureCode.duplicateObjectKey
            }
            guard keys.count <= limits.maximumKeysPerObject else {
                throw AttachedJSONFailureCode.maximumKeysPerObjectExceeded
            }
            try skipWhitespace()
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            guard consumeIf(0x3A) else { throw AttachedJSONFailureCode.malformedDocument }
            try addAggregateBytes(1)
            try skipWhitespace()
            members.append(AttachedJSONObjectMember(
                key: key,
                value: try parseValue(containerDepth: containerDepth + 1)
            ))
            try skipWhitespace()
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            if consumeIf(0x7D) {
                return .object(members.sorted {
                    AttachedJSONOrdering.less($0.key, $1.key)
                })
            }
            guard consumeIf(0x2C) else { throw AttachedJSONFailureCode.malformedDocument }
            try addAggregateBytes(1)
            try skipWhitespace()
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
        }
    }

    mutating func parseString() throws -> String {
        guard consumeIf(0x22) else { throw AttachedJSONFailureCode.malformedDocument }
        var output = Data()
        var segmentStart = index

        while index < bytes.count {
            try checkCancellation()
            let byte = bytes[index]
            if byte == 0x22 {
                try appendStringSegment(segmentStart..<index, to: &output)
                index += 1
                try addAggregateBytes(output.count)
                return String(decoding: output, as: UTF8.self)
            }
            if byte == 0x5C {
                try appendStringSegment(segmentStart..<index, to: &output)
                index += 1
                guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
                switch bytes[index] {
                case 0x22, 0x5C, 0x2F:
                    try appendDecoded(bytes[index], to: &output)
                    index += 1
                case 0x62:
                    try appendDecoded(0x08, to: &output)
                    index += 1
                case 0x66:
                    try appendDecoded(0x0C, to: &output)
                    index += 1
                case 0x6E:
                    try appendDecoded(0x0A, to: &output)
                    index += 1
                case 0x72:
                    try appendDecoded(0x0D, to: &output)
                    index += 1
                case 0x74:
                    try appendDecoded(0x09, to: &output)
                    index += 1
                case 0x75:
                    index += 1
                    let first = try parseUnicodeCodeUnit()
                    let scalarValue: UInt32
                    if (0xD800...0xDBFF).contains(first) {
                        guard index + 1 < bytes.count else {
                            throw AttachedJSONFailureCode.truncatedDocument
                        }
                        guard bytes[index] == 0x5C, bytes[index + 1] == 0x75 else {
                            throw AttachedJSONFailureCode.malformedDocument
                        }
                        index += 2
                        let second = try parseUnicodeCodeUnit()
                        guard (0xDC00...0xDFFF).contains(second) else {
                            throw AttachedJSONFailureCode.malformedDocument
                        }
                        scalarValue = 0x10000
                            + ((UInt32(first) - 0xD800) << 10)
                            + (UInt32(second) - 0xDC00)
                    } else {
                        guard !(0xDC00...0xDFFF).contains(first) else {
                            throw AttachedJSONFailureCode.malformedDocument
                        }
                        scalarValue = UInt32(first)
                    }
                    guard let scalar = UnicodeScalar(scalarValue) else {
                        throw AttachedJSONFailureCode.malformedDocument
                    }
                    try appendDecoded(contentsOf: String(scalar).utf8, to: &output)
                default:
                    throw AttachedJSONFailureCode.malformedDocument
                }
                segmentStart = index
                continue
            }
            guard byte >= 0x20 else { throw AttachedJSONFailureCode.malformedDocument }
            index += 1
        }
        throw AttachedJSONFailureCode.truncatedDocument
    }

    mutating func parseNumber() throws -> AttachedJSONNumber {
        let start = index
        if consumeIf(0x2D), index >= bytes.count {
            throw AttachedJSONFailureCode.truncatedDocument
        }
        guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }

        if consumeIf(0x30) {
            if index < bytes.count, (0x30...0x39).contains(bytes[index]) {
                throw AttachedJSONFailureCode.malformedDocument
            }
        } else {
            guard index < bytes.count, (0x31...0x39).contains(bytes[index]) else {
                throw AttachedJSONFailureCode.malformedDocument
            }
            repeat {
                index += 1
                try checkCancellation()
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }

        var hasFractionOrExponent = false
        if consumeIf(0x2E) {
            hasFractionOrExponent = true
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            guard (0x30...0x39).contains(bytes[index]) else {
                throw AttachedJSONFailureCode.malformedDocument
            }
            repeat {
                index += 1
                try checkCancellation()
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }

        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            hasFractionOrExponent = true
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D {
                index += 1
            }
            guard index < bytes.count else { throw AttachedJSONFailureCode.truncatedDocument }
            guard (0x30...0x39).contains(bytes[index]) else {
                throw AttachedJSONFailureCode.malformedDocument
            }
            repeat {
                index += 1
                try checkCancellation()
            } while index < bytes.count && (0x30...0x39).contains(bytes[index])
        }

        let count = index - start
        guard count <= limits.maximumNumberBytes else {
            throw AttachedJSONFailureCode.maximumNumberBytesExceeded
        }
        let token = String(decoding: bytes[start..<index], as: UTF8.self)
        let number = AttachedJSONNumber(
            token: token,
            hasFractionOrExponent: hasFractionOrExponent
        )
        try addAggregateBytes(number.canonicalLexeme.utf8.count)
        return number
    }

    mutating func consumeLiteral(_ literal: [UInt8]) throws {
        guard bytes.count - index >= literal.count else {
            throw AttachedJSONFailureCode.truncatedDocument
        }
        guard Array(bytes[index..<(index + literal.count)]) == literal else {
            throw AttachedJSONFailureCode.malformedDocument
        }
        index += literal.count
    }

    mutating func parseUnicodeCodeUnit() throws -> UInt16 {
        guard bytes.count - index >= 4 else { throw AttachedJSONFailureCode.truncatedDocument }
        var value: UInt16 = 0
        for _ in 0..<4 {
            guard let digit = AttachedJSONHex.value(bytes[index]) else {
                throw AttachedJSONFailureCode.malformedDocument
            }
            value = (value << 4) | UInt16(digit)
            index += 1
        }
        return value
    }

    mutating func appendStringSegment(_ range: Range<Int>, to output: inout Data) throws {
        guard output.count <= limits.maximumStringBytes - range.count else {
            throw AttachedJSONFailureCode.maximumStringBytesExceeded
        }
        output.append(contentsOf: bytes[range])
    }

    mutating func appendDecoded(_ byte: UInt8, to output: inout Data) throws {
        guard output.count < limits.maximumStringBytes else {
            throw AttachedJSONFailureCode.maximumStringBytesExceeded
        }
        output.append(byte)
    }

    mutating func appendDecoded<Bytes: Collection>(contentsOf bytes: Bytes, to output: inout Data) throws
    where Bytes.Element == UInt8 {
        guard output.count <= limits.maximumStringBytes - bytes.count else {
            throw AttachedJSONFailureCode.maximumStringBytesExceeded
        }
        output.append(contentsOf: bytes)
    }

    mutating func addAggregateBytes(_ count: Int) throws {
        guard count >= 0,
              aggregateDecodedBytes <= limits.maximumAggregateMaterializationBytes - count
        else { throw AttachedJSONFailureCode.maximumAggregateBytesExceeded }
        aggregateDecodedBytes += count
    }

    mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1
        return true
    }
}

private enum AttachedJSONCanonical {
    static func data(
        for value: AttachedJSONValue,
        limits: AttachedJSONLimits,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Data {
        var writer = Writer(limits: limits, isCancelled: isCancelled)
        try writer.write(value, containerDepth: 0)
        try writer.checkCancellation(force: true)
        return writer.output
    }

    private struct Writer {
        let limits: AttachedJSONLimits
        let isCancelled: @Sendable () -> Bool
        var output = Data()
        var nextCancellationCount = 0

        mutating func checkCancellation(force: Bool = false) throws {
            guard force || output.count >= nextCancellationCount else { return }
            if Task.isCancelled || isCancelled() { throw AttachedJSONFailureCode.cancelled }
            nextCancellationCount = output.count + limits.cancellationCheckIntervalBytes
        }

        mutating func write(_ value: AttachedJSONValue, containerDepth: Int) throws {
            try checkCancellation()
            switch value {
            case .null:
                try append("null".utf8)
            case let .boolean(value):
                try append((value ? "true" : "false").utf8)
            case let .number(number):
                try append(number.canonicalLexeme.utf8)
            case let .string(string):
                try writeString(string)
            case let .array(values):
                guard containerDepth < limits.maximumNestingDepth else {
                    throw AttachedJSONFailureCode.maximumDepthExceeded
                }
                try append([0x5B])
                for (index, value) in values.enumerated() {
                    if index > 0 { try append([0x2C]) }
                    try write(value, containerDepth: containerDepth + 1)
                }
                try append([0x5D])
            case let .object(members):
                guard containerDepth < limits.maximumNestingDepth else {
                    throw AttachedJSONFailureCode.maximumDepthExceeded
                }
                try append([0x7B])
                let sorted = members.sorted { AttachedJSONOrdering.less($0.key, $1.key) }
                for (index, member) in sorted.enumerated() {
                    if index > 0 { try append([0x2C]) }
                    try writeString(member.key)
                    try append([0x3A])
                    try write(member.value, containerDepth: containerDepth + 1)
                }
                try append([0x7D])
            }
        }

        mutating func writeString(_ value: String) throws {
            try append([0x22])
            for byte in value.utf8 {
                switch byte {
                case 0x22:
                    try append([0x5C, 0x22])
                case 0x5C:
                    try append([0x5C, 0x5C])
                case 0x00...0x1F:
                    try append([
                        0x5C, 0x75, 0x30, 0x30,
                        AttachedJSONHex.lowercase[Int(byte >> 4)],
                        AttachedJSONHex.lowercase[Int(byte & 0x0F)],
                    ])
                default:
                    try append([byte])
                }
            }
            try append([0x22])
        }

        mutating func append<Bytes: Collection>(_ bytes: Bytes) throws where Bytes.Element == UInt8 {
            guard output.count <= limits.maximumAggregateMaterializationBytes - bytes.count else {
                throw AttachedJSONFailureCode.maximumAggregateBytesExceeded
            }
            output.append(contentsOf: bytes)
            try checkCancellation()
        }
    }
}

private enum AttachedJSONPointer {
    static func validate(_ pointer: String) throws {
        _ = try tokens(pointer)
    }

    static func resolve(_ pointer: String, in root: AttachedJSONValue) throws -> AttachedJSONValue {
        var current = root
        for token in try tokens(pointer) {
            switch current {
            case let .object(members):
                guard let member = members.first(where: { $0.key == token }) else {
                    throw AttachedJSONFailureCode.jsonPointerNotFound
                }
                current = member.value
            case let .array(values):
                guard !token.isEmpty,
                      token == "0" || token.first != "0",
                      token.allSatisfy(\.isNumber),
                      let index = Int(token),
                      values.indices.contains(index)
                else { throw AttachedJSONFailureCode.jsonPointerNotFound }
                current = values[index]
            default:
                throw AttachedJSONFailureCode.jsonPointerNotFound
            }
        }
        return current
    }

    static func appending(_ token: String, to pointer: String) -> String {
        pointer + "/" + escape(token)
    }

    static func escape(_ token: String) -> String {
        token
            .replacingOccurrences(of: "~", with: "~0")
            .replacingOccurrences(of: "/", with: "~1")
    }

    private static func tokens(_ pointer: String) throws -> [String] {
        if pointer.isEmpty { return [] }
        guard pointer.first == "/" else { throw AttachedJSONFailureCode.invalidJSONPointer }
        return try pointer
            .split(separator: "/", omittingEmptySubsequences: false)
            .dropFirst()
            .map { try unescape(String($0)) }
    }

    private static func unescape(_ token: String) throws -> String {
        var output = String()
        var index = token.startIndex
        while index < token.endIndex {
            if token[index] != "~" {
                output.append(token[index])
                index = token.index(after: index)
                continue
            }
            let escapeIndex = token.index(after: index)
            guard escapeIndex < token.endIndex else {
                throw AttachedJSONFailureCode.invalidJSONPointer
            }
            switch token[escapeIndex] {
            case "0": output.append("~")
            case "1": output.append("/")
            default: throw AttachedJSONFailureCode.invalidJSONPointer
            }
            index = token.index(after: escapeIndex)
        }
        return output
    }
}

private enum AttachedJSONIdentity {
    private static let recognizedNames: Set<String> = [
        "id", "_id", "uuid", "identifier", "record_id", "recordid",
    ]

    static func validateExplicitID(
        pointer: String,
        records: [AttachedJSONValue],
        limits: AttachedJSONLimits
    ) throws {
        var identities = Set<String>()
        for record in records {
            let value: AttachedJSONValue
            do {
                value = try AttachedJSONPointer.resolve(pointer, in: record)
            } catch {
                throw AttachedJSONFailureCode.invalidIDField
            }
            let canonical = try canonicalIdentityValue(value, limits: limits)
            let key = String(decoding: canonical, as: UTF8.self)
            guard identities.insert(key).inserted else {
                throw AttachedJSONFailureCode.duplicateRecordIdentifier
            }
        }
    }

    static func unambiguousRecognizedIDPointer(
        records: [AttachedJSONValue],
        limits: AttachedJSONLimits
    ) throws -> String? {
        guard !records.isEmpty else { return nil }
        var candidateKeys = Set<String>()
        for record in records {
            guard case let .object(members) = record else { return nil }
            for member in members where recognizedNames.contains(member.key.lowercased()) {
                candidateKeys.insert(member.key)
            }
        }

        var eligible: [String] = []
        for key in candidateKeys.sorted(by: AttachedJSONOrdering.less) {
            let pointer = "/" + AttachedJSONPointer.escape(key)
            var values = Set<String>()
            var qualifies = true
            for record in records {
                guard let value = record.member(named: key),
                      let canonical = try? canonicalIdentityValue(value, limits: limits)
                else {
                    qualifies = false
                    break
                }
                let identity = String(decoding: canonical, as: UTF8.self)
                if !values.insert(identity).inserted {
                    qualifies = false
                    break
                }
            }
            if qualifies { eligible.append(pointer) }
        }
        return eligible.count == 1 ? eligible[0] : nil
    }

    static func canonicalIdentityValue(
        _ value: AttachedJSONValue,
        limits: AttachedJSONLimits
    ) throws -> Data {
        switch value {
        case let .string(string) where !string.isEmpty:
            return try AttachedJSONCanonical.data(
                for: value,
                limits: limits,
                isCancelled: { Task.isCancelled }
            )
        case .number:
            return try AttachedJSONCanonical.data(
                for: value,
                limits: limits,
                isCancelled: { Task.isCancelled }
            )
        default:
            throw AttachedJSONFailureCode.invalidIDField
        }
    }
}

private enum AttachedJSONFieldInference {
    private struct Accumulator {
        let label: String
        var kinds = Set<AttachedJSONValueKind>()
        var presentCount = 0
        var nullCount = 0
    }

    static func fields(for records: [AttachedJSONValue]) -> [AttachedJSONInferredField] {
        var fields: [String: Accumulator] = [:]
        for record in records {
            switch record {
            case let .object(members):
                for member in members {
                    let pointer = "/" + AttachedJSONPointer.escape(member.key)
                    var accumulator = fields[pointer] ?? Accumulator(label: member.key)
                    accumulator.kinds.insert(member.value.kind)
                    accumulator.presentCount += 1
                    if member.value.kind == .null { accumulator.nullCount += 1 }
                    fields[pointer] = accumulator
                }
            default:
                var accumulator = fields[""] ?? Accumulator(label: "$record")
                accumulator.kinds.insert(record.kind)
                accumulator.presentCount += 1
                if record.kind == .null { accumulator.nullCount += 1 }
                fields[""] = accumulator
            }
        }

        return fields.keys.sorted(by: AttachedJSONOrdering.less).compactMap { pointer in
            guard let accumulator = fields[pointer] else { return nil }
            return AttachedJSONInferredField(
                jsonPointer: pointer,
                boundedLabel: accumulator.label,
                valueKinds: accumulator.kinds.sorted { $0.rawValue < $1.rawValue },
                presentRecordCount: accumulator.presentCount,
                nullRecordCount: accumulator.nullCount,
                isPresentInEveryRecord: accumulator.presentCount == records.count
            )
        }
    }
}

private enum AttachedJSONUTF8 {
    static func validate(
        _ bytes: [UInt8],
        checkInterval: Int,
        isCancelled: @Sendable () -> Bool
    ) throws {
        var index = 0
        var nextCancellationIndex = 0
        while index < bytes.count {
            if index >= nextCancellationIndex {
                if Task.isCancelled || isCancelled() { throw AttachedJSONFailureCode.cancelled }
                nextCancellationIndex = index + checkInterval
            }
            let first = bytes[index]
            if first <= 0x7F {
                index += 1
            } else if (0xC2...0xDF).contains(first) {
                guard continuation(bytes, at: index + 1) else {
                    throw AttachedJSONFailureCode.invalidUTF8
                }
                index += 2
            } else if first == 0xE0 {
                guard byte(bytes, at: index + 1, isIn: 0xA0...0xBF),
                      continuation(bytes, at: index + 2)
                else { throw AttachedJSONFailureCode.invalidUTF8 }
                index += 3
            } else if (0xE1...0xEC).contains(first) || (0xEE...0xEF).contains(first) {
                guard continuation(bytes, at: index + 1), continuation(bytes, at: index + 2) else {
                    throw AttachedJSONFailureCode.invalidUTF8
                }
                index += 3
            } else if first == 0xED {
                guard byte(bytes, at: index + 1, isIn: 0x80...0x9F),
                      continuation(bytes, at: index + 2)
                else { throw AttachedJSONFailureCode.invalidUTF8 }
                index += 3
            } else if first == 0xF0 {
                guard byte(bytes, at: index + 1, isIn: 0x90...0xBF),
                      continuation(bytes, at: index + 2), continuation(bytes, at: index + 3)
                else { throw AttachedJSONFailureCode.invalidUTF8 }
                index += 4
            } else if (0xF1...0xF3).contains(first) {
                guard continuation(bytes, at: index + 1),
                      continuation(bytes, at: index + 2),
                      continuation(bytes, at: index + 3)
                else { throw AttachedJSONFailureCode.invalidUTF8 }
                index += 4
            } else if first == 0xF4 {
                guard byte(bytes, at: index + 1, isIn: 0x80...0x8F),
                      continuation(bytes, at: index + 2), continuation(bytes, at: index + 3)
                else { throw AttachedJSONFailureCode.invalidUTF8 }
                index += 4
            } else {
                throw AttachedJSONFailureCode.invalidUTF8
            }
        }
    }

    private static func continuation(_ bytes: [UInt8], at index: Int) -> Bool {
        byte(bytes, at: index, isIn: 0x80...0xBF)
    }

    private static func byte(_ bytes: [UInt8], at index: Int, isIn range: ClosedRange<UInt8>) -> Bool {
        index < bytes.count && range.contains(bytes[index])
    }
}

private enum AttachedJSONDigest {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func domainSeparated(domain: String, fields: [String]) -> String {
        var data = Data()
        for field in [domain] + fields {
            let bytes = Data(field.utf8)
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { data.append(contentsOf: $0) }
            data.append(bytes)
        }
        return "attached-json-record:" + sha256(data)
    }
}

private enum AttachedJSONOrdering {
    static func less(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

private enum AttachedJSONHex {
    static let lowercase = Array("0123456789abcdef".utf8)

    static func value(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }
}

private struct AttachedJSONSignedDecimal {
    private let isNegative: Bool
    private let magnitude: [UInt8]

    init(_ raw: String) {
        var digits = Array(raw.utf8)
        var negative = false
        if digits.first == 0x2D {
            negative = true
            digits.removeFirst()
        } else if digits.first == 0x2B {
            digits.removeFirst()
        }
        while digits.count > 1, digits.first == 0x30 { digits.removeFirst() }
        if digits.allSatisfy({ $0 == 0x30 }) {
            isNegative = false
            magnitude = [0]
        } else {
            isNegative = negative
            magnitude = digits.map { $0 - 0x30 }
        }
    }

    func adding(_ delta: Int) -> String {
        if delta == 0 { return rendered(isNegative: isNegative, magnitude: magnitude) }
        let deltaNegative = delta < 0
        let deltaMagnitude = String(delta.magnitude).utf8.map { $0 - 0x30 }
        if isNegative == deltaNegative {
            return rendered(
                isNegative: isNegative,
                magnitude: addMagnitudes(magnitude, deltaMagnitude)
            )
        }
        switch compareMagnitudes(magnitude, deltaMagnitude) {
        case 0:
            return "0"
        case 1:
            return rendered(
                isNegative: isNegative,
                magnitude: subtractMagnitudes(magnitude, deltaMagnitude)
            )
        default:
            return rendered(
                isNegative: deltaNegative,
                magnitude: subtractMagnitudes(deltaMagnitude, magnitude)
            )
        }
    }

    private func rendered(isNegative: Bool, magnitude: [UInt8]) -> String {
        let digits = String(decoding: magnitude.map { $0 + 0x30 }, as: UTF8.self)
        return isNegative && magnitude != [0] ? "-" + digits : digits
    }

    private func compareMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
        if lhs.count != rhs.count { return lhs.count < rhs.count ? -1 : 1 }
        for (left, right) in zip(lhs, rhs) where left != right {
            return left < right ? -1 : 1
        }
        return 0
    }

    private func addMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var left = lhs.reversed().makeIterator()
        var right = rhs.reversed().makeIterator()
        var result: [UInt8] = []
        var carry: UInt8 = 0
        while true {
            let leftDigit = left.next()
            let rightDigit = right.next()
            if leftDigit == nil, rightDigit == nil { break }
            let sum = (leftDigit ?? 0) + (rightDigit ?? 0) + carry
            result.append(sum % 10)
            carry = sum / 10
        }
        if carry > 0 { result.append(carry) }
        return result.reversed()
    }

    /// Subtracts rhs from lhs. The caller guarantees lhs >= rhs.
    private func subtractMagnitudes(_ lhs: [UInt8], _ rhs: [UInt8]) -> [UInt8] {
        var result = lhs
        var rightIndex = rhs.count - 1
        var leftIndex = result.count - 1
        var borrow = 0
        while leftIndex >= 0 {
            let right = rightIndex >= 0 ? Int(rhs[rightIndex]) : 0
            var value = Int(result[leftIndex]) - borrow - right
            if value < 0 {
                value += 10
                borrow = 1
            } else {
                borrow = 0
            }
            result[leftIndex] = UInt8(value)
            if leftIndex == 0 { break }
            leftIndex -= 1
            rightIndex -= 1
        }
        while result.count > 1, result.first == 0 { result.removeFirst() }
        return result
    }
}
