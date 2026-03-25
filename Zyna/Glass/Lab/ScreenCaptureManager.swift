//
// Experimental capture backends for Glass Lab.
// IOSurface (private API), Portal (_UIPortalView), full-window layer.render.
//

import UIKit
import IOSurface
import Metal

// MARK: - CaptureMethod

/// Capture method for glass background.
enum CaptureMethod: CaseIterable, CustomStringConvertible {
    case ioSurface      // Private API, zero-copy GPU→GPU
    case layerRender    // Public API, CPU render → GPU upload, per-region
    case layerRenderFull // Public API, single full-window render, crop per glass
    case portal         // Private _UIPortalView → layer.render → GPU upload

    var description: String {
        switch self {
        case .ioSurface: return "IOSurface"
        case .layerRender: return "layer.render"
        case .layerRenderFull: return "layer.render (full)"
        case .portal: return "Portal"
        }
    }
}

// MARK: - ScreenCaptureManager

/// Double-buffered screen capture with swappable backend.
final class ScreenCaptureManager {

    private var device: MTLDevice { MetalContext.shared.device }
    private var surfaceA: (unmanaged: Unmanaged<AnyObject>?, texture: MTLTexture?)?
    private var surfaceB: (unmanaged: Unmanaged<AnyObject>?, texture: MTLTexture?)?
    private var useA = true

    /// Toggle this to switch capture backend at runtime.
    var method: CaptureMethod = .layerRender

    // Reusable texture for layerRender / portal (avoid re-alloc every frame)
    private var layerTexture: MTLTexture?
    private var layerTextureSize: (Int, Int) = (0, 0)

    // Portal view for .portal method
    private var portalView: UIView?
    private weak var portalSourceWindow: UIWindow?

    init() {}

    deinit { cleanup() }

    func capture(frame: CGRect, from window: UIWindow) -> MTLTexture? {
        switch method {
        case .ioSurface:
            return captureViaIOSurface(frame: frame, from: window)
        case .layerRender:
            return captureViaLayerRender(frame: frame, from: window)
        case .layerRenderFull:
            return captureViaLayerRenderFull(frame: frame, from: window)
        case .portal:
            return captureViaPortal(frame: frame, from: window)
        }
    }

    // MARK: - IOSurface (zero-copy)

    private func captureViaIOSurface(frame: CGRect, from window: UIWindow) -> MTLTexture? {
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

    // MARK: - CALayer.render (public API, CPU→GPU)

    private func captureViaLayerRender(frame: CGRect, from window: UIWindow) -> MTLTexture? {
        let scale = window.screen.scale
        let w = Int(frame.width * scale)
        let h = Int(frame.height * scale)
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: -frame.origin.x * scale, y: (frame.origin.y + frame.height) * scale)
        ctx.scaleBy(x: scale, y: -scale)

        let layer = window.layer.presentation() ?? window.layer
        layer.render(in: ctx)

        guard let data = ctx.data else { return nil }

        if w != layerTextureSize.0 || h != layerTextureSize.1 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            layerTexture = device.makeTexture(descriptor: desc)
            layerTextureSize = (w, h)
        }

