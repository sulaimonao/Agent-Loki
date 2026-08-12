import Foundation

enum LokiChatExportFormat: String, Codable, CaseIterable, Identifiable, Sendable {
    case markdown
    case json

    var id: String { rawValue }

    var filenameExtension: String {
        switch self {
        case .markdown: "md"
        case .json: "json"
        }
    }
}

enum LokiChatExportError: Error, LocalizedError, Equatable {
    case conversationUnavailable
    case exportTooLarge
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .conversationUnavailable:
            "That local conversation is no longer available."
        case .exportTooLarge:
            "The conversation export exceeded the bounded export size."
        case .encodingFailed:
            "Loki Brief could not create the conversation export."
        }
    }
}

struct LokiChatExportSnapshot: Codable, Hashable, Sendable {
    static let contractVersion = "agent-loki.chat-export.v1"

    let contractVersion: String
    let exportedAt: Date
    let conversation: LokiConversation
    let contextSelections: [LokiChatContextSelectionRecord]
    let evidenceByMessageID: [String: [LokiEvidenceReference]]
    let toolReceiptsByMessageID: [String: [LokiChatToolReceipt]]
    let provenanceByMessageID: [String: LokiGenerationProvenance]

    init(
        exportedAt: Date,
        conversation: LokiConversation,
        contextSelections: [LokiChatContextSelectionRecord] = [],
        evidenceByMessageID: [String: [LokiEvidenceReference]],
        toolReceiptsByMessageID: [String: [LokiChatToolReceipt]],
        provenanceByMessageID: [String: LokiGenerationProvenance]
    ) {
        self.contractVersion = Self.contractVersion
        let userVisibleMessages = conversation.messages.filter(\.role.isUserVisiblePersistedRole)
        let userVisibleMessageIDs = Set(userVisibleMessages.map(\.id))
        self.exportedAt = exportedAt
        self.conversation = LokiConversation(
            id: conversation.id,
            title: conversation.title,
            createdAt: conversation.createdAt,
            updatedAt: conversation.updatedAt,
            context: conversation.context,
            messages: userVisibleMessages
        )
        self.contextSelections = contextSelections
            .filter {
                $0.conversationID == conversation.id
                    && userVisibleMessageIDs.contains($0.requestMessageID)
            }
            .sorted {
                if $0.context.selectedAt != $1.context.selectedAt {
                    return $0.context.selectedAt < $1.context.selectedAt
                }
                return $0.id < $1.id
            }
        self.evidenceByMessageID = evidenceByMessageID.filter {
            userVisibleMessageIDs.contains($0.key)
        }
        self.toolReceiptsByMessageID = toolReceiptsByMessageID.filter {
            userVisibleMessageIDs.contains($0.key)
        }
        self.provenanceByMessageID = provenanceByMessageID.filter {
            userVisibleMessageIDs.contains($0.key)
        }
    }
}

struct LokiChatExportDocument: Hashable, Sendable {
    let suggestedFilename: String
    let format: LokiChatExportFormat
    let data: Data
}

enum LokiChatExportRenderer {
    static func render(
        _ snapshot: LokiChatExportSnapshot,
        format: LokiChatExportFormat
    ) throws -> LokiChatExportDocument {
        let data: Data
        do {
            switch format {
            case .markdown:
                guard let encoded = markdown(snapshot).data(using: .utf8) else {
                    throw LokiChatExportError.encodingFailed
                }
                data = encoded
            case .json:
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                data = try encoder.encode(snapshot)
            }
        } catch let error as LokiChatExportError {
            throw error
        } catch {
            throw LokiChatExportError.encodingFailed
        }

        guard data.count <= LokiChatLimits.maximumExportBytes else {
            throw LokiChatExportError.exportTooLarge
        }
        return LokiChatExportDocument(
            suggestedFilename: "\(safeFilename(snapshot.conversation.title)).\(format.filenameExtension)",
            format: format,
            data: data
        )
    }

