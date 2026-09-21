//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Testing
import UIKit
@testable import Zyna

@Suite("Bubble portal capture", .serialized)
@MainActor
struct BubblePortalCaptureRendererTests {
    @MainActor
    private final class Fixture {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let source = PortalSourceView(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let canvas = UIView(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let table = UIView(frame: CGRect(x: 0, y: 0, width: 440, height: 956))
        let cell = UIView(frame: CGRect(x: 114, y: -15, width: 318, height: 147))
        let wrapper = UIView(frame: CGRect(x: 0, y: 0, width: 318, height: 147))
        let portal = BubblePortalBackgroundNode()

        init() {
            window.windowScene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
            window.rootViewController = UIViewController()
            let root = window.rootViewController!.view!
            root.frame = window.bounds
            window.isHidden = false
            root.addSubview(source)
            root.addSubview(table)
            source.alpha = 0
            source.addSubview(canvas)
            let gradient = CAGradientLayer()
            gradient.frame = canvas.bounds
            gradient.colors = [UIColor.red.cgColor, UIColor.blue.cgColor]
            gradient.startPoint = CGPoint(x: 0.5, y: 0)
            gradient.endPoint = CGPoint(x: 0.5, y: 1)
            canvas.layer.addSublayer(gradient)

            // Match Texture's inverted table and counter-flipped cells.
            table.transform = CGAffineTransform(scaleX: 1, y: -1)
            table.addSubview(cell)
            cell.transform = CGAffineTransform(scaleX: 1, y: -1)
            cell.addSubview(wrapper)
            portal.sourceView = source
            portal.frame = wrapper.bounds
            wrapper.addSubview(portal.view)
            portal.view.layoutIfNeeded()
        }

        func show() async throws {
            window.isHidden = false
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(60))
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
        }
    }

    @Test("Bottom bubble keeps its gradient during shrink")
    func bottomShrink() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.wrapper.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        try checkCapture(fixture, layer: fixture.portal.layer)
    }