        layerTexture?.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return layerTexture
    }

    // MARK: - CALayer.render full-window (single render, crop per glass)

    private var fullWindowCtx: CGContext?
    private var fullWindowSize: (Int, Int) = (0, 0)
    private var fullWindowData: UnsafeMutableRawPointer?
    private var fullWindowGeneration: UInt64 = 0
    private var fullWindowLastUsedGeneration: UInt64 = 0
    private var cropTextures: [String: MTLTexture] = [:]

    func invalidateFullWindowCache() {
        fullWindowGeneration &+= 1
    }

    private func captureViaLayerRenderFull(frame: CGRect, from window: UIWindow) -> MTLTexture? {
        let scale = window.screen.scale
        let winW = Int(window.bounds.width * scale)
        let winH = Int(window.bounds.height * scale)
        guard winW > 0, winH > 0 else { return nil }

        if fullWindowLastUsedGeneration != fullWindowGeneration
            || fullWindowSize.0 != winW || fullWindowSize.1 != winH {

            let bytesPerRow = winW * 4
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            if fullWindowSize.0 != winW || fullWindowSize.1 != winH {
                fullWindowCtx = CGContext(
                    data: nil,
                    width: winW, height: winH,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue
                )
                fullWindowSize = (winW, winH)
            }

            guard let ctx = fullWindowCtx else { return nil }

            ctx.clear(CGRect(x: 0, y: 0, width: winW, height: winH))
            ctx.saveGState()
            ctx.translateBy(x: 0, y: CGFloat(winH))
            ctx.scaleBy(x: scale, y: -scale)
            let layer = window.layer.presentation() ?? window.layer
            layer.render(in: ctx)
            ctx.restoreGState()

            fullWindowData = ctx.data
            fullWindowLastUsedGeneration = fullWindowGeneration
        }

        guard let srcData = fullWindowData else { return nil }

        let cropX = Int(frame.origin.x * scale)
        let cropY = Int(frame.origin.y * scale)
        let cropW = Int(frame.width * scale)
        let cropH = Int(frame.height * scale)
        guard cropW > 0, cropH > 0,
              cropX >= 0, cropY >= 0,
              cropX + cropW <= winW, cropY + cropH <= winH else { return nil }

        let sizeKey = "\(cropW)x\(cropH)"
        var tex = cropTextures[sizeKey]
        if tex == nil {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: cropW, height: cropH, mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            tex = device.makeTexture(descriptor: desc)
            cropTextures[sizeKey] = tex
        }

        let srcBytesPerRow = winW * 4
        let src = srcData.advanced(by: cropY * srcBytesPerRow + cropX * 4)

        tex?.replace(
            region: MTLRegionMake2D(0, 0, cropW, cropH),
            mipmapLevel: 0,
            withBytes: src,
            bytesPerRow: srcBytesPerRow
        )

        return tex
    }

    // MARK: - _UIPortalView (private API)

    private func ensurePortal(for window: UIWindow) {
        guard portalView == nil || portalSourceWindow !== window else { return }

        guard let portalClass = NSClassFromString("_UIPortalView") else {
            print("[glass-lab] _UIPortalView class not found")
            return
        }

        let pv = (portalClass as! UIView.Type).init(frame: window.bounds)
        pv.setValue(window, forKey: "sourceView")
        pv.setValue(false, forKey: "matchesPosition")
        pv.setValue(false, forKey: "matchesTransform")
        pv.setValue(false, forKey: "matchesAlpha")

        pv.frame = window.bounds
        pv.alpha = 0.01
        window.insertSubview(pv, at: 0)

        portalView = pv
        portalSourceWindow = window
    }

    private func captureViaPortal(frame: CGRect, from window: UIWindow) -> MTLTexture? {
        ensurePortal(for: window)
        guard let pv = portalView else { return nil }

        let scale = window.screen.scale
        let w = Int(frame.width * scale)
        let h = Int(frame.height * scale)
        guard w > 0, h > 0 else { return nil }

        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        ctx.translateBy(x: -frame.origin.x * scale, y: -frame.origin.y * scale)
        ctx.scaleBy(x: scale, y: scale)
        pv.layer.render(in: ctx)

        guard let data = ctx.data else { return nil }

        if w != layerTextureSize.0 || h != layerTextureSize.1 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            layerTexture = device.makeTexture(descriptor: desc)
            layerTextureSize = (w, h)
        }

        layerTexture?.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0,
            withBytes: data,
            bytesPerRow: bytesPerRow
        )

        return layerTexture
    }

    func cleanup() {
        surfaceA?.unmanaged?.release()
        surfaceB?.unmanaged?.release()
        surfaceA = nil
        surfaceB = nil
        layerTexture = nil
        portalView?.removeFromSuperview()
        portalView = nil
    }
}
