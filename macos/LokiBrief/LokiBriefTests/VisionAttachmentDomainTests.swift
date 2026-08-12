import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import LokiBrief

final class VisionAttachmentDomainTests: XCTestCase, @unchecked Sendable {
    private static let metadataSentinel = "PRIVATE_EXIF_SENTINEL_MUST_BE_REMOVED"

    func testFileDropAndClipboardIntakeProduceOllamaBase64ImageMessage() async throws {
        let fixture = try Self.syntheticImageData(
            width: 4,
            height: 3,
            typeIdentifier: UTType.png.identifier
        )
        let temporaryBase = try Self.temporaryBase()
        defer { try? FileManager.default.removeItem(at: temporaryBase) }
        let workspace = try VisionAttachmentWorkspace(
            baseTemporaryDirectoryURL: temporaryBase,
            scopeIdentifier: UUID(
                uuidString: "11111111-1111-1111-1111-111111111111"
            )!
        )
        let inputs = [
            VisionAttachmentInput(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000001")!,
                source: .filePicker,
                data: fixture,
                declaredTypeIdentifier: UTType.png.identifier,
                preferredFilename: "synthetic.png"
            ),
            VisionAttachmentInput(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000002")!,
                source: .dragAndDrop,
                data: fixture,
                declaredTypeIdentifier: UTType.png.identifier
            ),
            VisionAttachmentInput(
                id: UUID(uuidString: "10000000-0000-0000-0000-000000000003")!,
                source: .clipboardPaste,
                data: fixture
            ),
        ]

        let descriptors = try await workspace.add(inputs)
        XCTAssertEqual(
            descriptors.map(\.source),
            [.filePicker, .dragAndDrop, .clipboardPaste]
        )
        XCTAssertTrue(descriptors.allSatisfy { $0.originalFormat == .png })
        XCTAssertTrue(descriptors.allSatisfy { $0.modelFormat == .png })
        XCTAssertTrue(descriptors.allSatisfy {
            $0.accessibilityLabel.contains("4 by 3 pixels")
        })
        XCTAssertTrue(descriptors.allSatisfy { !$0.thumbnailData.isEmpty })

        let payload = try await workspace.makeOllamaMessage(
            role: .user,
            content: "Describe these synthetic images."
        )
        XCTAssertEqual(payload.role, .user)
        XCTAssertEqual(payload.content, "Describe these synthetic images.")
        XCTAssertEqual(payload.images.count, 3)
        for (index, input) in inputs.enumerated() {
            let decoded = try XCTUnwrap(Data(base64Encoded: payload.images[index]))
            let stored = try await workspace.modelData(for: input.id)
            XCTAssertEqual(decoded, stored)
        }
        let fileCount = await workspace.temporaryFileCount()
        XCTAssertEqual(fileCount, 3)

        await workspace.cancelAndRemoveAll()
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: workspace.temporaryDirectoryURL.path
        ))
    }

    func testJPEGMetadataIsStrippedAndThumbnailAndAccessibilityRemainLocal() async throws {
        let original = try Self.syntheticImageData(
            width: 12,
            height: 7,
            typeIdentifier: UTType.jpeg.identifier,
            metadataSentinel: Self.metadataSentinel
        )
        XCTAssertNotNil(original.range(of: Data(Self.metadataSentinel.utf8)))
        let temporaryBase = try Self.temporaryBase()
        defer { try? FileManager.default.removeItem(at: temporaryBase) }
        let workspace = try VisionAttachmentWorkspace(
            baseTemporaryDirectoryURL: temporaryBase
        )
        let identifier = UUID()

        let imported = try await workspace.add([
            .init(
                id: identifier,
                source: .filePicker,
                data: original,
                declaredTypeIdentifier: UTType.jpeg.identifier
            ),
        ])
        let descriptor = try XCTUnwrap(imported.first)
        let modelData = try await workspace.modelData(for: identifier)

        XCTAssertEqual(descriptor.originalFormat, .jpeg)
        XCTAssertEqual(descriptor.modelFormat, .jpeg)
        XCTAssertEqual(descriptor.pixelSize, .init(width: 12, height: 7))
        XCTAssertTrue(descriptor.accessibilityLabel.contains("JPEG"))
        XCTAssertNil(modelData.range(of: Data(Self.metadataSentinel.utf8)))
        let source = try XCTUnwrap(CGImageSourceCreateWithData(modelData as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        )
        if let exif = properties[
            kCGImagePropertyExifDictionary as String
        ] as? [String: Any] {
            XCTAssertNil(exif[kCGImagePropertyExifUserComment as String])
            XCTAssertNil(exif[kCGImagePropertyExifMakerNote as String])
        }
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary as String])
        XCTAssertNil(properties[kCGImagePropertyTIFFDictionary as String])
        XCTAssertNotNil(CGImageSourceCreateWithData(
            descriptor.thumbnailData as CFData,
            nil
        ))

        let attributes = try FileManager.default.attributesOfItem(
            atPath: workspace.temporaryDirectoryURL.path
        )
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let temporaryFiles = try FileManager.default.contentsOfDirectory(
            at: workspace.temporaryDirectoryURL,
            includingPropertiesForKeys: nil
        )
        let temporaryFile = try XCTUnwrap(temporaryFiles.first)
        let temporaryFileAttributes = try FileManager.default.attributesOfItem(
            atPath: temporaryFile.path
        )
        XCTAssertEqual(
            (temporaryFileAttributes[.posixPermissions] as? NSNumber)?.intValue,
            0o600
        )
        await workspace.cancelAndRemoveAll()
    }

    func testHEICIsSafelyConvertedToMetadataFreeJPEGWhenPlatformEncoderIsAvailable() async throws {
        guard let HEIC = try Self.optionalSyntheticImageData(
            width: 9,
            height: 5,
            typeIdentifier: UTType.heic.identifier,
            metadataSentinel: Self.metadataSentinel
        ) else {
            throw XCTSkip("The local ImageIO runtime does not provide a HEIC encoder.")
        }
        let temporaryBase = try Self.temporaryBase()
        defer { try? FileManager.default.removeItem(at: temporaryBase) }
        let workspace = try VisionAttachmentWorkspace(
            baseTemporaryDirectoryURL: temporaryBase
        )
        let identifier = UUID()

        let imported = try await workspace.add([
            .init(
                id: identifier,
                source: .dragAndDrop,
                data: HEIC,
                declaredTypeIdentifier: UTType.heic.identifier
            ),
        ])
        let descriptor = try XCTUnwrap(imported.first)
        let modelData = try await workspace.modelData(for: identifier)
        let modelSource = try XCTUnwrap(
            CGImageSourceCreateWithData(modelData as CFData, nil)
        )

        XCTAssertEqual(descriptor.originalFormat, .heic)
        XCTAssertEqual(descriptor.modelFormat, .jpeg)
        XCTAssertEqual(CGImageSourceGetType(modelSource) as String?, UTType.jpeg.identifier)
        XCTAssertNil(modelData.range(of: Data(Self.metadataSentinel.utf8)))
        await workspace.cancelAndRemoveAll()
    }

    func testCountByteTotalPixelAndTypeLimitsFailClosedBeforeRetention() async throws {
        let fixture = try Self.syntheticImageData(
            width: 4,
            height: 4,
            typeIdentifier: UTType.png.identifier
        )
        let temporaryBase = try Self.temporaryBase()
        defer { try? FileManager.default.removeItem(at: temporaryBase) }

        let countWorkspace = try VisionAttachmentWorkspace(
            policy: .init(maximumAttachmentCount: 2),
            baseTemporaryDirectoryURL: temporaryBase,
            scopeIdentifier: UUID(
                uuidString: "20000000-0000-0000-0000-000000000001"
            )!
        )
        await assertFailure(.attachmentCountExceeded) {
            _ = try await countWorkspace.add([
                .init(source: .filePicker, data: fixture),
                .init(source: .dragAndDrop, data: fixture),
                .init(source: .clipboardPaste, data: fixture),
            ])
        }
        let countDescriptors = await countWorkspace.descriptors()
        XCTAssertEqual(countDescriptors, [])

        let perImageByteLimit = fixture.count + 10
        let byteWorkspace = try VisionAttachmentWorkspace(
            policy: .init(
                maximumPerImageBytes: perImageByteLimit,
                maximumTotalBytes: fixture.count * 2 - 1
            ),
            baseTemporaryDirectoryURL: temporaryBase,
            scopeIdentifier: UUID(
                uuidString: "20000000-0000-0000-0000-000000000002"
            )!
        )
        await assertFailure(.perImageBytesExceeded) {
            _ = try await byteWorkspace.add([
                .init(
                    source: .filePicker,
                    data: Data(repeating: 0, count: perImageByteLimit + 1)
                ),
            ])
        }
        await assertFailure(.totalBytesExceeded) {
            _ = try await byteWorkspace.add([
                .init(source: .filePicker, data: fixture),
                .init(source: .dragAndDrop, data: fixture),
            ])
        }

        let pixelWorkspace = try VisionAttachmentWorkspace(
            policy: .init(
                maximumPixelDimension: 4,
                maximumDecodedPixels: 16
            ),
            baseTemporaryDirectoryURL: temporaryBase,
            scopeIdentifier: UUID(
                uuidString: "20000000-0000-0000-0000-000000000003"
            )!
        )
        let tooWide = try Self.syntheticImageData(
            width: 5,
            height: 1,
            typeIdentifier: UTType.png.identifier
        )
        await assertFailure(.pixelLimitExceeded) {
            _ = try await pixelWorkspace.add([
                .init(source: .filePicker, data: tooWide),
            ])
        }
        await assertFailure(.unsupportedFormat) {
            _ = try await pixelWorkspace.add([
                .init(
                    source: .clipboardPaste,
                    data: Data("RIFF synthetic audio".utf8),
                    declaredTypeIdentifier: "public.wav"
                ),
            ])
        }
        await assertFailure(.declaredFormatMismatch) {
            _ = try await pixelWorkspace.add([
                .init(
                    source: .filePicker,
                    data: fixture,
                    declaredTypeIdentifier: UTType.jpeg.identifier
                ),
            ])
        }

        await countWorkspace.cancelAndRemoveAll()
        await byteWorkspace.cancelAndRemoveAll()
        await pixelWorkspace.cancelAndRemoveAll()
    }

    func testRemovalAndCancellationDeleteScopedTemporaryRepresentations() async throws {
        let fixture = try Self.syntheticImageData(
            width: 3,
            height: 2,
            typeIdentifier: UTType.png.identifier
        )
        let temporaryBase = try Self.temporaryBase()
        defer { try? FileManager.default.removeItem(at: temporaryBase) }
        let workspace = try VisionAttachmentWorkspace(
            baseTemporaryDirectoryURL: temporaryBase
        )
        let firstID = UUID()
        let secondID = UUID()
        _ = try await workspace.add([
            .init(id: firstID, source: .filePicker, data: fixture),
            .init(id: secondID, source: .clipboardPaste, data: fixture),
        ])
        let initialFileCount = await workspace.temporaryFileCount()
        XCTAssertEqual(initialFileCount, 2)

        try await workspace.remove(firstID)
        let afterRemoval = await workspace.descriptors()
        let afterRemovalFileCount = await workspace.temporaryFileCount()
        XCTAssertEqual(afterRemoval.map(\.id), [secondID])
        XCTAssertEqual(afterRemovalFileCount, 1)
        await assertFailure(.attachmentNotFound) {
            _ = try await workspace.modelData(for: firstID)
        }

        let root = workspace.temporaryDirectoryURL
        await workspace.cancelAndRemoveAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let finalDescriptors = await workspace.descriptors()
        XCTAssertTrue(finalDescriptors.isEmpty)
        await assertFailure(.workspaceClosed) {
            _ = try await workspace.add([
                .init(source: .filePicker, data: fixture),
            ])
        }

        let cancellationWorkspace = try VisionAttachmentWorkspace(
            baseTemporaryDirectoryURL: temporaryBase
        )
        let cancelledImport = Task {
            await Task.yield()
            return try await cancellationWorkspace.add([
                .init(source: .filePicker, data: fixture),
            ])
        }
        cancelledImport.cancel()
        do {
            _ = try await cancelledImport.value
            XCTFail("Expected image processing cancellation")
        } catch let failure as VisionAttachmentFailure {
            XCTAssertEqual(failure.code, .cancelled)
        } catch is CancellationError {
            // The caller task may surface native cancellation before actor admission.
        }
        let cancelledDescriptors = await cancellationWorkspace.descriptors()
        let cancelledFileCount = await cancellationWorkspace.temporaryFileCount()
        XCTAssertTrue(cancelledDescriptors.isEmpty)
        XCTAssertEqual(cancelledFileCount, 0)
        await cancellationWorkspace.cancelAndRemoveAll()
    }

    func testPublicLimitsRemainStableForProviderValidation() {
        XCTAssertEqual(VisionAttachmentLimits.maximumAttachmentCount, 8)
        XCTAssertEqual(VisionAttachmentLimits.maximumPerImageBytes, 12 * 1_024 * 1_024)
        XCTAssertEqual(VisionAttachmentLimits.maximumTotalBytes, 32 * 1_024 * 1_024)
    }

    private func assertFailure(
        _ expected: VisionAttachmentFailureCode,
        operation: () async throws -> Void
    ) async {
        do {
            try await operation()
            XCTFail("Expected \(expected.rawValue)")
        } catch let failure as VisionAttachmentFailure {
            XCTAssertEqual(failure.code, expected)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private static func temporaryBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "agent-loki-vision-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return url
    }

    private static func syntheticImageData(
        width: Int,
        height: Int,
        typeIdentifier: String,
        metadataSentinel: String? = nil
    ) throws -> Data {
        guard let data = try optionalSyntheticImageData(
            width: width,
            height: height,
            typeIdentifier: typeIdentifier,
            metadataSentinel: metadataSentinel
        ) else {
            throw VisionAttachmentFailure(.metadataStrippingFailed)
        }
        return data
    }

    private static func optionalSyntheticImageData(
        width: Int,
        height: Int,
        typeIdentifier: String,
        metadataSentinel: String? = nil
    ) throws -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw VisionAttachmentFailure(.decodeFailed)
        }
        context.setFillColor(
            red: 0.15,
            green: 0.55,
            blue: 0.85,
            alpha: 1
        )
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(
            red: 0.95,
            green: 0.25,
            blue: 0.15,
            alpha: 1
        )
        context.fill(CGRect(
            x: 0,
            y: 0,
            width: max(1, width / 2),
            height: max(1, height / 2)
        ))
        guard let image = context.makeImage() else {
            throw VisionAttachmentFailure(.decodeFailed)
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            typeIdentifier as CFString,
            1,
            nil
        ) else {
            return nil
        }
        var properties: [CFString: Any] = [:]
        if typeIdentifier == UTType.jpeg.identifier
            || typeIdentifier == UTType.heic.identifier
        {
            properties[kCGImageDestinationLossyCompressionQuality] = 0.95
        }
        if let metadataSentinel {
            properties[kCGImagePropertyTIFFDictionary] = [
                kCGImagePropertyTIFFArtist: metadataSentinel,
            ]
        }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }
}
