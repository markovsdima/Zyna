//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal
import MetalKit
import QuartzCore

final class PaintSplashLayer: CAMetalLayer {

    private static let referenceArea: CGFloat = 8_000  // ~200×40 text bubble
    private static let baseDropletCount: UInt32 = 300
    private static let maxDropletCount: UInt32 = 1200

    var becameEmpty: (() -> Void)?

    // MARK: - Item

    private final class Item {
        let frame: CGRect
        let texture: MTLTexture
        let dropletBuffer: MTLBuffer
        let dropletCount: UInt32

        var phase: Float = 0
        var isInitialized = false

        init?(frame: CGRect, image: UIImage, device: MTLDevice) {
            self.frame = frame

            // Scale droplet count with bubble area
            let area = frame.width * frame.height
            let scale = pow(area / PaintSplashLayer.referenceArea, 0.6)
            self.dropletCount = min(
                max(UInt32(Float(PaintSplashLayer.baseDropletCount) * Float(scale)), 200),
                PaintSplashLayer.maxDropletCount
            )

            guard let cgImage = image.cgImage,
                  let texture = try? MTKTextureLoader(device: device)
                      .newTexture(cgImage: cgImage, options: [.SRGB: false as NSNumber])
            else { return nil }
            self.texture = texture

            let dropletStride = MemoryLayout<Float>.stride * 16 // matches Droplet struct
            guard let dbuf = device.makeBuffer(
                length: Int(dropletCount) * dropletStride,
                options: .storageModeShared
            ) else { return nil }
            self.dropletBuffer = dbuf
        }
    }

    // MARK: - Pipeline State Cache

    private struct PipelineStates {
        let initCompute: MTLComputePipelineState
        let updateCompute: MTLComputePipelineState
        let blobRender: MTLRenderPipelineState
        let compositeRender: MTLRenderPipelineState
    }

    // MARK: - Properties

    private var items: [Item] = []
    private var displayLinkToken: DisplayLinkToken?
    private var pipelineStates: PipelineStates?
    private var blobTexture: MTLTexture?

    // MARK: - Init

    override init() {
        super.init()
        commonInit()
    }

    override init(layer: Any) {
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        let ctx = MetalContext.shared
        device = ctx.device
        pixelFormat = .bgra8Unorm
        framebufferOnly = false
        isOpaque = false
        backgroundColor = nil
        contentsScale = UIScreen.main.scale

        buildPipelines()
    }

    private func buildPipelines() {
        let ctx = MetalContext.shared
        let lib = ctx.library

        guard let initFn = lib.makeFunction(name: "splashInitializeDroplet"),
              let updateFn = lib.makeFunction(name: "splashUpdateDroplet"),
              let vertexFn = lib.makeFunction(name: "splashVertex"),
              let blobFragFn = lib.makeFunction(name: "splashBlobFragment"),
              let compVertexFn = lib.makeFunction(name: "splashCompositeVertex"),
              let compFragFn = lib.makeFunction(name: "splashCompositeFragment")
        else { return }

        guard let initPSO = try? ctx.device.makeComputePipelineState(function: initFn),
              let updatePSO = try? ctx.device.makeComputePipelineState(function: updateFn)
        else { return }

        // Pass 1: blob accumulation — additive blend into float texture
        let blobRPD = MTLRenderPipelineDescriptor()
        blobRPD.vertexFunction = vertexFn
        blobRPD.fragmentFunction = blobFragFn
        blobRPD.colorAttachments[0].pixelFormat = .rgba16Float
        blobRPD.colorAttachments[0].isBlendingEnabled = true
        blobRPD.colorAttachments[0].rgbBlendOperation = .add
        blobRPD.colorAttachments[0].alphaBlendOperation = .add
        blobRPD.colorAttachments[0].sourceRGBBlendFactor = .one
        blobRPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        blobRPD.colorAttachments[0].destinationRGBBlendFactor = .one
        blobRPD.colorAttachments[0].destinationAlphaBlendFactor = .one

        // Pass 2: metaball composite — alpha blend to drawable
        let compRPD = MTLRenderPipelineDescriptor()
        compRPD.vertexFunction = compVertexFn
        compRPD.fragmentFunction = compFragFn
        compRPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        compRPD.colorAttachments[0].isBlendingEnabled = true
        compRPD.colorAttachments[0].rgbBlendOperation = .add
        compRPD.colorAttachments[0].alphaBlendOperation = .add
        compRPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        compRPD.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        compRPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        compRPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let blobPSO = try? ctx.device.makeRenderPipelineState(descriptor: blobRPD),
              let compPSO = try? ctx.device.makeRenderPipelineState(descriptor: compRPD)
        else { return }

        pipelineStates = PipelineStates(
            initCompute: initPSO,
            updateCompute: updatePSO,
            blobRender: blobPSO,
            compositeRender: compPSO
        )
    }

