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
/// Single-window architecture: glass output is rendered by shared overlay
/// renderers attached to the relevant host containers inside the same window.
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
        // Cached for render-without-capture (liquid wave animation)
        var lastTexture: MTLTexture?
        var lastCaptureFrame: CGRect?
        var lastShapes: GlassRenderer.ShapeParams?
        var lastIsHDR: Bool = false
        var lastLiquidZone: GlassRenderer.LiquidZone?
        var lastBarData: GlassRenderer.BarData?
        var adaptiveState = AdaptiveMaterialState()
    }

    private struct WeakSource {
        weak var source: GlassCaptureSource?
    }

    private struct BackdropStats {
        let meanLuma: Float
        let variance: Float
        let brightFraction: Float
        let darkFraction: Float
    }

    private struct CaptureResult {
        let texture: MTLTexture
        let stats: BackdropStats?
    }

    private struct AdaptiveMaterialState {
        private(set) var appearance: Float = 1
        private(set) var contrast: Float = 0

        private var initialized = false
        private var filteredLuma: Float = 0.5
        private var targetAppearance: Float = 1
        private var targetContrast: Float = 0
        private static let appearanceSwitchLuma: Float = 0.50

        var isAnimating: Bool {
            abs(appearance - targetAppearance) > 0.003 ||
            abs(contrast - targetContrast) > 0.003
        }

        mutating func ingest(_ stats: BackdropStats, dt: Float) {
            let safeDt = max(dt, 1.0 / 120.0)
            if !initialized {
                initialized = true
                filteredLuma = stats.meanLuma
                targetAppearance = stats.meanLuma >= Self.appearanceSwitchLuma ? 1 : 0
                targetContrast = Self.contrastTarget(for: stats)
                appearance = targetAppearance
                contrast = targetContrast
                return
            }

            let sampleAlpha = Self.alpha(dt: safeDt, tau: 0.12)
            filteredLuma += (stats.meanLuma - filteredLuma) * sampleAlpha

            // Single threshold selects the target so returning to the same
            // backdrop returns to the same material state. The visible
            // transition remains smooth because both luma and appearance
            // are temporally filtered.
            targetAppearance = filteredLuma >= Self.appearanceSwitchLuma ? 1 : 0
            targetContrast = Self.contrastTarget(for: stats)
            advance(dt: safeDt)
        }

        mutating func advance(dt: Float) {
            guard initialized else { return }
            let safeDt = max(dt, 1.0 / 120.0)
            let appearanceAlpha = Self.alpha(dt: safeDt, tau: 0.24)
            let contrastAlpha = Self.alpha(dt: safeDt, tau: 0.18)
            appearance += (targetAppearance - appearance) * appearanceAlpha
            contrast += (targetContrast - contrast) * contrastAlpha
        }

        private static func contrastTarget(for stats: BackdropStats) -> Float {
            let stdDev = sqrtf(max(stats.variance, 0))
            let mixedExtremes = min(stats.brightFraction, stats.darkFraction)
            let dominantExtreme = max(stats.brightFraction, stats.darkFraction)
            return clamp(stdDev * 2.7 + mixedExtremes * 1.6 + dominantExtreme * 0.2, 0, 1)
        }

        private static func alpha(dt: Float, tau: Float) -> Float {
            1.0 - expf(-dt / max(tau, 0.001))
        }

        private static func clamp(_ value: Float, _ minValue: Float, _ maxValue: Float) -> Float {
            min(max(value, minValue), maxValue)
        }
    }

    private final class RendererHost {
        weak var container: UIView?
        let renderer: GlassRenderer

        init(container: UIView) {
            self.container = container
            self.renderer = GlassRenderer()
        }
    }

    // MARK: - State

    private var registrations: [UUID: Registration] = [:]
    private var displayLinkToken: DisplayLinkToken?
    private weak var sourceWindow: UIWindow?
    private var rendererHosts: [ObjectIdentifier: RendererHost] = [:]

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

    private init() {}

    // MARK: - Public API

    /// Register a glass anchor. Output is drawn into a shared renderer that
    /// lives in the anchor's host container, above content and below controls.
    func register(anchor: GlassAnchor) -> GlassRegistration {
        let id = UUID()

        registrations[id] = Registration(anchor: anchor)

        if sourceWindow == nil {
            sourceWindow = anchor.window
        }

        if displayLinkToken == nil {
            startRenderLoop()
        }

        needsCapture = true

        return GlassRegistration(id: id, service: self)
    }

    func deregister(id: UUID) {
        registrations.removeValue(forKey: id)

        if registrations.isEmpty {
            tearDown()
        }
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
        for host in rendererHosts.values {
            host.renderer.removeFromSuperview()
        }
        rendererHosts.removeAll()
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

    private func resolveRenderHostContainer(for anchor: GlassAnchor) -> UIView? {
        anchor.renderHostContainerView ?? anchor.superview?.superview ?? anchor.superview ?? anchor.window
    }

    private func rendererHost(for container: UIView) -> RendererHost {
        let key = ObjectIdentifier(container)
        if let host = rendererHosts[key], host.container === container {
            return host
        }
        let host = RendererHost(container: container)
        rendererHosts[key] = host
        return host
    }

    private func cleanupRendererHosts(liveContainers: [UIView]) {
        let liveKeys = Set(liveContainers.map { ObjectIdentifier($0) })
        for (key, host) in rendererHosts where host.container == nil || !liveKeys.contains(key) {
            host.renderer.removeFromSuperview()
            rendererHosts.removeValue(forKey: key)
        }
    }

    private func ensureSharedRendererAttached(_ renderer: GlassRenderer, to container: UIView) {
        let insertionView = registrations.values
            .compactMap { $0.anchor?.superview }
            .filter { $0.superview === container }
            .min { lhs, rhs in
                (container.subviews.firstIndex(of: lhs) ?? Int.max) < (container.subviews.firstIndex(of: rhs) ?? Int.max)
            }

        if renderer.superview !== container {
            renderer.removeFromSuperview()
            if let insertionView {
                container.insertSubview(renderer, belowSubview: insertionView)
            } else {
                container.addSubview(renderer)
            }
            renderer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            renderer.accessibilityElementsHidden = true
        } else if let insertionView {
            container.insertSubview(renderer, belowSubview: insertionView)
        }

        renderer.frame = container.bounds
        renderer.contentScaleFactor = container.window?.screen.scale ?? UIScreen.main.scale
        renderer.layoutIfNeeded()
    }

    private func renderDestinationFrame(
        for captureFrame: CGRect,
        in renderHostContainer: UIView,
        sourceWindow: UIWindow
    ) -> CGRect {
        let containerLayer = renderHostContainer.layer.presentation() ?? renderHostContainer.layer
        let windowLayer = sourceWindow.layer.presentation() ?? sourceWindow.layer
        return containerLayer.convert(captureFrame, from: windowLayer)
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
        let hadPendingCaptureRequest = needsCapture
        var renderItemsByContainer: [ObjectIdentifier: (container: UIView, renderer: GlassRenderer, items: [GlassRenderer.RenderItem])] = [:]
        var deferredCaptureRequest = false

        // Check if capture is needed:
        // 1. Explicit trigger (scroll, layout)
        // 2. Timed burst (context menu animation)
        // 3. Anchor is being animated (navigation push/pop, keyboard)
        // 4. Animated content under glass (Lottie, GIF)
        let anyAnimating = registrations.values.contains { $0.anchor?.isAnimating == true }
        let hasLiquidPool = registrations.values.contains { $0.anchor?.extendsCaptureToScreenBottom == true }
        let inBurst = CACurrentMediaTime() < continuousCaptureUntil
        let shouldCapture = needsCapture || inBurst || anyAnimating || hasActiveSourceUnderGlass()

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
            } else {
                waveEnergy = max(waveEnergy - dt * 0.35, 0)
                if waveEnergy > 0.001 {
                    waveTime += dt * waveEnergy
                } else if waveEnergy <= 0.001 {
                    // Waves fully decayed — shrink capture back to glass rect
                    for (_, reg) in registrations {
                        if reg.anchor?.extendsCaptureToScreenBottom == true {
                            reg.anchor?.extendsCaptureToScreenBottom = false
                        }
                    }
                }
            }
        }

        // Render when capturing OR waves still decaying OR bars active
        // OR adaptive material is still easing toward a threshold-selected state.
        let hasActiveBars = registrations.values.contains { $0.anchor?.hasBars == true }
        let hasAdaptiveTransition = registrations.values.contains { $0.adaptiveState.isAnimating }
        let shouldRender = shouldCapture || (hasLiquidPool && waveEnergy > 0.001)
            || hasActiveBars || hasAdaptiveTransition

        let scale = sourceWindow.screen.scale
        let renderHostContainers = registrations.values
            .compactMap { $0.anchor }
            .compactMap { resolveRenderHostContainer(for: $0) }
        var uniqueRenderHostContainers: [UIView] = []
        var seenRenderHostContainers = Set<ObjectIdentifier>()
        for container in renderHostContainers {
            let key = ObjectIdentifier(container)
            if seenRenderHostContainers.insert(key).inserted {
                uniqueRenderHostContainers.append(container)
            }
        }

        for container in uniqueRenderHostContainers {
            let host = rendererHost(for: container)
            ensureSharedRendererAttached(host.renderer, to: container)
        }
        cleanupRendererHosts(liveContainers: uniqueRenderHostContainers)

        for (id, reg) in registrations {
            guard let anchor = reg.anchor,
                  let rawFrame = anchor.presentationFrame(),
                  rawFrame.width > 0, rawFrame.height > 0,
                  let renderHostContainer = resolveRenderHostContainer(for: anchor)
            else {
                continue
            }

            let renderHost = rendererHost(for: renderHostContainer)
            if shouldRender, renderHost.renderer.isFrameInFlight {
                if hadPendingCaptureRequest {
                    deferredCaptureRequest = true
                }
                continue
            }

            // Snap to device pixels
            let glassFrame = CGRect(
                x: round(rawFrame.origin.x * scale) / scale,
                y: round(rawFrame.origin.y * scale) / scale,
                width: round(rawFrame.width * scale) / scale,
                height: round(rawFrame.height * scale) / scale
            )

            let wantsLiquid = anchor.extendsCaptureToScreenBottom

            // Shared renderer clears the whole drawable at the start of a
            // batch, so render-only frames must redraw every cached glass item
            // in that container, not only the item whose animation is active.
            guard shouldCapture || shouldRender else { continue }

            if shouldCapture {
                // ── Capture new frame ──
                let windowBounds = sourceWindow.bounds
                let horizontalPadding: CGFloat = 50
                // Liquid mode: more top padding to capture cells approaching the surface
                // Bars mode: extend upward to capture environment for chrome reflections
                let anchorHasBars = anchor.hasBars
                let anchorHasScrollButton = anchor.hasScrollButton
                let isInputCapture = anchor.debugName == "input"
                let isNavCapture = anchor.debugName == "nav"
                let topPadding: CGFloat
                let bottomPadding: CGFloat
                if wantsLiquid {
                    topPadding = 80
                    bottomPadding = 0
                } else if anchorHasBars {
                    topPadding = 100
                    bottomPadding = 24
                } else if anchorHasScrollButton {
                    topPadding = 72
                    bottomPadding = 12
                } else if isNavCapture {
                    topPadding = 8
                    bottomPadding = 12
                } else if isInputCapture {
                    topPadding = 12
                    bottomPadding = 12
                } else {
                    topPadding = 20
                    bottomPadding = 24
                }
                let captureX = max(glassFrame.origin.x - horizontalPadding, 0)
                let captureY = max(glassFrame.origin.y - topPadding, 0)
                let captureFrame: CGRect
                if wantsLiquid {
                    captureFrame = CGRect(
                        x: captureX,
                        y: captureY,
                        width: min(glassFrame.width + horizontalPadding * 2, windowBounds.width - captureX),
                        height: windowBounds.height - captureY
                    )
                } else {
                    captureFrame = CGRect(
                        x: captureX,
                        y: captureY,
                        width: min(glassFrame.width + horizontalPadding * 2, windowBounds.width - captureX),
                        height: min(glassFrame.height + topPadding + bottomPadding, windowBounds.height - captureY)
                    )
                }

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

                guard let capture = captureRegion(captureFrame, from: sourceWindow, scale: scale,
                                                  sourceView: anchor.sourceView,
                                                  clearPattern: anchor.clearPatternBGRA,
                                                  shapes: shapes) else { continue }
                let texture = capture.texture
                let adaptiveMaterial = updateAdaptiveMaterial(
                    for: id,
                    stats: capture.stats,
                    dt: dt
                )

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
                let destinationFrame = renderDestinationFrame(
                    for: captureFrame,
                    in: renderHostContainer,
                    sourceWindow: sourceWindow
                )
                let key = ObjectIdentifier(renderHostContainer)
                if renderItemsByContainer[key] == nil {
                    renderItemsByContainer[key] = (
                        container: renderHostContainer,
                        renderer: renderHost.renderer,
                        items: []
                    )
                }
                if var group = renderItemsByContainer[key] {
                    group.items.append(
                        GlassRenderer.RenderItem(
                            name: anchor.debugName,
                            frame: destinationFrame,
                            sourceTexture: texture,
                            shapes: shapes,
                            isHDR: texture.pixelFormat == .bgr10a2Unorm,
                            liquidZone: liquidZone,
                            time: waveTime,
                            barData: barData,
                            adaptiveAppearance: adaptiveMaterial.appearance,
                            adaptiveContrast: adaptiveMaterial.contrast
                        )
                    )
                    renderItemsByContainer[key] = group
                }

            } else if shouldRender,
                      let texture = reg.lastTexture,
                      let shapes = reg.lastShapes,
                      let captureFrame = reg.lastCaptureFrame {
                // ── Render-only: reuse cached texture, update wave animation ──
                let adaptiveMaterial = updateAdaptiveMaterial(
                    for: id,
                    stats: nil,
                    dt: dt
                )
                var lz = wantsLiquid ? reg.lastLiquidZone : nil
                lz?.waveEnergy = waveEnergy
                let destinationFrame = renderDestinationFrame(
                    for: captureFrame,
                    in: renderHostContainer,
                    sourceWindow: sourceWindow
                )
                let key = ObjectIdentifier(renderHostContainer)
                if renderItemsByContainer[key] == nil {
                    renderItemsByContainer[key] = (
                        container: renderHostContainer,
                        renderer: renderHost.renderer,
                        items: []
                    )
                }
                if var group = renderItemsByContainer[key] {
                    group.items.append(
                        GlassRenderer.RenderItem(
                            name: anchor.debugName,
                            frame: destinationFrame,
                            sourceTexture: texture,
                            shapes: shapes,
                            isHDR: reg.lastIsHDR,
                            liquidZone: lz,
                            time: waveTime,
                            barData: anchor.hasBars ? reg.lastBarData : nil,
                            adaptiveAppearance: adaptiveMaterial.appearance,
                            adaptiveContrast: adaptiveMaterial.contrast
                        )
                    )
                    renderItemsByContainer[key] = group
                }
            }
        }

        for group in renderItemsByContainer.values {
            _ = group.renderer.render(items: group.items)
        }

        if hadPendingCaptureRequest {
            needsCapture = deferredCaptureRequest
        }

        tickCount &+= 1

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
                return
            }
        }
    }

    // MARK: - Adaptive Material

    private func updateAdaptiveMaterial(
        for id: UUID,
        stats: BackdropStats?,
        dt: Float
    ) -> (appearance: Float, contrast: Float) {
        guard var reg = registrations[id] else {
            return (appearance: 1, contrast: 0)
        }

        if let stats {
            reg.adaptiveState.ingest(stats, dt: dt)
        } else {
            reg.adaptiveState.advance(dt: dt)
        }

        let material = (
            appearance: reg.adaptiveState.appearance,
            contrast: reg.adaptiveState.contrast
        )
        registrations[id] = reg
        reg.anchor?.setAdaptiveMaterial(
            appearance: material.appearance,
            contrast: material.contrast
        )
        return material
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
        let byteCost: Int
        var lastUsedTick: Int
        var current: Int = 0

        mutating func next() -> CaptureSlot {
            let slot = slots[current]
            current = 1 - current
            return slot
        }
    }
    private var captureCaches: [String: CaptureCache] = [:]
    // Keyboard/liquid animation can produce many one-frame capture sizes.
    // Keep stable nav/input caches hot while evicting transient buffers.
    private let maxCaptureCacheBytes = 96 * 1024 * 1024

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
                                sourceView: UIView? = nil,
                                clearPattern: UInt32,
                                shapes: GlassRenderer.ShapeParams) -> CaptureResult? {
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

            let byteCost = slots.reduce(0) { $0 + $1.bytesPerRow * h }
            captureCaches[key] = CaptureCache(
                slots: slots,
                width: w,
                height: h,
                byteCost: byteCost,
                lastUsedTick: tickCount
            )
            pruneCaptureCachesIfNeeded()
        }

        let slot: CaptureSlot = {
            var cache = captureCaches[key]!
            cache.lastUsedTick = tickCount
            let s = cache.next()
            captureCaches[key] = cache
            return s
        }()
        let ctx = slot.ctx

        // Reset transform (CGContext accumulates transforms)
        ctx.saveGState()

        // Pre-fill backing memory with the anchor's backdrop color.
        // The sublayer-only render below skips sourceView.backgroundColor,
        // so without this fill, empty regions would read as opaque black.
        //
        // memset_pattern4 is NEON-optimized in libc — same cost as the
        // plain memset(0) it replaces (one pass at memory bandwidth).
        // Safe to do every frame; do not swap for CGContext fill.
        if let buffer = slot.buffer {
            var pattern = clearPattern
            memset_pattern4(buffer.contents(), &pattern, slot.bytesPerRow * h)
        } else {
            // Intel-simulator fallback (no shared memory). Visually wrong
            // — clears to transparent black — but never hit on device.
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

        // Inverted ASTableNode uses a flipped Y axis. Match the previous working
        // table-capture behaviour at the root, then preserve nested layer
        // transforms explicitly while walking portal-backed subtrees below.
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
                let intersection = sublayerFrame.intersection(visibleRect)
                guard !intersection.isEmpty else { continue }

                // Clip each top-level render to the actual visible band inside the
                // capture strip so tall cells do not redraw their full height.
                let localClipRect = intersection.offsetBy(
                    dx: -sublayerFrame.minX,
                    dy: -sublayerFrame.minY
                )

                withLayerGeometry(sublayer, in: ctx) {
                    renderLayerForCapture(
                        sublayer,
                        in: ctx,
                        clipRectInLayer: localClipRect
                    )
                }
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

        let stats = sampleBackdropStats(
            from: slot,
            shapes: shapes,
            captureSize: CGSize(width: CGFloat(w), height: CGFloat(h))
        )
        return CaptureResult(texture: slot.texture, stats: stats)
    }

    private func sampleBackdropStats(
        from slot: CaptureSlot,
        shapes: GlassRenderer.ShapeParams,
        captureSize: CGSize
    ) -> BackdropStats? {
        let width = Int(captureSize.width)
        let height = Int(captureSize.height)
        guard width > 0, height > 0 else { return nil }

        let rawData: UnsafeMutableRawPointer?
        if let buffer = slot.buffer {
            rawData = buffer.contents()
        } else {
            rawData = slot.ctx.data
        }
        guard let rawData else { return nil }

        let data = rawData.assumingMemoryBound(to: UInt8.self)
        let columns = 24
        let rows = 12
        let aspect = Float(width) / Float(max(height, 1))

        var count: Float = 0
        var sum: Float = 0
        var sumSq: Float = 0
        var bright: Float = 0
        var dark: Float = 0

        for row in 0..<rows {
            let v = (Float(row) + 0.5) / Float(rows)
            for column in 0..<columns {
                let u = (Float(column) + 0.5) / Float(columns)
                guard containsGlassPoint(u: u, v: v, shapes: shapes, aspect: aspect) else {
                    continue
                }

                let x = min(width - 1, max(0, Int(u * Float(width))))
                let y = min(height - 1, max(0, Int(v * Float(height))))
                let offset = y * slot.bytesPerRow + x * 4

                let b = Float(data[offset]) / 255.0
                let g = Float(data[offset + 1]) / 255.0
                let r = Float(data[offset + 2]) / 255.0
                let luma = r * 0.299 + g * 0.587 + b * 0.114

                count += 1
                sum += luma
                sumSq += luma * luma
                if luma > 0.72 { bright += 1 }
                if luma < 0.28 { dark += 1 }
            }
        }

        guard count > 0 else { return nil }

        let mean = sum / count
        let variance = max(0, sumSq / count - mean * mean)
        return BackdropStats(
            meanLuma: mean,
            variance: variance,
            brightFraction: bright / count,
            darkFraction: dark / count
        )
    }

    private func containsGlassPoint(
        u: Float,
        v: Float,
        shapes: GlassRenderer.ShapeParams,
        aspect: Float
    ) -> Bool {
        if roundedRectContains(
            u: u,
            v: v,
            rect: shapes.shape0,
            cornerR: shapes.shape0cornerR,
            aspect: aspect
        ) {
            return true
        }

        let shapeCount = Int(shapes.shapeCount)
        if shapeCount >= 2, circleContains(u: u, v: v, circle: shapes.shape1, aspect: aspect) {
            return true
        }
        if shapeCount >= 3, circleContains(u: u, v: v, circle: shapes.shape2, aspect: aspect) {
            return true
        }
        if shapes.scrollButtonVisible > 0.5,
           circleContains(u: u, v: v, circle: shapes.shape3, aspect: aspect) {
            return true
        }
        return false
    }

    private func roundedRectContains(
        u: Float,
        v: Float,
        rect: SIMD4<Float>,
        cornerR: Float,
        aspect: Float
    ) -> Bool {
        guard rect.z > 0, rect.w > 0 else { return false }

        let centerX = (rect.x + rect.z * 0.5) * aspect
        let centerY = rect.y + rect.w * 0.5
        let halfX = rect.z * aspect * 0.5
        let halfY = rect.w * 0.5
        let radius = min(cornerR, halfY)
        let px = u * aspect - centerX
        let py = v - centerY

        let dx = abs(px) - halfX + radius
        let dy = abs(py) - halfY + radius
        let outsideX = max(dx, 0)
        let outsideY = max(dy, 0)
        let sdf = sqrtf(outsideX * outsideX + outsideY * outsideY)
            + min(max(dx, dy), 0) - radius
        return sdf <= 0
    }

    private func circleContains(
        u: Float,
        v: Float,
        circle: SIMD4<Float>,
        aspect: Float
    ) -> Bool {
        guard circle.z > 0 else { return false }
        let dx = (u - circle.x) * aspect
        let dy = v - circle.y
        return dx * dx + dy * dy <= circle.z * circle.z
    }

    private func pruneCaptureCachesIfNeeded() {
        var totalBytes = captureCaches.values.reduce(0) { $0 + $1.byteCost }
        guard totalBytes > maxCaptureCacheBytes else { return }

        let keysByAge = captureCaches.keys.sorted {
            let lhs = captureCaches[$0]?.lastUsedTick ?? 0
            let rhs = captureCaches[$1]?.lastUsedTick ?? 0
            if lhs == rhs { return $0 < $1 }
            return lhs < rhs
        }

        for key in keysByAge {
            guard totalBytes > maxCaptureCacheBytes, captureCaches.count > 1 else { break }
            guard let cache = captureCaches[key], cache.lastUsedTick < tickCount else { continue }
            totalBytes -= cache.byteCost
            captureCaches.removeValue(forKey: key)
        }
    }

    private func renderLayerForCapture(
        _ layer: CALayer,
        in ctx: CGContext,
        clipRectInLayer: CGRect
    ) {
        BubblePortalCaptureRenderer.renderLayerForCapture(
            layer,
            in: ctx,
            clipRectInLayer: clipRectInLayer
        )
    }

    private func withLayerGeometry(
        _ layer: CALayer,
        in ctx: CGContext,
        body: () -> Void
    ) {
        ctx.saveGState()
        ctx.translateBy(x: layer.position.x, y: layer.position.y)

        let transform = layer.transform
        if CATransform3DIsAffine(transform) {
            ctx.concatenate(CATransform3DGetAffineTransform(transform))
        }

        ctx.translateBy(
            x: -layer.bounds.width * layer.anchorPoint.x,
            y: -layer.bounds.height * layer.anchorPoint.y
        )
        body()
        ctx.restoreGState()
    }

}
