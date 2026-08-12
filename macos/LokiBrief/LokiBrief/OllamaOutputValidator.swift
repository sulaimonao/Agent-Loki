import Foundation

struct OllamaOutputValidator: Sendable {
    static let schemaVersion = "loki.ollama.brief-summary.v1"

    func jsonSchema(for input: OllamaGenerationInput) -> [String: Any] {
        let sectionIDs = input.allowedSectionIDs
        let itemIDs = input.selectedItems.map(\.id)
        let itemSummaryLimit = input.includeItemSummaries
            ? min(itemIDs.count, OllamaProviderLimits.maximumGeneratedItemSummaries)
            : 0

        return [
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "type": "object",
            "additionalProperties": false,
            "required": [
                "schema_version",
                "brief_id",
                "overall_summary",
                "section_summaries",
                "item_summaries"
            ],
            "properties": [
                "schema_version": [
                    "type": "string",
                    "const": Self.schemaVersion
                ],
                "brief_id": [
                    "type": "string",
                    "const": input.deterministicBriefID
                ],
                "overall_summary": [
                    "type": "string",
                    "minLength": 1,
                    "maxLength": OllamaProviderLimits.maximumSummaryCharacters
                ],
                "section_summaries": [
                    "type": "array",
                    "maxItems": sectionIDs.count,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["section_id", "summary"],
                        "properties": [
                            "section_id": ["type": "string", "enum": sectionIDs],
                            "summary": [
                                "type": "string",
                                "minLength": 1,
                                "maxLength": OllamaProviderLimits.maximumSummaryCharacters
                            ]
                        ]
                    ]
                ],
                "item_summaries": [
                    "type": "array",
                    "maxItems": itemSummaryLimit,
                    "items": [
                        "type": "object",
                        "additionalProperties": false,
                        "required": ["item_id", "section_id", "summary"],
                        "properties": [
                            "item_id": ["type": "string", "enum": itemIDs],
                            "section_id": ["type": "string", "enum": sectionIDs],
                            "summary": [
                                "type": "string",
                                "minLength": 1,
                                "maxLength": OllamaProviderLimits.maximumSummaryCharacters
                            ]
                        ]
                    ]
                ]
            ]
        ]
    }

    func validate(_ responseText: String, for input: OllamaGenerationInput) throws -> OllamaValidatedSummary {
        guard Set(input.allowedSectionIDs).count == input.allowedSectionIDs.count,
              Set(input.selectedItems.map(\.id)).count == input.selectedItems.count
        else {
            throw OllamaFailure(.outputDuplicateIdentifier)
        }
        guard let data = responseText.data(using: .utf8),
              data.count <= OllamaProviderLimits.maximumResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any]
        else {
            throw OllamaFailure(.outputSchemaInvalid)
        }

        try requireExactKeys(
            root,
            expected: ["schema_version", "brief_id", "overall_summary", "section_summaries", "item_summaries"]
        )

        guard let schemaVersion = root["schema_version"] as? String,
              schemaVersion == Self.schemaVersion,
              let briefID = root["brief_id"] as? String,
              let overall = root["overall_summary"] as? String,
              let rawSectionSummaries = root["section_summaries"] as? [[String: Any]],
              let rawItemSummaries = root["item_summaries"] as? [[String: Any]]
        else {
            throw OllamaFailure(.outputSchemaInvalid)
        }

        guard briefID == input.deterministicBriefID else {
            throw OllamaFailure(.outputBriefMismatch)
        }

        let normalizedOverall = try validatedSummaryText(overall)
        let allowedSectionIDs = Set(input.allowedSectionIDs)
        var evidenceByID: [String: OllamaEvidenceItem] = [:]
        for item in input.selectedItems { evidenceByID[item.id] = item }

        guard rawSectionSummaries.count <= allowedSectionIDs.count else {
            throw OllamaFailure(.outputSchemaInvalid)
        }

        var sectionSummariesByID: [String: OllamaSectionSummary] = [:]
        for raw in rawSectionSummaries {
            try requireExactKeys(raw, expected: ["section_id", "summary"])
            guard let sectionID = raw["section_id"] as? String,
                  let summary = raw["summary"] as? String
            else {
                throw OllamaFailure(.outputSchemaInvalid)
            }
            guard allowedSectionIDs.contains(sectionID) else {
                throw OllamaFailure(.outputUnknownSection)
            }
            guard sectionSummariesByID[sectionID] == nil else {
                throw OllamaFailure(.outputDuplicateIdentifier)
            }
            sectionSummariesByID[sectionID] = .init(
                sectionID: sectionID,
                summary: try validatedSummaryText(summary)
            )
        }

        let allowedItemSummaryCount = input.includeItemSummaries
            ? min(input.selectedItems.count, OllamaProviderLimits.maximumGeneratedItemSummaries)
            : 0
        guard rawItemSummaries.count <= allowedItemSummaryCount else {
            throw OllamaFailure(.outputSchemaInvalid)
        }

        var itemSummariesByID: [String: OllamaItemSummary] = [:]
        for raw in rawItemSummaries {
            try requireExactKeys(raw, expected: ["item_id", "section_id", "summary"])
            guard let itemID = raw["item_id"] as? String,
                  let sectionID = raw["section_id"] as? String,
                  let summary = raw["summary"] as? String
            else {
                throw OllamaFailure(.outputSchemaInvalid)
            }
            guard let evidence = evidenceByID[itemID] else {
                throw OllamaFailure(.outputUnknownItem)
            }
            guard allowedSectionIDs.contains(sectionID), evidence.sectionID == sectionID else {
                throw OllamaFailure(.outputUnknownSection)
            }
            guard itemSummariesByID[itemID] == nil else {
                throw OllamaFailure(.outputDuplicateIdentifier)
            }
            itemSummariesByID[itemID] = .init(
                itemID: itemID,
                sectionID: sectionID,
                summary: try validatedSummaryText(summary)
            )
        }

        // Preserve deterministic brief order; model output never controls presentation order.
        let orderedSectionSummaries = input.allowedSectionIDs.compactMap { sectionSummariesByID[$0] }
        let orderedItemSummaries = input.selectedItems.compactMap { itemSummariesByID[$0.id] }

        return .init(
            schemaVersion: schemaVersion,
            deterministicBriefID: briefID,
            overallSummary: normalizedOverall,
            sectionSummaries: orderedSectionSummaries,
            itemSummaries: orderedItemSummaries
        )
    }

    private func requireExactKeys(_ object: [String: Any], expected: Set<String>) throws {
        guard Set(object.keys) == expected else {
            throw OllamaFailure(.outputSchemaInvalid)
        }
    }

    private func validatedSummaryText(_ text: String) throws -> String {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else {
            throw OllamaFailure(.outputSchemaInvalid)
        }
        guard normalized.count <= OllamaProviderLimits.maximumSummaryCharacters else {
            throw OllamaFailure(.outputTooLong)
        }
        guard normalized.range(
            of: #"(?i)\b(?:[a-z][a-z0-9+.-]{1,20}://|www\.)[^\s<>\"']+"#,
            options: .regularExpression
        ) == nil else {
            throw OllamaFailure(.outputInventedURL)
        }
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           detector.firstMatch(
               in: normalized,
               options: [],
               range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
           ) != nil {
            throw OllamaFailure(.outputInventedURL)
        }
        return normalized
    }
}
