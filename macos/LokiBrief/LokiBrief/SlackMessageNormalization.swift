import CryptoKit
import Foundation

enum SlackNormalizationSkipReason: String, Codable, CaseIterable, Sendable {
    case unsupportedMessageType = "slack_message_type_skipped"
    case unsupportedSubtype = "slack_message_subtype_skipped"
    case threadReply = "slack_thread_reply_skipped"
    case emptyText = "slack_empty_message_skipped"
    case invalidContext = "slack_normalization_context_invalid"
}

struct SlackNormalizationSkip: Codable, Hashable, Sendable {
    let messageTimestamp: SlackTimestamp?
    let reason: SlackNormalizationSkipReason
}

struct SlackNormalizationContext: Sendable {
    let connection: SlackWorkspaceConnection
    let selection: SlackConversationSelection
    let authorsByID: [String: SlackMessageAuthor]
    let retrievedAt: Date
}

struct SlackNormalizationResult: Codable, Hashable, Sendable {
    let evidence: [SlackMessageEvidence]
    let tombstones: [SlackMessageEvidence]
    let skipped: [SlackNormalizationSkip]
}

struct SlackMessageNormalizer: Sendable {
    typealias TraceSink = @Sendable (SlackTraceEvent) -> Void

    private let now: @Sendable () -> Date
    private let eventSink: TraceSink?

    init(now: @escaping @Sendable () -> Date = { Date() }, eventSink: TraceSink? = nil) {
        self.now = now
        self.eventSink = eventSink
    }

    func normalize(
        messages: [SlackHistoryMessage],
        context: SlackNormalizationContext,
        trace: SlackTraceContext = .init()
    ) throws -> SlackNormalizationResult {
        emit(.messageNormalization, trace: trace, status: .started, reason: "slack_message_normalization_started", metadata: .init([
            (.workspaceHash, SlackPrivacy.hashIdentifier(context.connection.id)),
            (.channelHash, SlackPrivacy.hashIdentifier(context.selection.channelID)),
            (.pageSize, String(messages.count)),
        ]))
        guard context.selection.workspaceID == context.connection.id,
              let weight = context.selection.validatedWeight,
              SlackPrivacy.boundedIdentifier(context.selection.channelID) != nil,
              SlackPrivacy.boundedIdentifier(context.connection.userID) != nil
        else {
            emit(.messageNormalization, trace: trace, status: .failed, reason: SlackNormalizationSkipReason.invalidContext.rawValue)
            throw SlackAPIError(.invalidRequest)
        }

        var byKey: [String: SlackMessageEvidence] = [:]
        var skipped: [SlackNormalizationSkip] = []
        for message in messages {
            guard message.type == "message" else {
                skipped.append(.init(messageTimestamp: message.timestamp, reason: .unsupportedMessageType))
                continue
            }
            if let thread = message.threadTimestamp, thread != message.timestamp {
                skipped.append(.init(messageTimestamp: message.timestamp, reason: .threadReply))
                continue
            }

            let isDeletion = message.subtype == "message_deleted" || message.deletedTimestamp != nil
            if !isDeletion, let subtype = message.subtype,
               !["bot_message", "me_message"].contains(subtype) {
                skipped.append(.init(messageTimestamp: message.timestamp, reason: .unsupportedSubtype))
                continue
            }
            let effectiveTimestamp = isDeletion ? (message.deletedTimestamp ?? message.timestamp) : message.timestamp
            let author = resolvedAuthor(for: message, authorsByID: context.authorsByID)
            let directMention = !isDeletion && containsExactUserMention(message.text, userID: context.connection.userID)
            let excerpt = isDeletion ? "" : plainText(message.text, authorsByID: context.authorsByID)
            if !isDeletion && excerpt.isEmpty {
                skipped.append(.init(messageTimestamp: effectiveTimestamp, reason: .emptyText))
                continue
            }
            let evidence = SlackMessageEvidence(
                id: stableEvidenceID(workspaceID: context.connection.id, channelID: context.selection.channelID, timestamp: effectiveTimestamp),
                workspaceID: context.connection.id,
                workspaceName: SlackPrivacy.boundedDisplayName(context.connection.teamName, maximum: SlackLimits.maximumWorkspaceNameCharacters, fallback: "Slack Workspace"),
                channelID: context.selection.channelID,
                channelName: SlackPrivacy.boundedDisplayName(context.selection.displayName, maximum: SlackLimits.maximumChannelNameCharacters, fallback: "Slack channel"),
                channelKind: context.selection.kind,
                messageTimestamp: effectiveTimestamp,
                excerpt: excerpt,
                author: author,
                directlyMentionsAuthenticatedUser: directMention,
                replyCount: min(max(message.replyCount, 0), 1_000_000),
                isEdited: message.editedAt != nil,
                editedAt: message.editedAt,
                permalink: nil,
                retrievedAt: context.retrievedAt,
                selectedChannelWeight: weight,
                state: isDeletion ? .deleted : .available
            )
            let key = evidence.deduplicationKey
            if let existing = byKey[key] { byKey[key] = deterministicWinner(existing, evidence) }
            else { byKey[key] = evidence }
        }

        let ordered = byKey.values.sorted {
            if $0.messageTimestamp != $1.messageTimestamp { return $0.messageTimestamp > $1.messageTimestamp }
            return $0.id < $1.id
        }
        let evidence = ordered.filter { $0.state == .available }
        let tombstones = ordered.filter { $0.state != .available }
        let status: SlackTraceStatus = skipped.isEmpty ? .success : .degraded
        emit(.messageNormalization, trace: trace, status: status, reason: skipped.isEmpty ? "slack_message_normalization_succeeded" : "slack_message_normalization_partial", metadata: .init([
            (.normalizedCount, String(evidence.count)),
            (.skippedCount, String(skipped.count)),
            (.directMentionCount, String(evidence.filter(\.directlyMentionsAuthenticatedUser).count)),
            (.workspaceHash, SlackPrivacy.hashIdentifier(context.connection.id)),
            (.channelHash, SlackPrivacy.hashIdentifier(context.selection.channelID)),
        ]))
        return .init(evidence: evidence, tombstones: tombstones, skipped: skipped)
    }

