import Foundation

struct EmailMessageParser: Sendable {
    private let htmlSanitizer: EmailHTMLSanitizer
    private let now: @Sendable () -> Date
    private let traceSink: EmailTraceSink?

    init(
        htmlSanitizer: EmailHTMLSanitizer = .init(),
        now: @escaping @Sendable () -> Date = { Date() },
        traceSink: EmailTraceSink? = nil
    ) {
        self.htmlSanitizer = htmlSanitizer
        self.now = now
        self.traceSink = traceSink
    }

    func parse(
        _ data: Data,
        receivedAtFallback: Date? = nil,
        trace: EmailTraceContext = .init(),
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailParsedMessage {
        emit(.messageParse, .started, "email_message_parse_started", trace: trace, metadata: [
            ("byte_count", String(data.count)),
        ])
        do {
            try Self.checkCancellation(isCancelled)
            guard !data.isEmpty, data.count <= EmailImportLimits.maximumMessageBytes else {
                throw data.isEmpty
                    ? EmailImportFailureCode.headerSectionMissing
                    : EmailImportFailureCode.messageTooLarge
            }
            let split = try Self.splitHeaderAndBody(
                data,
                isCancelled: isCancelled
            )
            let headerBlock = try Self.parseHeaders(
                split.headerData,
                isCancelled: isCancelled
            )
            var accumulator = MIMEAccumulator()
            try parseEntity(
                headers: headerBlock,
                body: split.bodyData,
                depth: 0,
                accumulator: &accumulator,
                isCancelled: isCancelled
            )
            try Self.checkCancellation(isCancelled)

            let selectedBody: String
            if !accumulator.plainText.isEmpty {
                selectedBody = accumulator.plainText.joined(separator: "\n\n")
            } else {
                selectedBody = accumulator.htmlText.joined(separator: "\n\n")
            }
            let normalizedBody = Self.normalizeBody(selectedBody)
            if normalizedBody.lengthOfBytes(using: .utf8) > EmailImportLimits.maximumTextBytes {
                throw EmailImportFailureCode.textBodyTooLarge
            }
            if normalizedBody.isEmpty {
                accumulator.warnings.insert(.bodyUnavailable)
            }

            let messageID = EmailMessageID.canonical(headerBlock.first("message-id"))
            let inReplyTo = EmailMessageID.canonical(headerBlock.first("in-reply-to"))
            let references = EmailMessageID.all(in: headerBlock.joined("references"))
            let dateValue = headerBlock.first("date")
            let sentDate = dateValue.flatMap(Self.parseInternetDate)
            if dateValue != nil, sentDate == nil { accumulator.warnings.insert(.dateUnparseable) }
            let receivedValue = headerBlock.values("received").first
            let receivedDate = receivedValue.flatMap(Self.parseReceivedDate) ?? receivedAtFallback
            if receivedValue != nil,
               receivedAtFallback == nil,
               receivedDate == nil {
                accumulator.warnings.insert(.receivedDateUnparseable)
            }
            accumulator.warnings.formUnion(headerBlock.warnings)
            if accumulator.suppressedActiveHTMLCount > 0 {
                accumulator.warnings.insert(.activeHTMLSuppressed)
            }
            if accumulator.suppressedRemoteResourceCount > 0 {
                accumulator.warnings.insert(.remoteHTMLResourceSuppressed)
            }

            let headers = EmailHeaderFields(
                messageID: messageID,
                inReplyTo: inReplyTo,
                references: references,
                from: Self.addressValues(headerBlock.values("from")),
                to: Self.addressValues(headerBlock.values("to")),
                cc: Self.addressValues(headerBlock.values("cc")),
                replyTo: Self.addressValues(headerBlock.values("reply-to")),
                subject: Self.boundedHeaderValue(headerBlock.first("subject") ?? "(no subject)"),
                sentDate: sentDate,
                receivedDate: receivedDate
            )
            let result = EmailParsedMessage(
                headers: headers,
                normalizedBody: normalizedBody,
                attachments: accumulator.attachments,
                rawMessageSHA256: EmailDigest.sha256(data),
                warnings: accumulator.warnings.sorted { $0.rawValue < $1.rawValue },
                suppressedActiveHTMLCount: accumulator.suppressedActiveHTMLCount,
                suppressedRemoteResourceCount: accumulator.suppressedRemoteResourceCount
            )
            emit(
                .messageParse,
                result.warnings.isEmpty ? .success : .degraded,
                result.warnings.isEmpty
                    ? "email_message_parse_succeeded"
                    : "email_message_parse_partial",
                trace: trace,
                metadata: [
                    ("attachment_count", String(result.attachments.count)),
                    ("warning_count", String(result.warnings.count)),
                    ("part_count", String(accumulator.partCount)),
                    ("active_suppressed_count", String(result.suppressedActiveHTMLCount)),
                    ("remote_suppressed_count", String(result.suppressedRemoteResourceCount)),
                ]
            )
            return result
        } catch {
            emit(
                .messageParse,
                error as? EmailImportFailureCode == .cancelled ? .skipped : .failed,
                (error as? EmailImportFailureCode)?.rawValue ?? "email_message_parse_failed",
                trace: trace
            )
            throw error
        }
    }

    private func parseEntity(
        headers: HeaderBlock,
        body: Data,
        depth: Int,
        accumulator: inout MIMEAccumulator,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        try Self.checkCancellation(isCancelled)
        guard depth <= EmailImportLimits.maximumMIMEDepth else {
            throw EmailImportFailureCode.mimeDepthExceeded
        }
        accumulator.partCount += 1
        guard accumulator.partCount <= EmailImportLimits.maximumMIMEParts else {
            throw EmailImportFailureCode.mimePartCountExceeded
        }

        let contentType = MIMEHeaderValue(
            headers.first("content-type") ?? "text/plain; charset=us-ascii"
        )
        let mediaType = contentType.value.lowercased()
        if mediaType.hasPrefix("multipart/") {
            guard let boundary = contentType.parameters["boundary"], !boundary.isEmpty else {
                throw EmailImportFailureCode.multipartBoundaryMissing
            }
            let parts = try Self.multipartParts(
                body,
                boundary: boundary,
                isCancelled: isCancelled
            )
            guard !parts.isEmpty else { throw EmailImportFailureCode.multipartMalformed }
            for part in parts {
                try Self.checkCancellation(isCancelled)
                let split = try Self.splitHeaderAndBody(
                    part,
                    isCancelled: isCancelled
                )
                let partHeaders = try Self.parseHeaders(
                    split.headerData,
                    isCancelled: isCancelled
                )
                accumulator.warnings.formUnion(partHeaders.warnings)
                try parseEntity(
                    headers: partHeaders,
                    body: split.bodyData,
                    depth: depth + 1,
                    accumulator: &accumulator,
                    isCancelled: isCancelled
                )
            }
            return
        }

        let decoded = try Self.decodeTransfer(
            body,
            encoding: headers.first("content-transfer-encoding"),
            isCancelled: isCancelled
        )
        guard decoded.count <= EmailImportLimits.maximumDecodedPartBytes else {
            throw EmailImportFailureCode.decodedPartTooLarge
        }
        let disposition = MIMEHeaderValue(headers.first("content-disposition") ?? "")
        let rawFilename = disposition.parameters["filename"]
            ?? contentType.parameters["name"]
        let filename = rawFilename.map {
            EmailFilenameSanitizer.basename(
                RFC2047.decode($0).value,
                fallback: "attachment"
            )
        }
        let isAttachment = disposition.value.lowercased() == "attachment"
            || filename != nil
            || !(mediaType == "text/plain" || mediaType == "text/html")

        if isAttachment {
            guard accumulator.attachments.count < EmailImportLimits.maximumAttachments else {
                accumulator.warnings.insert(.attachmentLimitReached)
                return
            }
            let digest = EmailDigest.sha256(decoded)
            let safeFilename = filename ?? Self.defaultFilename(mediaType: mediaType)
            let oversized = decoded.count > EmailImportLimits.maximumAttachmentBytes
            if oversized { accumulator.warnings.insert(.attachmentOversizedMetadataOnly) }
            let contentID = EmailMessageID.canonical(headers.first("content-id"))
            let identifier = EmailDigest.sha256(
                "attachment\u{1f}\(accumulator.attachments.count)\u{1f}\(safeFilename)\u{1f}\(mediaType)\u{1f}\(digest)"
            )
            accumulator.attachments.append(.init(
                identifier: identifier,
                filename: safeFilename,
                mediaType: mediaType.isEmpty ? "application/octet-stream" : mediaType,
                byteCount: decoded.count,
                sha256: digest,
                digestBasis: .decodedContent,
                disposition: disposition.value.isEmpty ? nil : disposition.value.lowercased(),
                contentID: contentID,
                wasOversized: oversized
            ))
            return
        }

        if mediaType == "text/plain" {
            let decodedText = Self.decodeText(
                decoded,
                charset: contentType.parameters["charset"],
                warnings: &accumulator.warnings
            )
            accumulator.plainText.append(decodedText)
        } else if mediaType == "text/html" {
            let decodedText = Self.decodeText(
                decoded,
                charset: contentType.parameters["charset"],
                warnings: &accumulator.warnings
            )
            let sanitized = try htmlSanitizer.sanitize(
                decodedText,
                isCancelled: isCancelled
            )
            accumulator.htmlText.append(sanitized.text)
            accumulator.suppressedActiveHTMLCount += sanitized.suppressedActiveContentCount
            accumulator.suppressedRemoteResourceCount += sanitized.suppressedRemoteResourceCount
        }
    }

    private func emit(
        _ event: EmailTraceEventName,
        _ status: EmailTraceStatus,
        _ reason: String,
        trace: EmailTraceContext,
        metadata: [(String, String)] = []
    ) {
        traceSink?(.init(
            timestamp: now(),
            event: event,
            status: status,
            reasonCode: String(reason.prefix(120)),
            traceID: trace.traceID,
            spanID: trace.spanID,
            parentSpanID: trace.parentSpanID,
            metadata: EmailTracePrivacy.metadata(metadata)
        ))
    }
}

private extension EmailMessageParser {
    struct HeaderBlock {
        var fields: [String: [String]]
        var warnings: Set<EmailParseWarningCode>

