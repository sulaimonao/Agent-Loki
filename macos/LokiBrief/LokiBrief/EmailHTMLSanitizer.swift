import Foundation

struct EmailHTMLSanitizationResult: Codable, Hashable, Sendable {
    let text: String
    let suppressedActiveContentCount: Int
    let suppressedRemoteResourceCount: Int
}

struct EmailHTMLSanitizer: Sendable {
    private static let suppressedContentTags: Set<String> = [
        "script", "style", "noscript", "iframe", "object", "embed",
        "svg", "math", "canvas", "template", "head",
    ]
    private static let remoteOnlyTags: Set<String> = [
        "img", "source", "track", "link", "meta",
    ]
    private static let blockTags: Set<String> = [
        "address", "article", "aside", "blockquote", "br", "div", "dl",
        "dt", "dd", "fieldset", "figcaption", "figure", "footer", "form",
        "h1", "h2", "h3", "h4", "h5", "h6", "header", "hr", "li",
        "main", "nav", "ol", "p", "pre", "section", "table", "tbody",
        "td", "tfoot", "th", "thead", "tr", "ul",
    ]

    func sanitize(_ html: String) -> EmailHTMLSanitizationResult {
        // The non-throwing convenience is retained for direct presentation and
        // focused sanitizer use. Import parsing uses the cancellable overload.
        (try? sanitize(html, isCancelled: { false })) ?? .init(
            text: "",
            suppressedActiveContentCount: 0,
            suppressedRemoteResourceCount: 0
        )
    }

    func sanitize(
        _ html: String,
        isCancelled: @escaping @Sendable () -> Bool
    ) throws -> EmailHTMLSanitizationResult {
        let bounded = String(html.prefix(EmailImportLimits.maximumTextBytes))
        var output = ""
        output.reserveCapacity(min(bounded.count, EmailImportLimits.maximumTextBytes))
        var activeStack: [String] = []
        var activeCount = 0
        var remoteCount = 0
        var index = bounded.startIndex
        var examinedCharacters = 0
        var nextCancellationCheck = 0

        while index < bounded.endIndex {
            if examinedCharacters >= nextCancellationCheck {
                if isCancelled() { throw EmailImportFailureCode.cancelled }
                nextCancellationCheck = examinedCharacters + 4_096
            }
            if bounded[index...].hasPrefix("<!--") {
                activeCount += 1
                if let end = bounded[index...].range(of: "-->")?.upperBound {
                    index = end
                } else {
                    break
                }
                examinedCharacters += 4
                continue
            }

            guard bounded[index] == "<" else {
                let next = bounded[index...].firstIndex(of: "<") ?? bounded.endIndex
                if activeStack.isEmpty {
                    output.append(Self.decodeEntities(String(bounded[index..<next])))
                }
                examinedCharacters += bounded.distance(from: index, to: next)
                index = next
                continue
            }

            guard let tagEnd = Self.tagEnd(in: bounded, from: index) else {
                if activeStack.isEmpty { output.append(" ") }
                break
            }
            let contentStart = bounded.index(after: index)
            let rawTag = String(bounded[contentStart..<tagEnd])
            examinedCharacters += bounded.distance(from: index, to: tagEnd) + 1
            index = bounded.index(after: tagEnd)

            let parsed = Self.parseTag(rawTag)
            guard !parsed.name.isEmpty else { continue }

            if !activeStack.isEmpty {
                if parsed.isClosing {
                    if let matching = activeStack.lastIndex(of: parsed.name) {
                        activeStack.removeSubrange(matching...)
                    }
                } else if Self.suppressedContentTags.contains(parsed.name), !parsed.isSelfClosing {
                    activeStack.append(parsed.name)
                    activeCount += 1
                }
                continue
            }

            if Self.suppressedContentTags.contains(parsed.name) {
                activeCount += 1
                if !parsed.isClosing && !parsed.isSelfClosing {
                    activeStack.append(parsed.name)
                }
                Self.appendBoundary(to: &output)
                continue
            }

            if Self.remoteOnlyTags.contains(parsed.name) {
                if parsed.name == "img" || parsed.name == "source" || Self.containsRemoteReference(rawTag) {
                    remoteCount += 1
                }
                continue
            }

            // All attributes, including event handlers, href, src, style, and
            // tracking parameters, are discarded. Only visible child text is
            // retained, so dangerous URL schemes cannot cross this boundary.
            if Self.blockTags.contains(parsed.name) {
                Self.appendBoundary(to: &output)
            }
        }

        if isCancelled() { throw EmailImportFailureCode.cancelled }
        let normalized = Self.normalizedVisibleText(output)
        return .init(
            text: normalized,
            suppressedActiveContentCount: activeCount,
            suppressedRemoteResourceCount: remoteCount
        )
    }

    private static func tagEnd(in html: String, from opening: String.Index) -> String.Index? {
        var cursor = html.index(after: opening)
        var quote: Character?
        while cursor < html.endIndex {
            let character = html[cursor]
            if let currentQuote = quote {
                if character == currentQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return cursor
            }
            cursor = html.index(after: cursor)
        }
        return nil
    }

    private static func parseTag(_ raw: String) -> (name: String, isClosing: Bool, isSelfClosing: Bool) {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.hasPrefix("!") && !value.hasPrefix("?") else {
            return ("", false, true)
        }
        let isClosing = value.hasPrefix("/")
        if isClosing { value.removeFirst() }
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = value.prefix { character in
            character.isLetter || character.isNumber || character == "-" || character == ":"
        }.lowercased()
        return (name, isClosing, value.hasSuffix("/"))
    }

    private static func containsRemoteReference(_ rawTag: String) -> Bool {
        let value = rawTag.lowercased()
        return value.contains("http://")
            || value.contains("https://")
            || value.contains("src=\"//")
            || value.contains("src='//")
            || value.contains("src=//")
    }

    private static func appendBoundary(to output: inout String) {
        guard output.last?.isWhitespace != true else { return }
        output.append(" ")
    }

    private static func normalizedVisibleText(_ value: String) -> String {
        let safe = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0)
                || $0 == "\n" || $0 == "\r" || $0 == "\t"
        })
        return safe.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func decodeEntities(_ value: String) -> String {
        var result = ""
        var index = value.startIndex
        while index < value.endIndex {
            guard value[index] == "&",
                  let semicolon = value[index...].firstIndex(of: ";"),
                  value.distance(from: index, to: semicolon) <= 16
            else {
                result.append(value[index])
                index = value.index(after: index)
                continue
            }
            let entityStart = value.index(after: index)
            let entity = String(value[entityStart..<semicolon])
            if let decoded = decodeEntity(entity) {
                result.append(decoded)
                index = value.index(after: semicolon)
            } else {
                result.append("&")
                index = entityStart
            }
        }
        return result
    }

    private static func decodeEntity(_ entity: String) -> String? {
        switch entity.lowercased() {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos", "#39": return "'"
        case "nbsp": return " "
        case "ndash": return "–"
        case "mdash": return "—"
        case "hellip": return "…"
        default:
            let scalarValue: UInt32?
            if entity.lowercased().hasPrefix("#x") {
                scalarValue = UInt32(entity.dropFirst(2), radix: 16)
            } else if entity.hasPrefix("#") {
                scalarValue = UInt32(entity.dropFirst(), radix: 10)
            } else {
                scalarValue = nil
            }
            guard let scalarValue,
                  let scalar = UnicodeScalar(scalarValue),
                  !CharacterSet.controlCharacters.contains(scalar)
            else { return nil }
            return String(scalar)
        }
    }
}