    @Test("Scroll translations preserve source alignment at both screen edges")
    func scroll() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        for cellY: CGFloat in [-15, 650, 790] {
            fixture.cell.center.y = cellY + fixture.cell.bounds.height / 2
            try checkCapture(fixture, layer: fixture.portal.layer)
        }
    }

    @Test("Capture follows the presentation scale, not the final model scale")
    func animatedShrink() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.show()
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DIdentity
        animation.toValue = CATransform3DMakeScale(0.92, 0.92, 1)
        animation.duration = 1
        animation.speed = 0
        animation.timeOffset = 0.5
        fixture.wrapper.layer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        fixture.wrapper.layer.add(animation, forKey: "test-shrink")
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(60))
        let wrapper = try #require(fixture.wrapper.layer.presentation())
        #expect(wrapper.transform.m11 > 0.94 && wrapper.transform.m11 < 0.98)
        let host = try #require(fixture.portal.layer.presentation())
        try checkCapture(fixture, layer: host)
    }

    @Test("Model and presentation captures work after reparenting to a menu window")
    func reparenting() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        try await fixture.show()
        let menuWindow = UIWindow(frame: fixture.window.frame)
        menuWindow.windowScene = fixture.window.windowScene
        menuWindow.rootViewController = UIViewController()
        menuWindow.isHidden = false
        defer {
            menuWindow.isHidden = true
            menuWindow.rootViewController = nil
        }
        menuWindow.rootViewController!.view.addSubview(fixture.wrapper)
        fixture.wrapper.frame = CGRect(x: 114, y: 700, width: 318, height: 147)
        fixture.wrapper.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        #expect(fixture.portal.view.window === menuWindow)
        #expect(fixture.source.window === fixture.window)
        try checkCapture(fixture, layer: fixture.portal.layer)
        CATransaction.flush()
        try await Task.sleep(for: .milliseconds(60))
        try checkCapture(fixture, layer: #require(fixture.portal.layer.presentation()))
    }

    @Test("Source orientation survives affine remapping")
    func rotatedSource() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.canvas.transform = CGAffineTransform(rotationAngle: .pi)
        fixture.wrapper.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        try checkCapture(fixture, layer: fixture.portal.layer)
    }

    @Test("Swipe capture includes the bubble outside its unclipped wrapper")
    func swipeOutsideWrapper() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.wrapper.transform = CGAffineTransform(translationX: -64, y: 0)
        let pointInBubble = CGPoint(x: 30, y: 90)
        let pointInTable = fixture.portal.layer.convert(pointInBubble, to: fixture.table.layer)
        #expect(pointInTable.x < fixture.cell.frame.minX)
        let capture = captureTable(fixture, clip: fixture.table.bounds)
        #expect(try pixel(capture, at: pointInTable)[3] > 250)

        fixture.cell.clipsToBounds = true
        let clipped = captureTable(fixture, clip: fixture.table.bounds)
        #expect(try pixel(clipped, at: pointInTable)[3] == 0)
    }

    @Test("A one-point overlap disappears when shrink moves the bubble out")
    func thinOverlap() throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.cell.center.y = 88 + fixture.cell.bounds.height / 2
        let clip = CGRect(x: 0, y: 5, width: 440, height: 84)
        let sample = CGPoint(x: 270, y: 83)
        let before = captureTable(fixture, clip: clip)
        #expect(try pixel(before, at: sample)[3] > 250)

        fixture.wrapper.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        let after = captureTable(fixture, clip: clip)
        #expect(try pixel(after, at: sample)[3] == 0)
    }

    @Test("Predicted scale and swipe offset move content while the gradient stays anchored")
    func predictedScale() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let label = UILabel(frame: CGRect(x: 8, y: 20, width: 100, height: 30))
        label.text = "Scale"
        label.textColor = .white
        fixture.wrapper.addSubview(label)
        try await fixture.show()

        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = CATransform3DMakeTranslation(-40, 0, 0)
        animation.toValue = CATransform3DMakeScale(0.92, 0.92, 1)
        animation.duration = 1
        animation.speed = 0
        animation.timeOffset = 0.5
        fixture.wrapper.layer.add(animation, forKey: "test-shrink")
        try await fixture.show()
        let root = try #require(fixture.wrapper.layer.presentation())
        let table = try #require(fixture.table.layer.presentation())
        let clip = CGRect(x: 80, y: 0, width: 350, height: 140)

        // Both shrinking and returning can cross the capture boundary.
        for (scale, offset): (CGFloat, CGFloat) in [(0.92, 0), (1, -20)] {
            let prediction = GlassCapturePrediction(
                layer: root, scale: scale, translation: CGPoint(x: offset, y: 0)
            )
            let captured = captureTable(fixture, clip: clip, layer: table, prediction: prediction)
            fixture.wrapper.transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offset, ty: 0)
            let reference = captureTable(fixture, clip: clip)
            var mismatches = 0
            for y in stride(from: 1, to: 138, by: 3) {
                for x in stride(from: 1, to: 348, by: 3) {
                    let point = CGPoint(x: x, y: y)
                    let actual = try pixel(captured, at: point)
                    let expected = try pixel(reference, at: point)
                    if zip(actual, expected).contains(where: { abs($0 - $1) > 4 }) {
                        mismatches += 1
                    }
                }
            }
            #expect(mismatches < 8, "Predicted geometry/gradient differs at \(mismatches) pixels")
        }
    }

    @Test("Viewport and nested shrink advance clipping and the anchored gradient together", arguments: [false, true])
    func predictedViewport(nestedShrink: Bool) async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        let viewport = UIScrollView(frame: CGRect(x: 0, y: 0, width: 318, height: 40))
        viewport.contentInsetAdjustmentBehavior = .never
        viewport.contentSize = fixture.wrapper.bounds.size
        fixture.cell.addSubview(viewport)
        viewport.addSubview(fixture.wrapper)
        viewport.contentOffset.y = 80
        let label = UILabel(frame: CGRect(x: 30, y: 40, width: 100, height: 30))
        label.text = "Return"
        label.textColor = .white
        fixture.wrapper.addSubview(label)
        try await fixture.show()
        let root = try #require(viewport.layer.presentation())
        let table = try #require(fixture.table.layer.presentation())
        let frame = CGRect(x: 0, y: -25, width: 318, height: 147)
        let prediction = GlassCapturePrediction(
            layer: root, position: CGPoint(x: frame.midX, y: frame.midY),
            bounds: CGRect(origin: .zero, size: frame.size)
        )
        var predictions = [prediction]
        if nestedShrink {
            predictions.insert(GlassCapturePrediction(
                layer: try #require(fixture.wrapper.layer.presentation()), scale: 0.92,
                translation: CGPoint(x: -15, y: 3)
            ), at: 0)
        }
        let clip = CGRect(x: 110, y: 0, width: 325, height: 150)
        let actual = captureTable(fixture, clip: clip, layer: table, predictions: predictions)
        let stale = captureTable(fixture, clip: clip, layer: table)
        viewport.frame = frame
        viewport.contentOffset = .zero
        if nestedShrink {
            fixture.wrapper.transform = CGAffineTransform(a: 0.92, b: 0, c: 0, d: 0.92, tx: -15, ty: 3)
        }
        let expected = captureTable(fixture, clip: clip)
        var mismatches = 0
        var newlyVisible = 0
        for y in stride(from: 1, to: 149, by: 3) {
            for x in stride(from: 1, to: 324, by: 3) {
                let point = CGPoint(x: x, y: y)
                let lhs = try pixel(actual, at: point)
                let rhs = try pixel(expected, at: point)
                if zip(lhs, rhs).contains(where: { abs($0 - $1) > 4 }) { mismatches += 1 }
                if rhs[3] > 250, try pixel(stale, at: point)[3] < 5 { newlyVisible += 1 }
            }
        }
        #expect(mismatches < 8, "Predicted viewport differs at \(mismatches) pixels")
        #expect(newlyVisible > 500, "The test must cover content outside the old presentation clip")
    }

    @Test("Two sibling bubbles are predicted independently and leave an idle sibling unchanged")
    func siblingPredictions() async throws {
        let fixture = Fixture()
        defer { fixture.close() }
        fixture.cell.bounds.size.height = 350
        fixture.cell.center.y = 175
        fixture.wrapper.frame = CGRect(x: 0, y: 0, width: 270, height: 100)
        fixture.portal.frame = fixture.wrapper.bounds
        fixture.wrapper.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        let shrinking = UIView(frame: CGRect(x: 0, y: 120, width: 270, height: 100))
        let idle = UIView(frame: CGRect(x: 0, y: 240, width: 270, height: 100))
        var portals = [fixture.portal]
        for wrapper in [shrinking, idle] {
            fixture.cell.addSubview(wrapper)
            let portal = BubblePortalBackgroundNode()
            portal.frame = wrapper.bounds
            portal.sourceView = fixture.source
            wrapper.addSubview(portal.view)
            portal.view.layoutIfNeeded()
            portals.append(portal)
        }
        // Include ordinary content as well as the shared portal gradient.
        for wrapper in [fixture.wrapper, shrinking, idle] {
            let marker = UIView(frame: CGRect(x: 20, y: 20, width: 40, height: 30))
            marker.backgroundColor = .green
            wrapper.addSubview(marker)
        }
        try await fixture.show()
        let table = try #require(fixture.table.layer.presentation())
        let predictions = [
            GlassCapturePrediction(layer: try #require(shrinking.layer.presentation()),
                                   scale: 0.85, translation: CGPoint(x: -25, y: 0)),
            GlassCapturePrediction(layer: try #require(fixture.wrapper.layer.presentation()), scale: 1)
        ]
        let clip = CGRect(x: 75, y: 0, width: 360, height: 350)
        let actual = captureTable(fixture, clip: clip, layer: table, predictions: predictions)
        let stale = captureTable(fixture, clip: clip, layer: table)
        fixture.wrapper.transform = .identity
        shrinking.transform = CGAffineTransform(a: 0.85, b: 0, c: 0, d: 0.85, tx: -25, ty: 0)
        let expected = captureTable(fixture, clip: clip)
        var mismatches = 0
        var correctedPixels = 0
        for y in stride(from: 2, to: 348, by: 3) {
            for x in stride(from: 2, to: 358, by: 3) {
                let point = CGPoint(x: x, y: y)
                let lhs = try pixel(actual, at: point)
                let rhs = try pixel(expected, at: point)
                if zip(lhs, rhs).contains(where: { abs($0 - $1) > 4 }) { mismatches += 1 }
                let old = try pixel(stale, at: point)
                if zip(old, rhs).contains(where: { abs($0 - $1) > 4 }) { correctedPixels += 1 }
            }
        }
        #expect(mismatches < 8, "Sibling predictions differ at \(mismatches) pixels")
        #expect(correctedPixels > 200)
        withExtendedLifetime(portals) {}
    }

    @Test("A portal-free viewport uses its predicted clip instead of the old CA clip")
    func predictedViewportWithoutPortal() throws {
        let parent = CALayer()
        parent.bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let viewport = CALayer()
        viewport.frame = CGRect(x: 20, y: 0, width: 120, height: 30)
        viewport.bounds.origin.y = 80
        viewport.masksToBounds = true
        parent.addSublayer(viewport)
        let content = CALayer()
        content.frame = CGRect(x: 0, y: 0, width: 120, height: 140)
        content.backgroundColor = UIColor.green.cgColor
        viewport.addSublayer(content)
        let bounds = CGRect(x: 0, y: 10, width: 120, height: 120)
        let position = CGPoint(x: 80, y: 110)
        let prediction = GlassCapturePrediction(layer: viewport, position: position, bounds: bounds)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: parent.bounds, format: format)
        let actual = renderer.image {
            BubblePortalCaptureRenderer.renderLayerForCapture(
                parent, in: $0.cgContext, clipRectInLayer: parent.bounds,
                predictions: GlassCapturePredictions([prediction])
            )
        }
        viewport.bounds = bounds
        viewport.position = position
        let expected = renderer.image { parent.render(in: $0.cgContext) }
        for point in [CGPoint(x: 50, y: 51), CGPoint(x: 50, y: 169),
                      CGPoint(x: 50, y: 49), CGPoint(x: 50, y: 171)] {
            let lhs = try pixel(actual, at: point)
            let rhs = try pixel(expected, at: point)
            #expect(zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 })
        }
    }

    @Test("Shared layer geometry preserves a nonzero bounds origin and flipped clip")
    func boundsOriginAndClip() throws {
        let parent = CALayer()
        parent.bounds = CGRect(x: 0, y: 0, width: 160, height: 140)
        let child = CALayer()
        child.bounds = CGRect(x: 13, y: 17, width: 100, height: 80)
        child.position = CGPoint(x: 80, y: 70)
        child.transform = CATransform3DMakeScale(0.9, -0.9, 1)
        child.backgroundColor = UIColor.blue.cgColor
        let content = CALayer()
        content.frame = CGRect(x: 30, y: 25, width: 35, height: 20)
        content.backgroundColor = UIColor.red.cgColor
        child.addSublayer(content)
        parent.addSublayer(child)
        let clip = CGRect(x: 45, y: 42, width: 60, height: 50)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(bounds: clip, format: format)
        let actual = renderer.image {
            let ctx = $0.cgContext
            ctx.clip(to: clip)
            BubblePortalCaptureRenderer.withLayerGeometry(child, in: ctx) {
                BubblePortalCaptureRenderer.renderLayerForCapture(
                    child, in: ctx, clipRectInLayer: child.convert(clip, from: parent)
                )
            }
        }
        let expected = renderer.image { parent.render(in: $0.cgContext) }
        for y in stride(from: 2, to: 48, by: 4) {
            for x in stride(from: 2, to: 58, by: 4) {
                let point = CGPoint(x: x, y: y)
                let lhs = try pixel(actual, at: point)
                let rhs = try pixel(expected, at: point)
                #expect(zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 })
            }
        }
    }

    @Test("A predicted subtree without portals keeps its own contents and background")
    func predictionWithoutPortal() throws {
        let parent = CALayer()
        parent.bounds = CGRect(x: 0, y: 0, width: 120, height: 100)
        let child = CALayer()
        child.frame = CGRect(x: 10, y: 10, width: 100, height: 80)
        child.backgroundColor = UIColor.blue.cgColor
        child.cornerRadius = 12
        child.masksToBounds = true
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        child.contents = UIGraphicsImageRenderer(size: CGSize(width: 100, height: 80), format: format).image {
            $0.cgContext.setFillColor(UIColor.green.cgColor)
            $0.cgContext.fill(CGRect(x: 20, y: 0, width: 20, height: 80))
        }.cgImage
        let detail = CALayer()
        detail.frame = CGRect(x: 60, y: 25, width: 20, height: 30)
        detail.backgroundColor = UIColor.red.cgColor
        child.addSublayer(detail)
        parent.addSublayer(child)
        let renderer = UIGraphicsImageRenderer(bounds: parent.bounds, format: format)
        let prediction = GlassCapturePrediction(layer: child, scale: 0.92)
        let actual = renderer.image {
            BubblePortalCaptureRenderer.renderLayerForCapture(
                parent, in: $0.cgContext, clipRectInLayer: parent.bounds,
                predictions: GlassCapturePredictions([prediction])
            )
        }
        child.transform = CATransform3DMakeScale(0.92, 0.92, 1)
        let expected = renderer.image { parent.render(in: $0.cgContext) }
        for point in [CGPoint(x: 20, y: 50), CGPoint(x: 40, y: 50),
                      CGPoint(x: 80, y: 50), CGPoint(x: 15, y: 15)] {
            let lhs = try pixel(actual, at: point)
            let rhs = try pixel(expected, at: point)
            #expect(zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 2 })
        }
    }

    private func captureTable(
        _ fixture: Fixture, clip: CGRect, layer: CALayer? = nil,
        prediction: GlassCapturePrediction? = nil,
        predictions: [GlassCapturePrediction] = []
    ) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        return UIGraphicsImageRenderer(bounds: clip, format: format).image {
            BubblePortalCaptureRenderer.renderLayerForCapture(
                layer ?? fixture.table.layer, in: $0.cgContext, clipRectInLayer: clip,
                predictions: GlassCapturePredictions(predictions + (prediction.map { [$0] } ?? []))
            )
        }
    }

    private func checkCapture(_ fixture: Fixture, layer: CALayer) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let capture = UIGraphicsImageRenderer(bounds: layer.bounds, format: format).image {
            BubblePortalCaptureRenderer.renderLayerForCapture(
                layer, in: $0.cgContext, clipRectInLayer: layer.bounds
            )
        }
        let sourceLayer = layer === fixture.portal.layer
            ? fixture.canvas.layer
            : try #require(fixture.canvas.layer.presentation())
        let reference = UIGraphicsImageRenderer(bounds: sourceLayer.bounds, format: format).image {
            sourceLayer.render(in: $0.cgContext)
        }
        for point in [CGPoint(x: 30, y: 60), CGPoint(x: 160, y: 90), CGPoint(x: 300, y: 120)] {
            let sourcePoint: CGPoint
            if layer === fixture.portal.layer || fixture.portal.view.window !== fixture.source.window {
                // The cross-window case has no active animation, so UIKit's
                // model conversion is an independent reference for both trees.
                sourcePoint = fixture.portal.view.convert(point, to: fixture.canvas)
            } else {
                sourcePoint = layer.convert(point, to: sourceLayer)
            }
            let actual = try pixel(capture, at: point)
            let expected = try pixel(reference, at: sourcePoint)
            #expect(actual[3] > 250, "Gradient missing at \(point)")
            for component in 0..<3 {
                #expect(abs(actual[component] - expected[component]) <= 3,
                        "Gradient misaligned at \(point), source \(sourcePoint)")
            }
        }
    }

    private func pixel(_ image: UIImage, at point: CGPoint) throws -> [Int] {
        let image = try #require(image.cgImage?.cropping(to: CGRect(
            x: floor(point.x), y: floor(point.y), width: 1, height: 1
        )))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try #require(CGContext(
                data: buffer.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
            ))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return bytes.map(Int.init)
    }
}
