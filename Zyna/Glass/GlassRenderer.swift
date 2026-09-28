//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal
import MetalPerformanceShaders

protocol GlassBackdropOverlaySource: AnyObject {
    var glassBackdropOverlay: GlassRenderer.BackdropOverlay? { get }
}

/// Renders the glass effect into a CAMetalLayer.
/// Driven externally by GlassService via DisplayLink.
/// Uses CAMetalLayer.nextDrawable() directly to avoid MTKView drawable reuse issues.
final class GlassRenderer: UIView {

    override class var layerClass: AnyClass { CAMetalLayer.self }

    // swiftlint:disable:next force_cast
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
    private let gaussianBlur: MPSImageGaussianBlur
    private var blurTextures: [ReusableTextureKey: CachedTexture] = [:]
    private var compositedSourceTextures: [ReusableTextureKey: CachedTexture] = [:]
    private var emptyOverlayTexture: MTLTexture?
    private var emptyGlyphTexture: MTLTexture?
    private lazy var glyphAtlas = GlassGlyphAtlasBuilder.makeAtlas(device: MetalContext.shared.device)
    private var textureCacheFrame = 0
    private var inFlightLease: GlassCaptureReadLease?
    private var pendingFrame: PendingFrame?

    var isFrameInFlight: Bool { inFlightLease != nil }
    var hasPendingFrame: Bool { pendingFrame != nil }

    // Temporary A/B switch; both paths use the same buffer ownership.
    static let captureOverlapEnabled: Bool = {
#if DEBUG
        ProcessInfo.processInfo.environment["GLASS_CAPTURE_OVERLAP"] != "0"
#else
        true
#endif
    }()

