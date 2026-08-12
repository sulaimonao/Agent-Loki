import CryptoKit
import Foundation

struct EmailMBoxEntry: Hashable, Sendable {
    let data: Data
    let separatorLine: String
    let separatorByteOffset: Int
    let messageEndByteOffset: Int
}

struct EmailMBoxReadPage: Hashable, Sendable {
    let entries: [EmailMBoxEntry]
    let skippedEntries: [EmailMBoxSkippedEntry]
    let requestByteOffset: Int?
    let nextByteOffset: Int?
    let committedByteCount: Int
    let committedPrefixSHA256: String
    let isComplete: Bool
}

struct EmailMBoxSkippedEntry: Hashable, Sendable {
    let separatorByteOffset: Int
    let messageEndByteOffset: Int
    let reasonCode: EmailImportFailureCode
}

/// Privacy-safe work accounting used to prove that one task-owned session does
/// not rescan or rehash the full mailbox for every page.
enum EmailMBoxWorkEvent: Hashable, Sendable {
    case separatorBytesScanned(Int)
    case prefixBytesHashed(Int)
}

/// Parses only the bounded ASCII ctime-shaped timestamp accepted by the mbox
/// separator recognizer. Zone-less separators use GMT so results do not vary by
/// machine locale; an explicit numeric or recognized abbreviation is honored.
enum EmailMBoxSeparatorDateParser {
    static func parse(_ separatorLine: String) -> Date? {
        guard separatorLine.lengthOfBytes(using: .utf8) <= 512,
              separatorLine.unicodeScalars.allSatisfy({
                  $0.isASCII && !CharacterSet.controlCharacters.contains($0)
              })
        else { return nil }
        let fields = separatorLine.split(whereSeparator: \.isWhitespace)
        guard fields.count == 7 || fields.count == 8,
              fields[0] == "From",
              let weekday = weekdays[String(fields[2])],
              let month = months[String(fields[3])],
              let day = Int(fields[4]),
              (1...31).contains(day)
        else { return nil }

        let timeFields = fields[5].split(separator: ":")
        guard timeFields.count == 2 || timeFields.count == 3,
              let hour = Int(timeFields[0]), (0...23).contains(hour),
              let minute = Int(timeFields[1]), (0...59).contains(minute)
        else { return nil }
        let second: Int
        if timeFields.count == 3 {
            guard let parsed = Int(timeFields[2]) else { return nil }
            second = parsed
        } else {
            second = 0
        }
        guard (0...59).contains(second) else { return nil }

        let yearIndex = fields.count - 1
        guard let year = Int(fields[yearIndex]), (1...9_999).contains(year)
        else { return nil }
        let timeZone: TimeZone
        if fields.count == 8 {
            guard let parsed = parseTimeZone(String(fields[6])) else { return nil }
            timeZone = parsed
        } else {
            guard let gmt = TimeZone(secondsFromGMT: 0) else { return nil }
            timeZone = gmt
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        let components = DateComponents(
            calendar: calendar,
            timeZone: timeZone,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute,
            second: second
        )
        guard let date = calendar.date(from: components),
              calendar.component(.weekday, from: date) == weekday
        else { return nil }
        let roundTrip = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: date
        )
        guard roundTrip.year == year,
              roundTrip.month == month,
              roundTrip.day == day,
              roundTrip.hour == hour,
              roundTrip.minute == minute,
              roundTrip.second == second
        else { return nil }
        return date
    }

    private static let weekdays = [
        "Sun": 1, "Mon": 2, "Tue": 3, "Wed": 4,
        "Thu": 5, "Fri": 6, "Sat": 7,
    ]

