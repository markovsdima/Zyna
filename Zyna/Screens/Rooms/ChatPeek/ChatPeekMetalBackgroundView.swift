//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import Metal
import os.log
import UIKit

final class ChatPeekMetalBackgroundView: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }

    weak var sourceView: UIView? {
        didSet {
            debugLog(
                "sourceView set hasSource=\(sourceView != nil) sourceBounds=\(sourceView?.bounds.debugDescription ?? "nil") sourceWindow=\(sourceView?.window != nil)"
            )
            sourceTexture = nil
            guard window != nil else { return }
            setNeedsRender()
        }
    }

    var sourceCaptureRect: CGRect? {
        didSet {
            let oldRect = oldValue ?? .null
            let newRect = sourceCaptureRect ?? .null
            guard !oldRect.equalTo(newRect) else { return }

            debugLog("sourceCaptureRect set rect=\(newRect.debugDescription)")
            sourceTexture = nil
            guard window != nil else { return }
            setNeedsRender()
        }
    }

    var cardFrame: CGRect = .zero {
        didSet {
            guard !cardFrame.equalTo(oldValue) else { return }
            setNeedsRender()
        }
    }

    var cardCornerRadius: CGFloat = 24 {
        didSet {
            guard cardCornerRadius != oldValue else { return }
            setNeedsRender()
        }
    }

    var progress: CGFloat {
        get { lensProgress }
        set {
            let clamped = min(max(newValue, 0), 1)
            guard abs(lensProgress - clamped) > 0.001 else { return }
            lensProgress = clamped
            setNeedsRender()
            updateDisplayLinkSubscription()
        }
    }

    private var metalLayer: CAMetalLayer {
        // swiftlint:disable:next force_cast
        layer as! CAMetalLayer
    }

    private struct QuadVertex {
        var position: SIMD2<Float>
        var uv: SIMD2<Float>
    }

    private struct Uniforms {
        var resolution: SIMD2<Float>
        var viewSize: SIMD2<Float>
        var cardRect: SIMD4<Float>
        var cornerRadius: Float
        var progress: Float
        var time: Float
        var impulse: Float
        var effectParams: SIMD4<Float>
    }

    private struct ProgressAnimation {
        let from: CGFloat
        let to: CGFloat
        let startTime: CFTimeInterval
        let duration: TimeInterval
        let curve: ProgressCurve
        let completion: (() -> Void)?
    }

    private struct RenderPayload {
        let pipelineState: MTLRenderPipelineState
        let sourceTexture: MTLTexture
        let metalLayer: CAMetalLayer
        let vertices: [QuadVertex]
        let uniforms: Uniforms
        let renderAttempt: Int
        let renderStart: CFTimeInterval
    }

    private enum RenderEvent {
        case noCommandBuffer
        case noDrawable(CFTimeInterval)
        case noEncoder
        case slowDrawable(CFTimeInterval)
        case committed(CFTimeInterval)
        case completed
    }

    enum ProgressCurve {
        case easeIn
        case easeOut
        case easeInOut

        func value(at progress: CGFloat) -> CGFloat {
            let t = min(max(progress, 0), 1)
            switch self {
            case .easeIn:
                return t * t * t
            case .easeOut:
                let inverse = 1 - t
                return 1 - inverse * inverse * inverse
            case .easeInOut:
                return t * t * (3 - 2 * t)
            }
        }
    }

    private static let pipelineState: MTLRenderPipelineState? = {
        let ctx = MetalContext.shared
        guard let vertexFunction = ctx.library.makeFunction(name: "chatPeekLensVertex"),
              let fragmentFunction = ctx.library.makeFunction(name: "chatPeekLensFragment")
        else {
#if DEBUG
            os_log(
                "%{public}@",
                log: .default,
                type: .debug,
                "[ChatPeekLens] pipeline missing vertex/fragment function"
            )
#endif
            return nil
        }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = false
        do {
            return try ctx.device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
#if DEBUG
            os_log(
                "%{public}@",
                log: .default,
                type: .debug,
                "[ChatPeekLens] pipeline creation failed: \(String(describing: error))"
            )
#endif
            return nil
        }
    }()

    private var sourceTexture: MTLTexture?
    private var lensProgress: CGFloat = 0
    private var displayLinkToken: DisplayLinkToken?
    private var progressAnimation: ProgressAnimation?
    private let renderQueue = DispatchQueue(label: "chat.peek.lens.render", qos: .userInteractive)
    private var startTime = CACurrentMediaTime()
    private var frameInFlight = false
    private var needsRender = false
    private var renderRetryScheduled = false

    private static var debugNextID = 0
    private let debugID: Int
    private var debugLastLogTimes: [String: CFTimeInterval] = [:]
    private var debugRenderAttemptCount = 0
    private var debugRenderedFrameCount = 0
    private var debugRetryCount = 0
    private var debugCaptureCount = 0

    override init(frame: CGRect) {
        Self.debugNextID += 1
        debugID = Self.debugNextID
        super.init(frame: frame)

        backgroundColor = .clear
        isUserInteractionEnabled = false
        isOpaque = false

        metalLayer.device = MetalContext.shared.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.isOpaque = false
        metalLayer.maximumDrawableCount = 3
        metalLayer.presentsWithTransaction = false
        if #available(iOS 16, *) {
            metalLayer.allowsNextDrawableTimeout = false
        }

        debugLog("init")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        debugLog(
            "deinit renderedFrames=\(debugRenderedFrameCount) retries=\(debugRetryCount) captures=\(debugCaptureCount)"
        )
        displayLinkToken?.invalidate()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        debugLog("didMoveToWindow hasWindow=\(window != nil) bounds=\(bounds.debugDescription)")
        if window == nil {
            sourceTexture = nil
            displayLinkToken?.invalidate()
            displayLinkToken = nil
        }
        setNeedsRender()
        updateDisplayLinkSubscription()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)

        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            debugLog("trait style changed to \(traitCollection.userInterfaceStyle.rawValue)")
            setNeedsRender()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        let scale = window?.screen.scale ?? UIScreen.main.scale
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        debugLog(
            "layout bounds=\(bounds.debugDescription) drawable=\(metalLayer.drawableSize.debugDescription)",
            throttleKey: "layout",
            interval: 0.35
        )
        setNeedsRender()
    }

    func animateProgress(
        to targetProgress: CGFloat,
        duration: TimeInterval,
        curve: ProgressCurve,
        completion: (() -> Void)? = nil
    ) {
        let targetProgress = min(max(targetProgress, 0), 1)
        guard duration > 0, abs(lensProgress - targetProgress) > 0.001 else {
            debugLog("animateProgress immediate target=\(targetProgress)")
            progress = targetProgress
            completion?()
            return
        }

        debugLog("animateProgress from=\(lensProgress) to=\(targetProgress) duration=\(duration)")

        progressAnimation = ProgressAnimation(
            from: lensProgress,
            to: targetProgress,
            startTime: CACurrentMediaTime(),
            duration: duration,
            curve: curve,
            completion: completion
        )

        setNeedsRender()
        updateDisplayLinkSubscription()
    }

    private func handleDisplayLinkTick() {
        guard window != nil else {
            displayLinkToken?.invalidate()
            displayLinkToken = nil
            return
        }

        let completion = updateProgressAnimation()
        let shouldRender = needsRender || lensProgress > 0.001 || completion != nil
        if shouldRender {
            if frameInFlight {
                needsRender = true
            } else {
                needsRender = false
                render()
            }
        }

        updateDisplayLinkSubscription()
        completion?()
    }

    private func updateProgressAnimation() -> (() -> Void)? {
        guard let progressAnimation else { return nil }

        let elapsed = CACurrentMediaTime() - progressAnimation.startTime
        let linearProgress = min(max(elapsed / max(progressAnimation.duration, 0.001), 0), 1)
        let curvedProgress = progressAnimation.curve.value(at: CGFloat(linearProgress))
        lensProgress = progressAnimation.from + (progressAnimation.to - progressAnimation.from) * curvedProgress

        guard linearProgress >= 1 else { return nil }

        lensProgress = progressAnimation.to
        self.progressAnimation = nil
        return progressAnimation.completion
    }

    private func setNeedsRender() {
        needsRender = true
        updateDisplayLinkSubscription()
        if displayLinkToken == nil {
            needsRender = false
            render()
        }
    }

    private func updateDisplayLinkSubscription() {
        let shouldRun = window != nil && (progressAnimation != nil || lensProgress > 0.001)

        guard shouldRun else {
            if displayLinkToken != nil {
                debugLog("displayLink stop progress=\(lensProgress)")
                displayLinkToken?.invalidate()
                displayLinkToken = nil
            }
            return
        }

        guard displayLinkToken == nil else { return }

        debugLog("displayLink start progress=\(lensProgress) animation=\(progressAnimation != nil)")
        displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .max) { [weak self] _ in
            self?.handleDisplayLinkTick()
        }
    }

    private func debugLog(
        _ message: @autoclosure () -> String,
        throttleKey: String? = nil,
        interval: CFTimeInterval = 0
    ) {
#if DEBUG
        if let throttleKey {
            let now = CACurrentMediaTime()
            if let lastTime = debugLastLogTimes[throttleKey],
               now - lastTime < interval {
                return
            }
            debugLastLogTimes[throttleKey] = now
        }

        os_log(
            "%{public}@",
            log: .default,
            type: .debug,
            "[ChatPeekLens#\(debugID)] \(message())"
        )
#endif
    }

    @discardableResult
    private func captureSourceTexture(afterScreenUpdates: Bool = false, reason: String) -> Bool {
        guard sourceTexture == nil else {
            debugLog("capture skip already-has-texture reason=\(reason)", throttleKey: "capture-has-texture", interval: 0.5)
            return true
        }

        guard let sourceView else {
            debugLog("capture skip no-source reason=\(reason)", throttleKey: "capture-no-source", interval: 0.5)
            return false
        }

        guard sourceView.bounds.width > 1,
              sourceView.bounds.height > 1
        else {
            debugLog(
                "capture skip invalid-source-bounds reason=\(reason) bounds=\(sourceView.bounds.debugDescription)",
                throttleKey: "capture-invalid-bounds",
                interval: 0.5
            )
            return false
        }

        let captureRect = resolvedSourceCaptureRect(in: sourceView)
        guard captureRect.width > 1, captureRect.height > 1 else {
            debugLog(
                "capture skip invalid-capture-rect reason=\(reason) rect=\(captureRect.debugDescription)",
                throttleKey: "capture-invalid-rect",
                interval: 0.5
            )
            return false
        }

        let scale = sourceView.window?.screen.scale ?? UIScreen.main.scale
        let captureStart = CACurrentMediaTime()
        let result = makeTextureByRenderingLayer(sourceView.layer, captureRect: captureRect, scale: scale)
        let renderMs = (result.renderFinishedAt - captureStart) * 1000
        let textureMs = (CACurrentMediaTime() - result.renderFinishedAt) * 1000
        let texture = result.texture
        sourceTexture = texture

        debugCaptureCount += 1
        debugLog(
            "capture \(texture == nil ? "failed" : "ok") #\(debugCaptureCount) strategy=layer.render.direct reason=\(reason) afterUpdates=\(afterScreenUpdates) src=\(sourceView.bounds.size.debugDescription) rect=\(captureRect.debugDescription) px=\(result.pixelWidth)x\(result.pixelHeight) scale=\(String(format: "%.1f", scale)) renderMs=\(String(format: "%.1f", renderMs)) textureMs=\(String(format: "%.1f", textureMs))",
            throttleKey: texture == nil ? "capture-fail" : nil,
            interval: 0.5
        )
        return texture != nil
    }

    private func resolvedSourceCaptureRect(in sourceView: UIView) -> CGRect {
        let requestedRect = sourceCaptureRect ?? sourceView.bounds
        return requestedRect
            .standardized
            .intersection(sourceView.bounds)
    }

    private func makeTextureByRenderingLayer(
        _ layer: CALayer,
        captureRect: CGRect,
        scale: CGFloat
    ) -> (texture: MTLTexture?, pixelWidth: Int, pixelHeight: Int, renderFinishedAt: CFTimeInterval) {
        let width = max(1, Int(ceil(captureRect.width * scale)))
        let height = max(1, Int(ceil(captureRect.height * scale)))
        guard width > 0, height > 0 else {
            debugLog("texture failed invalid-size \(width)x\(height)")
            return (nil, width, height, CACurrentMediaTime())
        }

        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue

        let drewImage = pixels.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: bitmapInfo
                  )
            else { return false }

            context.interpolationQuality = .high
            context.translateBy(x: 0, y: CGFloat(height))
            context.scaleBy(x: scale, y: -scale)
            context.translateBy(x: -captureRect.minX, y: -captureRect.minY)
            layer.render(in: context)
            return true
        }
        let renderFinishedAt = CACurrentMediaTime()

        guard drewImage else {
            debugLog("texture failed bitmap-context width=\(width) height=\(height) bytesPerRow=\(bytesPerRow)")
            return (nil, width, height, renderFinishedAt)
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = MetalContext.shared.device.makeTexture(descriptor: descriptor) else {
            debugLog("texture failed makeTexture width=\(width) height=\(height)")
            return (nil, width, height, renderFinishedAt)
        }

        texture.replace(
            region: MTLRegionMake2D(0, 0, width, height),
            mipmapLevel: 0,
            withBytes: pixels,
            bytesPerRow: bytesPerRow
        )
        return (texture, width, height, renderFinishedAt)
    }

    private func scheduleRenderRetry(reason: String) {
        guard window != nil else {
            debugLog("retry skip no-window reason=\(reason)", throttleKey: "retry-no-window", interval: 0.5)
            return
        }

        guard !renderRetryScheduled else {
            debugLog("retry already scheduled reason=\(reason)", throttleKey: "retry-already", interval: 0.5)
            return
        }

        renderRetryScheduled = true
        debugRetryCount += 1
        debugLog(
            "retry scheduled #\(debugRetryCount) reason=\(reason) progress=\(lensProgress)",
            throttleKey: "retry-\(reason)",
            interval: 0.35
        )
        let delay: TimeInterval = reason == "no-source-texture" ? 0.12 : 0.016
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }

            self.renderRetryScheduled = false
            self.debugLog("retry fired reason=\(reason)", throttleKey: "retry-fired-\(reason)", interval: 0.35)
            self.setNeedsRender()
        }
    }

    private func render() {
        debugRenderAttemptCount += 1
        let renderAttempt = debugRenderAttemptCount
        let renderStart = CACurrentMediaTime()

        guard bounds.width > 1,
              bounds.height > 1
        else {
            debugLog(
                "render skip #\(renderAttempt) invalid-bounds bounds=\(bounds.debugDescription)",
                throttleKey: "render-invalid-bounds",
                interval: 0.5
            )
            scheduleRenderRetry(reason: "invalid-bounds")
            return
        }

        guard let pipelineState = Self.pipelineState else {
            debugLog("render abort #\(renderAttempt) missing-pipeline", throttleKey: "render-missing-pipeline", interval: 5)
            return
        }

        guard !frameInFlight else {
            needsRender = true
            debugLog(
                "render defer #\(renderAttempt) frameInFlight progress=\(lensProgress)",
                throttleKey: "render-frame-in-flight",
                interval: 0.35
            )
            return
        }

        if sourceTexture == nil {
            captureSourceTexture(reason: "render")
        }

        guard let sourceTexture else {
            debugLog(
                "render skip #\(renderAttempt) no-source-texture progress=\(lensProgress)",
                throttleKey: "render-no-source-texture",
                interval: 0.35
            )
            scheduleRenderRetry(reason: "no-source-texture")
            return
        }

        frameInFlight = true
        renderAsync(RenderPayload(
            pipelineState: pipelineState,
            sourceTexture: sourceTexture,
            metalLayer: metalLayer,
            vertices: makeVertices(),
            uniforms: makeUniforms(),
            renderAttempt: renderAttempt,
            renderStart: renderStart
        ))
    }

    private func renderAsync(_ payload: RenderPayload) {
        let handleEvent: (RenderEvent) -> Void = { [weak self] event in
            DispatchQueue.main.async {
                guard let self else { return }

                switch event {
                case let .noDrawable(drawableMs):
                    self.frameInFlight = false
                    self.debugLog(
                        "render skip #\(payload.renderAttempt) no-drawable drawableMs=\(String(format: "%.1f", drawableMs)) drawableSize=\(payload.metalLayer.drawableSize.debugDescription)",
                        throttleKey: "render-no-drawable",
                        interval: 0.35
                    )
                    self.setNeedsRender()
                case .noCommandBuffer:
                    self.frameInFlight = false
                    self.debugLog(
                        "render skip #\(payload.renderAttempt) no-command-buffer",
                        throttleKey: "render-no-command-buffer",
                        interval: 0.5
                    )
                    self.scheduleRenderRetry(reason: "no-command-buffer")
                case .noEncoder:
                    self.frameInFlight = false
                    self.debugLog(
                        "render skip #\(payload.renderAttempt) no-encoder",
                        throttleKey: "render-no-encoder",
                        interval: 0.5
                    )
                    self.setNeedsRender()
                case let .slowDrawable(drawableMs):
                    self.debugLog(
                        "render slow nextDrawable #\(payload.renderAttempt) drawableMs=\(String(format: "%.1f", drawableMs))",
                        throttleKey: "render-slow-drawable",
                        interval: 0.25
                    )
                case let .committed(drawableMs):
                    self.debugRenderedFrameCount += 1
                    let totalMs = (CACurrentMediaTime() - payload.renderStart) * 1000
                    let shouldForceLog = self.debugRenderedFrameCount <= 3 || totalMs > 8 || drawableMs > 4
                    self.debugLog(
                        "render ok frame=\(self.debugRenderedFrameCount) attempt=\(payload.renderAttempt) progress=\(String(format: "%.3f", payload.uniforms.progress)) totalMs=\(String(format: "%.1f", totalMs)) drawableMs=\(String(format: "%.1f", drawableMs)) texture=\(payload.sourceTexture.width)x\(payload.sourceTexture.height)",
                        throttleKey: shouldForceLog ? nil : "render-ok",
                        interval: 1.0
                    )
                case .completed:
                    self.frameInFlight = false
                    if self.needsRender, self.displayLinkToken == nil {
                        self.needsRender = false
                        self.render()
                    }
                }
            }
        }

        renderQueue.async {
            guard let commandBuffer = MetalContext.shared.commandQueue.makeCommandBuffer() else {
                handleEvent(.noCommandBuffer)
                return
            }

            let drawableStart = CACurrentMediaTime()
            guard let drawable = payload.metalLayer.nextDrawable() else {
                handleEvent(.noDrawable((CACurrentMediaTime() - drawableStart) * 1000))
                return
            }

            let drawableMs = (CACurrentMediaTime() - drawableStart) * 1000
            if drawableMs > 4 {
                handleEvent(.slowDrawable(drawableMs))
            }

            let descriptor = MTLRenderPassDescriptor()
            descriptor.colorAttachments[0].texture = drawable.texture
            descriptor.colorAttachments[0].loadAction = .clear
            descriptor.colorAttachments[0].storeAction = .store
            descriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                commandBuffer.commit()
                handleEvent(.noEncoder)
                return
            }

            var vertices = payload.vertices
            var uniforms = payload.uniforms
            encoder.setRenderPipelineState(payload.pipelineState)
            encoder.setVertexBytes(
                &vertices,
                length: MemoryLayout<QuadVertex>.stride * vertices.count,
                index: 0
            )
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(payload.sourceTexture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: vertices.count)
            encoder.endEncoding()

            commandBuffer.addCompletedHandler { _ in
                handleEvent(.completed)
            }
            commandBuffer.present(drawable)
            commandBuffer.commit()
            handleEvent(.committed(drawableMs))
        }
    }

    private func makeVertices() -> [QuadVertex] {
        [
            QuadVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(1, -1), uv: SIMD2<Float>(1, 1)),
            QuadVertex(position: SIMD2<Float>(-1, 1), uv: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0))
        ]
    }

    private func makeUniforms() -> Uniforms {
        let width = max(bounds.width, 1)
        let height = max(bounds.height, 1)
        let drawableSize = metalLayer.drawableSize
        let darkRimStrength: Float
        switch traitCollection.userInterfaceStyle {
        case .dark:
            darkRimStrength = 1.0
        case .light:
            darkRimStrength = 0.52
        default:
            darkRimStrength = 0.72
        }
        let rect = SIMD4<Float>(
            Float(cardFrame.minX / width),
            Float(cardFrame.minY / height),
            Float(cardFrame.width / width),
            Float(cardFrame.height / height)
        )
        return Uniforms(
            resolution: SIMD2<Float>(
                Float(max(drawableSize.width, 1)),
                Float(max(drawableSize.height, 1))
            ),
            viewSize: SIMD2<Float>(Float(width), Float(height)),
            cardRect: rect,
            cornerRadius: Float(cardCornerRadius / height),
            progress: Float(lensProgress),
            time: Float(CACurrentMediaTime() - startTime),
            impulse: Float(sin(lensProgress * .pi)),
            effectParams: SIMD4<Float>(darkRimStrength, 0, 0, 0)
        )
    }
}