        func first(_ name: String) -> String? { fields[name.lowercased()]?.first }
        func values(_ name: String) -> [String] { fields[name.lowercased()] ?? [] }
        func joined(_ name: String) -> String? {
            let values = values(name)
            return values.isEmpty ? nil : values.joined(separator: " ")
        }
    }

    struct MIMEAccumulator {
        var plainText: [String] = []
        var htmlText: [String] = []
        var attachments: [EmailAttachmentMetadata] = []
        var warnings: Set<EmailParseWarningCode> = []
        var partCount = 0
        var suppressedActiveHTMLCount = 0
        var suppressedRemoteResourceCount = 0
    }

    struct MIMEHeaderValue {
        let value: String
        let parameters: [String: String]

        init(_ raw: String) {
            let pieces = Self.splitParameters(raw)
            value = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var parsed: [String: String] = [:]
            for piece in pieces.dropFirst() {
                guard let equals = piece.firstIndex(of: "=") else { continue }
                var name = piece[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                var parameter = piece[piece.index(after: equals)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if parameter.count >= 2,
                   ((parameter.first == "\"" && parameter.last == "\"")
                    || (parameter.first == "'" && parameter.last == "'")) {
                    parameter.removeFirst()
                    parameter.removeLast()
                }
                if name.hasSuffix("*") {
                    name.removeLast()
                    parameter = Self.decodeExtendedParameter(parameter)
                }
                if !name.isEmpty, parsed[name] == nil {
                    parsed[name] = String(parameter.prefix(EmailImportLimits.maximumHeaderValueCharacters))
                }
            }
            parameters = parsed
        }

        private static func splitParameters(_ value: String) -> [String] {
            var result: [String] = []
            var current = ""
            var quote: Character?
            var escaped = false
            for character in value {
                if escaped {
                    current.append(character)
                    escaped = false
                } else if character == "\\", quote != nil {
                    escaped = true
                } else if let currentQuote = quote {
                    current.append(character)
                    if character == currentQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                    current.append(character)
                } else if character == ";" {
                    result.append(current)
                    current = ""
                } else {
                    current.append(character)
                }
            }
            result.append(current)
            return result
        }

        private static func decodeExtendedParameter(_ value: String) -> String {
            let components = value.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
            let encoded = components.count == 3 ? String(components[2]) : value
            return encoded.removingPercentEncoding ?? encoded
        }
    }

    static func splitHeaderAndBody(
        _ data: Data,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> (headerData: Data, bodyData: Data) {
        guard !data.isEmpty else { throw EmailImportFailureCode.headerSectionMissing }
        try checkCancellation(isCancelled)
        let bytes = [UInt8](data)
        var separatorStart: Int?
        var separatorLength = 0
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) {
                if index.isMultiple(of: 65_536) {
                    try checkCancellation(isCancelled)
                }
                guard bytes[index...index + 3] == [13, 10, 13, 10] else {
                    continue
                }
                separatorStart = index
                separatorLength = 4
                break
            }
        }
        if separatorStart == nil, bytes.count >= 2 {
            for index in 0...(bytes.count - 2) {
                if index.isMultiple(of: 65_536) {
                    try checkCancellation(isCancelled)
                }
                guard bytes[index] == 10, bytes[index + 1] == 10 else {
                    continue
                }
                separatorStart = index
                separatorLength = 2
                break
            }
        }
        let headerEnd = separatorStart ?? data.count
        guard headerEnd > 0, headerEnd <= EmailImportLimits.maximumHeaderBytes else {
            throw headerEnd == 0
                ? EmailImportFailureCode.headerSectionMissing
                : EmailImportFailureCode.headerSectionTooLarge
        }
        let bodyStart = min(data.count, headerEnd + separatorLength)
        return (Data(bytes[0..<headerEnd]), Data(bytes[bodyStart..<bytes.count]))
    }

