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
    private let gaussianBlur: MPSImageGaussianBlur
    private var blurTexture: MTLTexture?
    private var frameInFlight = false

    var isFrameInFlight: Bool { frameInFlight }

    // MARK: - Init

    /// ── Tuning ──
    static let blurSigma: Float = 4.0      // MPS Gaussian blur radius (3=light, 6=default, 12=frosted)

    init() {
        let ctx = MetalContext.shared
        gaussianBlur = MPSImageGaussianBlur(device: ctx.device, sigma: Self.blurSigma)
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

    private struct QuadVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    /// Multi-shape glass uniforms. Matches GlassUniforms in Metal.
    struct ShapeParams {
        /// Shape 0: rounded rect (x, y, w, h) in normalized capture coords
        var shape0: SIMD4<Float> = .zero
        var shape0cornerR: Float = 0
        /// Shape 1: circle (centerX, centerY, radius, 0) in normalized capture coords
        var shape1: SIMD4<Float> = .zero
        /// Shape 2: circle (centerX, centerY, radius, 0) in normalized capture coords
        var shape2: SIMD4<Float> = .zero
        /// Shape 3: scroll button circle (centerX, centerY, radius, 0) — metaball with shape2
        var shape3: SIMD4<Float> = .zero
        var scrollButtonVisible: Float = 0
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

    struct RenderItem {
        let name: String
        let frame: CGRect
        let sourceTexture: MTLTexture
        let shapes: ShapeParams
        let isHDR: Bool
        let liquidZone: LiquidZone?
        let time: Float
        let barData: BarData?
        /// 0 = dark material, 1 = light material. Smoothed by GlassService.
        let adaptiveAppearance: Float
        /// 0 = clear/low intervention, 1 = stronger range compression.
        let adaptiveContrast: Float
    }

    struct ItemBreakdown {
        let name: String
        let renderMs: Double
        let blurMs: Double
        let passMs: Double
    }

    struct BatchBreakdown {
        var drawableMs: Double = 0
        var commitMs: Double = 0
        var items: [ItemBreakdown] = []
        var skippedReason: String?
    }

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var isHDR: Float
        var aspect: Float
        var shape0: SIMD4<Float>
        var shape0cornerR: Float
        var bezelWidth: Float
        var shape1: SIMD4<Float>
        var shape2: SIMD4<Float>
        var shape3: SIMD4<Float>
        var scrollButtonVisible: Float
        var shapeCount: Float
        var glassThickness: Float
        var liquidTop: Float
        var liquidBottom: Float
        var hasLiquid: Float
        var time: Float
        var waveEnergy: Float
        var barHeights: (Float, Float, Float, Float, Float, Float, Float, Float,
                         Float, Float, Float, Float, Float, Float, Float, Float) = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
        var barCount: Float = 0
        var barZone: SIMD4<Float> = .zero
        var barActive: Float = 0
        var ior: Float = 0
        var squircleN: Float = 0
        var refractScale: Float = 0
        var adaptiveAppearance: Float = 1
        var adaptiveContrast: Float = 0
    }

    // MARK: - Render

    @discardableResult
    func render(items: [RenderItem]) -> BatchBreakdown? {
        let validItems = items.filter { !$0.frame.isEmpty && $0.frame.width > 0 && $0.frame.height > 0 }
        guard !validItems.isEmpty else { return nil }
        guard !frameInFlight else {
            var skipped = BatchBreakdown()
            skipped.skippedReason = "in_flight"
            return skipped
        }

        let drawableSize = metalLayer.drawableSize
        guard drawableSize.width > 0, drawableSize.height > 0,
              let cmdBuf = MetalContext.shared.commandQueue.makeCommandBuffer() else { return nil }

        frameInFlight = true
        let nextDrawableStart = CACurrentMediaTime()
        guard let drawable = metalLayer.nextDrawable() else {
            frameInFlight = false
            return nil
        }

        var batch = BatchBreakdown()
        batch.drawableMs = (CACurrentMediaTime() - nextDrawableStart) * 1000

        var isFirstPass = true
        for item in validItems {
            blurTexture = ensureBlurTexture(matching: item.sourceTexture)
            guard let blurTex = blurTexture else { continue }

            let blurStart = CACurrentMediaTime()
            gaussianBlur.encode(commandBuffer: cmdBuf, sourceTexture: item.sourceTexture, destinationTexture: blurTex)
            let blurMs = (CACurrentMediaTime() - blurStart) * 1000

            let passStart = CACurrentMediaTime()
            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = isFirstPass ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { continue }

            var uniforms = makeUniforms(for: item)
            var vertices = makeVertices(for: item.frame)

            encoder.setRenderPipelineState(GlassPipeline.shared.pipelineState)
            encoder.setVertexBytes(&vertices, length: MemoryLayout<QuadVertex>.stride * vertices.count, index: 1)
            // Metal validates constant buffers against the struct's aligned
            // stride, not Swift's logical size without tail padding.
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(item.sourceTexture, index: 0)
            encoder.setFragmentTexture(blurTex, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            let passMs = (CACurrentMediaTime() - passStart) * 1000
            batch.items.append(
                ItemBreakdown(
                    name: item.name,
                    renderMs: blurMs + passMs,
                    blurMs: blurMs,
                    passMs: passMs
                )
            )
            isFirstPass = false
        }

        guard !isFirstPass else {
            frameInFlight = false
            return nil
        }

        let commitStart = CACurrentMediaTime()
        cmdBuf.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.frameInFlight = false
            }
        }
        cmdBuf.present(drawable)
        cmdBuf.commit()
        batch.commitMs = (CACurrentMediaTime() - commitStart) * 1000
        return batch
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

    private func makeUniforms(for item: RenderItem) -> Uniforms {
        let itemScale = window?.screen.scale ?? UIScreen.main.scale
        let res = SIMD2<Float>(Float(item.frame.width * itemScale), Float(item.frame.height * itemScale))
        let aspect = Float(item.frame.width / max(item.frame.height, 1))

        let tuning = GlassTuning.shared
        let captureH = max(item.frame.height, 1)
        let bezelW = Float(tuning.bezelPt / captureH)
        let glassThick = Float(tuning.glassThickPt / captureH)

        var uniforms = Uniforms(
            resolution: res,
            isHDR: item.isHDR ? 1.0 : 0.0,
            aspect: aspect,
            shape0: item.shapes.shape0,
            shape0cornerR: item.shapes.shape0cornerR,
            bezelWidth: bezelW,
            shape1: item.shapes.shape1,
            shape2: item.shapes.shape2,
            shape3: item.shapes.shape3,
            scrollButtonVisible: item.shapes.scrollButtonVisible,
            shapeCount: item.shapes.shapeCount,
            glassThickness: glassThick,
            liquidTop: item.liquidZone?.top ?? 0,
            liquidBottom: item.liquidZone?.bottom ?? 1,
            hasLiquid: item.liquidZone != nil ? 1.0 : 0.0,
            time: item.time,
            waveEnergy: item.liquidZone?.waveEnergy ?? 0
        )

        uniforms.ior = tuning.ior
        uniforms.squircleN = tuning.squircleN
        uniforms.refractScale = tuning.refractScale
        uniforms.adaptiveAppearance = item.adaptiveAppearance
        uniforms.adaptiveContrast = item.adaptiveContrast

        if let barData = item.barData {
            uniforms.barActive = 1.0
            uniforms.barCount = Float(min(barData.count, 16))
            uniforms.barZone = barData.zone
            withUnsafeMutablePointer(to: &uniforms.barHeights) { ptr in
                let floats = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: Float.self)
                for index in 0..<min(barData.heights.count, 16) {
                    floats[index] = barData.heights[index]
                }
            }
        }

        return uniforms
    }

    private func makeVertices(for frame: CGRect) -> [QuadVertex] {
        let boundsSize = bounds.size
        guard boundsSize.width > 0, boundsSize.height > 0 else { return [] }

        let minX = Float(frame.minX / boundsSize.width * 2.0 - 1.0)
        let maxX = Float(frame.maxX / boundsSize.width * 2.0 - 1.0)
        let minY = Float(1.0 - frame.maxY / boundsSize.height * 2.0)
        let maxY = Float(1.0 - frame.minY / boundsSize.height * 2.0)

        return [
            QuadVertex(position: SIMD2<Float>(minX, minY), uv: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(maxX, minY), uv: SIMD2<Float>(1, 1)),
            QuadVertex(position: SIMD2<Float>(minX, maxY), uv: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(maxX, maxY), uv: SIMD2<Float>(1, 0))
        ]
    }
}
