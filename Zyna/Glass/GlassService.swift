//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import IOSurface

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

        if registrations.isEmpty {
            tearDown()
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
        let inBurst = CACurrentMediaTime() < continuousCaptureUntil
        let shouldCapture = needsCapture || inBurst || anyAnimating || hasActiveSourceUnderGlass()

        if shouldCapture {
            needsCapture = false
        }

        let scale = sourceWindow.screen.scale

        #if DEBUG
        let tickStart = CACurrentMediaTime()
        var captureTime: Double = 0
        var renderTime: Double = 0
        #endif

        for (_, reg) in registrations {
            guard let anchor = reg.anchor,
                  let rawFrame = anchor.presentationFrame(),
                  rawFrame.width > 0, rawFrame.height > 0
            else {
                reg.renderer.isHidden = true
                continue
            }

            reg.renderer.isHidden = false

            // Snap to device pixels
            let frameInWindow = CGRect(
                x: round(rawFrame.origin.x * scale) / scale,
                y: round(rawFrame.origin.y * scale) / scale,
                width: round(rawFrame.width * scale) / scale,
                height: round(rawFrame.height * scale) / scale
            )

            guard shouldCapture else { continue }

            #if DEBUG
            let capStart = CACurrentMediaTime()
            #endif

            guard let texture = captureManager.capture(frame: frameInWindow, from: sourceWindow) else { continue }

            #if DEBUG
            captureTime += CACurrentMediaTime() - capStart
            #endif

            reg.renderer.frame = frameInWindow
            reg.renderer.contentScaleFactor = scale

            #if DEBUG
            let renStart = CACurrentMediaTime()
            #endif

            reg.renderer.render(
                with: texture,
                cornerRadius: anchor.cornerRadius,
                isHDR: texture.pixelFormat == .bgr10a2Unorm
            )

            #if DEBUG
            renderTime += CACurrentMediaTime() - renStart
            #endif
        }

        // Cleanup dead weak references periodically
        if captureSources.count > 0 && tickCount % 600 == 0 {
            captureSources.removeAll { $0.source == nil }
        }

        #if DEBUG
        let totalTime = CACurrentMediaTime() - tickStart
        if shouldCapture {
            captureTimeAccum += captureTime
            renderTimeAccum += renderTime
            totalTimeAccum += totalTime
            tickCount += 1
            idleFrames = 0
        } else {
            idleFrames += 1
        }

        let now = CACurrentMediaTime()
        if statsTimestamp == 0 { statsTimestamp = now }
        if now - statsTimestamp >= 1.0 {
            if tickCount > 0 {
                let n = Double(tickCount)
                let capAvg = captureTimeAccum / n * 1000
                let renAvg = renderTimeAccum / n * 1000
                let totAvg = totalTimeAccum / n * 1000
                print("[glass] active=\(tickCount) idle=\(idleFrames) capture=\(String(format: "%.2f", capAvg))ms render=\(String(format: "%.2f", renAvg))ms total=\(String(format: "%.2f", totAvg))ms")
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