    static func parseHeaders(
        _ data: Data,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> HeaderBlock {
        guard data.count <= EmailImportLimits.maximumHeaderBytes else {
            throw EmailImportFailureCode.headerSectionTooLarge
        }
        try checkCancellation(isCancelled)
        guard let raw = String(data: data, encoding: .isoLatin1) else {
            throw EmailImportFailureCode.malformedHeader
        }
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
        var unfolded: [String] = []
        for (index, lineValue) in lines.enumerated() {
            if index.isMultiple(of: 128) { try checkCancellation(isCancelled) }
            let line = String(lineValue)
            guard line.lengthOfBytes(using: .utf8) <= EmailImportLimits.maximumHeaderLineBytes else {
                throw EmailImportFailureCode.headerLineTooLarge
            }
            if line.first?.isWhitespace == true, !unfolded.isEmpty {
                unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                unfolded.append(line)
            }
        }
        guard unfolded.count <= EmailImportLimits.maximumHeaderCount else {
            throw EmailImportFailureCode.headerCountExceeded
        }
        var fields: [String: [String]] = [:]
        var warnings: Set<EmailParseWarningCode> = []
        for (index, line) in unfolded.enumerated() where !line.isEmpty {
            if index.isMultiple(of: 128) { try checkCancellation(isCancelled) }
            guard let colon = line.firstIndex(of: ":") else {
                warnings.insert(.malformedHeaderSkipped)
                continue
            }
            let name = line[..<colon].lowercased()
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") })
            else {
                warnings.insert(.malformedHeaderSkipped)
                continue
            }
            let rawValue = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let decoded = RFC2047.decode(rawValue)
            if decoded.hadInvalidWord { warnings.insert(.invalidEncodedWordPreserved) }
            fields[name, default: []].append(boundedHeaderValue(decoded.value))
        }
        guard !fields.isEmpty else { throw EmailImportFailureCode.headerSectionMissing }
        return .init(fields: fields, warnings: warnings)
    }

    static func multipartParts(
        _ data: Data,
        boundary: String,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> [Data] {
        guard !boundary.isEmpty,
              boundary.lengthOfBytes(using: .utf8) <= 200,
              let boundaryData = "--\(boundary)".data(using: .utf8)
        else { throw EmailImportFailureCode.multipartBoundaryMissing }
        let bytes = [UInt8](data)
        let marker = [UInt8](boundaryData)
        var parts: [Data] = []
        var partStart: Int?
        var lineStart = 0
        var nextCancellationByte = 0
        while lineStart <= bytes.count {
            if lineStart >= nextCancellationByte {
                try checkCancellation(isCancelled)
                nextCancellationByte = lineStart + 65_536
            }
            var lineEnd = lineStart
            while lineEnd < bytes.count, bytes[lineEnd] != 10 {
                if lineEnd >= nextCancellationByte {
                    try checkCancellation(isCancelled)
                    nextCancellationByte = lineEnd + 65_536
                }
                lineEnd += 1
            }
            var contentEnd = lineEnd
            if contentEnd > lineStart, bytes[contentEnd - 1] == 13 { contentEnd -= 1 }
            let line = Array(bytes[lineStart..<contentEnd])
            let isOpening = line == marker
            let isClosing = line == marker + [45, 45]
            if isOpening || isClosing {
                if let start = partStart, lineStart >= start {
                    var end = lineStart
                    while end > start && (bytes[end - 1] == 10 || bytes[end - 1] == 13) {
                        end -= 1
                    }
                    if end > start { parts.append(Data(bytes[start..<end])) }
                    if parts.count > EmailImportLimits.maximumMIMEParts {
                        throw EmailImportFailureCode.mimePartCountExceeded
                    }
                }
                if isClosing { return parts }
                partStart = lineEnd < bytes.count ? lineEnd + 1 : bytes.count
            }
            if lineEnd >= bytes.count { break }
            lineStart = lineEnd + 1
        }
        if let start = partStart, start < bytes.count {
            parts.append(Data(bytes[start..<bytes.count]))
        }
        return parts
    }

    static func decodeTransfer(
        _ data: Data,
        encoding: String?,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        let normalized = encoding?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "7bit"
        try checkCancellation(isCancelled)
        switch normalized {
        case "", "7bit", "8bit", "binary":
            return data
        case "base64":
            let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=\r\n\t ".utf8)
            for (index, byte) in data.enumerated() {
                if index.isMultiple(of: 65_536) {
                    try checkCancellation(isCancelled)
                }
                guard allowed.contains(byte) else {
                    throw EmailImportFailureCode.transferEncodingInvalid
                }
            }
            guard
                  let decoded = Data(base64Encoded: data, options: .ignoreUnknownCharacters)
            else { throw EmailImportFailureCode.transferEncodingInvalid }
            try checkCancellation(isCancelled)
            return decoded
        case "quoted-printable":
            return try decodeQuotedPrintable(
                data,
                isCancelled: isCancelled
            )
        default:
            throw EmailImportFailureCode.transferEncodingInvalid
        }
    }

    static func decodeQuotedPrintable(
        _ data: Data,
        underscoreAsSpace: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        let bytes = [UInt8](data)
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        while index < bytes.count {
            if index.isMultiple(of: 65_536) {
                try checkCancellation(isCancelled)
            }
            let byte = bytes[index]
            if underscoreAsSpace, byte == 95 {
                output.append(32)
                index += 1
                continue
            }
            guard byte == 61 else {
                output.append(byte)
                index += 1
                continue
            }
            if index + 1 < bytes.count, bytes[index + 1] == 10 {
                index += 2
                continue
            }
            if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 {
                index += 3
                continue
            }
            guard index + 2 < bytes.count,
                  let high = hex(bytes[index + 1]),
                  let low = hex(bytes[index + 2])
            else { throw EmailImportFailureCode.transferEncodingInvalid }
            output.append(high << 4 | low)
            index += 3
        }
        return Data(output)
    }

    static func checkCancellation(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw EmailImportFailureCode.cancelled }
    }

    static func decodeText(
        _ data: Data,
        charset: String?,
        warnings: inout Set<EmailParseWarningCode>
    ) -> String {
        let normalized = charset?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            .lowercased() ?? "us-ascii"
        let encoding: String.Encoding?
        switch normalized {
        case "utf-8", "utf8": encoding = .utf8
        case "us-ascii", "ascii": encoding = .ascii
        case "iso-8859-1", "latin1", "latin-1": encoding = .isoLatin1
        case "windows-1252", "cp1252": encoding = .windowsCP1252
        case "utf-16": encoding = .utf16
        case "utf-16le": encoding = .utf16LittleEndian
        case "utf-16be": encoding = .utf16BigEndian
        default:
            encoding = nil
            warnings.insert(.unsupportedCharacterSetReplaced)
        }
        if let encoding, let value = String(data: data, encoding: encoding) { return value }
        if let value = String(data: data, encoding: .utf8) {
            warnings.insert(.unsupportedCharacterSetReplaced)
            return value
        }
        warnings.insert(.unsupportedCharacterSetReplaced)
        return String(decoding: data, as: UTF8.self)
    }

    static func addressValues(_ values: [String]) -> [String] {
        var result: [String] = []
        for value in values {
            var current = ""
            var quote = false
            var angleDepth = 0
            for character in value {
                if character == "\"" { quote.toggle() }
                if !quote, character == "<" { angleDepth += 1 }
                if !quote, character == ">" { angleDepth = max(0, angleDepth - 1) }
                if !quote, angleDepth == 0, character == "," {
                    let item = boundedHeaderValue(current.trimmingCharacters(in: .whitespacesAndNewlines))
                    if !item.isEmpty { result.append(item) }
                    current = ""
                } else {
                    current.append(character)
                }
            }
            let item = boundedHeaderValue(current.trimmingCharacters(in: .whitespacesAndNewlines))
            if !item.isEmpty { result.append(item) }
            if result.count >= EmailImportLimits.maximumAddressValues { break }
        }
        return Array(result.prefix(EmailImportLimits.maximumAddressValues))
    }

    static func boundedHeaderValue(_ value: String) -> String {
        let safe = String(value.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !ConnectorEnvelopeValidation.isUnsafeScalar($0) || $0 == "\t"
        })
        return String(safe.prefix(EmailImportLimits.maximumHeaderValueCharacters))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func normalizeBody(_ value: String) -> String {
        String(value.precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !CharacterSet.illegalCharacters.contains($0)
                && (!CharacterSet.controlCharacters.contains($0)
                    || $0 == "\n" || $0 == "\r" || $0 == "\t")
        })
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func defaultFilename(mediaType: String) -> String {
        switch mediaType {
        case "image/png": "attachment.png"
        case "image/jpeg": "attachment.jpg"
        case "application/pdf": "attachment.pdf"
        case "message/rfc822": "attached-message.eml"
        default: "attachment"
        }
    }

    static func parseReceivedDate(_ value: String) -> Date? {
        guard let semicolon = value.lastIndex(of: ";") else { return nil }
        return parseInternetDate(String(value[value.index(after: semicolon)...]))
    }

    static func parseInternetDate(_ raw: String) -> Date? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let commentStart = value.lastIndex(of: "("), value.hasSuffix(")") {
            value = String(value[..<commentStart]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let formats = [
            "EEE, d MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss Z",
            "d MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z",
            "EEE, d MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm Z",
            "d MMM yyyy HH:mm Z", "dd MMM yyyy HH:mm Z",
            "EEE MMM d HH:mm:ss yyyy", "EEE MMM dd HH:mm:ss yyyy",
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            formatter.isLenient = false
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }

    static func hex(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 48...57: byte - 48
        case 65...70: byte - 55
        case 97...102: byte - 87
        default: nil
        }
    }
}

private enum RFC2047 {
    struct Result {
        let value: String
        let hadInvalidWord: Bool
    }

    static func decode(_ value: String) -> Result {
        let pattern = #"=\?([^?\s]+)\?([bBqQ])\?([^?]*)\?="#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return .init(value: value, hadInvalidWord: false)
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = expression.matches(in: value, range: range)
        guard !matches.isEmpty else { return .init(value: value, hadInvalidWord: false) }
        var output = ""
        var last = value.startIndex
        var invalid = false
        var decodedWordCount = 0
        for match in matches {
            guard let whole = Range(match.range(at: 0), in: value),
                  let charsetRange = Range(match.range(at: 1), in: value),
                  let encodingRange = Range(match.range(at: 2), in: value),
                  let payloadRange = Range(match.range(at: 3), in: value)
            else { continue }
            let interstitial = String(value[last..<whole.lowerBound])
            if decodedWordCount == 0 || !interstitial.allSatisfy(\.isWhitespace) {
                output.append(interstitial)
            }
            let charset = String(value[charsetRange])
            let encoding = value[encodingRange].lowercased()
            let payload = String(value[payloadRange])
            let decodedData: Data?
            if encoding == "b" {
                decodedData = Data(base64Encoded: payload)
            } else {
                decodedData = try? EmailMessageParser.decodeQuotedPrintable(
                    Data(payload.utf8),
                    underscoreAsSpace: true
                )
            }
            var warnings: Set<EmailParseWarningCode> = []
            if let decodedData {
                output.append(EmailMessageParser.decodeText(
                    decodedData,
                    charset: charset,
                    warnings: &warnings
                ))
                invalid = invalid || warnings.contains(.unsupportedCharacterSetReplaced)
            } else {
                output.append(String(value[whole]))
                invalid = true
            }
            decodedWordCount += 1
            last = whole.upperBound
        }
        output.append(contentsOf: value[last...])
        return .init(value: output, hadInvalidWord: invalid)
    }
}