    private struct PendingFrame {
        let items: [RenderItem]
#if DEBUG && GLASS_PROFILING
        let profile: GlassCaptureProfiler.Submission?
#endif
    }
#if DEBUG && GLASS_PROFILING
    // Retain the last token through completion to measure capture resumption.
    private(set) var profileSubmission: GlassCaptureProfiler.Submission?
#endif

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
        updateDrawableSize(scale: window?.screen.scale ?? UIScreen.main.scale)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            discardPendingFrame()
        }
    }

    /// Supersede the waiting frame before the CPU reuses its buffers.
    /// GPU leases remain alive until their command's completion callback.
    func discardPendingFrame() {
#if DEBUG && GLASS_PROFILING
        if let pendingFrame {
            GlassCaptureProfiler.shared.discardSubmission(pendingFrame.profile)
        }
#endif
        pendingFrame = nil
    }

    /// Capture can resize the host before UIKit's next layout pass.
    /// Update the drawable without forcing layout on every tick.
    func updateDrawableSize(scale: CGFloat) {
        if contentScaleFactor != scale { contentScaleFactor = scale }
        let size = CGSize(
            width: (bounds.width * scale).rounded(),
            height: (bounds.height * scale).rounded()
        )
        guard metalLayer.drawableSize != size else { return }
        metalLayer.drawableSize = size
        if pendingFrame != nil {
            // Pending item frames belong to the previous host geometry.
            // Recapture instead of submitting them into the resized surface.
            discardPendingFrame()
            GlassService.shared.setNeedsCapture()
        }
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
        /// Reply/forward/edit preview card, normalized in capture coords.
        var previewRect: SIMD4<Float> = .zero
        var previewCornerR: Float = 0
        var previewProgress: Float = 0
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

    /// Optional foreground glyph composited inside the glass pass.
    /// Rect is normalized in capture UV, matching ShapeParams.
    struct GlyphData {
        var items: [GlyphItem]
    }

    struct GlyphItem {
        var rect: SIMD4<Float>
        var effectRect: SIMD4<Float>
        var source0: GlassGlyphKind
        var source1: GlassGlyphKind
        var progress: Float
        var opacity: Float
        var activity: Float
        var sendColor: SIMD4<Float>

        init(
            rect: SIMD4<Float>,
            effectRect: SIMD4<Float>,
            source: GlassGlyphKind,
            opacity: Float = 1,
            activity: Float = 0,
            sendColor: SIMD4<Float> = SIMD4<Float>(0, 0.478, 1, 1)
        ) {
            self.rect = rect
            self.effectRect = effectRect
            self.source0 = source
            self.source1 = source
            self.progress = 0
            self.opacity = opacity
            self.activity = activity
            self.sendColor = sendColor
        }

        init(
            rect: SIMD4<Float>,
            effectRect: SIMD4<Float>,
            source0: GlassGlyphKind,
            source1: GlassGlyphKind,
            progress: Float,
            opacity: Float = 1,
            activity: Float = 0,
            sendColor: SIMD4<Float>
        ) {
            self.rect = rect
            self.effectRect = effectRect
            self.source0 = source0
            self.source1 = source1
            self.progress = progress
            self.opacity = opacity
            self.activity = activity
            self.sendColor = sendColor
        }
    }

    /// Optional dynamic alpha texture for reply/forward/edit preview text.
    /// The preview glass shape itself is carried in ShapeParams so the
    /// no-preview path stays a few zero uniforms and no dynamic texture.
    struct PreviewData {
        var textRect: SIMD4<Float>
        var mode: Float
        var opacity: Float
        var accentColor: SIMD4<Float>
        var texture: MTLTexture
    }

    /// Optional nav voice foreground. Text is a pre-rendered RGBA texture;
    /// waveform samples are drawn procedurally by the shader.
    struct VoiceData {
        var contentRect: SIMD4<Float>
        var contentScale: Float
        var contentReveal: Float
        var textRect: SIMD4<Float>
        var waveformRect: SIMD4<Float>
        var progress: Float
        var scrubProgress: Float
        var isScrubbing: Bool
        var opacity: Float
        var materialOpacity: Float
        var accentColor: SIMD4<Float>
        var samples: [Float]
        var sampleCount: Int
        var textTexture: MTLTexture
    }

    struct BackdropOverlay {
        let backdropTexture: MTLTexture
        let surfaceTexture: MTLTexture
        let frameInWindow: CGRect
        let backdropAlpha: Float
        let surfaceIntensity: Float
        let surfaceAge: Float
    }

    struct RenderItem {
        let name: String
        let frame: CGRect
        let captureFrameInWindow: CGRect
        let source: GlassCaptureBuffer
        var sourceTexture: MTLTexture { source.texture }
        let shapes: ShapeParams
        let isHDR: Bool
        let liquidZone: LiquidZone?
        let time: Float
        let barData: BarData?
        let glyphData: GlyphData?
        let previewData: PreviewData?
        let voiceData: VoiceData?
        let backdropOverlay: BackdropOverlay?
        /// True when sourceTexture changed and the blurred backdrop must be refreshed.
        let refreshBlur: Bool
        /// 0 = dark material, 1 = light material. Smoothed by GlassService.
        let adaptiveAppearance: Float
        /// 0 = clear/low intervention, 1 = stronger range compression.
        let adaptiveContrast: Float
    }

    struct BatchBreakdown {
#if DEBUG && GLASS_PROFILING
        var drawableMs: Double = 0
#endif
        var blurPassCount = 0
        var skippedReason: String?
        var queued = false
    }

    private typealias GlyphVec4Slots = (
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
        SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
    )

    private typealias VoiceSampleSlots = (
        Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float,
        Float, Float, Float, Float, Float, Float
    )

    private struct Uniforms {
        static let emptyGlyphVec4Slots: GlyphVec4Slots = (
            .zero, .zero, .zero, .zero, .zero, .zero
        )
        static let emptyVoiceSamples: VoiceSampleSlots = (
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
        )

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
        var splashCaptureOrigin: SIMD2<Float> = .zero
        var splashCaptureSize: SIMD2<Float> = .zero
        var splashOverlayOrigin: SIMD2<Float> = .zero
        var splashOverlaySize: SIMD2<Float> = .zero
        var splashActive: Float = 0
        var splashSurfaceIntensity: Float = 0
        var splashSurfaceAge: Float = 0
        var glyphMeta: SIMD4<Float> = .zero
        var glyphRects: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var glyphEffectRects: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var glyphSource0s: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var glyphSource1s: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var glyphParams: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var glyphSendColors: GlyphVec4Slots = Self.emptyGlyphVec4Slots
        var previewRect: SIMD4<Float> = .zero
        var previewTextRect: SIMD4<Float> = .zero
        var previewMeta: SIMD4<Float> = .zero
        var previewAccentColor: SIMD4<Float> = .zero
        var voiceContentRect: SIMD4<Float> = .zero
        var voiceContentMeta: SIMD4<Float> = .zero
        var voiceTextRect: SIMD4<Float> = .zero
        var voiceWaveformRect: SIMD4<Float> = .zero
        var voiceMeta: SIMD4<Float> = .zero
        var voiceAccentColor: SIMD4<Float> = .zero
        var voiceSamples: VoiceSampleSlots = Self.emptyVoiceSamples
    }

    private struct BackdropCompositeUniforms {
        var captureOrigin: SIMD2<Float>
        var captureSize: SIMD2<Float>
        var overlayOrigin: SIMD2<Float>
        var overlaySize: SIMD2<Float>
        var overlayAlpha: Float
    }

    private struct ReusableTextureKey: Hashable {
        let width: Int
        let height: Int
        let pixelFormat: UInt

        init(_ texture: MTLTexture) {
            width = texture.width
            height = texture.height
            pixelFormat = texture.pixelFormat.rawValue
        }
    }

    private struct CachedTexture {
        let texture: MTLTexture
        let estimatedBytes: Int
        var lastUsedFrame: Int
        var lastSourceTexture: ObjectIdentifier?
        var lastSourceGeneration: UInt64?
    }

    // MARK: - Render

    @discardableResult
    func render(items: [RenderItem]) -> BatchBreakdown? {
        discardPendingFrame()
        let validItems = items.filter { !$0.frame.isEmpty && $0.frame.width > 0 && $0.frame.height > 0 }
        guard !validItems.isEmpty else { return nil }
        if isFrameInFlight, !Self.captureOverlapEnabled {
            var skipped = BatchBreakdown()
            skipped.skippedReason = "in_flight"
            return skipped
        }
#if DEBUG && GLASS_PROFILING
        let frame = PendingFrame(
            items: validItems,
            profile: GlassCaptureProfiler.shared.prepareSubmission(renderer: self)
        )
#else
        let frame = PendingFrame(items: validItems)
#endif
        if isFrameInFlight {
            pendingFrame = frame
#if DEBUG && GLASS_PROFILING
            GlassCaptureProfiler.shared.queueSubmission(frame.profile)
#endif
            return BatchBreakdown(queued: true)
        }
        return submit(frame)
    }

    private func submit(_ frame: PendingFrame) -> BatchBreakdown? {
        // Release temporary drawable references after every submission,
        // including work submitted from a GPU completion callback.
        autoreleasepool { submitInPool(frame) }
    }

    private func renderPendingFrame() {
        guard window != nil, !isFrameInFlight, let pending = pendingFrame else { return }
        pendingFrame = nil
#if DEBUG && GLASS_PROFILING
        let start = GlassCaptureProfiler.shared.submissionTimer(pending.profile)
#endif
        let result = submit(pending)
#if DEBUG && GLASS_PROFILING
        GlassCaptureProfiler.shared.endQueuedRender(pending.profile, since: start, result: result)
#endif
        if result == nil { GlassService.shared.setNeedsRender() }
    }

    private func submitInPool(_ frame: PendingFrame) -> BatchBreakdown? {
        precondition(!isFrameInFlight)
        let validItems = frame.items
#if DEBUG && GLASS_PROFILING
        var didCommit = false
        defer {
            if !didCommit { GlassCaptureProfiler.shared.discardSubmission(frame.profile) }
        }
        let drawableStart = GlassCaptureProfiler.shared.submissionTimer(frame.profile)
#endif
        guard metalLayer.drawableSize.width > 0, metalLayer.drawableSize.height > 0,
              let drawable = metalLayer.nextDrawable() else { return nil }
#if DEBUG && GLASS_PROFILING
        let drawableWait = drawableStart.map { (CACurrentMediaTime() - $0) * 1000 } ?? 0
#endif

        guard let cmdBuf = MetalContext.shared.commandQueue.makeCommandBuffer() else { return nil }

        var batch = BatchBreakdown()
#if DEBUG && GLASS_PROFILING
        batch.drawableMs = drawableWait
#endif

        textureCacheFrame &+= 1
        cmdBuf.label = "GlassRenderer.render"

        var isFirstPass = true
        for item in validItems {
            let backdropTexture = makeBackdropTexture(for: item, commandBuffer: cmdBuf)

            guard let blurSlot = ensureBlurTexture(
                matching: backdropTexture, generation: item.source.generation
            ) else { continue }
            let blurTex = blurSlot.texture

            let shouldRefreshBlur = item.refreshBlur
                || blurSlot.isNew
                || !blurSlot.containsSource
                || item.backdropOverlay != nil
            if shouldRefreshBlur {
                gaussianBlur.encode(commandBuffer: cmdBuf, sourceTexture: backdropTexture, destinationTexture: blurTex)
                recordBlurTextureSource(backdropTexture, generation: item.source.generation)
                batch.blurPassCount += 1
            }

            let rpd = MTLRenderPassDescriptor()
            rpd.colorAttachments[0].texture = drawable.texture
            rpd.colorAttachments[0].loadAction = isFirstPass ? .clear : .load
            rpd.colorAttachments[0].storeAction = .store
            rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

            guard let encoder = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { continue }
            encoder.label = "GlassRenderer.glassPass.\(item.name)"

            let atlas = glyphAtlas
            var uniforms = makeUniforms(for: item, glyphAtlas: atlas)
            var vertices = makeVertices(for: item.frame)

            encoder.setRenderPipelineState(GlassPipeline.shared.pipelineState)
            encoder.setVertexBytes(&vertices, length: MemoryLayout<QuadVertex>.stride * vertices.count, index: 1)
            // Metal validates constant buffers against the struct's aligned
            // stride, not Swift's logical size without tail padding.
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
            encoder.setFragmentTexture(backdropTexture, index: 0)
            encoder.setFragmentTexture(blurTex, index: 1)
            encoder.setFragmentTexture(item.backdropOverlay?.surfaceTexture ?? emptyOverlayFallbackTexture(), index: 2)
            encoder.setFragmentTexture(atlas?.texture ?? emptyGlyphFallbackTexture(), index: 3)
            encoder.setFragmentTexture(item.previewData?.texture ?? emptyGlyphFallbackTexture(), index: 4)
            encoder.setFragmentTexture(item.voiceData?.textTexture ?? emptyGlyphFallbackTexture(), index: 5)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()

            isFirstPass = false
        }

        guard !isFirstPass else { return nil }

        let lease = GlassCaptureReadLease(validItems.map(\.source))
        inFlightLease = lease
#if DEBUG && GLASS_PROFILING
        let submission = frame.profile
        let measuresSubmission = drawableStart != nil
        profileSubmission = submission
        GlassCaptureProfiler.shared.setRefreshesBlur(submission, batch.blurPassCount > 0)
#endif
        cmdBuf.addCompletedHandler { [weak self] completedBuffer in
#if DEBUG && GLASS_PROFILING
            let callbackTime = measuresSubmission ? CACurrentMediaTime() : 0
            let gpuStart = measuresSubmission ? completedBuffer.gpuStartTime : 0
            let gpuEnd = measuresSubmission ? completedBuffer.gpuEndTime : 0
#endif
            DispatchQueue.main.async {
                // The completion owns the buffers even if its host was removed.
                lease.release()
#if DEBUG && GLASS_PROFILING
                if measuresSubmission {
                    GlassCaptureProfiler.shared.completeSubmission(
                        submission, gpuStart: gpuStart, gpuEnd: gpuEnd,
                        callback: callbackTime, released: CACurrentMediaTime()
                    )
                }
#endif
                guard let self, self.inFlightLease === lease else { return }
                self.inFlightLease = nil
                self.renderPendingFrame()
            }
        }
        cmdBuf.present(drawable)
#if DEBUG && GLASS_PROFILING
        GlassCaptureProfiler.shared.willCommit(submission)
#endif
        cmdBuf.commit()
#if DEBUG && GLASS_PROFILING
        didCommit = true
#endif
        return batch
    }

    private func makeBackdropTexture(for item: RenderItem, commandBuffer: MTLCommandBuffer) -> MTLTexture {
        guard let overlay = item.backdropOverlay,
              overlay.backdropAlpha > 0.001,
              overlay.frameInWindow.intersects(item.captureFrameInWindow),
              let targetTexture = ensureCompositedSourceTexture(matching: item.sourceTexture)
        else {
            return item.sourceTexture
        }

        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = targetTexture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) else {
            return item.sourceTexture
        }
        encoder.label = "GlassRenderer.backdropComposite.\(item.name)"

        var vertices = makeFullscreenVertices()
        var uniforms = BackdropCompositeUniforms(
            captureOrigin: SIMD2<Float>(
                Float(item.captureFrameInWindow.origin.x),
                Float(item.captureFrameInWindow.origin.y)
            ),
            captureSize: SIMD2<Float>(
                Float(item.captureFrameInWindow.width),
                Float(item.captureFrameInWindow.height)
            ),
            overlayOrigin: SIMD2<Float>(
                Float(overlay.frameInWindow.origin.x),
                Float(overlay.frameInWindow.origin.y)
            ),
            overlaySize: SIMD2<Float>(
                Float(max(overlay.frameInWindow.width, 1)),
                Float(max(overlay.frameInWindow.height, 1))
            ),
            overlayAlpha: overlay.backdropAlpha
        )

        encoder.setRenderPipelineState(GlassPipeline.shared.backdropCompositePipelineState)
        encoder.setVertexBytes(&vertices, length: MemoryLayout<QuadVertex>.stride * vertices.count, index: 1)
        encoder.setFragmentBytes(
            &uniforms,
            length: MemoryLayout<BackdropCompositeUniforms>.stride,
            index: 0
        )
        encoder.setFragmentTexture(item.sourceTexture, index: 0)
        encoder.setFragmentTexture(overlay.backdropTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        return targetTexture
    }

    private func emptyOverlayFallbackTexture() -> MTLTexture? {
        if let emptyOverlayTexture {
            return emptyOverlayTexture
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "Glass empty splash overlay 1x1"

        var zero: UInt32 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &zero,
            bytesPerRow: MemoryLayout<UInt32>.stride
        )
        emptyOverlayTexture = texture
        return texture
    }

    private func emptyGlyphFallbackTexture() -> MTLTexture? {
        if let emptyGlyphTexture {
            return emptyGlyphTexture
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: 1,
            height: 1,
            mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else { return nil }
        texture.label = "Glass empty glyph atlas 1x1"

        var zero: UInt8 = 0
        texture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0,
            withBytes: &zero,
            bytesPerRow: MemoryLayout<UInt8>.stride
        )
        emptyGlyphTexture = texture
        return texture
    }

    // MARK: - Blur Texture

    private func ensureBlurTexture(matching source: MTLTexture, generation: UInt64) -> (
        texture: MTLTexture,
        isNew: Bool,
        containsSource: Bool
    )? {
        let key = ReusableTextureKey(source)
        let sourceIdentity = ObjectIdentifier(source as AnyObject)
        if var cached = blurTextures[key] {
            let containsSource = cached.lastSourceTexture == sourceIdentity
                && cached.lastSourceGeneration == generation
            cached.lastUsedFrame = textureCacheFrame
            blurTextures[key] = cached
            return (cached.texture, false, containsSource)
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        desc.usage = [.shaderRead, .shaderWrite]
        desc.storageMode = .private
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else { return nil }

        texture.label = "Glass blur \(source.width)x\(source.height)"
        blurTextures[key] = CachedTexture(
            texture: texture,
            estimatedBytes: Self.estimatedTextureBytes(source),
            lastUsedFrame: textureCacheFrame,
            lastSourceTexture: nil
        )
        Self.pruneReusableTextures(
            &blurTextures,
            maxBytes: Self.maxReusableTextureCacheBytes,
            currentFrame: textureCacheFrame
        )
        return (texture, true, false)
    }

    private func recordBlurTextureSource(_ source: MTLTexture, generation: UInt64) {
        let key = ReusableTextureKey(source)
        guard var cached = blurTextures[key] else { return }
        cached.lastUsedFrame = textureCacheFrame
        cached.lastSourceTexture = ObjectIdentifier(source as AnyObject)
        cached.lastSourceGeneration = generation
        blurTextures[key] = cached
    }

    private func ensureCompositedSourceTexture(matching source: MTLTexture) -> MTLTexture? {
        let key = ReusableTextureKey(source)
        if var cached = compositedSourceTextures[key] {
            cached.lastUsedFrame = textureCacheFrame
            compositedSourceTextures[key] = cached
            return cached.texture
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat,
            width: source.width,
            height: source.height,
            mipmapped: false
        )
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        guard let texture = MetalContext.shared.device.makeTexture(descriptor: desc) else { return nil }

        texture.label = "Glass composited source \(source.width)x\(source.height)"
        compositedSourceTextures[key] = CachedTexture(
            texture: texture,
            estimatedBytes: Self.estimatedTextureBytes(source),
            lastUsedFrame: textureCacheFrame,
            lastSourceTexture: nil
        )
        Self.pruneReusableTextures(
            &compositedSourceTextures,
            maxBytes: Self.maxReusableTextureCacheBytes,
            currentFrame: textureCacheFrame
        )
        return texture
    }

    private static let maxReusableTextureCacheBytes = 32 * 1024 * 1024

    private static func estimatedTextureBytes(_ texture: MTLTexture) -> Int {
        let bytesPerPixel: Int
        switch texture.pixelFormat {
        case .rgba16Float:
            bytesPerPixel = 8
        case .rgba32Float:
            bytesPerPixel = 16
        default:
            bytesPerPixel = 4
        }
        return texture.width * texture.height * bytesPerPixel
    }

    private static func pruneReusableTextures(
        _ cache: inout [ReusableTextureKey: CachedTexture],
        maxBytes: Int,
        currentFrame: Int
    ) {
        var totalBytes = cache.values.reduce(0) { $0 + $1.estimatedBytes }
        guard totalBytes > maxBytes else { return }

        let entriesByAge = cache.sorted {
            if $0.value.lastUsedFrame == $1.value.lastUsedFrame {
                return $0.value.estimatedBytes > $1.value.estimatedBytes
            }
            return $0.value.lastUsedFrame < $1.value.lastUsedFrame
        }

        for (key, entry) in entriesByAge {
            guard totalBytes > maxBytes else { break }
            guard entry.lastUsedFrame < currentFrame else { continue }
            cache.removeValue(forKey: key)
            totalBytes -= entry.estimatedBytes
        }
    }

    private static let maxGlyphSlots = 6
    private static let maxVoiceSamples = 36

    private static func setGlyphVec4(_ value: SIMD4<Float>, in slots: inout GlyphVec4Slots, at index: Int) {
        withUnsafeMutableBytes(of: &slots) { rawBuffer in
            rawBuffer.bindMemory(to: SIMD4<Float>.self)[index] = value
        }
    }

    private static func setVoiceSample(_ value: Float, in slots: inout VoiceSampleSlots, at index: Int) {
        withUnsafeMutableBytes(of: &slots) { rawBuffer in
            rawBuffer.bindMemory(to: Float.self)[index] = value
        }
    }

    private func makeUniforms(for item: RenderItem, glyphAtlas: GlassGlyphAtlas?) -> Uniforms {
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
        uniforms.previewRect = item.shapes.previewRect
        uniforms.previewMeta = SIMD4<Float>(
            item.shapes.previewProgress,
            item.previewData?.mode ?? 0,
            item.previewData?.opacity ?? 0,
            item.shapes.previewCornerR
        )
        if let previewData = item.previewData {
            uniforms.previewTextRect = previewData.textRect
            uniforms.previewAccentColor = previewData.accentColor
        }

        if let voiceData = item.voiceData {
            let count = min(voiceData.sampleCount, voiceData.samples.count, Self.maxVoiceSamples)
            uniforms.voiceContentRect = voiceData.contentRect
            uniforms.voiceContentMeta = SIMD4<Float>(
                max(0.001, min(1.12, voiceData.contentScale)),
                max(0, min(1, voiceData.contentReveal)),
                0,
                0
            )
            uniforms.voiceTextRect = voiceData.textRect
            uniforms.voiceWaveformRect = voiceData.waveformRect
            uniforms.voiceMeta = SIMD4<Float>(
                max(0, min(1, voiceData.progress)),
                max(0, min(1, voiceData.opacity)),
                Float(count),
                voiceData.isScrubbing ? max(0, min(1, voiceData.scrubProgress)) : -1
            )
            uniforms.voiceAccentColor = SIMD4<Float>(
                voiceData.accentColor.x,
                voiceData.accentColor.y,
                voiceData.accentColor.z,
                max(0, min(1, voiceData.materialOpacity))
            )
            for index in 0..<count {
                Self.setVoiceSample(max(0, min(1, voiceData.samples[index])), in: &uniforms.voiceSamples, at: index)
            }
        }

        if let glyphData = item.glyphData, let glyphAtlas {
            var glyphCount = 0
            for glyph in glyphData.items where glyph.opacity > 0.001 {
                guard glyphCount < Self.maxGlyphSlots else { break }
                Self.setGlyphVec4(glyph.rect, in: &uniforms.glyphRects, at: glyphCount)
                Self.setGlyphVec4(glyph.effectRect, in: &uniforms.glyphEffectRects, at: glyphCount)
                Self.setGlyphVec4(glyphAtlas.uv(for: glyph.source0), in: &uniforms.glyphSource0s, at: glyphCount)
                Self.setGlyphVec4(glyphAtlas.uv(for: glyph.source1), in: &uniforms.glyphSource1s, at: glyphCount)
                Self.setGlyphVec4(
                    SIMD4<Float>(glyph.progress, glyph.opacity, glyph.activity, 0),
                    in: &uniforms.glyphParams,
                    at: glyphCount
                )
                Self.setGlyphVec4(glyph.sendColor, in: &uniforms.glyphSendColors, at: glyphCount)
                glyphCount += 1
            }
            uniforms.glyphMeta.x = Float(glyphCount)
        }

        if let overlay = item.backdropOverlay {
            uniforms.splashActive = 1
            uniforms.splashSurfaceIntensity = overlay.surfaceIntensity
            uniforms.splashSurfaceAge = overlay.surfaceAge
            uniforms.splashCaptureOrigin = SIMD2<Float>(
                Float(item.captureFrameInWindow.origin.x),
                Float(item.captureFrameInWindow.origin.y)
            )
            uniforms.splashCaptureSize = SIMD2<Float>(
                Float(max(item.captureFrameInWindow.width, 1)),
                Float(max(item.captureFrameInWindow.height, 1))
            )
            uniforms.splashOverlayOrigin = SIMD2<Float>(
                Float(overlay.frameInWindow.origin.x),
                Float(overlay.frameInWindow.origin.y)
            )
            uniforms.splashOverlaySize = SIMD2<Float>(
                Float(max(overlay.frameInWindow.width, 1)),
                Float(max(overlay.frameInWindow.height, 1))
            )
        }

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

    private func makeFullscreenVertices() -> [QuadVertex] {
        [
            QuadVertex(position: SIMD2<Float>(-1, -1), uv: SIMD2<Float>(0, 1)),
            QuadVertex(position: SIMD2<Float>(1, -1), uv: SIMD2<Float>(1, 1)),
            QuadVertex(position: SIMD2<Float>(-1, 1), uv: SIMD2<Float>(0, 0)),
            QuadVertex(position: SIMD2<Float>(1, 1), uv: SIMD2<Float>(1, 0))
        ]
    }
}
