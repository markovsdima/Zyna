//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import IOSurface
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

// MARK: - ScreenCaptureManager

/// Double-buffered IOSurface capture.
private final class ScreenCaptureManager {

    private var device: MTLDevice { MetalContext.shared.device }
    private var surfaceA: (unmanaged: Unmanaged<AnyObject>?, texture: MTLTexture?)?
    private var surfaceB: (unmanaged: Unmanaged<AnyObject>?, texture: MTLTexture?)?
    private var useA = true

    init() {}

    deinit { cleanup() }

    func capture(frame: CGRect, from window: UIWindow) -> MTLTexture? {
        let current = useA ? surfaceA : surfaceB

        useA.toggle()

        if useA {
            surfaceA?.unmanaged?.release()
            surfaceA = nil
        } else {
            surfaceB?.unmanaged?.release()
            surfaceB = nil
        }

        guard let result = captureIOSurface(frame: frame, from: window) else {
            return current?.texture
        }

        if useA { surfaceA = result } else { surfaceB = result }

        return result.texture
    }

    private func captureIOSurface(
        frame: CGRect, from window: UIWindow
    ) -> (unmanaged: Unmanaged<AnyObject>, texture: MTLTexture)? {
        let sel = Selector(("createIOSurfaceWithFrame:"))
        guard window.responds(to: sel) else { return nil }

        typealias Func = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(window.method(for: sel), to: Func.self)

        guard let unmanaged = fn(window, sel, frame) else { return nil }

        let obj = unmanaged.takeUnretainedValue()
        guard CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() else {
            unmanaged.release()
            return nil
        }

        let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)

        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        guard w > 0, h > 0 else {
            unmanaged.release()
            return nil
        }

        let pixelFormat = IOSurfaceGetPixelFormat(surface)
        let metalFormat: MTLPixelFormat = pixelFormat == 0x42475241 ? .bgra8Unorm : .bgr10a2Unorm

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: metalFormat, width: w, height: h, mipmapped: false
        )
        desc.usage = .shaderRead
        desc.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) else {
            unmanaged.release()
            return nil
        }

        return (unmanaged, texture)
    }

    func cleanup() {
        surfaceA?.unmanaged?.release()
        surfaceB?.unmanaged?.release()
        surfaceA = nil
        surfaceB = nil
    }
}

// MARK: - GlassService

