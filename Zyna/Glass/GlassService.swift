//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import Metal

// MARK: - GlassRegistration

/// RAII token: deregisters the glass effect on deinit.
final class GlassRegistration {

    private let id: UUID
    private weak var service: GlassService?

    init(id: UUID, service: GlassService) {
        self.id = id
        self.service = service
    }

    deinit { service?.deregister(id: id) }
}

// MARK: - GlassService

/// Central coordinator for the glass effect system.
/// Single-window architecture: renderers live in the main window.
/// Captures sourceView's layer tree only — glass UI is never in the capture path.
///
/// Capture is driven by explicit triggers, not continuous:
/// - `setNeedsCapture()` — one-shot (scroll, layout change, new message)
/// - `GlassCaptureSource` — continuous while animating (Lottie, GIF)
/// - Idle = ~0% CPU (display link stops, watchdog timer detects animations)
final class GlassService {

    static let shared = GlassService()

    // MARK: - Types

    private struct Registration {
        weak var anchor: GlassAnchor?
        let renderer: GlassRenderer
        var contentView: UIView?
        // Cached for render-without-capture (liquid wave animation)
        var lastTexture: MTLTexture?
        var lastCaptureFrame: CGRect?
        var lastShapes: GlassRenderer.ShapeParams?
        var lastIsHDR: Bool = false
        var lastLiquidZone: GlassRenderer.LiquidZone?
        var lastBarData: GlassRenderer.BarData?
    }

    private struct WeakSource {
        weak var source: GlassCaptureSource?
    }

    // MARK: - State

    private var registrations: [UUID: Registration] = [:]
    private var displayLinkToken: DisplayLinkToken?
    private weak var sourceWindow: UIWindow?

    // Reusable capture textures (keyed by pixel size)
    private var captureTextures: [String: MTLTexture] = [:]

    // Trigger system
    private var needsCapture = true // true on first frame
    private var continuousCaptureUntil: CFTimeInterval = 0
    private var captureSources: [WeakSource] = []
    private var idleTicks = 0
    private let idleThreshold = 3  // stop display link after N consecutive idle ticks
    private var watchdogTimer: Timer?

    // Liquid wave animation
    private var waveTime: Float = 0
    private var waveEnergy: Float = 0
    private var lastTickTime: CFTimeInterval = 0

    private var tickCount = 0
    
    #if DEBUG
    private var statsTimestamp: CFTimeInterval = 0
    private var perGlassStats: [UUID: (cap: Double, ren: Double, count: Int, label: String)] = [:]
    #endif

    private init() {}

    // MARK: - Public API

    func register(anchor: GlassAnchor) -> GlassRegistration {
        let id = UUID()
        let renderer = GlassRenderer()

        registrations[id] = Registration(anchor: anchor, renderer: renderer)

        if sourceWindow == nil {
            sourceWindow = anchor.window
        }

        // Renderer lives in the main window, above the anchor
        anchor.window?.addSubview(renderer)

        if displayLinkToken == nil {
            startRenderLoop()
        }

        needsCapture = true

        return GlassRegistration(id: id, service: self)
    }

    func deregister(id: UUID) {
        guard let reg = registrations.removeValue(forKey: id) else { return }
        reg.renderer.removeFromSuperview()
        reg.contentView?.removeFromSuperview()

        if registrations.isEmpty {
            tearDown()
        }
    }

    /// Attach interactive content view on top of the glass renderer.
    /// Content is placed in the main window, above the renderer.
    func attachContent(_ contentView: UIView, for anchor: GlassAnchor) {
        guard let window = anchor.window ?? sourceWindow else { return }

        for (id, reg) in registrations where reg.anchor === anchor {
            window.addSubview(contentView)
            registrations[id] = Registration(
                anchor: reg.anchor,
                renderer: reg.renderer,
                contentView: contentView
            )
            break
        }
        bringGlassToFront()
    }

    // MARK: - Capture Triggers

    /// Call when content under glass has changed (scroll, layout, new message).
    /// Triggers a single re-capture on the next tick.
    func setNeedsCapture() {
        needsCapture = true
        ensureRunning()
    }

