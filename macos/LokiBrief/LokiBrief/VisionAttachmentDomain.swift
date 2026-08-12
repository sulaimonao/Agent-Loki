import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum VisionAttachmentLimits {
    public static let maximumAttachmentCount = 8
    public static let maximumPerImageBytes = 12 * 1_024 * 1_024
    public static let maximumTotalBytes = 32 * 1_024 * 1_024
    public static let maximumPixelDimension = 8_192
    public static let maximumDecodedPixels = 40_000_000
    public static let maximumThumbnailPixelDimension = 320
}

struct VisionAttachmentPolicy: Hashable, Sendable {
    let maximumAttachmentCount: Int
    let maximumPerImageBytes: Int
    let maximumTotalBytes: Int
    let maximumPixelDimension: Int
    let maximumDecodedPixels: Int
    let maximumThumbnailPixelDimension: Int

    static let `default` = VisionAttachmentPolicy()

    init(
        maximumAttachmentCount: Int = VisionAttachmentLimits.maximumAttachmentCount,
        maximumPerImageBytes: Int = VisionAttachmentLimits.maximumPerImageBytes,
        maximumTotalBytes: Int = VisionAttachmentLimits.maximumTotalBytes,
        maximumPixelDimension: Int = VisionAttachmentLimits.maximumPixelDimension,
        maximumDecodedPixels: Int = VisionAttachmentLimits.maximumDecodedPixels,
        maximumThumbnailPixelDimension: Int = VisionAttachmentLimits.maximumThumbnailPixelDimension
    ) {
        self.maximumAttachmentCount = max(
            1,
            min(maximumAttachmentCount, VisionAttachmentLimits.maximumAttachmentCount)
        )
        self.maximumPerImageBytes = max(
            1,
            min(maximumPerImageBytes, VisionAttachmentLimits.maximumPerImageBytes)
        )
        self.maximumTotalBytes = max(
            self.maximumPerImageBytes,
            min(maximumTotalBytes, VisionAttachmentLimits.maximumTotalBytes)
        )
        self.maximumPixelDimension = max(
            1,
            min(maximumPixelDimension, VisionAttachmentLimits.maximumPixelDimension)
        )
        self.maximumDecodedPixels = max(
            self.maximumPixelDimension,
            min(maximumDecodedPixels, VisionAttachmentLimits.maximumDecodedPixels)
        )
        self.maximumThumbnailPixelDimension = max(
            1,
            min(
                maximumThumbnailPixelDimension,
                VisionAttachmentLimits.maximumThumbnailPixelDimension
            )
        )
    }
}

enum VisionAttachmentSource: String, Codable, CaseIterable, Hashable, Sendable {
    case filePicker = "file_picker"
    case dragAndDrop = "drag_and_drop"
    case clipboardPaste = "clipboard_paste"
}

enum VisionAttachmentFormat: String, Codable, CaseIterable, Hashable, Sendable {
    case png
    case jpeg
    case heic
    case heif

    var preferredFilenameExtension: String {
        switch self {
        case .png: "png"
        case .jpeg: "jpg"
        case .heic: "heic"
        case .heif: "heif"
        }
    }

    fileprivate var modelFormat: VisionAttachmentFormat {
        switch self {
        case .png: .png
        case .jpeg, .heic, .heif: .jpeg
        }
    }

    fileprivate var imageDestinationType: CFString {
        switch self {
        case .png:
            UTType.png.identifier as CFString
        case .jpeg, .heic, .heif:
            UTType.jpeg.identifier as CFString
        }
    }

    fileprivate static func from(typeIdentifier: String) -> VisionAttachmentFormat? {
        let normalized = typeIdentifier.lowercased()
        switch normalized {
        case UTType.png.identifier.lowercased():
            return .png
        case UTType.jpeg.identifier.lowercased(), "public.jpg":
            return .jpeg
        case UTType.heic.identifier.lowercased(), "public.heics":
            return .heic
        case "public.heif", "public.heifs":
            return .heif
        default:
            return nil
        }
    }

