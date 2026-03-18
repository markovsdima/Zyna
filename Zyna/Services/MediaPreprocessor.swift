//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import ImageIO

// MARK: - Processed Image

struct ProcessedImage {
    let imageData: Data
    let width: UInt64
    let height: UInt64
    // TODO: Thumbnail ready for when sendImage SDK bug is fixed
    // let thumbnailData: Data
    // let thumbnailWidth: UInt64
    // let thumbnailHeight: UInt64
}

// MARK: - Media Preprocessor

enum MediaPreprocessor {

    static let maxDimension: CGFloat = 2048
    static let jpegQuality: CGFloat = 0.78
    // static let thumbMaxDimension: CGFloat = 800  // TODO: for sendImage thumbnail

    // MARK: - Public

    static func processImage(from data: Data) async throws -> ProcessedImage {
        try await Task.detached {
            let strippedData = stripGPSMetadata(from: data)

            // UIImage handles all formats (JPEG, PNG, HEIC, WebP) and normalizes pixel format
            guard let original = UIImage(data: strippedData) else {
                throw PreprocessorError.invalidImageData
            }

            // Resize main image
            let resized = resizeUIImage(original, maxDimension: maxDimension)

            guard let imageData = resized.jpegData(compressionQuality: jpegQuality) else {
                throw PreprocessorError.encodingFailed
            }

            return ProcessedImage(
                imageData: imageData,
                width: UInt64(resized.size.width * resized.scale),
                height: UInt64(resized.size.height * resized.scale)
            )
        }.value
    }

    // MARK: - GPS Stripping

    private static func stripGPSMetadata(from data: Data) -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source) else {
            return data
        }

        let mutableData = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(mutableData, type, 1, nil) else {
            return data
        }

        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return data
        }

        var cleaned = properties
        cleaned.removeValue(forKey: kCGImagePropertyGPSDictionary)

        CGImageDestinationAddImageFromSource(dest, source, 0, cleaned as CFDictionary)

        guard CGImageDestinationFinalize(dest) else {
            return data
        }

        return mutableData as Data
    }

    // MARK: - Resize

    /// Resizes and normalizes an image: forces scale 1.0 and standard dynamic range (strips HDR).
    /// Always redraws through the renderer even if dimensions fit, to normalize pixel format.
    private static func resizeUIImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let w = image.size.width * image.scale   // pixel dimensions
        let h = image.size.height * image.scale
        let scale = min(maxDimension / w, maxDimension / h, 1.0)

        let newSize = CGSize(width: w * scale, height: h * scale)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        format.preferredRange = .standard   // Force SDR, strip HDR gain map
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    // MARK: - Errors

    enum PreprocessorError: Error {
        case invalidImageData
        case encodingFailed
    }
}
