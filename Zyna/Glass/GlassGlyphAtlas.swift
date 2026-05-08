//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal

enum GlassGlyphKind: Int, CaseIterable {
    case mic
    case send
    case attach
    case chevronDown
    case chevronLeft
    case phone
}

struct GlassGlyphAtlas {
    let texture: MTLTexture
    private let sourceRects: [SIMD4<Float>]

    init(texture: MTLTexture, sourceRects: [SIMD4<Float>]) {
        self.texture = texture
        self.sourceRects = sourceRects
    }

    func uv(for kind: GlassGlyphKind) -> SIMD4<Float> {
        sourceRects[kind.rawValue]
    }
}

enum GlassGlyphAtlasBuilder {

    static func makeAtlas(device: MTLDevice) -> GlassGlyphAtlas? {
        let tile = 128
        let glyphs = GlassGlyphKind.allCases
        let width = tile * glyphs.count
        let height = tile
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        let didRender = rgba.withUnsafeMutableBytes { rawBuffer -> Bool in
            guard let context = CGContext(
                data: rawBuffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: bytesPerRow,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                return false
            }

            UIGraphicsPushContext(context)
            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            drawSymbolGlyph(.mic, systemName: "mic.fill", tileSize: tile, pointSize: 92, weight: .medium)
            drawRoundedSendGlyph(.send, tileSize: tile)
            drawAttachGlyph(.attach, tileSize: tile)
            drawSymbolGlyph(.chevronDown, systemName: "chevron.down", tileSize: tile, pointSize: 76, weight: .semibold)
            drawSymbolGlyph(.chevronLeft, systemName: "chevron.left", tileSize: tile, pointSize: 76, weight: .semibold)
            drawSymbolGlyph(.phone, systemName: "phone.fill", tileSize: tile, pointSize: 78, weight: .medium)
            UIGraphicsPopContext()
            return true
        }
        guard didRender else {
            return nil
        }

        var alpha = [UInt8](repeating: 0, count: width * height)
        for index in 0..<(width * height) {
            alpha[index] = rgba[index * bytesPerPixel + 3]
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc) else {
            return nil
        }
        texture.label = "Glass glyph atlas"
        alpha.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        let tileWidth = 1.0 / Float(glyphs.count)
        let sourceRects = glyphs.map { kind in
            SIMD4<Float>(Float(kind.rawValue) * tileWidth, 0.0, tileWidth, 1.0)
        }

        return GlassGlyphAtlas(texture: texture, sourceRects: sourceRects)
    }

    private static func drawSymbolGlyph(
        _ kind: GlassGlyphKind,
        systemName: String,
        tileSize: Int,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight
    ) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = UIImage(systemName: systemName, withConfiguration: config) else { return }
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let imageSize = image.size
        let drawRect = CGRect(
            x: tileRect.midX - imageSize.width / 2,
            y: tileRect.midY - imageSize.height / 2,
            width: imageSize.width,
            height: imageSize.height
        )
        image.withTintColor(.white, renderingMode: .alwaysOriginal).draw(in: drawRect)
    }

    private static func drawRoundedSendGlyph(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let centerX = tileRect.midX
        let topY = tileRect.minY + 27
        let shoulderY = tileRect.minY + 58
        let bottomY = tileRect.minY + 96
        let halfHeadWidth: CGFloat = 32

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 15
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: centerX, y: bottomY))
        path.addLine(to: CGPoint(x: centerX, y: topY))
        path.move(to: CGPoint(x: centerX, y: topY))
        path.addLine(to: CGPoint(x: centerX - halfHeadWidth, y: shoulderY))
        path.move(to: CGPoint(x: centerX, y: topY))
        path.addLine(to: CGPoint(x: centerX + halfHeadWidth, y: shoulderY))
        path.stroke()
    }

    private static func drawAttachGlyph(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x, y: center.y + y)
        }

        UIColor.white.setStroke()

        let outer = UIBezierPath()
        outer.lineWidth = 9.5
        outer.lineCapStyle = .round
        outer.lineJoinStyle = .round
        outer.move(to: point(19, -42))
        outer.addCurve(
            to: point(-24, -24),
            controlPoint1: point(4, -58),
            controlPoint2: point(-24, -55)
        )
        outer.addLine(to: point(-24, 32))
        outer.addCurve(
            to: point(27, 27),
            controlPoint1: point(-24, 60),
            controlPoint2: point(27, 60)
        )
        outer.addLine(to: point(27, -21))
        outer.stroke()

        let inner = UIBezierPath()
        inner.lineWidth = 7.5
        inner.lineCapStyle = .round
        inner.lineJoinStyle = .round
        inner.move(to: point(11, -17.5))
        inner.addLine(to: point(11, 28))
        inner.addCurve(
            to: point(-8, 28),
            controlPoint1: point(11, 42),
            controlPoint2: point(-8, 42)
        )
        inner.addLine(to: point(-8, -13.5))
        inner.stroke()
    }
}