    fileprivate func isCompatible(with other: VisionAttachmentFormat) -> Bool {
        if self == other { return true }
        return Set([self, other]).isSubset(of: Set([.heic, .heif]))
    }
}

struct VisionAttachmentInput: Hashable, Sendable {
    let id: UUID
    let source: VisionAttachmentSource
    let data: Data
    let declaredTypeIdentifier: String?
    let preferredFilename: String?

    init(
        id: UUID = UUID(),
        source: VisionAttachmentSource,
        data: Data,
        declaredTypeIdentifier: String? = nil,
        preferredFilename: String? = nil
    ) {
        self.id = id
        self.source = source
        self.data = data
        self.declaredTypeIdentifier = declaredTypeIdentifier
        self.preferredFilename = preferredFilename
    }
}

struct VisionPixelSize: Codable, Hashable, Sendable {
    let width: Int
    let height: Int
}

struct VisionAttachmentDescriptor: Identifiable, Hashable, Sendable {
    let id: UUID
    let source: VisionAttachmentSource
    let originalFormat: VisionAttachmentFormat
    let modelFormat: VisionAttachmentFormat
    let originalByteCount: Int
    let modelByteCount: Int
    let pixelSize: VisionPixelSize
    let thumbnailData: Data
    let accessibilityLabel: String
}

struct OllamaVisionImageMessagePayload: Codable, Hashable, Sendable {
    let role: OllamaChatRole
    let content: String
    let images: [String]
}

enum VisionAttachmentFailureCode: String, Codable, CaseIterable, Hashable, Sendable {
    case attachmentCountExceeded = "vision_attachment_count_exceeded"
    case perImageBytesExceeded = "vision_attachment_image_bytes_exceeded"
    case totalBytesExceeded = "vision_attachment_total_bytes_exceeded"
    case unsupportedFormat = "vision_attachment_format_unsupported"
    case declaredFormatMismatch = "vision_attachment_declared_format_mismatch"
    case multipleFramesUnsupported = "vision_attachment_multiple_frames_unsupported"
    case invalidPixelDimensions = "vision_attachment_pixel_dimensions_invalid"
    case pixelLimitExceeded = "vision_attachment_pixel_limit_exceeded"
    case decodeFailed = "vision_attachment_decode_failed"
    case metadataStrippingFailed = "vision_attachment_metadata_strip_failed"
    case thumbnailFailed = "vision_attachment_thumbnail_failed"
    case temporaryStorageFailed = "vision_attachment_temporary_storage_failed"
    case attachmentNotFound = "vision_attachment_not_found"
    case cancelled = "vision_attachment_cancelled"
    case workspaceClosed = "vision_attachment_workspace_closed"
}

struct VisionAttachmentFailure: Error, Codable, Hashable, Sendable, LocalizedError {
    let code: VisionAttachmentFailureCode

    init(_ code: VisionAttachmentFailureCode) {
        self.code = code
    }

    var reasonCode: String { code.rawValue }

    var errorDescription: String? {
        switch code {
        case .attachmentCountExceeded:
            "The image attachment count exceeds the local intake limit."
        case .perImageBytesExceeded:
            "One image exceeds the per-image byte limit."
        case .totalBytesExceeded:
            "The combined image attachments exceed the total byte limit."
        case .unsupportedFormat:
            "Only PNG, JPEG, HEIC, and HEIF images are supported."
        case .declaredFormatMismatch:
            "The declared image type does not match the decoded image."
        case .multipleFramesUnsupported:
            "Animated or multi-frame image input is not supported."
        case .invalidPixelDimensions:
            "The decoded image dimensions are invalid."
        case .pixelLimitExceeded:
            "The decoded image exceeds the pixel-dimension limit."
        case .decodeFailed:
            "The local image could not be decoded safely."
        case .metadataStrippingFailed:
            "The metadata-free model representation could not be created."
        case .thumbnailFailed:
            "The local image thumbnail could not be created."
        case .temporaryStorageFailed:
            "The protected temporary image representation is unavailable."
        case .attachmentNotFound:
            "The requested image attachment is no longer available."
        case .cancelled:
            "Image attachment processing was cancelled."
        case .workspaceClosed:
            "The image attachment workspace has already been cleared."
        }
    }
}

