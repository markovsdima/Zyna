//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal

struct GlassGlyphAtlas {
    let texture: MTLTexture
    let micUV: SIMD4<Float>
    let sendUV: SIMD4<Float>
}

enum GlassGlyphAtlasBuilder {

    static func makeAtlas(device: MTLDevice) -> GlassGlyphAtlas? {
        let tile = 128
        let width = tile * 2
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
            drawSymbolGlyph(systemName: "mic.fill", tileIndex: 0, tileSize: tile, pointSize: 92, weight: .medium)
            drawRoundedSendGlyph(tileIndex: 1, tileSize: tile)
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
        texture.label = "Glass glyph atlas mic-send"
        alpha.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: width
            )
        }

        return GlassGlyphAtlas(
            texture: texture,
            micUV: SIMD4<Float>(0.0, 0.0, 0.5, 1.0),
            sendUV: SIMD4<Float>(0.5, 0.0, 0.5, 1.0)
        )
    }

    private static func drawSymbolGlyph(
        systemName: String,
        tileIndex: Int,
        tileSize: Int,
        pointSize: CGFloat,
        weight: UIImage.SymbolWeight
    ) {
        let config = UIImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        guard let image = UIImage(systemName: systemName, withConfiguration: config) else { return }
        let originX = CGFloat(tileIndex * tileSize)
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

    private static func drawRoundedSendGlyph(tileIndex: Int, tileSize: Int) {
        let originX = CGFloat(tileIndex * tileSize)
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
}
