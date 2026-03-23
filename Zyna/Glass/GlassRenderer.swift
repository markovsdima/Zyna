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
        uniformsBuffer = ctx.device.makeBuffer(length: 256, options: [])!
        gaussianBlur = MPSImageGaussianBlur(device: ctx.device, sigma: 12.0)
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

    // MARK: - Render

    func render(
        with sourceTexture: MTLTexture,
        cornerRadius: CGFloat,
        isHDR: Bool
    ) {
        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0 else { return }

        let res = SIMD2<Float>(Float(drawableSize.width), Float(drawableSize.height))

        blurTexture = ensureBlurTexture(matching: sourceTexture)
        guard let blurTex = blurTexture,
              let cmdBuf = MetalContext.shared.commandQueue.makeCommandBuffer() else { return }

        // Pass 1: Gaussian blur
        gaussianBlur.encode(commandBuffer: cmdBuf, sourceTexture: sourceTexture, destinationTexture: blurTex)

        // Pass 2: Glass fragment
        let scale = Float(metalLayer.contentsScale)
        let aspect = res.x / res.y

        struct Uniforms {
            var resolution: SIMD2<Float>
            var cornerRadius: Float
            var isHDR: Float
            var shapeRect: SIMD4<Float>
            var aspect: Float
            var padding0: Float
            var padding1: Float
            var padding2: Float
        }

        var u = Uniforms(
            resolution: res,
            cornerRadius: Float(cornerRadius) * scale / res.y,
            isHDR: isHDR ? 1.0 : 0.0,
            shapeRect: SIMD4<Float>(0, 0, 1, 1),
            aspect: aspect,
            padding0: 0,
            padding1: 0,
            padding2: 0
        )
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