private struct VisionProcessedImage: Sendable {
    let originalFormat: VisionAttachmentFormat
    let modelFormat: VisionAttachmentFormat
    let modelData: Data
    let thumbnailData: Data
    let pixelSize: VisionPixelSize
}

private struct VisionImageProcessor: Sendable {
    func process(
        _ data: Data,
        declaredTypeIdentifier: String?,
        policy: VisionAttachmentPolicy
    ) throws -> VisionProcessedImage {
        try checkCancellation()
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false,
        ] as CFDictionary),
              let sourceType = CGImageSourceGetType(source) as String?,
              let originalFormat = VisionAttachmentFormat.from(typeIdentifier: sourceType)
        else {
            throw VisionAttachmentFailure(.unsupportedFormat)
        }
        guard CGImageSourceGetCount(source) == 1 else {
            throw VisionAttachmentFailure(.multipleFramesUnsupported)
        }
        if let declaredTypeIdentifier {
            guard let declaredFormat = VisionAttachmentFormat.from(
                typeIdentifier: declaredTypeIdentifier
            ) else {
                throw VisionAttachmentFailure(.unsupportedFormat)
            }
            guard declaredFormat.isCompatible(with: originalFormat) else {
                throw VisionAttachmentFailure(.declaredFormatMismatch)
            }
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(
            source,
            0,
            nil
        ) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0,
              height > 0
        else {
            throw VisionAttachmentFailure(.invalidPixelDimensions)
        }
        guard width <= policy.maximumPixelDimension,
              height <= policy.maximumPixelDimension,
              height <= policy.maximumDecodedPixels / width
        else {
            throw VisionAttachmentFailure(.pixelLimitExceeded)
        }

        try checkCancellation()
        let modelImage = try decodedImage(
            from: source,
            maximumPixelDimension: max(width, height),
            failure: .decodeFailed
        )
        try checkCancellation()
        let modelFormat = originalFormat.modelFormat
        let modelData = try encoded(
            modelImage,
            as: modelFormat,
            failure: .metadataStrippingFailed
        )
        let thumbnailImage = try decodedImage(
            from: source,
            maximumPixelDimension: policy.maximumThumbnailPixelDimension,
            failure: .thumbnailFailed
        )
        let thumbnailData = try encoded(
            thumbnailImage,
            as: .png,
            failure: .thumbnailFailed
        )
        try checkCancellation()
        return VisionProcessedImage(
            originalFormat: originalFormat,
            modelFormat: modelFormat,
            modelData: modelData,
            thumbnailData: thumbnailData,
            pixelSize: .init(width: modelImage.width, height: modelImage.height)
        )
    }

    private func decodedImage(
        from source: CGImageSource,
        maximumPixelDimension: Int,
        failure: VisionAttachmentFailureCode
    ) throws -> CGImage {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixelDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else {
            throw VisionAttachmentFailure(failure)
        }
        return image
    }

    private func encoded(
        _ image: CGImage,
        as format: VisionAttachmentFormat,
        failure: VisionAttachmentFailureCode
    ) throws -> Data {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            format.imageDestinationType,
            1,
            nil
        ) else {
            throw VisionAttachmentFailure(failure)
        }
        let properties: [CFString: Any]
        if format == .jpeg {
            properties = [
                kCGImageDestinationLossyCompressionQuality: 0.90,
            ]
        } else {
            properties = [:]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw VisionAttachmentFailure(failure)
        }
        return output as Data
    }

    private func checkCancellation() throws {
        guard !Task.isCancelled else {
            throw VisionAttachmentFailure(.cancelled)
        }
    }
}

private final class VisionAttachmentTemporaryScope: @unchecked Sendable {
    let directoryURL: URL

    private let fileManager = FileManager.default
    private var active = true

