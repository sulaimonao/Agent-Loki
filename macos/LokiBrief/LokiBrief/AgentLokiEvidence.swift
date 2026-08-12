import CryptoKit
import Foundation

enum AgentLokiEvidenceLimits {
    static let maximumLabelCharacters = 160
    static let maximumExcerptCharacters = 1_200
    static let maximumIdentifierCharacters = 512
    static let maximumURLCharacters = 4_096
    static let maximumEvidenceItemsPerResult = 50
}

/// Answer-level epistemic classification. This deliberately does not extend
/// `TextOrigin`: stored source/generated content and answer claims are
/// different contracts.
enum AgentLokiClaimBasis: String, Codable, CaseIterable, Hashable, Sendable {
    case observed
    case inferred
    case generated
}

enum AgentLokiEvidenceTrust: String, Codable, CaseIterable, Hashable, Sendable {
    case authorizedExternalUntrusted = "authorized_external_untrusted"
    case localGenerated = "local_generated"
    case localApplicationState = "local_application_state"
}

enum AgentLokiEvidenceSourceKind: String, Codable, CaseIterable, Hashable, Sendable {
    case brief
    case briefHistory = "brief_history"
    case vault
    case feed
    case slack
    case webResearch = "web_research"
    case sourceStatus = "source_status"
    case deliveryStatus = "delivery_status"
    case updateStatus = "update_status"
    case backfillPreview = "backfill_preview"
}

enum AgentLokiEvidenceContentOrigin: String, Codable, CaseIterable, Hashable, Sendable {
    case source
    case generated
    case applicationState = "application_state"
}

enum AgentLokiHostileSourceSignal: String, Codable, CaseIterable, Hashable, Sendable {
    case authorityOverride = "authority_override"
    case toolImpersonation = "tool_impersonation"
    case credentialRequest = "credential_request"
    case externalActionRequest = "external_action_request"
    case citationSuppression = "citation_suppression"
    case memoryInstruction = "memory_instruction"
    case encodedInstructionLikeText = "encoded_instruction_like_text"
}

struct AgentLokiEvidenceReference: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let sourceKind: AgentLokiEvidenceSourceKind
    let accountClassification: String?
    let accountIdentifier: String?
    let containerClassification: String?
    let containerIdentifier: String?
    let sourceItemID: String
    let sourceTimestamp: Date?
    let retrievedAt: Date
    let localVaultID: String?
    let boundedLabel: String
    let directSourceURL: URL?
    let contentOrigin: AgentLokiEvidenceContentOrigin
    let trust: AgentLokiEvidenceTrust
    let claimBasis: AgentLokiClaimBasis

    init(
        id: String? = nil,
        sourceKind: AgentLokiEvidenceSourceKind,
        accountClassification: String? = nil,
        accountIdentifier: String? = nil,
        containerClassification: String? = nil,
        containerIdentifier: String? = nil,
        sourceItemID: String,
        sourceTimestamp: Date? = nil,
        retrievedAt: Date,
        localVaultID: String? = nil,
        boundedLabel: String,
        directSourceURL: URL? = nil,
        contentOrigin: AgentLokiEvidenceContentOrigin,
        trust: AgentLokiEvidenceTrust,
        claimBasis: AgentLokiClaimBasis
    ) {
        let safeItemID = AgentLokiEvidenceSanitizer.identifier(sourceItemID)
        let safeAccount = accountClassification.map(AgentLokiEvidenceSanitizer.classification)
        let safeAccountID = accountIdentifier.map(AgentLokiEvidenceSanitizer.identifier)
        let safeContainer = containerClassification.map(AgentLokiEvidenceSanitizer.classification)
        let safeContainerID = containerIdentifier.map(AgentLokiEvidenceSanitizer.identifier)
        let safeVaultID = localVaultID.map(AgentLokiEvidenceSanitizer.identifier)
        let safeURL = AgentLokiEvidenceSanitizer.directSourceURL(directSourceURL)
        self.id = AgentLokiEvidenceSanitizer.identifier(id ?? Self.makeIdentifier(
            sourceKind: sourceKind,
            accountClassification: safeAccount,
            accountIdentifier: safeAccountID,
            containerClassification: safeContainer,
            containerIdentifier: safeContainerID,
            sourceItemID: safeItemID,
            sourceTimestamp: sourceTimestamp,
            retrievedAt: retrievedAt,
            localVaultID: safeVaultID
        ))
        self.sourceKind = sourceKind
        self.accountClassification = safeAccount
        self.accountIdentifier = safeAccountID
        self.containerClassification = safeContainer
        self.containerIdentifier = safeContainerID
        self.sourceItemID = safeItemID
        self.sourceTimestamp = sourceTimestamp
        self.retrievedAt = retrievedAt
        self.localVaultID = safeVaultID
        self.boundedLabel = AgentLokiEvidenceSanitizer.text(
            boundedLabel,
            maximumCharacters: AgentLokiEvidenceLimits.maximumLabelCharacters
        )
        self.directSourceURL = safeURL
        self.contentOrigin = contentOrigin
        self.trust = trust
        self.claimBasis = claimBasis
    }

    private static func makeIdentifier(
        sourceKind: AgentLokiEvidenceSourceKind,
        accountClassification: String?,
        accountIdentifier: String?,
        containerClassification: String?,
        containerIdentifier: String?,
        sourceItemID: String,
        sourceTimestamp: Date?,
        retrievedAt: Date,
        localVaultID: String?
    ) -> String {
        let canonical = [
            sourceKind.rawValue,
            accountClassification ?? "",
            accountIdentifier ?? "",
            containerClassification ?? "",
            containerIdentifier ?? "",
            sourceItemID,
            sourceTimestamp.map(AgentLokiEvidenceSanitizer.canonicalDate) ?? "",
            AgentLokiEvidenceSanitizer.canonicalDate(retrievedAt),
            localVaultID ?? "",
        ].joined(separator: "\u{1f}")
        return "evidence_\(AgentLokiEvidenceHasher.sha256Prefix(canonical, bytes: 16))"
    }
}

