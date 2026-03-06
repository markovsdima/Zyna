//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

// Gradient data example:
// var locations: [CGFloat] = [0.0, 0.85, 0.9, 1.0]
// let colors: [CGColor] = [UIColor.yellow.cgColor, UIColor.red.cgColor, UIColor.blue.cgColor, UIColor.green.cgColor]


struct GradientNodeColor {
    let color: UIColor
    let location: CGFloat // 0.0...1.0
}

struct GradientNodeStyle {
    let gradientColors: [GradientNodeColor]
    let gradientDirection: Degrees // Angle in degrees (0–359). 0°= upwardDirection (colors start from below)
}

typealias Degrees = CGFloat

class GradientNode: ASDisplayNode {
    private var gradientColors: [GradientNodeColor]
    private var gradientDirectionAngle: Degrees

    init(nodeStyle: GradientNodeStyle) {
        self.gradientColors = nodeStyle.gradientColors
        self.gradientDirectionAngle = nodeStyle.gradientDirection

        super.init()
        self.isLayerBacked = true
        self.isOpaque = false
    }

    // MARK: - Thread-safe draw parameters

    private class DrawParameters: NSObject {
        let colors: [GradientNodeColor]
        let angle: Degrees

        init(colors: [GradientNodeColor], angle: Degrees) {
            self.colors = colors
            self.angle = angle
        }
    }

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        return DrawParameters(colors: gradientColors, angle: gradientDirectionAngle)
    }

    // MARK: - Texture Async Rendering (background thread)

    override class func draw(
        _ bounds: CGRect,
        withParameters parameters: Any?,
        isCancelled isCancelledBlock: () -> Bool,
        isRasterizing: Bool
    ) {
        if isCancelledBlock() { return }

        guard let context = UIGraphicsGetCurrentContext() else { return }

        guard let params = parameters as? DrawParameters else { return }

        let locations: [CGFloat] = params.colors.map { $0.location }
        let colors: [CGColor] = params.colors.map { $0.color.cgColor }

        guard !colors.isEmpty else { return }
        guard locations.allSatisfy({ $0 >= 0.0 && $0 <= 1.0 }) else { return }

        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return }

        context.saveGState()
        context.clip(to: bounds)

        let angle = (params.angle - 90) * .pi / 180.0

        let centerX = bounds.midX
        let centerY = bounds.midY

        let dx = cos(angle)
        let dy = sin(angle)

        let halfWidth = bounds.width * 0.5
        let halfHeight = bounds.height * 0.5

        let absDx = abs(dx)
        let absDy = abs(dy)
        let scaleX = absDx > 0.001 ? halfWidth / absDx : .greatestFiniteMagnitude
        let scaleY = absDy > 0.001 ? halfHeight / absDy : .greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)

        let scaledDx = dx * scale
        let scaledDy = dy * scale

        let startPoint = CGPoint(x: centerX - scaledDx, y: centerY - scaledDy)
        let endPoint = CGPoint(x: centerX + scaledDx, y: centerY + scaledDy)

        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )

        context.restoreGState()
    }
}
