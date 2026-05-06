//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import CoreImage

// MARK: - PerspectiveCorrectionService

final class PerspectiveCorrectionService {

    private let ciContext = CIContext()

    /// Applies perspective correction to the image using the given quadrilateral.
    /// The quad is in `ImageSpace` (origin top-left, pixels) — converted to `CISpace` internally.
    func correct(image: UIImage, quad: Quad<ImageSpace>) -> UIImage? {
        // Normalize orientation so CIImage has a predictable extent starting at (0,0)
        let normalized = normalizeOrientation(image)
        guard let cgInput = normalized.cgImage else { return nil }
        let ciImage = CIImage(cgImage: cgInput)

        let imageHeight = CGFloat(cgInput.height)
        let ciQuad = quad.toCISpace(imageHeight: imageHeight)

        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return nil }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: ciQuad.topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: ciQuad.topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: ciQuad.bottomRight), forKey: "inputBottomRight")
        filter.setValue(CIVector(cgPoint: ciQuad.bottomLeft), forKey: "inputBottomLeft")

        guard let outputImage = filter.outputImage,
              let cgImage = ciContext.createCGImage(outputImage, from: outputImage.extent) else {
            return nil
        }

        return UIImage(cgImage: cgImage)
    }

    /// Renders the image into a new context with `.up` orientation,
    /// removing any EXIF rotation metadata (e.g. `.right` from camera).
    private func normalizeOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }
        let format = UIGraphicsImageRendererFormat()
        format.scale = image.scale
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        return renderer.image { _ in
            image.draw(at: .zero)
        }
    }
}
