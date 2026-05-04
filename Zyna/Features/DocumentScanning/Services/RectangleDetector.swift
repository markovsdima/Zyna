//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Vision
import AVFoundation
import UIKit

// MARK: - RectangleDetectorDelegate

protocol RectangleDetectorDelegate: AnyObject {
    /// Called on the main queue when a rectangle is detected (or lost).
    func rectangleDetector(_ detector: RectangleDetector, didDetect quad: Quad<VisionSpace>?)

    /// Called on the main queue when the detected rectangle has been stable long enough for auto-capture.
    func rectangleDetectorDidStabilize(_ detector: RectangleDetector, quad: Quad<VisionSpace>)
}

// MARK: - RectangleDetector

final class RectangleDetector {

    // MARK: - Constants

    private enum Constants {
        static let stabilityThreshold: CGFloat = 0.05  // 5% — tolerates normal hand tremor
        static let requiredStableFrames = 8             // ~0.5s at 15fps processing
        static let framesToLose = 15                    // keep showing quad for N frames after losing it (~1s)
        static let smoothingFactor: CGFloat = 0.75      // EMA alpha (0 = full smooth, 1 = no smooth)
        static let confidenceThreshold: Float = 0.85    // min Vision confidence for auto-capture
    }

    // MARK: - Properties

    weak var delegate: RectangleDetectorDelegate?

    private var stableFrameCount = 0
    private var previousQuad: Quad<VisionSpace>?
    private var smoothedQuad: Quad<VisionSpace>?
    private var missedFrameCount = 0
    private var hasTriggeredAutoCapture = false
    private var lastConfidence: Float = 0

    private let documentRequest = VNDetectDocumentSegmentationRequest()

    // MARK: - Public

    /// Process a sample buffer for rectangle detection. Call from the capture session queue.
    func detect(in sampleBuffer: CMSampleBuffer) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([documentRequest])

        let observation = documentRequest.results?.first
        lastConfidence = observation?.confidence ?? 0

        let rawQuad = observation.map { obs in
            Quad<VisionSpace>(
                topLeft: obs.topLeft,
                topRight: obs.topRight,
                bottomRight: obs.bottomRight,
                bottomLeft: obs.bottomLeft
            )
        }

        // Determine the quad to report, applying loss buffering and smoothing
        let reportedQuad: Quad<VisionSpace>?

        if let raw = rawQuad {
            missedFrameCount = 0
            smoothedQuad = smooth(raw, previous: smoothedQuad)
            reportedQuad = smoothedQuad
        } else {
            missedFrameCount += 1
            if missedFrameCount <= Constants.framesToLose, let last = smoothedQuad {
                // Keep showing the last known quad for a few frames
                reportedQuad = last
            } else {
                smoothedQuad = nil
                reportedQuad = nil
            }
        }

