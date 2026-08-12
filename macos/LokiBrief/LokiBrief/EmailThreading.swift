import Foundation

enum EmailMessageID {
    static func canonical(_ value: String?) -> String? {
        guard let value else { return nil }
        let decoded = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !decoded.isEmpty else { return nil }
        if let opening = decoded.firstIndex(of: "<"),
           let closing = decoded[decoded.index(after: opening)...].firstIndex(of: ">") {
            return bounded(String(decoded[decoded.index(after: opening)..<closing]))
        }
        return bounded(decoded.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "")
    }

    static func all(in value: String?) -> [String] {
        guard let value else { return [] }
        var result: [String] = []
        var remainder = value[...]
        while let opening = remainder.firstIndex(of: "<"),
              let closing = remainder[remainder.index(after: opening)...].firstIndex(of: ">") {
            if let identifier = bounded(String(remainder[remainder.index(after: opening)..<closing])) {
                result.append(identifier)
            }
            remainder = remainder[remainder.index(after: closing)...]
            if result.count >= EmailImportLimits.maximumReferences { break }
        }
        if result.isEmpty, let single = canonical(value) { return [single] }
        var seen: Set<String> = []
        return result.filter { seen.insert($0).inserted }
    }

    private static func bounded(_ value: String) -> String? {
        let normalized = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        guard !normalized.isEmpty,
              normalized.lengthOfBytes(using: .utf8) <= 998,
              !normalized.unicodeScalars.contains(
                  where: ConnectorEnvelopeValidation.isUnsafeScalar
              )
        else { return nil }
        return normalized
    }
}

/// The only header material needed to follow Message-ID ancestry. Keeping this
/// separate prevents a long-running mbox session from retaining full headers,
/// bodies, or attachment metadata for already committed pages.
struct EmailThreadAncestry: Hashable, Sendable {
    let messageID: String
    let inReplyTo: String?
    let references: [String]

    init?(_ headers: EmailHeaderFields) {
        guard let messageID = headers.messageID else { return nil }
        self.messageID = messageID
        inReplyTo = headers.inReplyTo
        references = Array(
            headers.references.prefix(EmailImportLimits.maximumReferences)
        )
    }
}

enum EmailThreader {
    static func relation(for headers: EmailHeaderFields) -> EmailThreadRelation {
        relation(for: headers, ancestryByMessageID: [:])
    }

    /// Resolves In-Reply-To-only chains when their ancestors are present in the
    /// same atomic import page. References remain authoritative, and cycles are
    /// collapsed to a deterministic identifier instead of recursing forever.
    static func relations(
        for headers: [EmailHeaderFields],
        including committedAncestryByMessageID:
            [String: EmailThreadAncestry] = [:]
    ) -> [EmailThreadRelation] {
        var ancestryByMessageID = committedAncestryByMessageID
        for value in headers {
            guard let ancestry = EmailThreadAncestry(value),
                  ancestryByMessageID[ancestry.messageID] == nil
            else { continue }
            ancestryByMessageID[ancestry.messageID] = ancestry
        }
        return headers.map {
            relation(for: $0, ancestryByMessageID: ancestryByMessageID)
        }
    }

    /// Recomputes the authoritative relation for compact committed ancestry.
    /// This is used by bounded mbox convergence without retaining full headers
    /// or bodies for prior pages.
    static func relation(
        for ancestry: EmailThreadAncestry,
        including ancestryByMessageID: [String: EmailThreadAncestry]
    ) -> EmailThreadRelation {
        relation(
            messageID: ancestry.messageID,
            inReplyTo: ancestry.inReplyTo,
            references: ancestry.references,
            ancestryByMessageID: ancestryByMessageID
        )
    }

    private static func relation(
        for headers: EmailHeaderFields,
        ancestryByMessageID: [String: EmailThreadAncestry]
    ) -> EmailThreadRelation {
        let references = Array(headers.references.prefix(EmailImportLimits.maximumReferences))
        if !references.isEmpty || headers.inReplyTo != nil || headers.messageID != nil {
            return relation(
                messageID: headers.messageID,
                inReplyTo: headers.inReplyTo,
                references: references,
                ancestryByMessageID: ancestryByMessageID
            )
        }

        let subject = normalizedSubject(headers.subject)
        let participants = normalizedParticipants(headers)
        if !subject.isEmpty, !participants.isEmpty {
            return .init(
                basis: .heuristicSubjectParticipants,
                parentMessageID: nil,
                rootMessageID: nil,
                heuristicKey: EmailDigest.sha256(
                    (["email-thread-heuristic-v1", subject] + participants)
                        .joined(separator: "\u{1f}")
                )
            )
        }
        return .init(
            basis: .none,
            parentMessageID: nil,
            rootMessageID: nil,
            heuristicKey: nil
        )
    }

    private static func relation(
        messageID: String?,
        inReplyTo: String?,
        references: [String],
        ancestryByMessageID: [String: EmailThreadAncestry]
    ) -> EmailThreadRelation {
        if !references.isEmpty {
            return .init(
                basis: .messageReferences,
                parentMessageID: inReplyTo ?? references.last,
                rootMessageID: references.first,
                heuristicKey: nil
            )
        }
        if let inReplyTo {
            return .init(
                basis: .inReplyTo,
                parentMessageID: inReplyTo,
                rootMessageID: resolvedRootMessageID(
                    startingAt: inReplyTo,
                    ancestryByMessageID: ancestryByMessageID
                ),
                heuristicKey: nil
            )
        }

        // A root message must use its own Message-ID as the stable thread root
        // so a later References/In-Reply-To child resolves to the same Vault
        // grouping instead of splitting across a heuristic key.
        if let messageID {
            return .init(
                basis: .messageIDRoot,
                parentMessageID: nil,
                rootMessageID: messageID,
                heuristicKey: nil
            )
        }
        return .init(
            basis: .none,
            parentMessageID: nil,
            rootMessageID: nil,
            heuristicKey: nil
        )
    }

    private static func resolvedRootMessageID(
        startingAt identifier: String,
        ancestryByMessageID: [String: EmailThreadAncestry]
    ) -> String {
        var current = identifier
        var visited: Set<String> = []
        while visited.insert(current).inserted {
            guard let parent = ancestryByMessageID[current] else {
                return current
            }
            if let referencedRoot = parent.references.first {
                return referencedRoot
            }
            guard let next = parent.inReplyTo else {
                return parent.messageID
            }
            current = next
        }
        return visited.min() ?? identifier
    }

    static func normalizedSubject(_ value: String) -> String {
        var subject = value.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
        let prefixes = ["re:", "fw:", "fwd:", "aw:", "sv:"]
        var changed = true
        while changed {
            changed = false
            for prefix in prefixes where subject.hasPrefix(prefix) {
                subject.removeFirst(prefix.count)
                subject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
                changed = true
                break
            }
        }
        // Ticket markers are useful only when they are stable. Preserve their
        // text but normalize whitespace and punctuation case deterministically.
        return subject.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func normalizedParticipants(_ headers: EmailHeaderFields) -> [String] {
        var participants = (headers.from + headers.to + headers.cc + headers.replyTo)
            .prefix(EmailImportLimits.maximumAddressValues)
            .map {
                $0.precomposedStringWithCanonicalMapping
                    .lowercased(with: Locale(identifier: "en_US_POSIX"))
                    .split(whereSeparator: \.isWhitespace)
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
        participants.sort()
        var seen: Set<String> = []
        return participants.filter { seen.insert($0).inserted }
    }
}