struct AgentLokiEvidenceExcerpt: Codable, Hashable, Sendable {
    let reference: AgentLokiEvidenceReference
    let text: String
    let hostileSourceSignals: [AgentLokiHostileSourceSignal]
    let wasTruncated: Bool

    init(reference: AgentLokiEvidenceReference, text: String) {
        let neutralized = AgentLokiEvidenceSanitizer.text(
            text,
            maximumCharacters: AgentLokiEvidenceLimits.maximumExcerptCharacters
        )
        self.reference = reference
        self.text = neutralized
        self.hostileSourceSignals = AgentLokiEvidenceSanitizer.hostileSignals(in: neutralized)
        self.wasTruncated = neutralized.count < AgentLokiEvidenceSanitizer.normalized(text).count
    }
}

enum AgentLokiToolReceiptStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case success
    case empty
    case rejected
    case cancelled
    case failed
}

struct AgentLokiToolReceipt: Identifiable, Codable, Hashable, Sendable {
    let id: String
    let toolName: String
    let requestHash: String
    let status: AgentLokiToolReceiptStatus
    let reasonCode: String
    let startedAt: Date
    let completedAt: Date
    let evidenceReferenceIDs: [String]
    let evidenceCount: Int
    let wasTruncated: Bool

    init(
        id: String? = nil,
        toolName: String,
        canonicalRequest: String,
        status: AgentLokiToolReceiptStatus,
        reasonCode: String,
        startedAt: Date,
        completedAt: Date,
        evidenceReferenceIDs: [String],
        wasTruncated: Bool
    ) {
        let requestHash = AgentLokiEvidenceHasher.sha256Prefix(canonicalRequest, bytes: 16)
        self.init(
            id: id,
            toolName: toolName,
            requestHash: requestHash,
            status: status,
            reasonCode: reasonCode,
            startedAt: startedAt,
            completedAt: completedAt,
            evidenceReferenceIDs: evidenceReferenceIDs,
            wasTruncated: wasTruncated
        )
    }

    init(
        id: String? = nil,
        toolName: String,
        requestHash: String,
        status: AgentLokiToolReceiptStatus,
        reasonCode: String,
        startedAt: Date,
        completedAt: Date,
        evidenceReferenceIDs: [String],
        wasTruncated: Bool
    ) {
        let safeRequestHash = AgentLokiEvidenceSanitizer.identifier(requestHash)
        var seenEvidenceIDs: Set<String> = []
        var boundedEvidenceIDs: [String] = []
        for rawID in evidenceReferenceIDs {
            let safeID = AgentLokiEvidenceSanitizer.identifier(rawID)
            guard !seenEvidenceIDs.contains(safeID),
                  boundedEvidenceIDs.count < AgentLokiEvidenceLimits.maximumEvidenceItemsPerResult
            else { continue }
            seenEvidenceIDs.insert(safeID)
            boundedEvidenceIDs.append(safeID)
        }
        let receiptCanonical = [
            toolName,
            safeRequestHash,
            AgentLokiEvidenceSanitizer.canonicalDate(startedAt),
        ].joined(separator: "\u{1f}")
        let receiptHash = AgentLokiEvidenceHasher.sha256Prefix(
            receiptCanonical,
            bytes: 16
        )
        let generatedID = "tool_receipt_" + receiptHash
        self.id = AgentLokiEvidenceSanitizer.identifier(id ?? generatedID)
        self.toolName = AgentLokiEvidenceSanitizer.classification(toolName)
        self.requestHash = safeRequestHash
        self.status = status
        self.reasonCode = AgentLokiEvidenceSanitizer.reasonCode(reasonCode)
        self.startedAt = startedAt
        self.completedAt = max(startedAt, completedAt)
        self.evidenceReferenceIDs = boundedEvidenceIDs
        self.evidenceCount = boundedEvidenceIDs.count
        self.wasTruncated = wasTruncated || evidenceReferenceIDs.count > boundedEvidenceIDs.count
    }
}