    private static let months = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4,
        "May": 5, "Jun": 6, "Jul": 7, "Aug": 8,
        "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    private static func parseTimeZone(_ value: String) -> TimeZone? {
        let bytes = Array(value.utf8)
        if bytes.count == 5 || bytes.count == 6,
           bytes.first == 43 || bytes.first == 45 {
            let digits: [UInt8]
            if bytes.count == 6 {
                guard bytes[3] == 58 else { return nil }
                digits = [bytes[1], bytes[2], bytes[4], bytes[5]]
            } else {
                digits = Array(bytes[1...4])
            }
            guard digits.allSatisfy({ (48...57).contains($0) }) else {
                return nil
            }
            let hours = Int(digits[0] - 48) * 10 + Int(digits[1] - 48)
            let minutes = Int(digits[2] - 48) * 10 + Int(digits[3] - 48)
            guard hours <= 23, minutes <= 59 else { return nil }
            let sign = bytes[0] == 45 ? -1 : 1
            return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
        }
        guard let secondsFromGMT = fixedAbbreviationOffsets[value.uppercased()]
        else { return nil }
        return TimeZone(secondsFromGMT: secondsFromGMT)
    }

    /// RFC-obsolete zones commonly emitted by ctime-based mbox writers. This
    /// intentionally avoids Foundation's process-mutable abbreviation map.
    private static let fixedAbbreviationOffsets = [
        "Z": 0, "UT": 0, "UTC": 0, "GMT": 0,
        "EST": -5 * 3_600, "EDT": -4 * 3_600,
        "CST": -6 * 3_600, "CDT": -5 * 3_600,
        "MST": -7 * 3_600, "MDT": -6 * 3_600,
        "PST": -8 * 3_600, "PDT": -7 * 3_600,
    ]
}

/// Reads the traditional mboxo/mboxrd envelope shape without opening files or
/// retaining message bodies beyond the lifetime of an explicit import session.
struct EmailMBoxReader: Sendable {
    fileprivate let maximumMessageBytes: Int
    fileprivate let workObserver: (@Sendable (EmailMBoxWorkEvent) -> Void)?

    init(
        maximumMessageBytes: Int = EmailImportLimits.maximumMessageBytes,
        workObserver: (@Sendable (EmailMBoxWorkEvent) -> Void)? = nil
    ) {
        self.maximumMessageBytes = max(1, min(
            maximumMessageBytes,
            EmailImportLimits.maximumMessageBytes
        ))
        self.workObserver = workObserver
    }

