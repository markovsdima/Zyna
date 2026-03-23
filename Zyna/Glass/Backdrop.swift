import UIKit
import MetalKit
import MetalPerformanceShaders

// MARK: - BackdropView (iOS < 26)

final class BackdropView: UIView {

    override class var layerClass: AnyClass {
        NSClassFromString("CABackdropLayer") ?? CALayer.self
    }

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        layer.setValue(false, forKey: "layerUsesCoreImageFilters")
        layer.setValue(true, forKey: "windowServerAware")
        layer.setValue(UUID().uuidString, forKey: "groupName")
    }

    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - GlassView (CABackdropLayer path)

/// Self-contained glass effect view using CABackdropLayer for backdrop capture.
/// Works on iOS < 26. On iOS 26+, use GlassAnchor instead.
final class GlassView: MTKView {

    private let backdropView = BackdropView()
    private var commandQueue: MTLCommandQueue!
    private var uniformsBuffer: MTLBuffer!
    private var zeroCopyBridge: ZeroCopyBridge!
    private var gaussianBlur: MPSImageGaussianBlur!
    private var backgroundTexture: MTLTexture?
    private var blurTexture: MTLTexture?

    var cornerRadius: CGFloat = 24

    #if DEBUG
    private var tickCount = 0
    private var captureTimeAccum: Double = 0
    private var renderTimeAccum: Double = 0
    private var totalTimeAccum: Double = 0
    private var statsTimestamp: CFTimeInterval = 0
    #endif

    init() {
        super.init(frame: .zero, device: MetalContext.shared.device)
        setupMetal()
    }

    required init(coder: NSCoder) { fatalError() }

    private func setupMetal() {
        let ctx = MetalContext.shared
        commandQueue = ctx.commandQueue
        uniformsBuffer = ctx.device.makeBuffer(length: 256, options: [])!
        zeroCopyBridge = ZeroCopyBridge(device: ctx.device)
        gaussianBlur = MPSImageGaussianBlur(device: ctx.device, sigma: 12.0)
        gaussianBlur.edgeMode = .clamp

        isOpaque = false
        layer.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        isPaused = false
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()

        let scale = layer.contentsScale
        let w = Int(bounds.width * scale)
        let h = Int(bounds.height * scale)
        guard w > 0, h > 0 else { return }
        zeroCopyBridge.setupBuffer(width: w, height: h)
    }

    // MARK: - Capture

    private func captureBackdrop() {
        guard let superview else { return }

        let scale = layer.contentsScale
        let currentLayer = layer.presentation() ?? layer
        let frameInSuper = currentLayer.convert(currentLayer.bounds, to: superview.layer)

        backdropView.frame = frameInSuper

        if backdropView.superview !== superview {
            superview.insertSubview(backdropView, belowSubview: self)
        }

        backgroundTexture = zeroCopyBridge.render { ctx in
            ctx.scaleBy(x: scale, y: scale)
            UIGraphicsPushContext(ctx)
            backdropView.drawHierarchy(in: backdropView.bounds, afterScreenUpdates: false)
            UIGraphicsPopContext()
        }
    }

    // MARK: - Blur Texture

    private func ensureBlurTexture(matching source: MTLTexture) -> MTLTexture? {
        if let existing = blurTexture,
           existing.width == source.width,
           existing.height == source.height {
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
        blurTexture = device?.makeTexture(descriptor: desc)
        return blurTexture
    }

    // MARK: - Draw

    override func draw(_ rect: CGRect) {
        #if DEBUG
        let tickStart = CACurrentMediaTime()
        #endif

        captureBackdrop()

        guard let sourceTex = backgroundTexture,
              let blurTex = ensureBlurTexture(matching: sourceTex),
              let cmdBuf = commandQueue.makeCommandBuffer()
        else { return }

        #if DEBUG
        let captureEnd = CACurrentMediaTime()
        #endif

        // Pass 1: Gaussian blur
        gaussianBlur.encode(commandBuffer: cmdBuf, sourceTexture: sourceTex, destinationTexture: blurTex)

        // Pass 2: Glass
        let scale = Float(layer.contentsScale)
        let res = SIMD2<Float>(Float(bounds.width) * scale, Float(bounds.height) * scale)
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
            isHDR: 0.0,
            shapeRect: SIMD4<Float>(0, 0, 1, 1),
            aspect: aspect,
            padding0: 0,
            padding1: 0,
            padding2: 0
        )
        memcpy(uniformsBuffer.contents(), &u, MemoryLayout<Uniforms>.size)

        guard let drawable = currentDrawable,
              let rpd = currentRenderPassDescriptor,
              let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd)
        else { return }

        encoder.setRenderPipelineState(GlassPipeline.shared.pipelineState)
        encoder.setFragmentBuffer(uniformsBuffer, offset: 0, index: 0)
        encoder.setFragmentTexture(sourceTex, index: 0)
        encoder.setFragmentTexture(blurTex, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()

        #if DEBUG
        let now = CACurrentMediaTime()
        let captureTime = (captureEnd - tickStart) * 1000
        let renderTime = (now - captureEnd) * 1000
        let totalTime = (now - tickStart) * 1000
        captureTimeAccum += captureTime
        renderTimeAccum += renderTime
        totalTimeAccum += totalTime
        tickCount += 1

        if statsTimestamp == 0 { statsTimestamp = now }
        if now - statsTimestamp >= 1.0 {
            let n = Double(tickCount)
            let fps = n / (now - statsTimestamp)
            print("[glass:legacy] fps=\(String(format: "%.0f", fps)) capture=\(String(format: "%.2f", captureTimeAccum/n))ms render=\(String(format: "%.2f", renderTimeAccum/n))ms total=\(String(format: "%.2f", totalTimeAccum/n))ms")
            tickCount = 0
            captureTimeAccum = 0
            renderTimeAccum = 0
            totalTimeAccum = 0
            statsTimestamp = now
        }
        #endif
    }
}
