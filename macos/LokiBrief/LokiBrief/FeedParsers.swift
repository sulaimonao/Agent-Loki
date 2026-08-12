import Foundation

struct FeedParser: Sendable {
    func parse(_ data: Data, sourceURL: URL) throws -> FeedParseResult {
        guard !data.isEmpty else { throw FeedFetchFailure(.emptyResponse) }
        guard data.count <= FeedLimits.maximumParserBytes else { throw FeedFetchFailure(.responseTooLarge) }
        let first = data.first { byte in ![9, 10, 13, 32].contains(byte) }
        if first == Character("{").asciiValue || first == Character("[").asciiValue {
            return try parseJSON(data, sourceURL: sourceURL)
        }
        return try parseXML(data, sourceURL: sourceURL)
    }

    private func parseJSON(_ data: Data, sourceURL: URL) throws -> FeedParseResult {
        let decoded: JSONFeedDocument
        do { decoded = try JSONDecoder().decode(JSONFeedDocument.self, from: data) }
        catch { throw FeedFetchFailure(.malformedJSON) }
        let version = decoded.version.lowercased()
        guard version == "https://jsonfeed.org/version/1" || version == "https://jsonfeed.org/version/1.1" || version == "http://jsonfeed.org/version/1" || version == "http://jsonfeed.org/version/1.1" else {
            throw FeedFetchFailure(.unsupportedFormat)
        }
        let feedTitle = FeedTextSanitizer.plainText(decoded.title, maximumCharacters: FeedLimits.maximumTitleCharacters)
        guard !feedTitle.isEmpty else { throw FeedFetchFailure(.malformedJSON) }
        guard !decoded.items.isEmpty else { throw FeedFetchFailure(.noEntries) }
        guard decoded.items.count <= FeedLimits.maximumParsedEntries else { throw FeedFetchFailure(.parserLimitExceeded) }
        let entries = decoded.items.enumerated().map { position, item in
            let author = item.authors?.compactMap(\.name).first ?? item.author?.name
            return ParsedFeedEntry(
                title: item.title,
                summary: item.summary ?? item.contentText ?? item.contentHTML,
                url: resolvedURL(item.url ?? item.externalURL, relativeTo: sourceURL),
                author: author,
                publishedAt: FeedDateParser.date(item.datePublished),
                updatedAt: FeedDateParser.date(item.dateModified),
                upstreamIdentifier: item.id,
                originalPosition: position
            )
        }
        return .init(format: .jsonFeed11, feedTitle: feedTitle, entries: entries, warnings: [])
    }

    private func parseXML(_ data: Data, sourceURL: URL) throws -> FeedParseResult {
        let probe = String(decoding: data, as: UTF8.self).lowercased()
        if probe.contains("<!doctype") || probe.contains("<!entity") {
            throw FeedFetchFailure(.externalEntityRejected)
        }
        let delegate = XMLFeedDelegate(sourceURL: sourceURL)
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = true
        parser.shouldReportNamespacePrefixes = false
        parser.shouldResolveExternalEntities = false
        parser.externalEntityResolvingPolicy = .never
        let succeeded = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard succeeded else { throw FeedFetchFailure(.malformedXML) }
        guard let format = delegate.format else { throw FeedFetchFailure(.unsupportedFormat) }
        guard !delegate.entries.isEmpty else { throw FeedFetchFailure(.noEntries) }
        let title = FeedTextSanitizer.plainText(delegate.feedTitle, maximumCharacters: FeedLimits.maximumTitleCharacters)
        return .init(format: format, feedTitle: title.isEmpty ? sourceURL.host ?? "Feed" : title, entries: delegate.entries, warnings: delegate.warnings)
    }

    private func resolvedURL(_ value: String?, relativeTo base: URL) -> URL? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return URL(string: value, relativeTo: base)?.absoluteURL
    }
}

private final class XMLFeedDelegate: NSObject, XMLParserDelegate {
    struct Builder {
        var title: String?
        var summary: String?
        var url: URL?
        var author: String?
        var publishedAt: Date?
        var updatedAt: Date?
        var upstreamIdentifier: String?
        var position: Int
    }

    let sourceURL: URL
    var format: FeedFormat?
    var feedTitle: String?
    var entries: [ParsedFeedEntry] = []
    var warnings: [String] = []
    var failure: FeedFetchFailure?

    private var elementNames: [String] = []
    private var textBuffers: [String] = []
    private var current: Builder?
    private var totalTextCharacters = 0

    init(sourceURL: URL) { self.sourceURL = sourceURL }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = normalized(elementName.isEmpty ? qName ?? "" : elementName)
        if elementNames.count >= FeedLimits.maximumXMLDepth {
            reject(parser, .parserLimitExceeded)
            return
        }
        elementNames.append(name)
        textBuffers.append("")