    /// Creates a task-owned session. A persisted checkpoint is authenticated by
    /// hashing its committed prefix once. Later pages extend a copyable SHA-256
    /// state only across newly committed bytes.
    func makeSession(
        for data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailMBoxReadSession {
        try .init(
            reader: self,
            data: data,
            source: source,
            checkpoint: checkpoint,
            isCancelled: isCancelled
        )
    }

    /// Compatibility entry point for a single page. Multi-page callers should
    /// keep one `EmailMBoxReadSession` for their import task so prefix work is
    /// incremental rather than repeated.
    func readPage(
        from data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailMBoxReadPage {
        let session = try makeSession(
            for: data,
            source: source,
            checkpoint: checkpoint,
            isCancelled: isCancelled
        )
        return try session.readPage(
            checkpoint: checkpoint,
            pageSize: pageSize,
            isCancelled: isCancelled
        )
    }
}

/// A bounded, task-owned view of one immutable authorized mailbox snapshot.
/// It is intentionally not Codable or persistent and owns no authorization.
/// The lock makes accidental concurrent calls deterministic; callers still
/// consume pages serially and publish each returned checkpoint only after the
/// corresponding Vault page commits.
final class EmailMBoxReadSession: @unchecked Sendable {
    let sourceIdentifierHash: String
    let sourceByteCount: Int

    private struct PrefixState {
        let byteCount: Int
        let digest: String
        let hasher: SHA256
    }

    private struct ReconciliationPrefixState {
        let byteCount: Int
        let digest: String
        let value: EmailMBoxReconciliationState
    }

    private let reader: EmailMBoxReader
    private let data: Data
    private let lock = NSLock()
    private var committedState: PrefixState
    private var pendingState: PrefixState?
    private var committedReconciliationState: ReconciliationPrefixState?
    private var pendingReconciliationState: ReconciliationPrefixState?

    fileprivate init(
        reader: EmailMBoxReader,
        data: Data,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint?,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard source.format == .mbox else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        guard data.count <= EmailImportLimits.maximumSourceBytes else {
            throw EmailImportFailureCode.sourceTooLarge
        }
        try EmailMBoxReader.checkCancellation(isCancelled)

        self.reader = reader
        self.data = data
        sourceIdentifierHash = source.sourceIdentifierHash
        sourceByteCount = data.count

        let committedByteCount = try reader.validatedCheckpointOffset(
            dataCount: data.count,
            source: source,
            checkpoint: checkpoint
        )
        var hasher = SHA256()
        try reader.update(
            &hasher,
            with: data,
            range: 0..<committedByteCount,
            isCancelled: isCancelled
        )
        let digest = EmailMBoxReader.digest(of: hasher)
        if let checkpoint,
           checkpoint.committedPrefixSHA256 != digest {
            throw EmailImportFailureCode.mailboxChanged
        }
        committedState = .init(
            byteCount: committedByteCount,
            digest: digest,
            hasher: hasher
        )
        if committedByteCount == 0 {
            committedReconciliationState = .init(
                byteCount: 0,
                digest: digest,
                value: .init()
            )
        }
    }

    /// Installs context rebuilt from an authenticated persisted prefix. Session
    /// creation calls this before any page is exposed after a restart.
    func restoreReconciliationState(
        _ value: EmailMBoxReconciliationState,
        checkpoint: EmailImportCheckpoint?
    ) throws {
        try lock.withLock {
            let requestedByteCount = try reader.validatedCheckpointOffset(
                dataCount: data.count,
                sourceIdentifierHash: sourceIdentifierHash,
                checkpoint: checkpoint
            )
            guard requestedByteCount == committedState.byteCount,
                  checkpoint == nil
                    || checkpoint?.committedPrefixSHA256 == committedState.digest,
                  pendingState == nil
            else { throw EmailImportFailureCode.mailboxChanged }
            committedReconciliationState = .init(
                byteCount: committedState.byteCount,
                digest: committedState.digest,
                value: value
            )
            pendingReconciliationState = nil
        }
    }

    /// Returns only context whose prefix checkpoint has been committed. A
    /// prepared page remains pending until its exact checkpoint is presented.
    func reconciliationState(
        checkpoint: EmailImportCheckpoint?
    ) throws -> EmailMBoxReconciliationState {
        try lock.withLock {
            let requestedByteCount = try reader.validatedCheckpointOffset(
                dataCount: data.count,
                sourceIdentifierHash: sourceIdentifierHash,
                checkpoint: checkpoint
            )
            let requestedDigest = checkpoint?.committedPrefixSHA256
            if let committedReconciliationState,
               requestedByteCount == committedReconciliationState.byteCount,
               checkpoint == nil
                    || requestedDigest == committedReconciliationState.digest {
                return committedReconciliationState.value
            }
            if let pendingReconciliationState,
               requestedByteCount == pendingReconciliationState.byteCount,
               requestedDigest == pendingReconciliationState.digest {
                committedReconciliationState = pendingReconciliationState
                self.pendingReconciliationState = nil
                return pendingReconciliationState.value
            }
            throw EmailImportFailureCode.mailboxChanged
        }
    }

    /// Stages the page-local result beside the raw pending prefix. Neither is
    /// promoted by a retry that still presents the prior checkpoint.
    func stageReconciliationState(
        _ value: EmailMBoxReconciliationState,
        for checkpoint: EmailImportCheckpoint
    ) throws {
        try lock.withLock {
            guard let pendingState,
                  checkpoint.committedByteCount == pendingState.byteCount,
                  checkpoint.committedPrefixSHA256 == pendingState.digest,
                  let committedReconciliationState,
                  committedReconciliationState.byteCount
                    == committedState.byteCount,
                  committedReconciliationState.digest == committedState.digest
            else { throw EmailImportFailureCode.mailboxChanged }
            pendingReconciliationState = .init(
                byteCount: pendingState.byteCount,
                digest: pendingState.digest,
                value: value
            )
        }
    }

    /// Replays the authenticated prefix one message at a time so restart state
    /// is rebuilt without retaining another mailbox-sized body buffer.
    func forEachCommittedPrefixEntry(
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled },
        _ body: (EmailMBoxEntry) throws -> Void
    ) throws {
        let committedByteCount = lock.withLock { committedState.byteCount }
        var offset = 0
        while offset < committedByteCount {
            try EmailMBoxReader.checkCancellation(isCancelled)
            let scanned = try reader.scanPage(
                in: data,
                resumeOffset: offset,
                checkpoint: nil,
                pageSize: 1,
                scanEndOffset: committedByteCount,
                exactResume: true,
                isCancelled: isCancelled
            )
            guard scanned.committedByteCount > offset else {
                throw EmailImportFailureCode.mailboxChanged
            }
            for entry in scanned.entries { try body(entry) }
            offset = scanned.committedByteCount
        }
        try EmailMBoxReader.checkCancellation(isCancelled)
    }

    /// Reconstructs one selected prior message on demand for a bounded thread
    /// repair page. The locator must remain inside the authenticated committed
    /// prefix; only this one message body is materialized.
    func committedEntry(
        at locator: EmailMBoxEntryLocator,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailMBoxEntry {
        let committedByteCount = lock.withLock { committedState.byteCount }
        guard locator.messageEndByteOffset <= committedByteCount else {
            throw EmailImportFailureCode.mailboxChanged
        }
        let scanned = try reader.scanPage(
            in: data,
            resumeOffset: locator.separatorByteOffset,
            checkpoint: nil,
            pageSize: 1,
            scanEndOffset: locator.messageEndByteOffset,
            exactResume: true,
            isCancelled: isCancelled
        )
        guard scanned.skippedEntries.isEmpty,
              scanned.entries.count == 1,
              let entry = scanned.entries.first,
              entry.separatorByteOffset == locator.separatorByteOffset,
              entry.messageEndByteOffset == locator.messageEndByteOffset
        else { throw EmailImportFailureCode.mailboxChanged }
        return entry
    }

    func readPage(
        checkpoint: EmailImportCheckpoint? = nil,
        pageSize: Int = EmailImportLimits.maximumMessagesPerPage,
        isCancelled: @escaping @Sendable () -> Bool = { Task.isCancelled }
    ) throws -> EmailMBoxReadPage {
        try lock.withLock {
            guard (1...EmailImportLimits.maximumMessagesPerPage)
                .contains(pageSize)
            else { throw EmailImportFailureCode.checkpointInvalid }
            try EmailMBoxReader.checkCancellation(isCancelled)
            let requestedByteCount = try reader.validatedCheckpointOffset(
                dataCount: data.count,
                sourceIdentifierHash: sourceIdentifierHash,
                checkpoint: checkpoint
            )
            try promoteCommittedState(
                requestedByteCount: requestedByteCount,
                checkpoint: checkpoint
            )

            let scanned = try reader.scanPage(
                in: data,
                resumeOffset: committedState.byteCount,
                checkpoint: checkpoint,
                pageSize: pageSize,
                isCancelled: isCancelled
            )
            var nextHasher = committedState.hasher
            try reader.update(
                &nextHasher,
                with: data,
                range: committedState.byteCount..<scanned.committedByteCount,
                isCancelled: isCancelled
            )
            try EmailMBoxReader.checkCancellation(isCancelled)
            let nextState = PrefixState(
                byteCount: scanned.committedByteCount,
                digest: EmailMBoxReader.digest(of: nextHasher),
                hasher: nextHasher
            )
            // This state remains pending until a later call presents the page's
            // committed checkpoint. A retry with the old checkpoint therefore
            // recomputes only this bounded page and never advances silently.
            pendingState = nextState
            return .init(
                entries: scanned.entries,
                skippedEntries: scanned.skippedEntries,
                requestByteOffset: checkpoint == nil
                    ? nil : committedState.byteCount,
                nextByteOffset: scanned.nextByteOffset,
                committedByteCount: scanned.committedByteCount,
                committedPrefixSHA256: nextState.digest,
                isComplete: scanned.nextByteOffset == nil
            )
        }
    }

    private func promoteCommittedState(
        requestedByteCount: Int,
        checkpoint: EmailImportCheckpoint?
    ) throws {
        let requestedDigest = checkpoint?.committedPrefixSHA256
        if requestedByteCount == committedState.byteCount,
           checkpoint == nil || requestedDigest == committedState.digest {
            return
        }
        if let pendingState,
           requestedByteCount == pendingState.byteCount,
           requestedDigest == pendingState.digest {
            committedState = pendingState
            self.pendingState = nil
            return
        }
        throw EmailImportFailureCode.mailboxChanged
    }
}

private extension EmailMBoxReader {
    struct Separator: Hashable, Sendable {
        let start: Int
        let end: Int
        let line: String
    }

    struct ScannedPage {
        let entries: [EmailMBoxEntry]
        let skippedEntries: [EmailMBoxSkippedEntry]
        let nextByteOffset: Int?
        let committedByteCount: Int
    }

    static let separatorExpression = try? NSRegularExpression(
        pattern: #"^From\s+\S+\s+(?:Mon|Tue|Wed|Thu|Fri|Sat|Sun)\s+(?:Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)\s+\d{1,2}\s+\d{2}:\d{2}(?::\d{2})?(?:\s+\S+)?\s+\d{4}\s*$"#
    )

    func validatedCheckpointOffset(
        dataCount: Int,
        source: EmailImportSource,
        checkpoint: EmailImportCheckpoint?
    ) throws -> Int {
        try validatedCheckpointOffset(
            dataCount: dataCount,
            sourceIdentifierHash: source.sourceIdentifierHash,
            checkpoint: checkpoint
        )
    }

    func validatedCheckpointOffset(
        dataCount: Int,
        sourceIdentifierHash: String,
        checkpoint: EmailImportCheckpoint?
    ) throws -> Int {
        guard let checkpoint else { return 0 }
        guard checkpoint.sourceIdentifierHash == sourceIdentifierHash,
              checkpoint.format == .mbox,
              let committedCount = checkpoint.committedByteCount,
              checkpoint.committedPrefixSHA256 != nil,
              committedCount <= dataCount
        else { throw EmailImportFailureCode.mailboxChanged }
        if checkpoint.completed { return committedCount }
        guard checkpoint.nextByteOffset == committedCount else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        return committedCount
    }

    func scanPage(
        in data: Data,
        resumeOffset: Int,
        checkpoint: EmailImportCheckpoint?,
        pageSize: Int,
        scanEndOffset: Int? = nil,
        exactResume: Bool = false,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> ScannedPage {
        let scanEnd = scanEndOffset ?? data.count
        guard scanEnd >= 0, scanEnd <= data.count else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        if resumeOffset >= scanEnd {
            return .init(
                entries: [],
                skippedEntries: [],
                nextByteOffset: nil,
                committedByteCount: scanEnd
            )
        }

        // One look-ahead separator closes the last message in this page. The
        // scan never builds a whole-mailbox index.
        let separators = try Self.separatorLines(
            in: data,
            startingAt: resumeOffset,
            endingAt: scanEnd,
            maximumCount: pageSize + 1,
            isCancelled: isCancelled,
            workObserver: workObserver
        )
        guard let first = separators.first else {
            throw checkpoint == nil
                ? EmailImportFailureCode.mailboxMalformed
                : EmailImportFailureCode.mailboxChanged
        }
        guard Self.isLineBoundary(first.start, in: data) else {
            throw EmailImportFailureCode.mailboxChanged
        }
        if exactResume {
            guard first.start == resumeOffset else {
                throw EmailImportFailureCode.mailboxChanged
            }
        } else if checkpoint == nil {
            guard first.start == 0 else {
                throw EmailImportFailureCode.mailboxMalformed
            }
        } else if checkpoint?.completed == true {
            guard first.start >= resumeOffset,
                  Self.onlyLineBreaks(data[resumeOffset..<first.start])
            else { throw EmailImportFailureCode.mailboxChanged }
        } else {
            guard first.start == resumeOffset else {
                throw EmailImportFailureCode.mailboxChanged
            }
        }

        let messageCount = min(pageSize, separators.count)
        var entries: [EmailMBoxEntry] = []
        var skippedEntries: [EmailMBoxSkippedEntry] = []
        entries.reserveCapacity(messageCount)
        for index in 0..<messageCount {
            try Self.checkCancellation(isCancelled)
            let separator = separators[index]
            let messageEnd = index + 1 < separators.count
                ? separators[index + 1].start
                : scanEnd
            guard messageEnd >= separator.end else {
                throw EmailImportFailureCode.mailboxMalformed
            }
            let encodedByteCount = messageEnd - separator.end
            guard encodedByteCount <= maximumMessageBytes else {
                skippedEntries.append(.init(
                    separatorByteOffset: separator.start,
                    messageEndByteOffset: messageEnd,
                    reasonCode: .messageTooLarge
                ))
                continue
            }
            let encodedMessage = Data(data[separator.end..<messageEnd])
            entries.append(.init(
                data: try Self.unescapeMBoxFromLines(
                    encodedMessage,
                    isCancelled: isCancelled
                ),
                separatorLine: separator.line,
                separatorByteOffset: separator.start,
                messageEndByteOffset: messageEnd
            ))
        }

        try Self.checkCancellation(isCancelled)
        let nextOffset = separators.count > pageSize
            ? separators[pageSize].start : nil
        return .init(
            entries: entries,
            skippedEntries: skippedEntries,
            nextByteOffset: nextOffset,
            committedByteCount: nextOffset ?? scanEnd
        )
    }

    func update(
        _ hasher: inout SHA256,
        with data: Data,
        range: Range<Int>,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws {
        guard range.lowerBound >= 0,
              range.upperBound <= data.count,
              range.lowerBound <= range.upperBound
        else { throw EmailImportFailureCode.checkpointInvalid }
        var offset = range.lowerBound
        while offset < range.upperBound {
            try Self.checkCancellation(isCancelled)
            let upper = min(
                range.upperBound,
                offset + EmailImportLimits.fileReadChunkBytes
            )
            hasher.update(data: data[offset..<upper])
            workObserver?(.prefixBytesHashed(upper - offset))
            offset = upper
        }
        try Self.checkCancellation(isCancelled)
    }

    static func digest(of hasher: SHA256) -> String {
        let copy = hasher
        return copy.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func separatorLines(
        in data: Data,
        startingAt start: Int,
        endingAt end: Int? = nil,
        maximumCount: Int,
        isCancelled: @escaping @Sendable () -> Bool,
        workObserver: (@Sendable (EmailMBoxWorkEvent) -> Void)?
    ) throws -> [Separator] {
        let scanEnd = end ?? data.count
        guard start >= 0, start <= scanEnd, scanEnd <= data.count,
              maximumCount > 0 else {
            throw EmailImportFailureCode.checkpointInvalid
        }
        return try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            var result: [Separator] = []
            result.reserveCapacity(maximumCount)
            var lineStart = start
            var examinedLines = 0
            var nextCancellationByte = start
            var furthestExamined = start
            while lineStart < scanEnd, result.count < maximumCount {
                if examinedLines.isMultiple(of: 1_024) {
                    try checkCancellation(isCancelled)
                }
                var lineEnd = lineStart
                while lineEnd < scanEnd, bytes[lineEnd] != 10 {
                    if lineEnd >= nextCancellationByte {
                        try checkCancellation(isCancelled)
                        nextCancellationByte = lineEnd + 65_536
                    }
                    lineEnd += 1
                }
                furthestExamined = max(
                    furthestExamined,
                    lineEnd < scanEnd ? lineEnd + 1 : lineEnd
                )
                var contentEnd = lineEnd
                if contentEnd > lineStart, bytes[contentEnd - 1] == 13 {
                    contentEnd -= 1
                }
                let lineByteCount = contentEnd - lineStart
                if lineByteCount >= 5,
                   lineByteCount <= 512,
                   bytes[lineStart..<(lineStart + 5)]
                    .elementsEqual([70, 114, 111, 109, 32]),
                   let line = String(
                    bytes: bytes[lineStart..<contentEnd],
                    encoding: .ascii
                   ),
                   plausibleSeparator(line) {
                    result.append(.init(
                        start: lineStart,
                        end: lineEnd < scanEnd ? lineEnd + 1 : lineEnd,
                        line: line
                    ))
                }
                examinedLines += 1
                guard lineEnd < scanEnd else { break }
                lineStart = lineEnd + 1
            }
            workObserver?(.separatorBytesScanned(furthestExamined - start))
            return result
        }
    }

    static func plausibleSeparator(_ line: String) -> Bool {
        guard let separatorExpression else { return false }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        return separatorExpression.firstMatch(in: line, range: range)?.range
            == range
    }

    static func isLineBoundary(_ offset: Int, in data: Data) -> Bool {
        offset == 0 || (offset > 0 && data[offset - 1] == 10)
    }

    static func onlyLineBreaks(_ data: Data.SubSequence) -> Bool {
        data.allSatisfy { $0 == 10 || $0 == 13 }
    }

    static func unescapeMBoxFromLines(
        _ data: Data,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Data {
        let bytes = [UInt8](data)
        guard let bodyStart = try bodyStart(
            in: bytes,
            isCancelled: isCancelled
        ), bodyStart < bytes.count else { return data }
        let fromMarker: [UInt8] = [70, 114, 111, 109, 32] // From
        var output: [UInt8] = []
        output.reserveCapacity(bytes.count)
        var index = 0
        var atLineStart = true
        while index < bytes.count {
            if index.isMultiple(of: 65_536) {
                try checkCancellation(isCancelled)
            }
            if index >= bodyStart, atLineStart, bytes[index] == 62 {
                var markerStart = index
                while markerStart < bytes.count, bytes[markerStart] == 62 {
                    markerStart += 1
                }
                if markerStart + fromMarker.count <= bytes.count,
                   bytes[markerStart..<(markerStart + fromMarker.count)]
                    .elementsEqual(fromMarker) {
                    // mboxrd removes exactly one quoting level. Thus `>From`
                    // becomes `From` and `>>From` becomes `>From`.
                    index += 1
                }
            }
            guard index < bytes.count else { break }
            output.append(bytes[index])
            atLineStart = bytes[index] == 10
            index += 1
        }
        return Data(output)
    }

    static func bodyStart(
        in bytes: [UInt8],
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> Int? {
        if bytes.count >= 4 {
            for index in 0...(bytes.count - 4) {
                if index.isMultiple(of: 65_536) {
                    try checkCancellation(isCancelled)
                }
                guard bytes[index] == 13, bytes[index + 1] == 10,
                      bytes[index + 2] == 13, bytes[index + 3] == 10
                else { continue }
                return index + 4
            }
        }
        if bytes.count >= 2 {
            for index in 0...(bytes.count - 2) {
                if index.isMultiple(of: 65_536) {
                    try checkCancellation(isCancelled)
                }
                guard bytes[index] == 10, bytes[index + 1] == 10 else {
                    continue
                }
                return index + 2
            }
        }
        return nil
    }

    static func checkCancellation(
        _ isCancelled: @Sendable () -> Bool
    ) throws {
        if isCancelled() { throw EmailImportFailureCode.cancelled }
    }
}
