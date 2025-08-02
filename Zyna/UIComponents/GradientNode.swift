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
        self.isLayerBacked = true ///< layer-backed rendering for async performance
        self.isOpaque = false ///< allow transparency for gradient
    }
    
    // MARK: - Texture Async Rendering
    
    override class func draw(
        _ bounds: CGRect,
        withParameters parameters: Any?,
        isCancelled isCancelledBlock: () -> Bool,
        isRasterizing: Bool
    ) {
        // Check if rendering is cancelled to avoid unnecessary work
        if isCancelledBlock() {
            return
        }
        
        // Ensure we have a valid context
        guard let context = UIGraphicsGetCurrentContext() else { return }
        
        // Cast parameters to GradientNode
        guard let parameters = parameters as? GradientNode else {
            print("Failed to cast parameters to GradientNode")
            return
        }
        
        // Extract colors and locations from parameters
        let locations: [CGFloat] = parameters.gradientColors.map { $0.location }
        let colors: [CGColor] = parameters.gradientColors.map { $0.color.cgColor }
        
        // Validate inputs
        guard !colors.isEmpty else {
            print("GradientNode: No colors provided")
            return
        }
        guard locations.allSatisfy({ $0 >= 0.0 && $0 <= 1.0 }) else {
            print("GradientNode: Locations must be in range [0.0, 1.0]")
            return
        }
        
        // Create gradient with sRGB color space
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else { return }
        guard let gradient = CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations) else { return }
        
        // Isolate context changes
        context.saveGState() ///< save context state to avoid affecting other renderings
        context.clip(to: bounds) ///< clip drawing to node bounds
        
        // Calculate angle in radians, adjusting coordinate system (0° = up, 180° = down)
        let angle = (parameters.gradientDirectionAngle - 90) * .pi / 180.0
        
        // Find center of bounds
        let centerX = bounds.midX
        let centerY = bounds.midY
        
        // Calculate direction vector
        let dx = cos(angle)
        let dy = sin(angle)
        
        // Get half dimensions for scaling
        let halfWidth = bounds.width * 0.5
        let halfHeight = bounds.height * 0.5
        
        // Calculate scaling to ensure gradient touches bounds edges
        let absDx = abs(dx)
        let absDy = abs(dy)
        let scaleX = absDx > 0.001 ? halfWidth / absDx : .greatestFiniteMagnitude
        let scaleY = absDy > 0.001 ? halfHeight / absDy : .greatestFiniteMagnitude
        let scale = min(scaleX, scaleY)
        
        // Scale direction vector
        let scaledDx = dx * scale
        let scaledDy = dy * scale
        
        // Define start and end points for gradient
        let startPoint = CGPoint(x: centerX - scaledDx, y: centerY - scaledDy)
        let endPoint = CGPoint(x: centerX + scaledDx, y: centerY + scaledDy)
        
        // Draw gradient with extended fill
        context.drawLinearGradient(
            gradient,
            start: startPoint,
            end: endPoint,
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        
        // Restore context state
        context.restoreGState()
    }
    
    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        return self // Pass self as parameters for drawing
    }
}
