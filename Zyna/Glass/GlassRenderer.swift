//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal
import MetalPerformanceShaders

/// Renders the glass effect into a CAMetalLayer.
/// Driven externally by GlassService via DisplayLink.
/// Uses CAMetalLayer.nextDrawable() directly to avoid MTKView drawable reuse issues.
final class GlassRenderer: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }

    // swiftlint:disable:next force_cast
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let uniformsBuffer: MTLBuffer
    private let gaussianBlur: MPSImageGaussianBlur
    private var blurTexture: MTLTexture?

    // MARK: - Init

    init() {
        let ctx = MetalContext.shared
        uniformsBuffer = ctx.device.makeBuffer(length: 512, options: [])!
        gaussianBlur = MPSImageGaussianBlur(device: ctx.device, sigma: 6.0)
        gaussianBlur.edgeMode = .clamp
        super.init(frame: .zero)

        metalLayer.device = ctx.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        if #available(iOS 16, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }
        isUserInteractionEnabled = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }

    // MARK: - Types

    /// Multi-shape glass uniforms. Matches GlassUniforms in Metal.
    struct ShapeParams {
        /// Shape 0: rounded rect (x, y, w, h) in normalized capture coords
        var shape0: SIMD4<Float> = .zero
        var shape0cornerR: Float = 0
        /// Shape 1: circle (centerX, centerY, radius, 0) in normalized capture coords
        var shape1: SIMD4<Float> = .zero
        /// Shape 2: circle (centerX, centerY, radius, 0) in normalized capture coords
        var shape2: SIMD4<Float> = .zero
        var shapeCount: Float = 1
    }

    /// Liquid pool parameters.
    struct LiquidZone {
        /// Normalized Y of the liquid surface (rest position) in capture coords.
        var top: Float
        /// Normalized Y of pool bottom (1.0 = screen bottom).
        var bottom: Float
        /// 0..1 — wave amplitude. Driven by scroll, decays in idle.
        var waveEnergy: Float
    }

    /// Chrome audio-reactive bars above input bar.
    struct BarData {
        /// Bar heights normalized 0..1 (max 16 bars)
        var heights: [Float]
        /// Number of active bars
        var count: Int
        /// Bar zone rect (x, y, w, h) in normalized capture coords.
        /// y = top of tallest bar, h = max bar height zone
        var zone: SIMD4<Float>
    }

    // MARK: - Render

    func render(
        with sourceTexture: MTLTexture,
        shapes: ShapeParams,
        isHDR: Bool,
        liquidZone: LiquidZone? = nil,
        time: Float = 0,
        barData: BarData? = nil
    ) {
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        let res = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        blurTexture = ensureBlurTexture(matching: sourceTexture)
        guard let blurTex = blurTexture,
              let cmdBuf = MetalContext.shared.commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Gaussian blur
        gaussianBlur.encode(commandBuffer: cmdBuf, sourceTexture: sourceTexture, destinationTexture: blurTex)

        // Pass 2: Glass + liquid pool fragment
        let aspect = res.x / res.y

        struct Uniforms {
            var resolution: SIMD2<Float>
            var isHDR: Float
            var aspect: Float
            var shape0: SIMD4<Float>
            var shape0cornerR: Float
            var shape1: SIMD4<Float>
            var shape2: SIMD4<Float>
            var shapeCount: Float
            var screenResY: Float
            var liquidTop: Float
            var liquidBottom: Float
            var hasLiquid: Float
            var time: Float
            var waveEnergy: Float
            // Chrome bars
            var barHeights: (Float, Float, Float, Float, Float, Float, Float, Float,
                             Float, Float, Float, Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
            var barCount: Float = 0
            var barZone: SIMD4<Float> = .zero
            var barActive: Float = 0
        }

        let screenResY = Float(UIScreen.main.bounds.height * UIScreen.main.scale)

        var u = Uniforms(
            resolution: res,
            isHDR: isHDR ? 1.0 : 0.0,
            aspect: aspect,
            shape0: shapes.shape0,
            shape0cornerR: shapes.shape0cornerR,
            shape1: shapes.shape1,
            shape2: shapes.shape2,
            shapeCount: shapes.shapeCount,
            screenResY: screenResY,
            liquidTop: liquidZone?.top ?? 0,
            liquidBottom: liquidZone?.bottom ?? 1,
            hasLiquid: liquidZone != nil ? 1.0 : 0.0,
            time: time,
            waveEnergy: liquidZone?.waveEnergy ?? 0
        )

        if let bd = barData {
            u.barActive = 1.0
            u.barCount = Float(min(bd.count, 16))
            u.barZone = bd.zone
            withUnsafeMutablePointer(to: &u.barHeights) { ptr in
                let floats = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Float.self)
                for i in 0..<min(bd.heights.count, 16) {
                    floats[i] = bd.heights[i]
                }
            }
        }

        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<Uniforms>.size)

        guard let drawable = metalLayer.nextDrawable() else { return }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }

        encoder.setRenderPipelineState(GlassPipeline.shared.pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(sourceTexture, index: 0)
        encoder.setFragmentTexture(blurTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }

    // MARK: - Blur Texture

    private func ensureBlurTexture(matching source: MTLTexture) -> MTLTexture? {
        if let existing = blurTexture,
           existing.width == source.width,
           existing.height == source.height,
           existing.pixelFormat == source.pixelFormat {
            return existing
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        return MetalContext.shared.device.makeTexture(descriptor: desc)
    }
}