        if elementNames.count == 1 {
            if name == "rss" || name == "rdf" { format = .rss2 }
            else if name == "feed" { format = .atom1 }
            else { reject(parser, .unsupportedFormat) }
        }
        if name == "item" || name == "entry" {
            guard entries.count < FeedLimits.maximumParsedEntries else { reject(parser, .parserLimitExceeded); return }
            current = Builder(position: entries.count)
        }
        if name == "link", current != nil, format == .atom1 {
            let relation = attributeDict.first { normalized($0.key) == "rel" }?.value.lowercased()
            if relation == nil || relation == "alternate" {
                let href = attributeDict.first { normalized($0.key) == "href" }?.value
                if let href, let url = URL(string: href, relativeTo: sourceURL)?.absoluteURL { current?.url = url }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { append(string, parser: parser) }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { append(String(decoding: CDATABlock, as: UTF8.self), parser: parser) }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard !elementNames.isEmpty, !textBuffers.isEmpty else { return }
        let name = normalized(elementName.isEmpty ? qName ?? "" : elementName)
        let text = textBuffers.removeLast()
        _ = elementNames.removeLast()
        if !textBuffers.isEmpty { textBuffers[textBuffers.count - 1].append(" "); textBuffers[textBuffers.count - 1].append(text) }

        if name == "item" || name == "entry" {
            if let current {
                entries.append(.init(
                    title: current.title,
                    summary: current.summary,
                    url: current.url,
                    author: current.author,
                    publishedAt: current.publishedAt,
                    updatedAt: current.updatedAt,
                    upstreamIdentifier: current.upstreamIdentifier,
                    originalPosition: current.position
                ))
            }
            current = nil
            return
        }

        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if current != nil {
            switch name {
            case "title": if current?.title == nil { current?.title = value }
            case "description", "summary", "content", "encoded": if current?.summary == nil { current?.summary = value }
            case "link":
                if current?.url == nil, let url = URL(string: value, relativeTo: sourceURL)?.absoluteURL { current?.url = url }
            case "guid", "id": if current?.upstreamIdentifier == nil { current?.upstreamIdentifier = value }
            case "author", "creator", "name": if current?.author == nil { current?.author = value }
            case "pubdate", "published", "date": if current?.publishedAt == nil { current?.publishedAt = FeedDateParser.date(value) }
            case "updated", "modified": if current?.updatedAt == nil { current?.updatedAt = FeedDateParser.date(value) }
            default: break
            }
        } else if name == "title", feedTitle == nil {
            feedTitle = value
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if failure == nil { failure = .init(.malformedXML) }
    }

    func parser(_ parser: XMLParser, validationErrorOccurred validationError: Error) {
        if failure == nil { failure = .init(.malformedXML) }
    }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) { reject(parser, .externalEntityRejected) }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) { reject(parser, .externalEntityRejected) }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?, notationName: String?) { reject(parser, .externalEntityRejected) }
    func parser(_ parser: XMLParser, resolveExternalEntityName name: String, systemID: String?) -> Data? { reject(parser, .externalEntityRejected); return nil }

    private func append(_ value: String, parser: XMLParser) {
        guard !textBuffers.isEmpty else { return }
        if totalTextCharacters > FeedLimits.maximumTextCharacters * FeedLimits.maximumParsedEntries - value.count {
            reject(parser, .parserLimitExceeded)
            return
        }
        totalTextCharacters += value.count
        textBuffers[textBuffers.count - 1].append(value)
    }

    private func reject(_ parser: XMLParser, _ code: FeedFetchFailureCode) {
        if failure == nil { failure = .init(code) }
        parser.abortParsing()
    }

    private func normalized(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
    }
}

private enum FeedDateParser {
    static func date(_ value: String?) -> Date? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: value) { return date }
        }
        return nil
    }
}

private struct JSONFeedDocument: Decodable {
    let version: String
    let title: String
    let items: [JSONFeedItem]
}

private struct JSONFeedAuthor: Decodable { let name: String? }

private struct JSONFeedItem: Decodable {
    let id: String?
    let url: String?
    let externalURL: String?
    let title: String?
    let contentText: String?
    let contentHTML: String?
    let summary: String?
    let datePublished: String?
    let dateModified: String?
    let authors: [JSONFeedAuthor]?
    let author: JSONFeedAuthor?

    enum CodingKeys: String, CodingKey {
        case id, url, title, summary, authors, author
        case externalURL = "external_url"
        case contentText = "content_text"
        case contentHTML = "content_html"
        case datePublished = "date_published"
        case dateModified = "date_modified"
    }
}