    private static func markdown(_ snapshot: LokiChatExportSnapshot) -> String {
        var lines = [
            "# \(snapshot.conversation.title)",
            "",
            "Exported: \(timestamp(snapshot.exportedAt))",
            "Context: \(snapshot.conversation.context.scope.displayName)",
            "",
            "> Chat history is stored locally. Agent Loki does not create durable personal memories in this version.",
            "",
        ]

        for message in snapshot.conversation.messages.sorted(by: messageOrder) {
            lines.append("## \(message.role == .user ? "You" : "Agent Loki")")
            lines.append("")
            lines.append(message.visibleText)
            lines.append("")
            lines.append("State: \(message.state.rawValue)")
            if let selection = snapshot.contextSelections
                .first(where: { $0.requestMessageID == message.id }) {
                var contextLine = "Selected context: \(selection.context.scope.displayName)"
                if selection.wasTruncated {
                    contextLine += " (bounded and truncated)"
                }
                lines.append(contextLine)
            }
            if message.isPartial {
                lines.append("Partial response: yes")
            }

            let evidence = snapshot.evidenceByMessageID[message.id] ?? []
            if !evidence.isEmpty {
                lines.append("")
                lines.append("### Evidence")
                lines.append("")
                for reference in evidence.sorted(by: evidenceOrder) {
                    var detail = "- \(reference.displayLabel) [\(reference.sourceKind.rawValue)]"
                    if let sourceTimestamp = reference.sourceTimestamp {
                        detail += " — \(timestamp(sourceTimestamp))"
                    }
                    lines.append(detail)
                    if let excerpt = reference.boundedExcerpt, !excerpt.isEmpty {
                        lines.append("  Excerpt: \(excerpt)")
                    }
                }
            }

            let receipts = snapshot.toolReceiptsByMessageID[message.id] ?? []
            if !receipts.isEmpty {
                lines.append("")
                lines.append("### Read-only tool activity")
                lines.append("")
                for receipt in receipts.sorted(by: receiptOrder) {
                    lines.append(
                        "- \(receipt.toolName): \(receipt.status) (\(receipt.reasonCode)); results \(receipt.resultCount)"
                    )
                }
            }

            if let provenance = snapshot.provenanceByMessageID[message.id] {
                lines.append("")
                lines.append("### Generation")
                lines.append("")
                lines.append("- Provider: \(provenance.provider)")
                lines.append("- Model: \(provenance.modelIdentifier)")
                lines.append("- Assessment: \(provenance.assessmentVersion)")
                lines.append("- Status: \(provenance.status) (\(provenance.reasonCode))")
            }
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }

    private static func safeFilename(_ title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let words = title
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .unicodeScalars
            .map { allowed.contains($0) ? Character(String($0)) : "-" }
        let collapsed = String(words)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((collapsed.isEmpty ? "agent-loki-conversation" : collapsed).prefix(80))
    }

    private static func messageOrder(_ lhs: LokiMessage, _ rhs: LokiMessage) -> Bool {
        if lhs.sequence != rhs.sequence { return lhs.sequence < rhs.sequence }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id < rhs.id
    }

    private static func evidenceOrder(
        _ lhs: LokiEvidenceReference,
        _ rhs: LokiEvidenceReference
    ) -> Bool {
        if lhs.retrievedAt != rhs.retrievedAt { return lhs.retrievedAt < rhs.retrievedAt }
        return lhs.id < rhs.id
    }

    private static func receiptOrder(_ lhs: LokiChatToolReceipt, _ rhs: LokiChatToolReceipt) -> Bool {
        if lhs.requestedAt != rhs.requestedAt { return lhs.requestedAt < rhs.requestedAt }
        return lhs.id < rhs.id
    }

    private static func timestamp(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

@MainActor
extension LocalStore {
    func lokiChatExportSnapshot(
        conversationID: String,
        exportedAt: Date = .now
    ) throws -> LokiChatExportSnapshot {
        guard let conversation = try lokiConversation(id: conversationID) else {
            throw LokiChatExportError.conversationUnavailable
        }

        var evidenceByMessageID: [String: [LokiEvidenceReference]] = [:]
        var receiptsByMessageID: [String: [LokiChatToolReceipt]] = [:]
        var provenanceByMessageID: [String: LokiGenerationProvenance] = [:]
        for message in conversation.messages where message.role.isUserVisiblePersistedRole {
            let evidence = try lokiEvidenceReferences(messageID: message.id)
            if !evidence.isEmpty { evidenceByMessageID[message.id] = evidence }
            let receipts = try lokiToolReceipts(messageID: message.id)
            if !receipts.isEmpty { receiptsByMessageID[message.id] = receipts }
            if let provenance = try lokiGenerationProvenance(messageID: message.id) {
                provenanceByMessageID[message.id] = provenance
            }
        }

        return LokiChatExportSnapshot(
            exportedAt: exportedAt,
            conversation: conversation,
            contextSelections: try lokiChatContextSelections(conversationID: conversationID),
            evidenceByMessageID: evidenceByMessageID,
            toolReceiptsByMessageID: receiptsByMessageID,
            provenanceByMessageID: provenanceByMessageID
        )
    }
}