    init(baseDirectoryURL: URL, identifier: UUID) throws {
        directoryURL = baseDirectoryURL.appendingPathComponent(
            "agent-loki-vision-\(identifier.uuidString)",
            isDirectory: true
        )
        guard !fileManager.fileExists(atPath: directoryURL.path) else {
            throw VisionAttachmentFailure(.temporaryStorageFailed)
        }
        do {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: directoryURL.path
            )
        } catch {
            throw VisionAttachmentFailure(.temporaryStorageFailed)
        }
    }

    deinit {
        removeAll()
    }

    func write(_ data: Data, id: UUID, format: VisionAttachmentFormat) throws -> URL {
        guard active else {
            throw VisionAttachmentFailure(.workspaceClosed)
        }
        let url = directoryURL.appendingPathComponent(
            "\(id.uuidString).\(format.preferredFilenameExtension)",
            isDirectory: false
        )
        do {
            try data.write(to: url, options: [.atomic])
            try fileManager.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return url
        } catch {
            try? fileManager.removeItem(at: url)
            throw VisionAttachmentFailure(.temporaryStorageFailed)
        }
    }

    func read(_ url: URL) throws -> Data {
        guard active, isChild(url) else {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }
        do {
            return try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }
    }

    func remove(_ url: URL) throws {
        guard active, isChild(url) else {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }
        do {
            try fileManager.removeItem(at: url)
        } catch {
            throw VisionAttachmentFailure(.temporaryStorageFailed)
        }
    }

    func fileCount() -> Int {
        guard active else { return 0 }
        return (try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ).count) ?? 0
    }

    func removeAll() {
        guard active else { return }
        active = false
        try? fileManager.removeItem(at: directoryURL)
    }

    private func isChild(_ url: URL) -> Bool {
        url.deletingLastPathComponent().standardizedFileURL
            == directoryURL.standardizedFileURL
    }
}