        updateStability(quad: rawQuad)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.rectangleDetector(self, didDetect: reportedQuad)
        }
    }

    /// Padding added around the crop hint bounding box (in normalized 0…1 coords).
    static let cropPadding: CGFloat = 0.05

    /// Runs a single-shot rectangle detection on a full-resolution image.
    ///
    /// The image is first rendered to `.up` orientation so that Vision `.up` coords
    /// match the same portrait space as the live preview (Vision `.right` on landscape buffer).
    ///
    /// When `cropHint` is provided (a quad from the live preview), the CGImage is cropped
    /// to that area + padding before detection to avoid false positives.
    /// Returns `(quad, cropRect)` — the crop rect (in Vision normalized coords) is provided
    /// for diagnostic overlay purposes. Both are `nil` when detection fails.
    static func detect(
        in image: UIImage,
        cropHint: Quad<VisionSpace>? = nil
    ) -> (quad: Quad<VisionSpace>, cropRect: CGRect?)? {
        // Render to .up so CGImage pixels match portrait orientation
        let upImage = image.imageOrientation == .up ? image : normalizeOrientation(image)
        guard let cgImage = upImage.cgImage else { return nil }

        let imgW = CGFloat(cgImage.width)
        let imgH = CGFloat(cgImage.height)

        let effectiveCGImage: CGImage
        var cropNorm: CGRect? // Vision normalized coords (0…1, bottom-left origin)

        if let hint = cropHint {
            let padding = cropPadding
            let xs = hint.points.map(\.x)
            let ys = hint.points.map(\.y)

            let vMinX = max(0, xs.min()! - padding)
            let vMaxX = min(1, xs.max()! + padding)
            let vMinY = max(0, ys.min()! - padding)
            let vMaxY = min(1, ys.max()! + padding)
            cropNorm = CGRect(x: vMinX, y: vMinY, width: vMaxX - vMinX, height: vMaxY - vMinY)

            // Vision bottom-left → CGImage top-left pixel coords
            let pixelRect = CGRect(
                x: vMinX * imgW,
                y: (1 - vMaxY) * imgH,
                width: (vMaxX - vMinX) * imgW,
                height: (vMaxY - vMinY) * imgH
            ).intersection(CGRect(x: 0, y: 0, width: imgW, height: imgH))

            guard pixelRect.width > 0, pixelRect.height > 0,
                  let cropped = cgImage.cropping(to: pixelRect) else { return nil }
            effectiveCGImage = cropped
        } else {
            effectiveCGImage = cgImage
            cropNorm = nil
        }

        let request = VNDetectDocumentSegmentationRequest()
        let handler = VNImageRequestHandler(cgImage: effectiveCGImage, orientation: .up, options: [:])
        try? handler.perform([request])

        guard let observation = request.results?.first else { return nil }

        var quad = Quad<VisionSpace>(
            topLeft: observation.topLeft,
            topRight: observation.topRight,
            bottomRight: observation.bottomRight,
            bottomLeft: observation.bottomLeft
        )

        // Map crop-local coords back to full-image coords
        if let crop = cropNorm {
            quad = quad.applying { point in
                CGPoint(
                    x: crop.origin.x + point.x * crop.width,
                    y: crop.origin.y + point.y * crop.height
                )
            }
        }

        return (quad, cropNorm)
    }

    // MARK: - Orientation Helpers

    private static func normalizeOrientation(_ image: UIImage) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1.0
        return UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
            image.draw(at: .zero)
        }
    }

    /// Resets stability tracking. Call after a capture to prepare for next page.
    func resetStability() {
        stableFrameCount = 0
        previousQuad = nil
        smoothedQuad = nil
        missedFrameCount = 0
        hasTriggeredAutoCapture = false
    }

    // MARK: - Stability Detection

    private func updateStability(quad: Quad<VisionSpace>?) {
        // If Vision missed this frame but we're within the loss buffer, keep counting
        guard let quad else {
            if missedFrameCount > Constants.framesToLose {
                previousQuad = nil
                stableFrameCount = 0
                hasTriggeredAutoCapture = false
            }
            // Otherwise: keep previousQuad and stableFrameCount as-is
            return
        }

        guard let previous = previousQuad else {
            previousQuad = quad
            stableFrameCount = 0
            return
        }

        if isStable(quad, comparedTo: previous) {
            stableFrameCount += 1

            if stableFrameCount >= Constants.requiredStableFrames && !hasTriggeredAutoCapture
                && lastConfidence >= Constants.confidenceThreshold {
                hasTriggeredAutoCapture = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.delegate?.rectangleDetectorDidStabilize(self, quad: quad)
                }
            }
        } else {
            stableFrameCount = 0
            hasTriggeredAutoCapture = false
        }

        previousQuad = quad
    }

    private func isStable(_ a: Quad<VisionSpace>, comparedTo b: Quad<VisionSpace>) -> Bool {
        let threshold = Constants.stabilityThreshold
        return distance(a.topLeft, b.topLeft) < threshold
            && distance(a.topRight, b.topRight) < threshold
            && distance(a.bottomRight, b.bottomRight) < threshold
            && distance(a.bottomLeft, b.bottomLeft) < threshold
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // MARK: - Smoothing

    private func smooth(_ quad: Quad<VisionSpace>, previous: Quad<VisionSpace>?) -> Quad<VisionSpace> {
        guard let prev = previous else { return quad }
        let alpha = Constants.smoothingFactor
        return Quad<VisionSpace>(
            topLeft: lerp(from: prev.topLeft, to: quad.topLeft, alpha: alpha),
            topRight: lerp(from: prev.topRight, to: quad.topRight, alpha: alpha),
            bottomRight: lerp(from: prev.bottomRight, to: quad.bottomRight, alpha: alpha),
            bottomLeft: lerp(from: prev.bottomLeft, to: quad.bottomLeft, alpha: alpha)
        )
    }

    private func lerp(from a: CGPoint, to b: CGPoint, alpha: CGFloat) -> CGPoint {
        CGPoint(
            x: a.x + (b.x - a.x) * alpha,
            y: a.y + (b.y - a.y) * alpha
        )
    }
}
