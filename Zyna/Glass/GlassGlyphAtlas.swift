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

    /// Attach glyph variant selector:
    /// 0 = Sweep, 1 = Sweep ribbon, 2 = Round light, 3 = Round soft.
    static let attachGlyphVariant = 2

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
            drawSoftChevronDownGlyph(.chevronDown, tileSize: tile)
            drawSoftChevronLeftGlyph(.chevronLeft, tileSize: tile)
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
        switch attachGlyphVariant {
        case 0:
            drawAttachGlyphDesignerSweep(kind, tileSize: tileSize)
        case 1:
            drawAttachGlyphDesignerRibbon(kind, tileSize: tileSize)
        case 2:
            drawAttachGlyphDesignerRoundLight(kind, tileSize: tileSize)
        case 3:
            drawAttachGlyphDesignerRoundSoft(kind, tileSize: tileSize)
        default:
            drawAttachGlyphDesignerRoundLight(kind, tileSize: tileSize)
        }
    }

    private static func drawAttachGlyphDesignerRibbon(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
        let angle = CGFloat.pi / 4
        let cosA = cos(angle)
        let sinA = sin(angle)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + x * cosA - y * sinA,
                y: center.y + x * sinA + y * cosA
            )
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 9.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(17, -41))
        path.addCurve(
            to: point(-22, -23),
            controlPoint1: point(5, -55),
            controlPoint2: point(-22, -54)
        )
        path.addCurve(
            to: point(-22, 30),
            controlPoint1: point(-23, -4),
            controlPoint2: point(-24, 17)
        )
        path.addCurve(
            to: point(24, 27),
            controlPoint1: point(-17, 54),
            controlPoint2: point(24, 55)
        )
        path.addCurve(
            to: point(20, -19),
            controlPoint1: point(24, 12),
            controlPoint2: point(23, -4)
        )
        path.addCurve(
            to: point(-3, -17),
            controlPoint1: point(16, -31),
            controlPoint2: point(-3, -31)
        )
        path.addCurve(
            to: point(-3, 29),
            controlPoint1: point(-4, -1),
            controlPoint2: point(-4, 16)
        )
        path.stroke()
    }

    private static func drawAttachGlyphDesignerSweep(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
        let angle = CGFloat.pi / 4
        let cosA = cos(angle)
        let sinA = sin(angle)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + x * cosA - y * sinA,
                y: center.y + x * sinA + y * cosA
            )
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 9.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(16, -42))
        path.addCurve(
            to: point(-23, -24),
            controlPoint1: point(4, -56),
            controlPoint2: point(-23, -55)
        )
        path.addCurve(
            to: point(-23, 30),
            controlPoint1: point(-24, -5),
            controlPoint2: point(-25, 18)
        )
        path.addCurve(
            to: point(24, 27),
            controlPoint1: point(-16, 55),
            controlPoint2: point(24, 56)
        )
        path.addCurve(
            to: point(21, -20),
            controlPoint1: point(24, 11),
            controlPoint2: point(24, -5)
        )
        path.addCurve(
            to: point(-2, -17),
            controlPoint1: point(18, -31),
            controlPoint2: point(-2, -31)
        )
        path.addCurve(
            to: point(-2, 29),
            controlPoint1: point(-3, -1),
            controlPoint2: point(-3, 15)
        )
        path.stroke()
    }

    private static func drawAttachGlyphDesignerRoundLight(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
        let angle = CGFloat.pi / 4
        let cosA = cos(angle)
        let sinA = sin(angle)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + x * cosA - y * sinA,
                y: center.y + x * sinA + y * cosA
            )
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 8.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(15, -41))
        path.addCurve(
            to: point(-24, -21),
            controlPoint1: point(2, -57),
            controlPoint2: point(-24, -54)
        )
        path.addCurve(
            to: point(-23, 31),
            controlPoint1: point(-25, -3),
            controlPoint2: point(-25, 18)
        )
        path.addCurve(
            to: point(24, 29),
            controlPoint1: point(-18, 58),
            controlPoint2: point(24, 59)
        )
        path.addCurve(
            to: point(22, -19),
            controlPoint1: point(25, 13),
            controlPoint2: point(25, -4)
        )
        path.addCurve(
            to: point(-1, -17),
            controlPoint1: point(18, -31),
            controlPoint2: point(-1, -32)
        )
        path.addCurve(
            to: point(-1, 29),
            controlPoint1: point(-2, -1),
            controlPoint2: point(-2, 16)
        )
        path.stroke()
    }

    private static func drawAttachGlyphDesignerRoundSoft(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)
        let angle = CGFloat.pi / 4
        let cosA = cos(angle)
        let sinA = sin(angle)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(
                x: center.x + x * cosA - y * sinA,
                y: center.y + x * sinA + y * cosA
            )
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 10
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(16, -38))
        path.addCurve(
            to: point(-21, -20),
            controlPoint1: point(4, -52),
            controlPoint2: point(-21, -51)
        )
        path.addCurve(
            to: point(-21, 29),
            controlPoint1: point(-22, -2),
            controlPoint2: point(-23, 17)
        )
        path.addCurve(
            to: point(23, 27),
            controlPoint1: point(-16, 54),
            controlPoint2: point(23, 55)
        )
        path.addCurve(
            to: point(20, -18),
            controlPoint1: point(23, 12),
            controlPoint2: point(23, -3)
        )
        path.addCurve(
            to: point(1, -16),
            controlPoint1: point(17, -28),
            controlPoint2: point(1, -29)
        )
        path.addCurve(
            to: point(1, 27),
            controlPoint1: point(0, -1),
            controlPoint2: point(0, 15)
        )
        path.stroke()
    }

    private static func drawSoftChevronDownGlyph(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x, y: center.y + y)
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 13.5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(-31, -9))
        path.addCurve(
            to: point(0, 20),
            controlPoint1: point(-22, -2),
            controlPoint2: point(-12, 14)
        )
        path.addCurve(
            to: point(31, -9),
            controlPoint1: point(12, 14),
            controlPoint2: point(22, -2)
        )
        path.stroke()
    }

    private static func drawSoftChevronLeftGlyph(_ kind: GlassGlyphKind, tileSize: Int) {
        let originX = CGFloat(kind.rawValue * tileSize)
        let tileRect = CGRect(x: originX, y: 0, width: CGFloat(tileSize), height: CGFloat(tileSize))
        let center = CGPoint(x: tileRect.midX, y: tileRect.midY)

        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: center.x + x, y: center.y + y)
        }

        UIColor.white.setStroke()

        let path = UIBezierPath()
        path.lineWidth = 13
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: point(13, -31))
        path.addCurve(
            to: point(-21, 0),
            controlPoint1: point(3, -23),
            controlPoint2: point(-13, -10)
        )
        path.addCurve(
            to: point(13, 31),
            controlPoint1: point(-13, 10),
            controlPoint2: point(3, 23)
        )
        path.stroke()
    }
}