/// Central coordinator for the glass overlay system.
/// Owns the overlay window, IOSurface capture, and render loop.
///
/// Capture is driven by explicit triggers, not continuous:
/// - `setNeedsCapture()` — one-shot (scroll, layout change, new message)
/// - `GlassCaptureSource` — continuous while animating (Lottie, GIF)
/// - Idle = 0% CPU (display link still ticks but skips capture+render)
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
    }

    private struct WeakSource {
        weak var source: GlassCaptureSource?
    }

    // MARK: - State

    private var overlayWindow: PassthroughWindow?
    private var registrations: [UUID: Registration] = [:]
    private var displayLinkToken: DisplayLinkToken?
    private weak var sourceWindow: UIWindow?
    private var captureManager: ScreenCaptureManager?

    // Trigger system
    private var needsCapture = true // true on first frame
    private var continuousCaptureUntil: CFTimeInterval = 0
    private var captureSources: [WeakSource] = []

    // Liquid wave animation
    private var waveTime: Float = 0
    private var waveEnergy: Float = 0
    private var lastTickTime: CFTimeInterval = 0

    #if DEBUG
    private var tickCount = 0
    private var captureTimeAccum: Double = 0
    private var renderTimeAccum: Double = 0
    private var totalTimeAccum: Double = 0
    private var statsTimestamp: CFTimeInterval = 0
    private var idleFrames = 0
    #endif

    private init() {}

    // MARK: - Public API

    func register(anchor: GlassAnchor) -> GlassRegistration {
        let id = UUID()
        let renderer = GlassRenderer()

        registrations[id] = Registration(anchor: anchor, renderer: renderer)

        ensureOverlayWindow(for: anchor)
        overlayWindow?.rootViewController?.view.addSubview(renderer)

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
    /// Called by GlassContainerView when it gets a window.
    func attachContent(_ contentView: UIView, for anchor: GlassAnchor) {
        guard let overlayRoot = overlayWindow?.rootViewController?.view else { return }

        for (id, reg) in registrations where reg.anchor === anchor {
            overlayRoot.addSubview(contentView)
            registrations[id] = Registration(
                anchor: reg.anchor,
                renderer: reg.renderer,
                contentView: contentView
            )
            break
        }
    }

    // MARK: - Capture Triggers

    /// Call when content under glass has changed (scroll, layout, new message).
    /// Triggers a single re-capture on the next tick.
    func setNeedsCapture() {
        needsCapture = true
    }

    /// Capture continuously for the given duration (e.g. during a UIView animation).
    /// Useful when content under glass animates but the anchor itself doesn't move.
    func captureFor(duration: CFTimeInterval) {
        continuousCaptureUntil = max(continuousCaptureUntil, CACurrentMediaTime() + duration)
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
    }

    /// Remove a capture source (cell exited visible state).
    func removeCaptureSource(_ source: GlassCaptureSource) {
        captureSources.removeAll { $0.source === source }
    }

    // MARK: - Overlay Window

    private func ensureOverlayWindow(for anchor: GlassAnchor) {
        guard overlayWindow == nil else { return }
        guard let scene = anchor.window?.windowScene,
              let mainWindow = anchor.window else { return }

        sourceWindow = mainWindow
        captureManager = ScreenCaptureManager()

        let window = PassthroughWindow(windowScene: scene)
        window.windowLevel = mainWindow.windowLevel + 0.5
        window.frame = mainWindow.bounds
        window.isHidden = false
        overlayWindow = window
    }

    private func tearDown() {
        displayLinkToken?.invalidate()
        displayLinkToken = nil
        captureManager?.cleanup()
        captureManager = nil
        overlayWindow?.isHidden = true
        overlayWindow = nil
        sourceWindow = nil
        captureSources.removeAll()
    }

    // MARK: - Render Loop

    private func startRenderLoop() {
        displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .fps(120)) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let sourceWindow, let captureManager else { return }

        // Sync overlay size with source window
        if let overlay = overlayWindow, overlay.bounds.size != sourceWindow.bounds.size {
            overlay.frame = sourceWindow.bounds
        }

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
            } else {
                waveEnergy = max(waveEnergy - dt * 0.35, 0)
                if waveEnergy > 0.001 {
                    waveTime += dt * waveEnergy
                }
            }
        }

        // Render when capturing OR waves still decaying
        let shouldRender = shouldCapture || (hasLiquidPool && waveEnergy > 0.001)

        let scale = sourceWindow.screen.scale

        #if DEBUG
        let tickStart = CACurrentMediaTime()
        var captureTime: Double = 0
        var renderTime: Double = 0
        #endif

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
            guard shouldCapture || (shouldRender && wantsLiquid) else { continue }

            if shouldCapture {
                // ── Capture new frame ──
                let windowBounds = sourceWindow.bounds
                let sidePadding: CGFloat = 20
                // Liquid mode: more top padding to capture cells approaching the surface
                let topPadding: CGFloat = wantsLiquid ? 80 : 20
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

                guard let texture = captureManager.capture(frame: captureFrame, from: sourceWindow) else { continue }

                #if DEBUG
                captureTime += CACurrentMediaTime() - capStart
                #endif

                reg.renderer.frame = captureFrame
                reg.renderer.contentScaleFactor = scale
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

                // Cache for render-only frames
                registrations[id]?.lastTexture = texture
                registrations[id]?.lastCaptureFrame = captureFrame
                registrations[id]?.lastShapes = shapes
                registrations[id]?.lastIsHDR = texture.pixelFormat == .bgr10a2Unorm
                registrations[id]?.lastLiquidZone = liquidZone

                #if DEBUG
                let renStart = CACurrentMediaTime()
                #endif

                reg.renderer.render(
                    with: texture,
                    shapes: shapes,
                    isHDR: texture.pixelFormat == .bgr10a2Unorm,
                    liquidZone: liquidZone,
                    time: waveTime
                )

                #if DEBUG
                renderTime += CACurrentMediaTime() - renStart
                #endif

            } else if wantsLiquid,
                      let texture = reg.lastTexture,
                      let shapes = reg.lastShapes {
                // ── Render-only: reuse cached texture, update wave animation ──
                var lz = reg.lastLiquidZone
                lz?.waveEnergy = waveEnergy

                #if DEBUG
                let renStart = CACurrentMediaTime()
                #endif

                reg.renderer.render(
                    with: texture,
                    shapes: shapes,
                    isHDR: reg.lastIsHDR,
                    liquidZone: lz,
                    time: waveTime
                )

                #if DEBUG
                renderTime += CACurrentMediaTime() - renStart
                #endif
            }
        }

        // Cleanup dead weak references periodically
        if captureSources.count > 0 && tickCount % 600 == 0 {
            captureSources.removeAll { $0.source == nil }
        }

        #if DEBUG
        let totalTime = CACurrentMediaTime() - tickStart
        if shouldRender {
            captureTimeAccum += captureTime
            renderTimeAccum += renderTime
            totalTimeAccum += totalTime
            tickCount += 1
            idleFrames = 0
        } else {
            idleFrames += 1
        }

        let statsNow = CACurrentMediaTime()
        if statsTimestamp == 0 { statsTimestamp = statsNow }
        if statsNow - statsTimestamp >= 1.0 {
            if tickCount > 0 {
                let n = Double(tickCount)
                let capAvg = captureTimeAccum / n * 1000
                let renAvg = renderTimeAccum / n * 1000
                let totAvg = totalTimeAccum / n * 1000
                print("[glass] views=\(registrations.count) active=\(tickCount) idle=\(idleFrames) capture=\(String(format: "%.2f", capAvg))ms render=\(String(format: "%.2f", renAvg))ms total=\(String(format: "%.2f", totAvg))ms")
            } else {
                print("[glass] idle (0 captures)")
            }
            tickCount = 0
            idleFrames = 0
            captureTimeAccum = 0
            renderTimeAccum = 0
            totalTimeAccum = 0
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
}
