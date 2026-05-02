//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AVFoundation
import UIKit

// MARK: - Coordinate Space Tags (phantom types, zero runtime overhead)

protocol CoordinateSpaceTag {}

/// Vision normalized coords: 0…1, origin bottom-left.
enum VisionSpace: CoordinateSpaceTag {}

/// AVCaptureDevice normalized coords: 0…1, origin top-left.
enum CaptureDeviceSpace: CoordinateSpaceTag {}

/// View/screen pixel coords: origin top-left.
enum ViewSpace: CoordinateSpaceTag {}

/// UIImage pixel coords: origin top-left.
enum ImageSpace: CoordinateSpaceTag {}

/// CIImage pixel coords: origin bottom-left.
enum CISpace: CoordinateSpaceTag {}

// MARK: - Quad

struct Quad<Space: CoordinateSpaceTag>: Equatable {
    var topLeft: CGPoint
    var topRight: CGPoint
    var bottomRight: CGPoint
    var bottomLeft: CGPoint

    var points: [CGPoint] {
        [topLeft, topRight, bottomRight, bottomLeft]
    }

    /// Transforms all points within the same coordinate space (e.g. clamping, offsetting).
    func applying(_ transform: (CGPoint) -> CGPoint) -> Quad<Space> {
        Quad<Space>(
            topLeft: transform(topLeft),
            topRight: transform(topRight),
            bottomRight: transform(bottomRight),
            bottomLeft: transform(bottomLeft)
        )
    }
}

// MARK: - Vision → CaptureDevice

extension Quad where Space == VisionSpace {

    /// Vision oriented (x, y) → CaptureDevice (1-y, 1-x).
    /// Used as an intermediate step before `layerPointConverted`.
    func toCaptureDevice() -> Quad<CaptureDeviceSpace> {
        Quad<CaptureDeviceSpace>(
            topLeft: CGPoint(x: 1 - topLeft.y, y: 1 - topLeft.x),
            topRight: CGPoint(x: 1 - topRight.y, y: 1 - topRight.x),
            bottomRight: CGPoint(x: 1 - bottomRight.y, y: 1 - bottomRight.x),
            bottomLeft: CGPoint(x: 1 - bottomLeft.y, y: 1 - bottomLeft.x)
        )
    }
}

// MARK: - Vision → View

extension Quad where Space == VisionSpace {

    /// Maps Vision normalized coords to view pixel coords within a display rect.
    /// Flips Y (bottom-left → top-left) and scales to rect dimensions.
    func toView(in rect: CGRect) -> Quad<ViewSpace> {
        func convert(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: rect.origin.x + p.x * rect.width,
                y: rect.origin.y + (1 - p.y) * rect.height
            )
        }
        return Quad<ViewSpace>(
            topLeft: convert(topLeft),
            topRight: convert(topRight),
            bottomRight: convert(bottomRight),
            bottomLeft: convert(bottomLeft)
        )
    }
}

// MARK: - Vision → Image

extension Quad where Space == VisionSpace {

    /// Maps Vision normalized coords to UIImage pixel coords.
    /// Flips Y (bottom-left → top-left) and scales to image size.
    func toImage(size: CGSize) -> Quad<ImageSpace> {
        Quad<ImageSpace>(
            topLeft: CGPoint(x: topLeft.x * size.width, y: (1 - topLeft.y) * size.height),
            topRight: CGPoint(x: topRight.x * size.width, y: (1 - topRight.y) * size.height),
            bottomRight: CGPoint(x: bottomRight.x * size.width, y: (1 - bottomRight.y) * size.height),
            bottomLeft: CGPoint(x: bottomLeft.x * size.width, y: (1 - bottomLeft.y) * size.height)
        )
    }
}

// MARK: - CaptureDevice → View

extension Quad where Space == CaptureDeviceSpace {

    /// Converts capture device coords to view pixel coords using the preview layer,
    /// clamped to the given bounds.
    func toView(using layer: AVCaptureVideoPreviewLayer, clampTo bounds: CGRect) -> Quad<ViewSpace> {
        func convert(_ p: CGPoint) -> CGPoint {
            let layerPoint = layer.layerPointConverted(fromCaptureDevicePoint: p)
            return CGPoint(
                x: min(max(layerPoint.x, 0), bounds.width),
                y: min(max(layerPoint.y, 0), bounds.height)
            )
        }
        return Quad<ViewSpace>(
            topLeft: convert(topLeft),
            topRight: convert(topRight),
            bottomRight: convert(bottomRight),
            bottomLeft: convert(bottomLeft)
        )
    }
}

// MARK: - ViewSpace helpers

extension Quad where Space == ViewSpace {

    /// Axis-aligned bounding rect enclosing all four corners.
    var boundingRect: CGRect {
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let minX = xs.min()!, maxX = xs.max()!
        let minY = ys.min()!, maxY = ys.max()!
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

// MARK: - View → Image

extension Quad where Space == ViewSpace {

    /// Maps view pixel coords to UIImage pixel coords.
    /// Normalizes within the display rect, then scales to image dimensions.
    func toImage(from displayRect: CGRect, imageSize: CGSize) -> Quad<ImageSpace> {
        guard displayRect.width > 0, displayRect.height > 0 else {
            return Quad<ImageSpace>(topLeft: topLeft, topRight: topRight,
                                    bottomRight: bottomRight, bottomLeft: bottomLeft)
        }
        func convert(_ p: CGPoint) -> CGPoint {
            CGPoint(
                x: ((p.x - displayRect.origin.x) / displayRect.width) * imageSize.width,
                y: ((p.y - displayRect.origin.y) / displayRect.height) * imageSize.height
            )
        }
        return Quad<ImageSpace>(
            topLeft: convert(topLeft),
            topRight: convert(topRight),
            bottomRight: convert(bottomRight),
            bottomLeft: convert(bottomLeft)
        )
    }
}

// MARK: - Image → CISpace

extension Quad where Space == ImageSpace {

    /// Flips Y from UIKit top-left origin to CIImage bottom-left origin.
    func toCISpace(imageHeight: CGFloat) -> Quad<CISpace> {
        Quad<CISpace>(
            topLeft: CGPoint(x: topLeft.x, y: imageHeight - topLeft.y),
            topRight: CGPoint(x: topRight.x, y: imageHeight - topRight.y),
            bottomRight: CGPoint(x: bottomRight.x, y: imageHeight - bottomRight.y),
            bottomLeft: CGPoint(x: bottomLeft.x, y: imageHeight - bottomLeft.y)
        )
    }
}