    func containsExactUserMention(_ text: String, userID: String) -> Bool {
        guard SlackPrivacy.boundedIdentifier(userID) != nil else { return false }
        var remainder = text[...]
        while let opening = remainder.firstIndex(of: "<"),
              let closing = remainder[opening...].firstIndex(of: ">") {
            let tokenStart = remainder.index(after: opening)
            let token = remainder[tokenStart..<closing]
            let target = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
            if target == "@\(userID)" { return true }
            remainder = remainder[remainder.index(after: closing)...]
        }
        return false
    }

    func plainText(_ text: String, authorsByID: [String: SlackMessageAuthor]) -> String {
        var output = ""
        var remainder = text[...]
        while let opening = remainder.firstIndex(of: "<"),
              let closing = remainder[opening...].firstIndex(of: ">") {
            output += String(remainder[..<opening])
            let tokenStart = remainder.index(after: opening)
            output += plainReplacement(for: String(remainder[tokenStart..<closing]), authorsByID: authorsByID)
            remainder = remainder[remainder.index(after: closing)...]
        }
        output += String(remainder)
        output = output
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
        output = removeFormattingDelimiters(output)

        let safeScalars = output.unicodeScalars.filter { scalar in
            !CharacterSet.controlCharacters.contains(scalar) &&
            !CharacterSet.illegalCharacters.contains(scalar) &&
            !SlackPrivacy.isBidirectionalControl(scalar.value)
        }
        let safe = String(String.UnicodeScalarView(safeScalars))
        let collapsed = safe.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(collapsed.prefix(SlackLimits.maximumExcerptCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func plainReplacement(for token: String, authorsByID: [String: SlackMessageAuthor]) -> String {
        let parts = token.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let target = parts.first ?? ""
        let label = parts.count > 1 ? parts[1] : nil
        if target.hasPrefix("@") {
            let userID = String(target.dropFirst())
            let name = authorsByID[userID]?.displayName ?? "member"
            return "@\(SlackPrivacy.boundedDisplayName(name, maximum: SlackLimits.maximumAuthorNameCharacters, fallback: "member"))"
        }
        if target.hasPrefix("#") {
            guard let label, !label.isEmpty else { return "#channel" }
            return "#\(SlackPrivacy.boundedDisplayName(label, maximum: SlackLimits.maximumChannelNameCharacters, fallback: "channel"))"
        }
        if target.hasPrefix("!date") {
            return label.map { SlackPrivacy.boundedDisplayName($0, maximum: SlackLimits.maximumExcerptCharacters, fallback: "date") } ?? "date"
        }
        if target.hasPrefix("!subteam") {
            return label.map { "@\(SlackPrivacy.boundedDisplayName($0, maximum: SlackLimits.maximumAuthorNameCharacters, fallback: "group"))" } ?? "@group"
        }
        if target == "!here" { return "@here" }
        if target == "!channel" { return "@channel" }
        if target == "!everyone" { return "@everyone" }
        if let label, !label.isEmpty {
            return SlackPrivacy.boundedDisplayName(label, maximum: SlackLimits.maximumExcerptCharacters, fallback: "link")
        }
        if target.hasPrefix("http://") || target.hasPrefix("https://") || target.hasPrefix("mailto:") {
            return "[link]"
        }
        return "[reference]"
    }

    private func removeFormattingDelimiters(_ value: String) -> String {
        let characters = Array(value)
        var result: [Character] = []
        var openMarkers: [Character: Int] = [:]
        for index in characters.indices {
            let character = characters[index]
            guard ["*", "_", "~", "`"].contains(character) else {
                result.append(character)
                continue
            }
            let previous = index > characters.startIndex ? characters[characters.index(before: index)] : nil
            let next = index < characters.index(before: characters.endIndex) ? characters[characters.index(after: index)] : nil
            let opens = (previous == nil || previous!.isWhitespace || previous!.isPunctuation) && (next != nil && !next!.isWhitespace)
            let closes = (previous != nil && !previous!.isWhitespace) && (next == nil || next!.isWhitespace || next!.isPunctuation)
            if character == "`" {
                if openMarkers[character] != nil { openMarkers.removeValue(forKey: character) }
                else { openMarkers[character] = result.count }
                continue
            }
            if opens, openMarkers[character] == nil {
                openMarkers[character] = result.count
                continue
            }
            if closes, let openingPosition = openMarkers.removeValue(forKey: character), openingPosition <= result.count {
                continue
            }
            result.append(character)
        }
        for (marker, position) in openMarkers.sorted(by: { $0.value > $1.value }) where position <= result.count {
            result.insert(marker, at: position)
        }
        return String(result)
    }

    private func resolvedAuthor(for message: SlackHistoryMessage, authorsByID: [String: SlackMessageAuthor]) -> SlackMessageAuthor {
        if let appID = message.appID {
            return .init(id: appID, displayName: message.username ?? "Slack app", kind: .app, isDeleted: false)
        }
        if let botID = message.botID {
            return .init(id: botID, displayName: message.username ?? "Slack bot", kind: .bot, isDeleted: false)
        }
        if let userID = message.userID, let author = authorsByID[userID] { return author }
        return .init(id: message.userID ?? "unknown", displayName: "Unknown member", kind: .unknown, isDeleted: false)
    }

    private func stableEvidenceID(workspaceID: String, channelID: String, timestamp: SlackTimestamp) -> String {
        let material = "\(workspaceID)\u{1f}\(channelID)\u{1f}\(timestamp.rawValue)"
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "slack-message-\(digest)"
    }

    private func deterministicWinner(_ lhs: SlackMessageEvidence, _ rhs: SlackMessageEvidence) -> SlackMessageEvidence {
        let stateRank: (SlackMessageEvidenceState) -> Int = { state in
            switch state { case .available: 0; case .inaccessible: 1; case .deleted: 2 }
        }
        if stateRank(lhs.state) != stateRank(rhs.state) { return stateRank(lhs.state) > stateRank(rhs.state) ? lhs : rhs }
        let leftEdit = lhs.editedAt ?? lhs.messageTimestamp
        let rightEdit = rhs.editedAt ?? rhs.messageTimestamp
        if leftEdit != rightEdit { return leftEdit > rightEdit ? lhs : rhs }
        let leftKey = "\(lhs.excerpt)\u{1f}\(lhs.author.id)\u{1f}\(lhs.replyCount)"
        let rightKey = "\(rhs.excerpt)\u{1f}\(rhs.author.id)\u{1f}\(rhs.replyCount)"
        return leftKey >= rightKey ? lhs : rhs
    }

    private func emit(_ event: SlackTraceEventName, trace: SlackTraceContext, status: SlackTraceStatus, reason: String, metadata: SlackTraceMetadata = .init()) {
        eventSink?(.init(
            ts: now(), event: event, traceID: trace.traceID, spanID: trace.spanID,
            parentSpanID: trace.parentSpanID, component: "slack_message_normalizer",
            status: status, reasonCode: String(reason.prefix(120)), durationMilliseconds: nil, metadata: metadata
        ))
    }
}