    /// Capture continuously for the given duration (e.g. during a UIView animation).
    /// Useful when content under glass animates but the anchor itself doesn't move.
    func captureFor(duration: CFTimeInterval) {
        continuousCaptureUntil = max(continuousCaptureUntil, CACurrentMediaTime() + duration)
        ensureRunning()
        #if DEBUG
        print("[glass] captureFor(\(String(format: "%.2f", duration))s)")
        #endif
    }

    /// Register a continuous capture source (animated cell, Lottie, GIF).
    /// Source is checked each tick: if `needsGlassCapture` and intersects glass → capture.
    func addCaptureSource(_ source: GlassCaptureSource) {
        // Avoid duplicates
        guard !captureSources.contains(where: { $0.source === source }) else { return }
        captureSources.append(WeakSource(source: source))
        ensureRunning()
    }

    /// Remove a capture source (cell exited visible state).
    func removeCaptureSource(_ source: GlassCaptureSource) {
        captureSources.removeAll { $0.source === source }
    }

    private func tearDown() {
        displayLinkToken?.invalidate()
        displayLinkToken = nil
        stopWatchdog()
        captureTextures.removeAll()
        captureCaches.removeAll()
        sourceWindow = nil
        captureSources.removeAll()
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        guard displayLinkToken == nil else { return }
        idleTicks = 0
        displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .fps(120)) { [weak self] _ in
            self?.tick()
        }
    }

    private func stopRenderLoop() {
        displayLinkToken?.invalidate()
        displayLinkToken = nil
        lastTickTime = 0
        startWatchdog()
    }

    /// Restart display link if it was stopped due to idle.
    private func ensureRunning() {
        guard !registrations.isEmpty else { return }
        stopWatchdog()
        startRenderLoop()
    }

    /// Low-frequency check for anchor animations (navigation gestures, etc.)
    /// Runs only while display link is stopped. Wakes the render loop when needed.
    private func startWatchdog() {
        guard watchdogTimer == nil else { return }
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.watchdogCheck()
        }
    }

    private func stopWatchdog() {
        watchdogTimer?.invalidate()
        watchdogTimer = nil
    }

    private func watchdogCheck() {
        let anyAnimating = registrations.values.contains { $0.anchor?.isAnimating == true }
        let inBurst = CACurrentMediaTime() < continuousCaptureUntil
        let hasActiveSources = hasActiveSourceUnderGlass()
        if anyAnimating || inBurst || needsCapture || hasActiveSources {
            // Sustain: keep display link alive for at least 0.5s after detection.
            // Avoids rapid start/stop cycles during interactive gestures.
            continuousCaptureUntil = max(continuousCaptureUntil, CACurrentMediaTime() + 0.5)
            ensureRunning()
        }
    }

    private func tick() {
        guard let sourceWindow else { return }

        // Check if capture is needed:
        // 1. Explicit trigger (scroll, layout)
        // 2. Timed burst (context menu animation)
        // 3. Anchor is being animated (navigation push/pop, keyboard)
        // 4. Animated content under glass (Lottie, GIF)
        let anyAnimating = registrations.values.contains { $0.anchor?.isAnimating == true }
        let hasLiquidPool = registrations.values.contains { $0.anchor?.extendsCaptureToScreenBottom == true }
        let inBurst = CACurrentMediaTime() < continuousCaptureUntil
        let shouldCapture = needsCapture || inBurst || anyAnimating || hasActiveSourceUnderGlass()

        if shouldCapture {
            needsCapture = false
        }

        // Wave energy: ramps up during scroll, decays when idle
        let now = CACurrentMediaTime()
        let dt = lastTickTime > 0 ? Float(now - lastTickTime) : 0
        lastTickTime = now

        if hasLiquidPool {
            // Splash only when the input bar itself moves (keyboard), not on scroll
            let anchorMoving = registrations.values.contains {
                $0.anchor?.extendsCaptureToScreenBottom == true && $0.anchor?.isAnimating == true
            }
            if anchorMoving {
                waveEnergy = min(waveEnergy + dt * 5.0, 1.0)
                waveTime += dt
                #if DEBUG
                if waveEnergy == dt * 5.0 { print("[glass] liquid pool ON — keyboard moving") }
                #endif
            } else {
                waveEnergy = max(waveEnergy - dt * 0.35, 0)
                if waveEnergy > 0.001 {
                    waveTime += dt * waveEnergy
                } else if waveEnergy <= 0.001 {
                    // Waves fully decayed — shrink capture back to glass rect
                    var didDisable = false
                    for (_, reg) in registrations {
                        if reg.anchor?.extendsCaptureToScreenBottom == true {
                            reg.anchor?.extendsCaptureToScreenBottom = false
                            didDisable = true
                        }
                    }
                    #if DEBUG
                    if didDisable { print("[glass] liquid pool OFF — waves decayed") }
                    #endif
                }
            }
        }

        // Render when capturing OR waves still decaying OR bars active
        let hasActiveBars = registrations.values.contains { $0.anchor?.hasBars == true }
        let shouldRender = shouldCapture || (hasLiquidPool && waveEnergy > 0.001) || hasActiveBars

        let scale = sourceWindow.screen.scale

        for (id, reg) in registrations {
            guard let anchor = reg.anchor,
                  let rawFrame = anchor.presentationFrame(),
                  rawFrame.width > 0, rawFrame.height > 0
            else {
                reg.renderer.isHidden = true
                continue
            }

            reg.renderer.isHidden = false

            // Snap to device pixels
            let glassFrame = CGRect(
                x: round(rawFrame.origin.x * scale) / scale,
                y: round(rawFrame.origin.y * scale) / scale,
                width: round(rawFrame.width * scale) / scale,
                height: round(rawFrame.height * scale) / scale
            )

            let wantsLiquid = anchor.extendsCaptureToScreenBottom

            // Skip if nothing to do
            guard shouldCapture || (shouldRender && (wantsLiquid || anchor.hasBars || anchor.hasScrollButton)) else { continue }

            if shouldCapture {
                // ── Capture new frame ──
                let windowBounds = sourceWindow.bounds
                let sidePadding: CGFloat = 50
                // Liquid mode: more top padding to capture cells approaching the surface
                // Bars mode: extend upward to capture environment for chrome reflections
                let anchorHasBars = anchor.hasBars
                let anchorHasScrollButton = anchor.hasScrollButton
                let topPadding: CGFloat = wantsLiquid ? 80 : ((anchorHasBars || anchorHasScrollButton) ? 100 : 20)
                let captureY = max(glassFrame.origin.y - topPadding, 0)
                let captureFrame: CGRect
                if wantsLiquid {
                    captureFrame = CGRect(
                        x: max(glassFrame.origin.x - sidePadding, 0),
                        y: captureY,
                        width: min(glassFrame.width + sidePadding * 2, windowBounds.width - max(glassFrame.origin.x - sidePadding, 0)),
                        height: windowBounds.height - captureY
                    )
                } else {
                    captureFrame = CGRect(
                        x: max(glassFrame.origin.x - sidePadding, 0),
                        y: captureY,
                        width: min(glassFrame.width + sidePadding * 2, windowBounds.width - max(glassFrame.origin.x - sidePadding, 0)),
                        height: min(glassFrame.height + sidePadding * 2, windowBounds.height - captureY)
                    )
                }

                #if DEBUG
                let capStart = CACurrentMediaTime()
                #endif

                guard let texture = captureRegion(captureFrame, from: sourceWindow, scale: scale,
                                                     sourceView: anchor.sourceView) else { continue }

                #if DEBUG
                let capTime = CACurrentMediaTime() - capStart
                #endif

                reg.renderer.frame = captureFrame
                reg.renderer.contentScaleFactor = scale
                reg.renderer.layoutIfNeeded()  // sync drawableSize before render
                reg.contentView?.frame = glassFrame

                let shapes: GlassRenderer.ShapeParams
                if let provider = anchor.shapeProvider {
                    shapes = provider(glassFrame, captureFrame, scale)
                } else {
                    var s = GlassRenderer.ShapeParams()
                    s.shape0 = SIMD4<Float>(
                        Float((glassFrame.origin.x - captureFrame.origin.x) / captureFrame.width),
                        Float((glassFrame.origin.y - captureFrame.origin.y) / captureFrame.height),
                        Float(glassFrame.width / captureFrame.width),
                        Float(glassFrame.height / captureFrame.height)
                    )
                    s.shape0cornerR = Float(anchor.cornerRadius * scale) / Float(captureFrame.height * scale)
                    s.shapeCount = 1
                    shapes = s
                }

                let liquidZone: GlassRenderer.LiquidZone?
                if wantsLiquid, captureFrame.height > 0 {
                    // Surface overlaps into input bar for seamless blur
                    let surfaceY = glassFrame.maxY - 14
                    liquidZone = GlassRenderer.LiquidZone(
                        top: Float((surfaceY - captureFrame.origin.y) / captureFrame.height),
                        bottom: 1.0,
                        waveEnergy: waveEnergy
                    )
                } else {
                    liquidZone = nil
                }

                // Chrome bars
                let barData = anchor.barProvider?(glassFrame, captureFrame, scale)

                // Cache for render-only frames
                registrations[id]?.lastTexture = texture
                registrations[id]?.lastCaptureFrame = captureFrame
                registrations[id]?.lastShapes = shapes
                registrations[id]?.lastIsHDR = texture.pixelFormat == .bgr10a2Unorm
                registrations[id]?.lastLiquidZone = liquidZone
                registrations[id]?.lastBarData = barData

                #if DEBUG
                let renStart = CACurrentMediaTime()
                #endif

                reg.renderer.render(
                    with: texture,
                    shapes: shapes,
                    isHDR: texture.pixelFormat == .bgr10a2Unorm,
                    liquidZone: liquidZone,
                    time: waveTime,
                    barData: barData
                )

                #if DEBUG
                let renTime = CACurrentMediaTime() - renStart
                let label = anchor.extendsCaptureToScreenBottom ? "input" : "nav"
                var s = perGlassStats[id] ?? (cap: 0, ren: 0, count: 0, label: label)
                s.cap += capTime
                s.ren += renTime
                s.count += 1
                perGlassStats[id] = s
                #endif

            } else if (wantsLiquid || (anchor.hasBars && reg.lastBarData != nil)),
                      let texture = reg.lastTexture,
                      let shapes = reg.lastShapes {
                // ── Render-only: reuse cached texture, update wave animation ──
                var lz = reg.lastLiquidZone
                lz?.waveEnergy = waveEnergy

                reg.renderer.render(
                    with: texture,
                    shapes: shapes,
                    isHDR: reg.lastIsHDR,
                    liquidZone: lz,
                    time: waveTime,
                    barData: reg.lastBarData
                )
            }
        }

        // Cleanup dead weak references periodically
        if captureSources.count > 0 && tickCount % 600 == 0 {
            captureSources.removeAll { $0.source == nil }
        }

        // Stop display link when idle — 0% CPU between triggers
        if shouldRender {
            idleTicks = 0
        } else {
            idleTicks += 1
            if idleTicks >= idleThreshold {
                stopRenderLoop()
                #if DEBUG
                print("[glass] display link stopped (idle)")
                #endif
                return
            }
        }

        #if DEBUG
        if shouldRender {
            tickCount += 1
        }

        let statsNow = CACurrentMediaTime()
        if statsTimestamp == 0 { statsTimestamp = statsNow }
        if statsNow - statsTimestamp >= 1.0 {
            if perGlassStats.isEmpty {
                print("[glass] idle")
            } else {
                for (_, stats) in perGlassStats {
                    guard stats.count > 0 else { continue }
                    let n = Double(stats.count)
                    let capAvg = stats.cap / n * 1000
                    let renAvg = stats.ren / n * 1000
                    let totAvg = capAvg + renAvg
                    print("[glass] [\(stats.label)] active=\(stats.count) capture=\(String(format: "%.2f", capAvg))ms render=\(String(format: "%.2f", renAvg))ms total=\(String(format: "%.2f", totAvg))ms")
                }
            }
            perGlassStats.removeAll(keepingCapacity: true)
            tickCount = 0
            statsTimestamp = now
        }
        #endif
    }

    // MARK: - Source Intersection Check

    /// Checks if any registered capture source is animating AND overlaps a glass rect.
    private func hasActiveSourceUnderGlass() -> Bool {
        guard !captureSources.isEmpty else { return false }

        // Collect glass rects
        var glassRects: [CGRect] = []
        for (_, reg) in registrations {
            if let frame = reg.anchor?.presentationFrame() {
                glassRects.append(frame)
            }
        }

        guard !glassRects.isEmpty else { return false }

        for weakSource in captureSources {
            guard let source = weakSource.source,
                  source.needsGlassCapture,
                  let sourceFrame = source.captureSourceFrame else { continue }

            for glassRect in glassRects {
                if glassRect.intersects(sourceFrame) {
                    return true
                }
            }
        }

        return false
    }

    // MARK: - Layer Render Capture

    /// Capture scale factor. @2x instead of @3x = fewer pixels, invisible behind blur.
    private let captureScale: CGFloat = 2.0

    /// Cached capture: MTLBuffer(.shared) backs both CGContext and MTLTexture (zero-copy CPU→GPU).
    /// Double-buffered: CPU writes slot A while GPU reads slot B, then flip.
    /// Falls back to texture.replace() on devices that don't support buffer-backed textures (Intel sim).
    private struct CaptureSlot {
        let ctx: CGContext
        let buffer: MTLBuffer? // nil in fallback mode
        let texture: MTLTexture
        let bytesPerRow: Int
        let zeroCopy: Bool // true = buffer-backed, false = texture.replace()
    }
    private struct CaptureCache {
        let slots: [CaptureSlot]
        let width: Int
        let height: Int
        var current: Int = 0

        mutating func next() -> CaptureSlot {
            let slot = slots[current]
            current = 1 - current
            return slot
        }
    }
    private var captureCaches: [String: CaptureCache] = [:]

    /// Align bytesPerRow to 256 for MTLBuffer.makeTexture() requirement.
    private static func alignedBytesPerRow(_ width: Int) -> Int {
        let raw = width * 4
        return (raw + 255) & ~255
    }

    /// Buffer-backed textures work on device and Apple Silicon simulator.
    /// Intel simulator GPU doesn't support buffer-backed textures.
    private let supportsBufferTexture: Bool = {
        #if targetEnvironment(simulator) && arch(x86_64)
        return false
        #else
        return true
        #endif
    }()

    /// Render source view's layer tree into a texture for the given region.
    /// Zero-copy CPU→GPU on device (CGContext → MTLBuffer → texture view), fallback on Intel simulator.
    private func captureRegion(_ frame: CGRect, from window: UIWindow, scale: CGFloat,
                                sourceView: UIView? = nil) -> MTLTexture? {
        let renderScale = captureScale
        let w = Int(frame.width * renderScale)
        let h = Int(frame.height * renderScale)
        guard w > 0, h > 0 else { return nil }

        // Double-buffered: pick next slot so CPU writes while GPU reads previous
        let key = "\(w)x\(h)"
        if captureCaches[key] == nil {
            let device = MetalContext.shared.device
            let zeroCopy = supportsBufferTexture
            let alignedBPR = zeroCopy ? Self.alignedBytesPerRow(w) : w * 4
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            var slots: [CaptureSlot] = []
            for _ in 0..<2 {
                let ctx: CGContext
                let buffer: MTLBuffer?
                let texture: MTLTexture

                if zeroCopy {
                    let bufferSize = alignedBPR * h
                    guard let buf = device.makeBuffer(length: bufferSize, options: .storageModeShared) else { return nil }

                    guard let c = CGContext(
                        data: buf.contents(),
                        width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: alignedBPR,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue
                    ) else { return nil }

                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
                    )
                    desc.usage = .shaderRead
                    desc.storageMode = .shared
                    guard let tex = buf.makeTexture(
                        descriptor: desc, offset: 0, bytesPerRow: alignedBPR
                    ) else { return nil }

                    ctx = c
                    buffer = buf
                    texture = tex
                } else {
                    // Fallback: separate CGContext + texture, connected via replace()
                    guard let c = CGContext(
                        data: nil, width: w, height: h,
                        bitsPerComponent: 8, bytesPerRow: alignedBPR,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                            | CGBitmapInfo.byteOrder32Little.rawValue
                    ) else { return nil }

                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
                    )
                    desc.usage = .shaderRead
                    desc.storageMode = .shared
                    guard let tex = device.makeTexture(descriptor: desc) else { return nil }

                    ctx = c
                    buffer = nil
                    texture = tex
                }

                slots.append(CaptureSlot(ctx: ctx, buffer: buffer, texture: texture,
                                         bytesPerRow: alignedBPR, zeroCopy: zeroCopy))
            }

            captureCaches[key] = CaptureCache(slots: slots, width: w, height: h)
        }

        let slot: CaptureSlot = {
            var cache = captureCaches[key]!
            let s = cache.next()
            captureCaches[key] = cache
            return s
        }()
        let ctx = slot.ctx

        // Reset transform (CGContext accumulates transforms)
        ctx.saveGState()

        // Zero the backing memory
        if let buffer = slot.buffer {
            memset(buffer.contents(), 0, slot.bytesPerRow * h)
        } else {
            ctx.clear(CGRect(x: 0, y: 0, width: w, height: h))
        }

        // Render source view's layer tree
        let target = sourceView ?? window
        let targetLayer = target.layer.presentation() ?? target.layer

        // Convert capture frame from window coords to source view's layer coords.
        // Use presentation layer for mid-animation accuracy (navigation gestures).
        let frameInTarget: CGRect
        if sourceView != nil {
            let windowPresentation = window.layer.presentation() ?? window.layer
            frameInTarget = targetLayer.convert(frame, from: windowPresentation)
        } else {
            frameInTarget = frame
        }

        // Check if source view is Y-flipped (inverted table)
        let isFlipped = sourceView.map { $0.transform.d < 0 } ?? false

        if isFlipped {
            ctx.translateBy(x: -frameInTarget.origin.x * renderScale,
                            y: -frameInTarget.origin.y * renderScale)
            ctx.scaleBy(x: renderScale, y: renderScale)
        } else {
            ctx.translateBy(x: -frameInTarget.origin.x * renderScale,
                            y: (frameInTarget.origin.y + frameInTarget.height) * renderScale)
            ctx.scaleBy(x: renderScale, y: -renderScale)
        }

        // Render only sublayers that intersect the capture frame.
        // Skips off-screen cells — critical for Texture/ASDK where layer.contents
        // is pre-rendered and layer.render still composites all sublayers.
        if let sublayers = targetLayer.sublayers {
            let visibleRect = frameInTarget
            for sublayer in sublayers {
                guard !sublayer.isHidden, sublayer.opacity > 0 else { continue }
                let sublayerFrame = sublayer.frame
                guard sublayerFrame.intersects(visibleRect) else { continue }
                ctx.saveGState()
                ctx.translateBy(x: sublayerFrame.origin.x, y: sublayerFrame.origin.y)
                sublayer.render(in: ctx)
                ctx.restoreGState()
            }
        } else {
            targetLayer.render(in: ctx)
        }
        ctx.restoreGState()

        // Zero-copy CPU→GPU: GPU reads directly from buffer memory
        // Fallback: copy CGContext data into texture
        if !slot.zeroCopy, let data = ctx.data {
            slot.texture.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: data,
                bytesPerRow: slot.bytesPerRow
            )
        }

        return slot.texture
    }

    /// Ensure all renderers and content views are at the front of the window,
    /// with content above its renderer.
    private func bringGlassToFront() {
        for (_, reg) in registrations {
            reg.renderer.superview?.bringSubviewToFront(reg.renderer)
            if let content = reg.contentView {
                content.superview?.bringSubviewToFront(content)
            }
        }
    }
}
