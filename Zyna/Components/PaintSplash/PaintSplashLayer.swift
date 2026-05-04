//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal
import MetalKit
import QuartzCore

final class PaintSplashLayer: CAMetalLayer, GlassBackdropOverlaySource {

    private static let referenceArea: CGFloat = 8_000  // ~200×40 text bubble
    private static let baseDropletCount: UInt32 = 300
    private static let maxDropletCount: UInt32 = 1200
    private static let glassDripDuration: CFTimeInterval = 3.2
    private static let maxGlassDropletCount: UInt32 = 160
    private static let maxGlassHitTargetCount = 16
    private static let glassCellsPerTarget = 96
    private static let glassDropletStride = MemoryLayout<Float>.stride * 16
    private static let maxGlassSPHParticleCount: UInt32 = 512
    private static let glassSPHParticleStride = MemoryLayout<Float>.stride * 32

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
                      .newTexture(
                        cgImage: cgImage,
                        options: [
                            .SRGB: false as NSNumber,
                            .origin: MTKTextureLoader.Origin.topLeft.rawValue as NSString
                        ]
                      )
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
        let simulateGlassCompute: MTLComputePipelineState
        let clearGlassEventsCompute: MTLComputePipelineState
        let updateGlassSPHCompute: MTLComputePipelineState
        let blobRender: MTLRenderPipelineState
        let glassImpactRender: MTLRenderPipelineState
        let glassSPHFieldRender: MTLRenderPipelineState
        let glassSPHCompositeRender: MTLRenderPipelineState
        let compositeRender: MTLRenderPipelineState
    }

    // MARK: - Properties

    private var items: [Item] = []
    private var displayLinkToken: DisplayLinkToken?
    private var pipelineStates: PipelineStates?
    private var blobTexture: MTLTexture?
    private var glassSurfaceTexture: MTLTexture?
    private var glassSurfaceWorkTexture: MTLTexture?
    private var glassVelocityTexture: MTLTexture?
    private var glassVelocityWorkTexture: MTLTexture?
    private var glassImpactTexture: MTLTexture?
    private var glassImpactVelocityTexture: MTLTexture?
    private var glassEventBuffer: MTLBuffer?
    private var glassCursorBuffer: MTLBuffer?
    private var glassCellBuffer: MTLBuffer?
    private var glassSPHParticleBuffer: MTLBuffer?
    private var glassSPHParticleWorkBuffer: MTLBuffer?
    private var glassHitTargetBuffer: MTLBuffer?
    private var glassSPHTexture: MTLTexture?
    private var glassDripRemaining: CFTimeInterval = 0
    private var glassDripElapsed: CFTimeInterval = 0
    private var shouldResetGlassSurface = true
    weak var overlayHostView: UIView?

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

    deinit {
        GlassService.shared.removeBackdropOverlaySource(self)
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
              let simulateGlassFn = lib.makeFunction(name: "splashSimulateGlassSurface"),
              let clearGlassEventsFn = lib.makeFunction(name: "splashClearGlassEvents"),
              let updateGlassSPHFn = lib.makeFunction(name: "splashUpdateGlassSPHParticles"),
              let vertexFn = lib.makeFunction(name: "splashVertex"),
              let blobFragFn = lib.makeFunction(name: "splashBlobFragment"),
              let glassDropletVertexFn = lib.makeFunction(name: "splashGlassDropletVertex"),
              let glassDropletFragFn = lib.makeFunction(name: "splashGlassDropletFragment"),
              let glassSPHVertexFn = lib.makeFunction(name: "splashGlassSPHParticleVertex"),
              let glassSPHFragFn = lib.makeFunction(name: "splashGlassSPHParticleFragment"),
              let compVertexFn = lib.makeFunction(name: "splashCompositeVertex"),
              let sphCompFragFn = lib.makeFunction(name: "splashSPHCompositeFragment"),
              let compFragFn = lib.makeFunction(name: "splashCompositeFragment")
        else { return }

        guard let initPSO = try? ctx.device.makeComputePipelineState(function: initFn),
              let updatePSO = try? ctx.device.makeComputePipelineState(function: updateFn),
              let simulateGlassPSO = try? ctx.device.makeComputePipelineState(function: simulateGlassFn),
              let clearGlassEventsPSO = try? ctx.device.makeComputePipelineState(function: clearGlassEventsFn),
              let updateGlassSPHPSO = try? ctx.device.makeComputePipelineState(function: updateGlassSPHFn)
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

        // Pass 1b: one-frame impacts that feed the persistent glass surface.
        let glassDropletRPD = MTLRenderPipelineDescriptor()
        glassDropletRPD.vertexFunction = glassDropletVertexFn
        glassDropletRPD.fragmentFunction = glassDropletFragFn
        glassDropletRPD.colorAttachments[0].pixelFormat = .rgba16Float
        glassDropletRPD.colorAttachments[0].isBlendingEnabled = true
        glassDropletRPD.colorAttachments[0].rgbBlendOperation = .add
        glassDropletRPD.colorAttachments[0].alphaBlendOperation = .add
        glassDropletRPD.colorAttachments[0].sourceRGBBlendFactor = .one
        glassDropletRPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        glassDropletRPD.colorAttachments[0].destinationRGBBlendFactor = .one
        glassDropletRPD.colorAttachments[0].destinationAlphaBlendFactor = .one
        glassDropletRPD.colorAttachments[1].pixelFormat = .rgba16Float
        glassDropletRPD.colorAttachments[1].isBlendingEnabled = true
        glassDropletRPD.colorAttachments[1].rgbBlendOperation = .add
        glassDropletRPD.colorAttachments[1].alphaBlendOperation = .add
        glassDropletRPD.colorAttachments[1].sourceRGBBlendFactor = .one
        glassDropletRPD.colorAttachments[1].sourceAlphaBlendFactor = .one
        glassDropletRPD.colorAttachments[1].destinationRGBBlendFactor = .one
        glassDropletRPD.colorAttachments[1].destinationAlphaBlendFactor = .one

        let glassSPHFieldRPD = MTLRenderPipelineDescriptor()
        glassSPHFieldRPD.vertexFunction = glassSPHVertexFn
        glassSPHFieldRPD.fragmentFunction = glassSPHFragFn
        glassSPHFieldRPD.colorAttachments[0].pixelFormat = .rgba16Float
        glassSPHFieldRPD.colorAttachments[0].isBlendingEnabled = true
        glassSPHFieldRPD.colorAttachments[0].rgbBlendOperation = .add
        glassSPHFieldRPD.colorAttachments[0].alphaBlendOperation = .add
        glassSPHFieldRPD.colorAttachments[0].sourceRGBBlendFactor = .one
        glassSPHFieldRPD.colorAttachments[0].sourceAlphaBlendFactor = .one
        glassSPHFieldRPD.colorAttachments[0].destinationRGBBlendFactor = .one
        glassSPHFieldRPD.colorAttachments[0].destinationAlphaBlendFactor = .one

        let glassSPHCompositeRPD = MTLRenderPipelineDescriptor()
        glassSPHCompositeRPD.vertexFunction = compVertexFn
        glassSPHCompositeRPD.fragmentFunction = sphCompFragFn
        glassSPHCompositeRPD.colorAttachments[0].pixelFormat = .bgra8Unorm
        glassSPHCompositeRPD.colorAttachments[0].isBlendingEnabled = true
        glassSPHCompositeRPD.colorAttachments[0].rgbBlendOperation = .add
        glassSPHCompositeRPD.colorAttachments[0].alphaBlendOperation = .add
        glassSPHCompositeRPD.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        glassSPHCompositeRPD.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        glassSPHCompositeRPD.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        glassSPHCompositeRPD.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        guard let blobPSO = try? ctx.device.makeRenderPipelineState(descriptor: blobRPD),
              let glassDropletPSO = try? ctx.device.makeRenderPipelineState(descriptor: glassDropletRPD),
              let glassSPHFieldPSO = try? ctx.device.makeRenderPipelineState(descriptor: glassSPHFieldRPD),
              let glassSPHCompositePSO = try? ctx.device.makeRenderPipelineState(descriptor: glassSPHCompositeRPD),
              let compPSO = try? ctx.device.makeRenderPipelineState(descriptor: compRPD)
        else { return }

        pipelineStates = PipelineStates(
            initCompute: initPSO,
            updateCompute: updatePSO,
            simulateGlassCompute: simulateGlassPSO,
            clearGlassEventsCompute: clearGlassEventsPSO,
            updateGlassSPHCompute: updateGlassSPHPSO,
            blobRender: blobPSO,
            glassImpactRender: glassDropletPSO,
            glassSPHFieldRender: glassSPHFieldPSO,
            glassSPHCompositeRender: glassSPHCompositePSO,
            compositeRender: compPSO
        )
    }

    // MARK: - Public API

    func addItem(frame: CGRect, image: UIImage) {
        let wasIdle = items.isEmpty && glassDripRemaining <= 0
        guard let item = Item(
            frame: frame,
            image: image,
            device: MetalContext.shared.device
        ) else { return }

        items.append(item)
        if wasIdle {
            shouldResetGlassSurface = true
            glassDripElapsed = 0
        }
        glassDripRemaining = 0
        isHidden = false
        updateNeedsAnimation()
    }

    var glassBackdropOverlay: GlassRenderer.BackdropOverlay? {
        let isVisibleSplash = !items.isEmpty
        guard let overlayHostView,
              overlayHostView.window != nil,
              (isVisibleSplash || glassDripRemaining > 0) else {
            return nil
        }

        let backdropTexture = isVisibleSplash ? blobTexture : glassSurfaceTexture
        let surfaceTexture = glassSurfaceTexture ?? blobTexture
        guard let backdropTexture, let surfaceTexture else {
            return nil
        }

        let wetProgress = glassDripRemaining > 0
            ? Float(glassDripRemaining / Self.glassDripDuration)
            : 1
        let wetIntensity = min(max(wetProgress, 0), 1)
        let frameInWindow = overlayHostView.convert(bounds, to: nil)
        return GlassRenderer.BackdropOverlay(
            backdropTexture: backdropTexture,
            surfaceTexture: surfaceTexture,
            frameInWindow: frameInWindow,
            backdropAlpha: isVisibleSplash ? 1 : 0,
            surfaceIntensity: glassSurfaceTexture == nil ? 0 : (isVisibleSplash ? 1 : wetIntensity),
            surfaceAge: Float(glassDripElapsed)
        )
    }

    // MARK: - Animation Loop

    private func updateNeedsAnimation() {
        if !items.isEmpty || glassDripRemaining > 0 {
            if displayLinkToken == nil {
                GlassService.shared.addBackdropOverlaySource(self)
                displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] dt in
                    self?.tick(deltaTime: dt)
                }
            }
        } else {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
            GlassService.shared.removeBackdropOverlaySource(self)
        }
    }

    private func tick(deltaTime: CFTimeInterval) {
        let dt = Float(min(max(deltaTime, 0.001), 0.05))
        let hadItems = !items.isEmpty

        var didRemove = false
        for i in (0..<items.count).reversed() {
            items[i].phase += dt
            if items[i].phase >= 1.2 {
                items.remove(at: i)
                didRemove = true
            }
        }

        if !items.isEmpty {
            glassDripElapsed += deltaTime
        } else if hadItems && didRemove {
            glassDripRemaining = Self.glassDripDuration
            isHidden = false
        } else if glassDripRemaining > 0 {
            glassDripRemaining = max(0, glassDripRemaining - deltaTime)
            glassDripElapsed += deltaTime
        }

        if !items.isEmpty || glassDripRemaining > 0 {
            render(timeStep: dt)
        }

        if items.isEmpty && glassDripRemaining <= 0 {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
            GlassService.shared.removeBackdropOverlaySource(self)
            isHidden = true
            becameEmpty?()
        }
    }

    // MARK: - Metal Rendering

    private func render(timeStep: Float) {
        guard let pipelineStates else { return }
        let shouldRenderVisibleSplash = !items.isEmpty
        let shouldRenderDrawable = shouldRenderVisibleSplash || glassDripRemaining > 0
        let drawable = shouldRenderDrawable ? nextDrawable() : nil
        guard !shouldRenderDrawable || drawable != nil else { return }

        let ctx = MetalContext.shared
        guard let commandBuffer = ctx.commandQueue.makeCommandBuffer() else { return }

        let containerSize = bounds.size
        guard containerSize.width > 0, containerSize.height > 0 else { return }
        ensureGlassResources()

        // Ensure offscreen blob texture matches drawable
        let dw = Int(drawableSize.width)
        let dh = Int(drawableSize.height)
        if shouldRenderVisibleSplash && (blobTexture?.width != dw || blobTexture?.height != dh) {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba16Float, width: dw, height: dh, mipmapped: false
            )
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .private
            blobTexture = ctx.device.makeTexture(descriptor: desc)
        }
        guard !shouldRenderVisibleSplash || blobTexture != nil else { return }

        ensureGlassTextures(width: dw, height: dh)
        if shouldResetGlassSurface {
            resetGlassEventState()
            clearGlassSurfaceTextures(commandBuffer: commandBuffer)
            shouldResetGlassSurface = false
        }
        let hitTargetCount = updateGlassHitTargets()

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
                var origin = SIMD2<Float>(Float(item.frame.origin.x), Float(item.frame.origin.y))
                computeEncoder.setBytes(&origin, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
                computeEncoder.setBuffer(glassHitTargetBuffer, offset: 0, index: 4)
                var targetCount = hitTargetCount
                computeEncoder.setBytes(&targetCount, length: MemoryLayout<UInt32>.size, index: 5)
                computeEncoder.setBuffer(glassEventBuffer, offset: 0, index: 6)
                computeEncoder.setBuffer(glassCursorBuffer, offset: 0, index: 7)
                var glassCapacity = Self.maxGlassDropletCount
                computeEncoder.setBytes(&glassCapacity, length: MemoryLayout<UInt32>.size, index: 8)
                computeEncoder.setBuffer(glassCellBuffer, offset: 0, index: 9)
                computeEncoder.dispatchThreadgroups(threadgroupCount, threadsPerThreadgroup: threadgroupSize)
            }

            computeEncoder.endEncoding()
        }

        // --- Pass 1: Blobs → offscreen float texture (additive) ---
        if shouldRenderVisibleSplash, let blobTex = blobTexture {
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
        }

        // --- Pass 1b: One-frame glass impacts → source fields for simulation ---
        if let glassImpactTexture, let glassImpactVelocityTexture, let glassEventBuffer {
            let glassRPD = MTLRenderPassDescriptor()
            glassRPD.colorAttachments[0].texture = glassImpactTexture
            glassRPD.colorAttachments[0].loadAction = .clear
            glassRPD.colorAttachments[0].storeAction = .store
            glassRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            glassRPD.colorAttachments[1].texture = glassImpactVelocityTexture
            glassRPD.colorAttachments[1].loadAction = .clear
            glassRPD.colorAttachments[1].storeAction = .store
            glassRPD.colorAttachments[1].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            if let glassEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: glassRPD) {
                glassEncoder.setRenderPipelineState(pipelineStates.glassImpactRender)
                var container = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
                glassEncoder.setVertexBytes(&container, length: MemoryLayout<SIMD2<Float>>.size, index: 0)
                glassEncoder.setVertexBuffer(glassEventBuffer, offset: 0, index: 1)
                glassEncoder.drawPrimitives(
                    type: .triangle,
                    vertexStart: 0,
                    vertexCount: 6,
                    instanceCount: Int(Self.maxGlassDropletCount)
                )
                glassEncoder.endEncoding()
            }
        }

        simulateGlassSurface(
            commandBuffer: commandBuffer,
            timeStep: timeStep,
            containerSize: containerSize,
            hitTargetCount: hitTargetCount
        )
        updateGlassSPHParticles(
            commandBuffer: commandBuffer,
            timeStep: timeStep,
            containerSize: containerSize,
            hitTargetCount: hitTargetCount
        )

        // --- Pass 2: Metaball composite → drawable ---
        var didDrawDrawable = false
        if shouldRenderVisibleSplash, let drawable, let blobTex = blobTexture {
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
                didDrawDrawable = true
            }
        }

        didDrawDrawable = renderGlassSPHMetaballs(
            commandBuffer: commandBuffer,
            drawable: drawable,
            containerSize: containerSize,
            shouldRenderVisibleSplash: shouldRenderVisibleSplash,
            didDrawDrawable: didDrawDrawable
        )

        if let drawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    private func ensureGlassResources() {
        let ctx = MetalContext.shared

        if glassEventBuffer == nil {
            glassEventBuffer = ctx.device.makeBuffer(
                length: Int(Self.maxGlassDropletCount) * Self.glassDropletStride,
                options: .storageModeShared
            )
            shouldResetGlassSurface = true
        }

        if glassCursorBuffer == nil {
            glassCursorBuffer = ctx.device.makeBuffer(
                length: MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            shouldResetGlassSurface = true
        }

        if glassCellBuffer == nil {
            glassCellBuffer = ctx.device.makeBuffer(
                length: Self.maxGlassHitTargetCount * Self.glassCellsPerTarget * MemoryLayout<UInt32>.stride,
                options: .storageModeShared
            )
            shouldResetGlassSurface = true
        }

        if glassSPHParticleBuffer == nil {
            glassSPHParticleBuffer = ctx.device.makeBuffer(
                length: Int(Self.maxGlassSPHParticleCount) * Self.glassSPHParticleStride,
                options: .storageModeShared
            )
            shouldResetGlassSurface = true
        }

        if glassSPHParticleWorkBuffer == nil {
            glassSPHParticleWorkBuffer = ctx.device.makeBuffer(
                length: Int(Self.maxGlassSPHParticleCount) * Self.glassSPHParticleStride,
                options: .storageModeShared
            )
            shouldResetGlassSurface = true
        }

        if glassHitTargetBuffer == nil {
            glassHitTargetBuffer = ctx.device.makeBuffer(
                length: Self.maxGlassHitTargetCount * MemoryLayout<PaintSplashGlassHitTarget>.stride,
                options: .storageModeShared
            )
        }
    }

    private func ensureGlassTextures(width: Int, height: Int) {
        guard width > 0, height > 0 else { return }
        guard glassSurfaceTexture?.width != width || glassSurfaceTexture?.height != height else { return }

        let ctx = MetalContext.shared
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float,
            width: width,
            height: height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead, .shaderWrite]
        desc.storageMode = .private

        glassSurfaceTexture = ctx.device.makeTexture(descriptor: desc)
        glassSurfaceWorkTexture = ctx.device.makeTexture(descriptor: desc)
        glassVelocityTexture = ctx.device.makeTexture(descriptor: desc)
        glassVelocityWorkTexture = ctx.device.makeTexture(descriptor: desc)
        glassImpactTexture = ctx.device.makeTexture(descriptor: desc)
        glassImpactVelocityTexture = ctx.device.makeTexture(descriptor: desc)
        glassSPHTexture = ctx.device.makeTexture(descriptor: desc)
        shouldResetGlassSurface = true
    }

    private func resetGlassEventState() {
        if let glassEventBuffer {
            memset(glassEventBuffer.contents(), 0, glassEventBuffer.length)
        }
        if let glassCursorBuffer {
            memset(glassCursorBuffer.contents(), 0, glassCursorBuffer.length)
        }
        if let glassCellBuffer {
            memset(glassCellBuffer.contents(), 0, glassCellBuffer.length)
        }
        if let glassSPHParticleBuffer {
            memset(glassSPHParticleBuffer.contents(), 0, glassSPHParticleBuffer.length)
        }
        if let glassSPHParticleWorkBuffer {
            memset(glassSPHParticleWorkBuffer.contents(), 0, glassSPHParticleWorkBuffer.length)
        }
    }

    private func clearGlassSurfaceTextures(commandBuffer: MTLCommandBuffer) {
        let textures = [
            glassSurfaceTexture,
            glassSurfaceWorkTexture,
            glassVelocityTexture,
            glassVelocityWorkTexture,
            glassImpactTexture,
            glassImpactVelocityTexture,
            glassSPHTexture
        ]

        let rpd = MTLRenderPassDescriptor()
        for (index, texture) in textures.enumerated() {
            guard let texture else { continue }
            rpd.colorAttachments[index].texture = texture
            rpd.colorAttachments[index].loadAction = .clear
            rpd.colorAttachments[index].storeAction = .store
            rpd.colorAttachments[index].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        }

        commandBuffer.makeRenderCommandEncoder(descriptor: rpd)?.endEncoding()
    }

    private func simulateGlassSurface(
        commandBuffer: MTLCommandBuffer,
        timeStep: Float,
        containerSize: CGSize,
        hitTargetCount: UInt32
    ) {
        guard let pipelineStates,
              let glassSurfaceTexture,
              let glassSurfaceWorkTexture,
              let glassVelocityTexture,
              let glassVelocityWorkTexture,
              let glassImpactTexture,
              let glassImpactVelocityTexture,
              let glassEventBuffer,
              let glassCursorBuffer,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipelineStates.simulateGlassCompute)
        encoder.setTexture(glassSurfaceTexture, index: 0)
        encoder.setTexture(glassVelocityTexture, index: 1)
        encoder.setTexture(glassImpactTexture, index: 2)
        encoder.setTexture(glassImpactVelocityTexture, index: 3)
        encoder.setTexture(glassSurfaceWorkTexture, index: 4)
        encoder.setTexture(glassVelocityWorkTexture, index: 5)
        var ts = timeStep
        encoder.setBytes(&ts, length: MemoryLayout<Float>.size, index: 0)
        var container = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
        encoder.setBytes(&container, length: MemoryLayout<SIMD2<Float>>.size, index: 1)
        encoder.setBuffer(glassHitTargetBuffer, offset: 0, index: 2)
        var targetCount = hitTargetCount
        encoder.setBytes(&targetCount, length: MemoryLayout<UInt32>.size, index: 3)

        let tg = MTLSize(width: 16, height: 16, depth: 1)
        let grid = MTLSize(
            width: glassSurfaceTexture.width,
            height: glassSurfaceTexture.height,
            depth: 1
        )
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)

        encoder.setComputePipelineState(pipelineStates.clearGlassEventsCompute)
        encoder.setBuffer(glassEventBuffer, offset: 0, index: 0)
        encoder.setBuffer(glassCursorBuffer, offset: 0, index: 1)
        var glassCapacity = Self.maxGlassDropletCount
        encoder.setBytes(&glassCapacity, length: MemoryLayout<UInt32>.size, index: 2)
        let eventGrid = MTLSize(width: Int(Self.maxGlassDropletCount), height: 1, depth: 1)
        let eventTG = MTLSize(width: 64, height: 1, depth: 1)
        encoder.dispatchThreads(eventGrid, threadsPerThreadgroup: eventTG)
        encoder.endEncoding()

        let previousSurface = self.glassSurfaceTexture
        self.glassSurfaceTexture = self.glassSurfaceWorkTexture
        self.glassSurfaceWorkTexture = previousSurface

        let previousVelocity = self.glassVelocityTexture
        self.glassVelocityTexture = self.glassVelocityWorkTexture
        self.glassVelocityWorkTexture = previousVelocity
    }

    private func updateGlassSPHParticles(
        commandBuffer: MTLCommandBuffer,
        timeStep: Float,
        containerSize: CGSize,
        hitTargetCount: UInt32
    ) {
        guard let pipelineStates,
              let glassSurfaceTexture,
              let glassVelocityTexture,
              let glassSPHParticleBuffer,
              let glassSPHParticleWorkBuffer,
              let glassHitTargetBuffer,
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }

        encoder.setComputePipelineState(pipelineStates.updateGlassSPHCompute)
        encoder.setBuffer(glassSPHParticleBuffer, offset: 0, index: 0)
        encoder.setBuffer(glassSPHParticleWorkBuffer, offset: 0, index: 1)
        var ts = timeStep
        encoder.setBytes(&ts, length: MemoryLayout<Float>.size, index: 2)
        var container = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
        encoder.setBytes(&container, length: MemoryLayout<SIMD2<Float>>.size, index: 3)
        encoder.setBuffer(glassHitTargetBuffer, offset: 0, index: 4)
        var targetCount = hitTargetCount
        encoder.setBytes(&targetCount, length: MemoryLayout<UInt32>.size, index: 5)
        var capacity = Self.maxGlassSPHParticleCount
        encoder.setBytes(&capacity, length: MemoryLayout<UInt32>.size, index: 6)
        encoder.setTexture(glassSurfaceTexture, index: 0)
        encoder.setTexture(glassVelocityTexture, index: 1)

        let grid = MTLSize(width: Int(Self.maxGlassSPHParticleCount), height: 1, depth: 1)
        let tg = MTLSize(width: 64, height: 1, depth: 1)
        encoder.dispatchThreads(grid, threadsPerThreadgroup: tg)
        encoder.endEncoding()

        let previousParticles = self.glassSPHParticleBuffer
        self.glassSPHParticleBuffer = self.glassSPHParticleWorkBuffer
        self.glassSPHParticleWorkBuffer = previousParticles
    }

    @discardableResult
    private func renderGlassSPHMetaballs(
        commandBuffer: MTLCommandBuffer,
        drawable: CAMetalDrawable?,
        containerSize: CGSize,
        shouldRenderVisibleSplash: Bool,
        didDrawDrawable: Bool
    ) -> Bool {
        guard let pipelineStates,
              let drawable,
              let glassSPHTexture,
              let glassSPHParticleBuffer else {
            return didDrawDrawable
        }

        var visibleFade: Float = shouldRenderVisibleSplash
            ? 1
            : Float(min(1, max(0, glassDripRemaining / 1.15)))

        let fieldRPD = MTLRenderPassDescriptor()
        fieldRPD.colorAttachments[0].texture = glassSPHTexture
        fieldRPD.colorAttachments[0].loadAction = .clear
        fieldRPD.colorAttachments[0].storeAction = .store
        fieldRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let fieldEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: fieldRPD) {
            fieldEncoder.setRenderPipelineState(pipelineStates.glassSPHFieldRender)
            var container = SIMD2<Float>(Float(containerSize.width), Float(containerSize.height))
            fieldEncoder.setVertexBytes(
                &container,
                length: MemoryLayout<SIMD2<Float>>.size,
                index: 0
            )
            fieldEncoder.setVertexBuffer(glassSPHParticleBuffer, offset: 0, index: 1)
            fieldEncoder.setVertexBytes(
                &visibleFade,
                length: MemoryLayout<Float>.size,
                index: 2
            )
            fieldEncoder.setFragmentBytes(
                &visibleFade,
                length: MemoryLayout<Float>.size,
                index: 0
            )
            fieldEncoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: 6,
                instanceCount: Int(Self.maxGlassSPHParticleCount)
            )
            fieldEncoder.endEncoding()
        }

        let compositeRPD = MTLRenderPassDescriptor()
        compositeRPD.colorAttachments[0].texture = drawable.texture
        compositeRPD.colorAttachments[0].loadAction = didDrawDrawable ? .load : .clear
        compositeRPD.colorAttachments[0].storeAction = .store
        compositeRPD.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        if let compositeEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: compositeRPD) {
            compositeEncoder.setRenderPipelineState(pipelineStates.glassSPHCompositeRender)
            compositeEncoder.setFragmentTexture(glassSPHTexture, index: 0)
            compositeEncoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            compositeEncoder.endEncoding()
            return true
        }

        return didDrawDrawable
    }

    private func updateGlassHitTargets() -> UInt32 {
        guard let overlayHostView,
              let glassHitTargetBuffer else {
            return 0
        }

        let targets = GlassService.shared.paintSplashGlassHitTargets(
            in: overlayHostView,
            maxCount: Self.maxGlassHitTargetCount
        )
        guard !targets.isEmpty else { return 0 }

        let pointer = glassHitTargetBuffer.contents()
            .bindMemory(to: PaintSplashGlassHitTarget.self, capacity: Self.maxGlassHitTargetCount)
        for index in targets.indices {
            pointer[index] = targets[index]
        }

        return UInt32(targets.count)
    }
}