    // MARK: - Public API

    func addItem(frame: CGRect, image: UIImage) {
        guard let item = Item(
            frame: frame,
            image: image,
            device: MetalContext.shared.device
        ) else { return }

        items.append(item)
        updateNeedsAnimation()
    }

    // MARK: - Animation Loop

    private func updateNeedsAnimation() {
        if !items.isEmpty {
            if displayLinkToken == nil {
                displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] dt in
                    self?.tick(deltaTime: dt)
                }
            }
        } else {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
        }
    }

    private func tick(deltaTime: CFTimeInterval) {
        let dt = Float(min(max(deltaTime, 0.001), 0.05))

        var didRemove = false
        for i in (0..<items.count).reversed() {
            items[i].phase += dt
            if items[i].phase >= 1.2 {
                items.remove(at: i)
                didRemove = true
            }
        }

        render(timeStep: dt)

        if didRemove && items.isEmpty {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
            becameEmpty?()
        }
    }

    // MARK: - Metal Rendering

    private func render(timeStep: Float) {
        guard let pipelineStates else { return }
        guard let drawable = nextDrawable() else { return }

        let ctx = MetalContext.shared
        guard let commandBuffer = ctx.commandQueue.makeCommandBuffer() else { return }

        let containerSize = bounds.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }

        // Ensure offscreen blob texture matches drawable
        let dw = Int(drawableSize.width)
        let dh = Int(drawableSize.height)
        if blobTexture?.width != dw || blobTexture?.height != dh {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: dw, height: dh, mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            blobTexture = ctx.device.makeTexture(descriptor: desc)
        }
        guard let blobTex = blobTexture else { return }

        // --- Compute pass ---
        if let computeEncoder = commandBuffer.makeComputeCommandEncoder() {
            let threadgroupSize = MTLSize(width: 64, height: 1, depth: 1)

            for item in items {
                let threadgroupCount = MTLSize(
                    width: (Int(item.dropletCount) + 63) / 64,
                    height: 1,
                    depth: 1
                )

                computeEncoder.setBuffer(item.dropletBuffer, offset: 0, index: 0)

                if !item.isInitialized {
                    item.isInitialized = true
                    computeEncoder.setComputePipelineState(pipelineStates.initCompute)
                    computeEncoder.setTexture(item.texture, index: 0)
                    var itemSize = SIMD2<Float>(Float(item.frame.width), Float(item.frame.height))
                    computeEncoder.setBytes(&itemSize, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
                    var count = item.dropletCount
                    computeEncoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
                    computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
                }

                computeEncoder.setComputePipelineState(pipelineStates.updateCompute)
                var ts = timeStep
                computeEncoder.setBytes(&ts, length: MemoryLayout<Float>.size, index: 1)
                var count = item.dropletCount
                computeEncoder.setBytes(&count, length: MemoryLayout<UInt32>.size, index: 2)
                computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            }

            computeEncoder.endEncoding()
        }

        // --- Pass 1: Blobs → offscreen float texture (additive) ---
        let blobRPD = MTLRenderPassDescriptor()
        blobRPD.colorAttachments[0].texture = blobTex
        blobRPD.colorAttachments[0].loadAction = .clear
        blobRPD.colorAttachments[0].storeAction = .store
        blobRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let blobEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: blobRPD) {
            blobEncoder.setRenderPipelineState(pipelineStates.blobRender)

            var container = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
            blobEncoder.setVertexBytes(&container, length: MemoryLayout<SIMD2<Float>>.size, index: 0)

            for item in items {
                var origin = SIMD2<Float>(Float(item.frame.origin.x), Float(item.frame.origin.y))
                blobEncoder.setVertexBytes(&origin, length: MemoryLayout<SIMD2<Float>>.size, index: 1)

                var size = SIMD2<Float>(Float(item.frame.width), Float(item.frame.height))
                blobEncoder.setVertexBytes(&size, length: MemoryLayout<SIMD2<Float>>.size, index: 2)

                blobEncoder.setVertexBuffer(item.dropletBuffer, offset: 0, index: 3)

                blobEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: Int(item.dropletCount)
                )
            }

            blobEncoder.endEncoding()
        }

        // --- Pass 2: Metaball composite → drawable ---
        let compRPD = MTLRenderPassDescriptor()
        compRPD.colorAttachments[0].texture = drawable.texture
        compRPD.colorAttachments[0].loadAction = .clear
        compRPD.colorAttachments[0].storeAction = .store
        compRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let compEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compRPD) {
            compEncoder.setRenderPipelineState(pipelineStates.compositeRender)
            compEncoder.setFragmentTexture(blobTex, index: 0)
            compEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            compEncoder.endEncoding()
        }

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}
