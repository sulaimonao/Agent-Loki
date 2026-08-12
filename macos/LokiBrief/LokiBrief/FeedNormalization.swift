import CryptoKit
import Foundation

enum FeedTextSanitizer {
    static func plainText(_ input: String?, maximumCharacters: Int = FeedLimits.maximumTextCharacters) -> String {
        guard var value = input, !value.isEmpty else { return "" }
        value = replacing(pattern: #"(?is)<(script|style|iframe|object|embed)\b[^>]*>.*?</\1\s*>"#, in: value, with: " ")
        value = replacing(pattern: #"(?s)<[^>]*>"#, in: value, with: " ")
        let entities = [
            "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"",
            "&#39;": "'", "&apos;": "'", "&nbsp;": " "
        ]
        for (entity, replacement) in entities { value = value.replacingOccurrences(of: entity, with: replacement) }
        value = replacing(pattern: #"&#(?:x[0-9A-Fa-f]+|[0-9]+);"#, in: value, with: " ")
        value = value.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }.map(String.init).joined()
        value = replacing(pattern: #"\s+"#, in: value, with: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return String(value.prefix(max(0, maximumCharacters)))
    }

    private static func replacing(pattern: String, in value: String, with replacement: String) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.stringByReplacingMatches(in: value, range: range, withTemplate: replacement)
    }
}

struct FeedNormalizer: Sendable {
    func normalize(_ result: FeedParseResult, subscription: FeedSubscription, retrievedAt: Date) -> [NormalizedFeedEntry] {
        var deduplicated: [NormalizedFeedEntry] = []
        for raw in result.entries.prefix(FeedLimits.maximumParsedEntries) {
            let summary = FeedTextSanitizer.plainText(raw.summary)
            let suppliedTitle = FeedTextSanitizer.plainText(raw.title, maximumCharacters: FeedLimits.maximumTitleCharacters)
            let title = suppliedTitle.isEmpty ? fallbackTitle(from: summary) : suppliedTitle
            let canonicalURL = canonicalItemURL(raw.url)
            let author = optional(FeedTextSanitizer.plainText(raw.author, maximumCharacters: FeedLimits.maximumAuthorCharacters))
            let upstreamIdentifier = optional(FeedTextSanitizer.plainText(raw.upstreamIdentifier, maximumCharacters: 2_000))
            let identity = makeIdentity(
                subscriptionID: subscription.id,
                upstreamIdentifier: upstreamIdentifier,
                canonicalURL: canonicalURL,
                title: title,
                publishedAt: raw.publishedAt,
                summary: summary
            )
            let entry = NormalizedFeedEntry(
                id: identity.value,
                identity: identity,
                subscriptionID: subscription.id,
                sourceTitle: subscription.title,
                title: title,
                summary: summary.isEmpty ? "No summary supplied by this feed." : summary,
                canonicalURL: canonicalURL,
                author: author,
                publishedAt: raw.publishedAt,
                updatedAt: raw.updatedAt,
                retrievedAt: retrievedAt,
                originalPosition: max(0, raw.originalPosition),
                provenance: .init(
                    subscriptionID: subscription.id,
                    feedURL: subscription.canonicalURL,
                    format: result.format,
                    upstreamIdentifier: upstreamIdentifier,
                    retrievedAt: retrievedAt,
                    originalPosition: max(0, raw.originalPosition)
                )
            )

            let matchingIndices = deduplicated.indices.filter { index in
                let existing = deduplicated[index]
                return existing.id == entry.id || (
                    existing.canonicalURL != nil &&
                    existing.canonicalURL == entry.canonicalURL
                )
            }
            guard !matchingIndices.isEmpty else {
                deduplicated.append(entry)
                continue
            }

            let winner = matchingIndices.map { deduplicated[$0] }.reduce(entry, preferredEntry)
            for index in matchingIndices.reversed() { deduplicated.remove(at: index) }
            deduplicated.append(winner)
        }
        return deduplicated.sorted {
            if $0.originalPosition != $1.originalPosition { return $0.originalPosition < $1.originalPosition }
            return $0.id < $1.id
        }
    }

    private func fallbackTitle(from summary: String) -> String {
        let prefix = String(summary.prefix(100)).trimmingCharacters(in: .whitespacesAndNewlines)
        return prefix.isEmpty ? "Untitled feed item" : prefix
    }

    private func optional(_ value: String) -> String? { value.isEmpty ? nil : value }

    private func preferredEntry(_ first: NormalizedFeedEntry, _ second: NormalizedFeedEntry) -> NormalizedFeedEntry {
        let firstDate = first.updatedAt ?? first.publishedAt ?? .distantPast
        let secondDate = second.updatedAt ?? second.publishedAt ?? .distantPast
        if firstDate != secondDate { return firstDate > secondDate ? first : second }
        if first.originalPosition != second.originalPosition {
            return first.originalPosition < second.originalPosition ? first : second
        }
        return first.id <= second.id ? first : second
    }

    private func canonicalItemURL(_ input: URL?) -> URL? {
        guard let input, var components = URLComponents(url: input, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { return nil }
        components.scheme = "https"
        components.host = host
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        return components.url
    }

    private func makeIdentity(subscriptionID: String, upstreamIdentifier: String?, canonicalURL: URL?, title: String, publishedAt: Date?, summary: String) -> FeedEntryIdentity {
        if let upstreamIdentifier {
            return .init(value: digest("id\u{1f}\(subscriptionID)\u{1f}\(upstreamIdentifier)"), basis: .upstreamIdentifier)
        }
        if let canonicalURL {
            return .init(value: digest("url\u{1f}\(subscriptionID)\u{1f}\(canonicalURL.absoluteString)"), basis: .canonicalURL)
        }
        let normalizedTitle = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        if let publishedAt {
            return .init(value: digest("title-date\u{1f}\(subscriptionID)\u{1f}\(normalizedTitle)\u{1f}\(Int(publishedAt.timeIntervalSince1970))"), basis: .titleAndDate)
        }
        return .init(value: digest("fallback\u{1f}\(subscriptionID)\u{1f}\(normalizedTitle)\u{1f}\(summary.prefix(256))"), basis: .boundedFallback)
    }

    private func digest(_ value: String) -> String {
        let digest = SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
        return "feed-entry-\(digest)"
    }
}

extension FeedSubscription {
    static func syntacticallyCanonicalURL(_ input: URL) -> URL? {
        guard var components = URLComponents(url: input, resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.fragment = nil
        if components.port == 443 { components.port = nil }
        if components.path.isEmpty { components.path = "/" }
        return components.url
    }

    static func stableIdentifier(for canonicalURL: URL) -> String {
        let material = syntacticallyCanonicalURL(canonicalURL)?.absoluteString ?? canonicalURL.absoluteString
        let digest = SHA256.hash(data: Data(material.utf8)).map { String(format: "%02x", $0) }.joined()
        return "feed-\(digest)"
    }
}