enum AgentLokiEvidenceHasher {
    static func sha256Prefix(_ value: String, bytes: Int) -> String {
        let byteCount = max(1, min(bytes, 32))
        return SHA256.hash(data: Data(value.utf8))
            .prefix(byteCount)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum AgentLokiEvidenceSanitizer {
    private static let forbiddenFormatScalars: Set<UInt32> = [
        0x061C,
        0x200B,
        0x200C,
        0x200D,
        0x200E,
        0x200F,
        0x202A,
        0x202B,
        0x202C,
        0x202D,
        0x202E,
        0x2060,
        0x2066,
        0x2067,
        0x2068,
        0x2069,
        0xFEFF,
    ]

    static func normalized(_ value: String) -> String {
        let scalars = value.unicodeScalars.map { scalar -> UnicodeScalar in
            if forbiddenFormatScalars.contains(scalar.value) ||
                (CharacterSet.controlCharacters.contains(scalar) &&
                    scalar != "\n" && scalar != "\r" && scalar != "\t") {
                return " "
            }
            if scalar == "\n" || scalar == "\r" || scalar == "\t" {
                return " "
            }
            return scalar
        }
        return String(String.UnicodeScalarView(scalars))
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func text(_ value: String, maximumCharacters: Int) -> String {
        String(normalized(value).prefix(max(0, maximumCharacters)))
    }

    static func identifier(_ value: String) -> String {
        text(value, maximumCharacters: AgentLokiEvidenceLimits.maximumIdentifierCharacters)
    }

    static func classification(_ value: String) -> String {
        let normalizedValue = normalized(value).lowercased()
        let allowed = normalizedValue.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" || $0 == "."
        }
        let result = String(String.UnicodeScalarView(allowed))
        return String((result.isEmpty ? "unknown" : result).prefix(80))
    }

    static func reasonCode(_ value: String) -> String {
        let classified = classification(value)
        return classified == "unknown" ? "agent_loki_reason_invalid" : classified
    }

    static func directSourceURL(_ value: URL?) -> URL? {
        guard let value,
              value.absoluteString.count <= AgentLokiEvidenceLimits.maximumURLCharacters,
              var components = URLComponents(url: value, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              components.host?.isEmpty == false,
              components.user == nil,
              components.password == nil
        else { return nil }
        components.fragment = nil
        return components.url
    }

    static func canonicalDate(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }

    static func hostileSignals(in value: String) -> [AgentLokiHostileSourceSignal] {
        let lowered = normalized(value).lowercased()
        var signals: Set<AgentLokiHostileSourceSignal> = []
        if containsAny(lowered, [
            "ignore previous", "ignore all previous", "system message",
            "higher priority instruction", "developer message",
        ]) {
            signals.insert(.authorityOverride)
        }
        if containsAny(lowered, [
            "tool_call", "function_call", "\"tool\"", "<tool", "invoke tool", "call the tool",
        ]) || (lowered.contains("\"name\"") && lowered.contains("\"arguments\"")) {
            signals.insert(.toolImpersonation)
        }
        if containsAny(lowered, [
            "api key", "access token", "password", "private key", "credential",
        ]) {
            signals.insert(.credentialRequest)
        }
        if containsAny(lowered, [
            "send a message", "delete the", "write to", "run shell", "open terminal",
            "make a network request",
        ]) {
            signals.insert(.externalActionRequest)
        }
        if containsAny(lowered, [
            "do not cite", "omit citations", "hide the source", "suppress evidence",
        ]) {
            signals.insert(.citationSuppression)
        }
        if containsAny(lowered, [
            "remember this", "store in memory", "forget the system", "update your memory",
        ]) {
            signals.insert(.memoryInstruction)
        }
        if containsAny(lowered, ["base64", "decode this", "\\u00", "&#x"]) {
            signals.insert(.encodedInstructionLikeText)
        }
        return signals.sorted { $0.rawValue < $1.rawValue }
    }

    private static func containsAny(_ value: String, _ candidates: [String]) -> Bool {
        candidates.contains(where: value.contains)
    }
}