actor VisionAttachmentWorkspace {
    private struct StoredAttachment {
        let descriptor: VisionAttachmentDescriptor
        let modelFileURL: URL
    }

    nonisolated let temporaryDirectoryURL: URL

    private let policy: VisionAttachmentPolicy
    private let processor = VisionImageProcessor()
    private let scope: VisionAttachmentTemporaryScope
    private var attachments: [UUID: StoredAttachment] = [:]
    private var order: [UUID] = []
    private var closed = false

    init(
        policy: VisionAttachmentPolicy = .default,
        baseTemporaryDirectoryURL: URL = FileManager.default.temporaryDirectory,
        scopeIdentifier: UUID = UUID()
    ) throws {
        self.policy = policy
        let newScope = try VisionAttachmentTemporaryScope(
            baseDirectoryURL: baseTemporaryDirectoryURL,
            identifier: scopeIdentifier
        )
        scope = newScope
        temporaryDirectoryURL = newScope.directoryURL
    }

    func add(_ inputs: [VisionAttachmentInput]) throws -> [VisionAttachmentDescriptor] {
        guard !closed else {
            throw VisionAttachmentFailure(.workspaceClosed)
        }
        try checkCancellation()
        guard !inputs.isEmpty,
              attachments.count + inputs.count <= policy.maximumAttachmentCount
        else {
            throw VisionAttachmentFailure(.attachmentCountExceeded)
        }
        guard Set(inputs.map(\.id)).count == inputs.count,
              inputs.allSatisfy({ attachments[$0.id] == nil })
        else {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }

        var originalTotal = attachments.values.reduce(0) {
            $0 + $1.descriptor.originalByteCount
        }
        for input in inputs {
            guard input.data.count <= policy.maximumPerImageBytes else {
                throw VisionAttachmentFailure(.perImageBytesExceeded)
            }
            guard originalTotal <= policy.maximumTotalBytes - input.data.count else {
                throw VisionAttachmentFailure(.totalBytesExceeded)
            }
            originalTotal += input.data.count
        }

        var pending: [StoredAttachment] = []
        do {
            var modelTotal = attachments.values.reduce(0) {
                $0 + $1.descriptor.modelByteCount
            }
            for input in inputs {
                try checkCancellation()
                let processed = try processor.process(
                    input.data,
                    declaredTypeIdentifier: input.declaredTypeIdentifier,
                    policy: policy
                )
                guard processed.modelData.count <= policy.maximumPerImageBytes else {
                    throw VisionAttachmentFailure(.perImageBytesExceeded)
                }
                guard modelTotal <= policy.maximumTotalBytes - processed.modelData.count else {
                    throw VisionAttachmentFailure(.totalBytesExceeded)
                }
                modelTotal += processed.modelData.count
                let fileURL = try scope.write(
                    processed.modelData,
                    id: input.id,
                    format: processed.modelFormat
                )
                let ordinal = attachments.count + pending.count + 1
                let descriptor = VisionAttachmentDescriptor(
                    id: input.id,
                    source: input.source,
                    originalFormat: processed.originalFormat,
                    modelFormat: processed.modelFormat,
                    originalByteCount: input.data.count,
                    modelByteCount: processed.modelData.count,
                    pixelSize: processed.pixelSize,
                    thumbnailData: processed.thumbnailData,
                    accessibilityLabel: Self.accessibilityLabel(
                        ordinal: ordinal,
                        format: processed.originalFormat,
                        pixelSize: processed.pixelSize
                    )
                )
                pending.append(.init(
                    descriptor: descriptor,
                    modelFileURL: fileURL
                ))
            }
            try checkCancellation()
        } catch {
            for attachment in pending {
                try? scope.remove(attachment.modelFileURL)
            }
            if error is CancellationError {
                throw VisionAttachmentFailure(.cancelled)
            }
            throw error
        }

        for attachment in pending {
            attachments[attachment.descriptor.id] = attachment
            order.append(attachment.descriptor.id)
        }
        return pending.map(\.descriptor)
    }

    func descriptors() -> [VisionAttachmentDescriptor] {
        order.compactMap { attachments[$0]?.descriptor }
    }

    func modelData(for attachmentID: UUID) throws -> Data {
        guard !closed, let attachment = attachments[attachmentID] else {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }
        return try scope.read(attachment.modelFileURL)
    }

    func makeOllamaMessage(
        role: OllamaChatRole,
        content: String,
        attachmentIDs: [UUID]? = nil
    ) throws -> OllamaVisionImageMessagePayload {
        guard !closed else {
            throw VisionAttachmentFailure(.workspaceClosed)
        }
        let selectedIDs = attachmentIDs ?? order
        guard !selectedIDs.isEmpty,
              selectedIDs.count <= policy.maximumAttachmentCount,
              Set(selectedIDs).count == selectedIDs.count
        else {
            throw VisionAttachmentFailure(.attachmentCountExceeded)
        }
        let images = try selectedIDs.map { identifier -> String in
            guard let attachment = attachments[identifier] else {
                throw VisionAttachmentFailure(.attachmentNotFound)
            }
            return try scope.read(attachment.modelFileURL).base64EncodedString()
        }
        return OllamaVisionImageMessagePayload(
            role: role,
            content: content,
            images: images
        )
    }

    func remove(_ attachmentID: UUID) throws {
        guard !closed, let attachment = attachments.removeValue(forKey: attachmentID) else {
            throw VisionAttachmentFailure(.attachmentNotFound)
        }
        do {
            try scope.remove(attachment.modelFileURL)
            order.removeAll { $0 == attachmentID }
        } catch {
            attachments[attachmentID] = attachment
            throw error
        }
    }

    func cancelAndRemoveAll() {
        guard !closed else { return }
        closed = true
        attachments.removeAll()
        order.removeAll()
        scope.removeAll()
    }

    func temporaryFileCount() -> Int {
        scope.fileCount()
    }

    private func checkCancellation() throws {
        guard !Task.isCancelled else {
            throw VisionAttachmentFailure(.cancelled)
        }
    }

    private static func accessibilityLabel(
        ordinal: Int,
        format: VisionAttachmentFormat,
        pixelSize: VisionPixelSize
    ) -> String {
        "Image attachment \(ordinal), \(format.rawValue.uppercased()), "
            + "\(pixelSize.width) by \(pixelSize.height) pixels."
    }
}
