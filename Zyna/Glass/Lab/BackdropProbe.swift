//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//
// Phase 2: Test all promising leads from the deep dive.
//

import UIKit
import IOSurface
import Metal
import ObjectiveC
import QuartzCore
import ReplayKit
import CoreMedia
import CoreVideo

// MARK: - BackdropProbe

enum BackdropProbe {

    private static func p(_ msg: String) {
        print("[probe] \(msg)")
    }

    static func run(in hostView: UIView) {
        guard let window = hostView.window else { return }
        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        p("  PHASE 7: Hot leads — RenderLayer, ExcludeWindows, ClientList")
        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        probeIOSurfaceScan(window: window)

        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        p("  DONE")
        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
    }

    // ═══════════════════════════════════════════════════════════
    // CARenderServerRenderDisplay — deep investigation
    // ═══════════════════════════════════════════════════════════

    private static func probeCARenderServerDeep(window: UIWindow) {
        p("\n══ CARenderServer Deep Investigation ══")

        let handle = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW)
        defer { if handle != nil { dlclose(handle) } }

        guard let renderDisplayPtr = dlsym(handle, "CARenderServerRenderDisplay") else {
            p("  ❌ CARenderServerRenderDisplay not found")
            return
        }

        // ── Step 1: Ports ──
        p("  ── Step 1: Ports ──")

        var ports: [(String, UInt32)] = [("zero", 0)]

        if let getPortPtr = dlsym(handle, "CARenderServerGetPort") {
            typealias F = @convention(c) () -> UInt32
            let port = unsafeBitCast(getPortPtr, to: F.self)()
            ports.append(("GetPort", port))
            p("    CARenderServerGetPort = \(port)")
        }

        if let getServerPortPtr = dlsym(handle, "CARenderServerGetServerPort") {
            typealias F = @convention(c) () -> UInt32
            let port = unsafeBitCast(getServerPortPtr, to: F.self)()
            ports.append(("GetServerPort", port))
            p("    CARenderServerGetServerPort = \(port)")
        }

        // ── Step 3: Try matching the actual IOSurface format from createIOSurfaceWithFrame ──
        p("\n  ── Step 3: Surface format matching ──")

        // First capture with createIOSurfaceWithFrame to see the real format
        let sel = Selector(("createIOSurfaceWithFrame:"))
        typealias WinFunc = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let winFn = unsafeBitCast(window.method(for: sel), to: WinFunc.self)

        var refFormat: UInt32 = 0x42475241
        var refBPE: Int = 4
        var refBPR: Int = 0
        var refW: Int = 0
        var refH: Int = 0

        if let ref = winFn(window, sel, window.bounds) {
            let obj = ref.takeUnretainedValue()
            let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
            refFormat = IOSurfaceGetPixelFormat(surface)
            refBPE = IOSurfaceGetBytesPerElement(surface)
            refBPR = IOSurfaceGetBytesPerRow(surface)
            refW = IOSurfaceGetWidth(surface)
            refH = IOSurfaceGetHeight(surface)
            p("    Reference surface: \(refW)×\(refH)")
            p("    pixelFormat: 0x\(String(refFormat, radix: 16))")
            p("    bytesPerElement: \(refBPE)")
            p("    bytesPerRow: \(refBPR)")
            p("    planeCount: \(IOSurfaceGetPlaneCount(surface))")
            p("    allocSize: \(IOSurfaceGetAllocSize(surface))")
            ref.release()
        }

        // ── Step 4: Create surface matching real format ──
        p("\n  ── Step 4: Try with matching format ──")

        // Try BGRA (simple) and the device's native format
        let formats: [(String, [CFString: Any])] = [
            ("BGRA", [
                kIOSurfaceWidth: refW > 0 ? refW : 1320,
                kIOSurfaceHeight: refH > 0 ? refH : 2868,
                kIOSurfacePixelFormat: 0x42475241 as UInt32,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: (refW > 0 ? refW : 1320) * 4,
            ]),
            ("NativeFormat", [
                kIOSurfaceWidth: refW > 0 ? refW : 1320,
                kIOSurfaceHeight: refH > 0 ? refH : 2868,
                kIOSurfacePixelFormat: refFormat,
                kIOSurfaceBytesPerElement: refBPE,
                kIOSurfaceBytesPerRow: refBPR > 0 ? refBPR : (refW > 0 ? refW : 1320) * 4,
            ]),
        ]

        let displayNames = ["LCD", "Main", "Default", "1"]

        typealias RenderDisplayFunc = @convention(c) (UInt32, CFString, IOSurfaceRef, Int32, Int32) -> Void
        let renderDisplay = unsafeBitCast(renderDisplayPtr, to: RenderDisplayFunc.self)

        for (formatName, props) in formats {
            guard let surface = IOSurfaceCreate(props as CFDictionary) else { continue }
            let w = IOSurfaceGetWidth(surface)
            let h = IOSurfaceGetHeight(surface)

            for (portName, port) in ports {
                for displayName in displayNames {
                    // Clear surface first
                    IOSurfaceLock(surface, [], nil)
                    memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
                    IOSurfaceUnlock(surface, [], nil)

                    let start = CACurrentMediaTime()
                    renderDisplay(port, displayName as CFString, surface, 0, 0)
                    let time = (CACurrentMediaTime() - start) * 1000

                    // Check pixels
                    IOSurfaceLock(surface, .readOnly, nil)
                    let baseAddr = IOSurfaceGetBaseAddress(surface)
                    var nonZero = 0
                    let pixelPtr = baseAddr.assumingMemoryBound(to: UInt8.self)
                    let totalBytes = IOSurfaceGetAllocSize(surface)
                    let step = max(1, totalBytes / 200)
                    for i in Swift.stride(from: 0, to: min(totalBytes, step * 200), by: step) {
                        if pixelPtr[i] != 0 { nonZero += 1 }
                    }
                    IOSurfaceUnlock(surface, .readOnly, nil)

                    if nonZero > 0 {
                        p("    ⭐️ \(formatName) port=\(portName) display=\"\(displayName)\": \(nonZero)/200 non-zero \(String(format: "%.2f", time))ms")
                    }
                }
            }
        }

        // ── Step 5: Try with delay (async render?) ──
        p("\n  ── Step 5: Async check ──")
        let asyncProps: [CFString: Any] = [
            kIOSurfaceWidth: refW > 0 ? refW : 1320,
            kIOSurfaceHeight: refH > 0 ? refH : 2868,
            kIOSurfacePixelFormat: 0x42475241 as UInt32,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: (refW > 0 ? refW : 1320) * 4,
        ]
        if let asyncSurface = IOSurfaceCreate(asyncProps as CFDictionary) {
            renderDisplay(0, "LCD" as CFString, asyncSurface, 0, 0)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                IOSurfaceLock(asyncSurface, .readOnly, nil)
                let ptr = IOSurfaceGetBaseAddress(asyncSurface).assumingMemoryBound(to: UInt8.self)
                var nonZero = 0
                let total = IOSurfaceGetAllocSize(asyncSurface)
                let step = max(1, total / 200)
                for i in Swift.stride(from: 0, to: min(total, step * 200), by: step) {
                    if ptr[i] != 0 { nonZero += 1 }
                }
                IOSurfaceUnlock(asyncSurface, .readOnly, nil)
                p("    After 500ms: \(nonZero)/200 non-zero \(nonZero > 0 ? "⭐️" : "❌")")
            }
        }

        // ── Step 6: Try ExcludeList variant ──
        p("\n  ── Step 6: ExcludeList variants ──")
        let excludeSymbols = [
            "CARenderServerRenderDisplayExcludeList",
            "CARenderServerCaptureDisplayExcludeList",
            "CARenderServerRenderDisplayClientList",
            "CARenderServerCaptureDisplayClientList",
        ]
        for sym in excludeSymbols {
            if dlsym(handle, sym) != nil {
                p("    ✅ \(sym) exists")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // (reference) CaptureGroup Activation
    // ═══════════════════════════════════════════════════════════

    private static func probeCaptureGroupActivation(in hostView: UIView) {
        p("\n══ CaptureGroup Activation Test ══")

        guard let groupCls = NSClassFromString("_UIVisualEffectViewBackdropCaptureGroup"),
              let bdViewCls = NSClassFromString("_UIVisualEffectBackdropView") as? UIView.Type,
              let bdLayerCls = NSClassFromString("CABackdropLayer") as? CALayer.Type
        else {
            p("  ❌ Required classes not found")
            return
        }

        // ── Step 1: Create our own CaptureGroup via initWithName:scale: ──
        p("  Step 1: Create CaptureGroup")
        let initSel = NSSelectorFromString("initWithName:scale:")
        guard groupCls.instancesRespond(to: initSel) else {
            p("  ❌ initWithName:scale: not available")
            return
        }

        let allocSel = NSSelectorFromString("alloc")
        guard let allocated = (groupCls as AnyObject).perform(allocSel)?.takeUnretainedValue() else {
            p("  ❌ alloc failed")
            return
        }

        typealias InitFunc = @convention(c) (AnyObject, Selector, NSString, Double) -> AnyObject?
        let initFn = unsafeBitCast(
            (allocated as AnyObject).method(for: initSel),
            to: InitFunc.self
        )
        guard let group = initFn(allocated, initSel, "ZynaGlass" as NSString, 1.0) else {
            p("  ❌ initWithName:scale: returned nil")
            return
        }
        let groupObj = group as! NSObject
        p("  ✅ Created: \(groupObj)")

        // ── Step 2: Create _UIVisualEffectBackdropView ──
        p("  Step 2: Create BackdropView")
        let bdView = bdViewCls.init(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        hostView.addSubview(bdView)
        p("  ✅ BackdropView: \(bdView)")
        p("  BackdropView layer type: \(NSStringFromClass(type(of: bdView.layer)))")

        // Check layer contents before
        let layerBefore = bdView.layer.contents != nil
        p("  Layer contents before: \(layerBefore)")

        // ── Step 3: Set capture group on backdrop view ──
        p("  Step 3: setCaptureGroup:")
        let setCaptureGroupSel = NSSelectorFromString("setCaptureGroup:")
        if bdView.responds(to: setCaptureGroupSel) {
            bdView.perform(setCaptureGroupSel, with: groupObj)
            p("  ✅ setCaptureGroup: called")
        } else {
            p("  ❌ setCaptureGroup: not available")
        }

        // ── Step 4: Also try addBackdrop:update: on group ──
        p("  Step 4: addBackdrop:update:")
        let addSel = NSSelectorFromString("addBackdrop:update:")
        if groupObj.responds(to: addSel) {
            typealias AddFunc = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
            let addFn = unsafeBitCast(groupObj.method(for: addSel), to: AddFunc.self)
            addFn(groupObj, addSel, bdView, true)
            p("  ✅ addBackdrop:update: called")
        }

        // ── Step 5: Apply filter effects ──
        p("  Step 5: applyRequestedFilterEffects")
        let applyEffectsSel = NSSelectorFromString("applyRequestedFilterEffects")
        if bdView.responds(to: applyEffectsSel) {
            bdView.perform(applyEffectsSel)
            p("  ✅ applyRequestedFilterEffects called")
        }

        // ── Step 6: Update and flush ──
        let updateSel = NSSelectorFromString("updateAllBackdropViews")
        if groupObj.responds(to: updateSel) {
            groupObj.perform(updateSel)
            p("  ✅ updateAllBackdropViews called")
        }

        CATransaction.flush()

        // ── Step 7: Check for contents ──
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasContents = bdView.layer.contents != nil
            p("  Step 7: Layer contents after activation: \(hasContents)")

            if hasContents {
                p("  ⭐️⭐️⭐️ BACKDROP ACTIVATED WITHOUT UIVisualEffectView!")
                p("  Contents type: \(type(of: bdView.layer.contents!))")
            } else {
                p("  ❌ Still no contents")

                // ── Fallback: Try using the LIVE group from a real UIVisualEffectView ──
                p("  Fallback: Try live group from UIVisualEffectView...")
                let vev = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
                vev.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
                hostView.addSubview(vev)

                if let liveGroup = vev.subviews.first?.value(forKey: "captureGroup") as? NSObject {
                    // Add OUR backdrop view to the LIVE group
                    let bdView2 = bdViewCls.init(frame: CGRect(x: 0, y: 0, width: 200, height: 100))
                    hostView.addSubview(bdView2)

                    if liveGroup.responds(to: addSel) {
                        typealias AddFunc = @convention(c) (AnyObject, Selector, AnyObject, Bool) -> Void
                        let addFn = unsafeBitCast(liveGroup.method(for: addSel), to: AddFunc.self)
                        addFn(liveGroup, addSel, bdView2, true)
                        p("    Added to live group")
                    }

                    if bdView2.responds(to: setCaptureGroupSel) {
                        bdView2.perform(setCaptureGroupSel, with: liveGroup)
                        p("    setCaptureGroup with live group")
                    }

                    CATransaction.flush()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        let hasContents2 = bdView2.layer.contents != nil
                        p("    Live group → contents: \(hasContents2)")
                        if hasContents2 {
                            p("    ⭐️⭐️⭐️ LIVE GROUP ACTIVATED OUR BACKDROP!")
                        }
                        bdView2.removeFromSuperview()
                        vev.removeFromSuperview()
                    }
                } else {
                    vev.removeFromSuperview()
                }
            }

            bdView.removeFromSuperview()
        }
    }

    // ═══════════════════════════════════════════════════════════
    // (kept for reference) CARenderServerRenderDisplay
    // ═══════════════════════════════════════════════════════════

    private static func probeCARenderServerRenderDisplay(window: UIWindow) {
        p("\n══ 1. CARenderServerRenderDisplay ══")
        p("  Signature: void(mach_port_t, CFStringRef displayName, IOSurfaceRef, int x, int y)")
        p("  Source: coolstar/RecordMyScreen + WebKit QuartzCoreSPI.h")

        let handle = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW)
        defer { if handle != nil { dlclose(handle) } }

        // Find the function
        guard let renderDisplayPtr = dlsym(handle, "CARenderServerRenderDisplay") else {
            p("  ❌ CARenderServerRenderDisplay not found")
            return
        }
        p("  ✅ Found at \(renderDisplayPtr)")

        // Create our reusable IOSurface (full screen size)
        let screenScale = window.screen.scale
        let screenW = Int(window.bounds.width * screenScale)
        let screenH = Int(window.bounds.height * screenScale)

        let props: [CFString: Any] = [
            kIOSurfaceWidth: screenW,
            kIOSurfaceHeight: screenH,
            kIOSurfacePixelFormat: 0x42475241, // BGRA
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: screenW * 4,
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else {
            p("  ❌ IOSurfaceCreate failed")
            return
        }
        p("  Target IOSurface: \(screenW)×\(screenH)")

        // Call: CARenderServerRenderDisplay(0, CFSTR("LCD"), surface, 0, 0)
        // port=0 means auto-lookup
        typealias RenderDisplayFunc = @convention(c) (UInt32, CFString, IOSurfaceRef, Int32, Int32) -> Void
        let renderDisplay = unsafeBitCast(renderDisplayPtr, to: RenderDisplayFunc.self)

        let start = CACurrentMediaTime()
        renderDisplay(0, "LCD" as CFString, surface, 0, 0)
        let time = (CACurrentMediaTime() - start) * 1000
        p("  RenderDisplay time: \(String(format: "%.2f", time))ms")

        // Check pixels
        IOSurfaceLock(surface, .readOnly, nil)
        let baseAddr = IOSurfaceGetBaseAddress(surface)
        var nonZero = 0
        let ptr = baseAddr.assumingMemoryBound(to: UInt32.self)
        let pixelCount = screenW * screenH
        let step = max(1, pixelCount / 100)
        for i in stride(from: 0, to: min(pixelCount, step * 100), by: step) {
            if ptr[i] != 0 { nonZero += 1 }
        }
        IOSurfaceUnlock(surface, .readOnly, nil)
        p("  Pixels: \(nonZero)/100 non-zero \(nonZero > 0 ? "⭐️ HAS CONTENT!" : "❌ empty")")

        if nonZero > 0 {
            // Benchmark: reuse same surface 10×
            p("  Benchmark (reusable surface, 10 iterations):")
            var times: [Double] = []
            for _ in 0..<10 {
                let t = CACurrentMediaTime()
                renderDisplay(0, "LCD" as CFString, surface, 0, 0)
                times.append((CACurrentMediaTime() - t) * 1000)
            }
            let avg = times.reduce(0, +) / Double(times.count)
            let minT = times.min()!
            p("    avg=\(String(format: "%.2f", avg))ms  min=\(String(format: "%.2f", minT))ms")

            // Compare with createIOSurfaceWithFrame:
            let sel = Selector(("createIOSurfaceWithFrame:"))
            typealias WinFunc = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
            let fn = unsafeBitCast(window.method(for: sel), to: WinFunc.self)
            var winTimes: [Double] = []
            for _ in 0..<10 {
                let t = CACurrentMediaTime()
                let s = fn(window, sel, window.bounds)
                winTimes.append((CACurrentMediaTime() - t) * 1000)
                s?.release()
            }
            let winAvg = winTimes.reduce(0, +) / Double(winTimes.count)
            p("    createIOSurfaceWithFrame: avg=\(String(format: "%.2f", winAvg))ms")
            p("    Winner: \(avg < winAvg ? "⭐️ CARenderServer" : "createIOSurfaceWithFrame")")

            // Try smaller surface (just glass region)
            let smallW = 400 * Int(screenScale)
            let smallH = 50 * Int(screenScale)
            let smallProps: [CFString: Any] = [
                kIOSurfaceWidth: smallW,
                kIOSurfaceHeight: smallH,
                kIOSurfacePixelFormat: 0x42475241,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: smallW * 4,
            ]
            if let smallSurface = IOSurfaceCreate(smallProps as CFDictionary) {
                p("  Small surface (\(smallW)×\(smallH)):")
                var smallTimes: [Double] = []
                for _ in 0..<10 {
                    let t = CACurrentMediaTime()
                    renderDisplay(0, "LCD" as CFString, smallSurface, 0, 0)
                    smallTimes.append((CACurrentMediaTime() - t) * 1000)
                }
                let smallAvg = smallTimes.reduce(0, +) / Double(smallTimes.count)
                p("    avg=\(String(format: "%.2f", smallAvg))ms")
            }

            // Can we create MTLTexture from our surface?
            let device = MetalContext.shared.device
            let texDesc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: screenW, height: screenH, mipmapped: false
            )
            texDesc.usage = .shaderRead
            texDesc.storageMode = .shared
            if let texture = device.makeTexture(descriptor: texDesc, iosurface: surface, plane: 0) {
                p("  ✅ MTLTexture from reusable surface: \(texture.width)×\(texture.height)")
                p("  ⭐️ REUSABLE SURFACE + MTLTexture = no allocation per frame!")
            }
        }

        // Also try ExcludeList variant
        if let excludePtr = dlsym(handle, "CARenderServerRenderDisplayExcludeList") {
            p("\n  CARenderServerRenderDisplayExcludeList also found!")
            p("  Could exclude overlay window from capture → no overlay needed?")
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 3. _UIVisualEffectViewBackdropCaptureGroup
    // ═══════════════════════════════════════════════════════════

    private static func probeCaptureGroup(in hostView: UIView) {
        p("\n══ 3. BackdropCaptureGroup ══")

        guard let groupCls = NSClassFromString("_UIVisualEffectViewBackdropCaptureGroup") else {
            p("  ❌ Class not found")
            return
        }

        // Dump all methods
        p("  Class methods:")
        var classMethodCount: UInt32 = 0
        if let methods = class_copyMethodList(object_getClass(groupCls), &classMethodCount) {
            for i in 0..<Int(classMethodCount) {
                p("    +\(NSStringFromSelector(method_getName(methods[i])))")
            }
            free(methods)
        }

        p("  Instance methods:")
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(groupCls, &methodCount) {
            for i in 0..<Int(methodCount) {
                p("    \(NSStringFromSelector(method_getName(methods[i])))")
            }
            free(methods)
        }

        p("  Ivars:")
        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(groupCls, &ivarCount) {
            for i in 0..<Int(ivarCount) {
                let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
                let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                p("    \(name) [\(type)]")
            }
            free(ivars)
        }

        // Get a live capture group from UIVisualEffectView
        let vev = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        vev.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        hostView.addSubview(vev)
        CATransaction.flush()

        // Read _captureGroup ivar
        if let bdView = vev.subviews.first {
            if bdView.responds(to: NSSelectorFromString("captureGroup")),
               let group = bdView.value(forKey: "captureGroup") as? NSObject {
                p("  Live captureGroup: \(group)")

                // Read its properties
                let groupProps = ["scale", "backdrops", "captureRect", "groupName",
                                  "captureEnabled", "isActive", "captureQuality"]
                for prop in groupProps {
                    if group.responds(to: NSSelectorFromString(prop)) {
                        let val = group.value(forKey: prop)
                        p("    \(prop) = \(String(describing: val))")
                    }
                }

                // Try to create our own backdrop layer and add it to this group
                if let bdCls = NSClassFromString("CABackdropLayer") as? CALayer.Type {
                    let newLayer = bdCls.init()
                    newLayer.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
                    newLayer.setValue(true, forKey: "enabled")
                    hostView.layer.addSublayer(newLayer)

                    // Try addBackdrop: or similar
                    let addSelectors = ["addBackdrop:", "addBackdropLayer:",
                                        "registerBackdrop:", "addLayer:"]
                    for selName in addSelectors {
                        if group.responds(to: NSSelectorFromString(selName)) {
                            p("    ✅ responds to \(selName)")
                        }
                    }

                    // Try setCaptureGroup on our backdrop view
                    if let bdViewCls = NSClassFromString("_UIVisualEffectBackdropView") {
                        let setCaptureGroupSel = NSSelectorFromString("setCaptureGroup:")
                        if bdView.responds(to: setCaptureGroupSel) {
                            p("    ✅ backdropView responds to setCaptureGroup:")
                        }
                    }

                    CATransaction.flush()

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        let hasContents = newLayer.contents != nil
                        p("    New layer in group → contents: \(hasContents)")
                        newLayer.removeFromSuperlayer()
                    }
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            vev.removeFromSuperview()
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 4. CAWindowServerDisplay.acquireFrozenSurface
    // ═══════════════════════════════════════════════════════════

    private static func probeAcquireFrozenSurface(window: UIWindow) {
        p("\n══ 4. acquireFrozenSurface ══")

        guard let serverCls = NSClassFromString("CAWindowServer") else {
            p("  ❌ CAWindowServer not found")
            return
        }

        // Get shared server
        let serverSelectors = ["server", "sharedServer", "defaultServer"]
        var server: NSObject?
        for selName in serverSelectors {
            if serverCls.responds(to: NSSelectorFromString(selName)) {
                server = (serverCls as AnyObject).perform(NSSelectorFromString(selName))?.takeUnretainedValue() as? NSObject
                if server != nil {
                    p("  Server via +\(selName): \(server!)")
                    break
                }
            }
        }

        // Try contextWithOptions: to get a context
        if serverCls.responds(to: NSSelectorFromString("contextWithOptions:")) {
            p("  ✅ +contextWithOptions: exists")
        }

        guard let server else {
            p("  ❌ Could not get server instance")

            // Try via displays
            if serverCls.responds(to: NSSelectorFromString("displays")) {
                p("  Trying +displays...")
            }
            return
        }

        // Get displays
        if server.responds(to: NSSelectorFromString("displays")) {
            if let displays = server.value(forKey: "displays") as? [NSObject] {
                p("  Displays: \(displays.count)")
                for (i, display) in displays.enumerated() {
                    p("    [\(i)] \(NSStringFromClass(type(of: display)))")

                    if display.responds(to: NSSelectorFromString("acquireFrozenSurface")) {
                        p("      ✅ acquireFrozenSurface available!")
                        let start = CACurrentMediaTime()
                        let result = display.perform(NSSelectorFromString("acquireFrozenSurface"))
                        let time = (CACurrentMediaTime() - start) * 1000
                        if let surface = result?.takeUnretainedValue() {
                            p("      ⭐️ Got surface: \(surface) in \(String(format: "%.2f", time))ms")
                            if CFGetTypeID(surface as CFTypeRef) == IOSurfaceGetTypeID() {
                                let ioSurf = unsafeBitCast(surface, to: IOSurfaceRef.self)
                                p("      IOSurface: \(IOSurfaceGetWidth(ioSurf))×\(IOSurfaceGetHeight(ioSurf))")
                            }
                        } else {
                            p("      Returned nil (\(String(format: "%.2f", time))ms)")
                        }
                    }

                    // Also check presentSurface:withOptions:
                    if display.responds(to: NSSelectorFromString("presentSurface:withOptions:")) {
                        p("      ✅ presentSurface:withOptions: available")
                    }
                }
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // 5. Backdrop scale control
    // ═══════════════════════════════════════════════════════════

    private static func probeBackdropScaleControl(in hostView: UIView) {
        p("\n══ 5. Backdrop scale control ══")

        let vev = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        vev.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        hostView.addSubview(vev)
        CATransaction.flush()

        guard let bdView = vev.subviews.first else {
            vev.removeFromSuperview()
            return
        }

        // Current scale on backdrop layer
        let bdLayer = bdView.layer
        if bdLayer.responds(to: NSSelectorFromString("scale")) {
            let currentScale = bdLayer.value(forKey: "scale")
            p("  Current backdrop scale: \(String(describing: currentScale))")
        }

        // Try _applyScaleHintAsRequested:
        if bdView.responds(to: NSSelectorFromString("_applyScaleHintAsRequested:")) {
            p("  ✅ _applyScaleHintAsRequested: exists")

            // Try setting different scales
            for scale in [0.25, 0.5, 1.0, 2.0] as [CGFloat] {
                bdLayer.setValue(scale, forKey: "scale")
                let actual = bdLayer.value(forKey: "scale")
                p("    Set \(scale) → actual: \(String(describing: actual))")
            }
        }

        // CaptureGroup scale
        if bdView.responds(to: NSSelectorFromString("captureGroup")),
           let group = bdView.value(forKey: "captureGroup") as? NSObject {

            if group.responds(to: NSSelectorFromString("scale")) {
                let groupScale = group.value(forKey: "scale")
                p("  CaptureGroup scale: \(String(describing: groupScale))")

                // Try changing it
                for scale in [0.25, 0.5, 1.0] as [CGFloat] {
                    group.setValue(scale, forKey: "scale")
                    let actual = group.value(forKey: "scale")
                    p("    Set group scale \(scale) → actual: \(String(describing: actual))")
                }
            }
        }

        // MTMaterialLayer scale
        if let mtCls = NSClassFromString("MTMaterialLayer") as? CALayer.Type {
            p("  MTMaterialLayer:")
            let mtLayer = mtCls.init()
            if mtLayer.responds(to: NSSelectorFromString("_backdropScale")) {
                let s = mtLayer.value(forKey: "_backdropScale")
                p("    _backdropScale: \(String(describing: s))")
            }
            if mtLayer.responds(to: NSSelectorFromString("backdropScaleAdjustment")) {
                let s = mtLayer.value(forKey: "backdropScaleAdjustment")
                p("    backdropScaleAdjustment: \(String(describing: s))")
            }
        }

        vev.removeFromSuperview()
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 11: IOSurface global scan — find live display surface
    // ═══════════════════════════════════════════════════════════

    private static func probeIOSurfaceScan(window: UIWindow) {
        p("\n══ 11.1 IOSurface global scan ══")

        let screenScale = window.screen.scale
        let screenW = Int(window.screen.bounds.width * screenScale)
        let screenH = Int(window.screen.bounds.height * screenScale)
        p("  Screen: \(screenW)×\(screenH) @\(screenScale)x")

        // ── Step 1: Scan ID range 1..500 — find all accessible surfaces ──
        p("\n  ── Scanning IDs 1..500 ──")

        struct FoundSurface {
            let id: UInt32
            let width: Int
            let height: Int
            let pixelFormat: UInt32
            let bytesPerRow: Int
            let allocSize: Int
            let seed: UInt32
            let planeCount: Int
        }

        var found: [FoundSurface] = []

        for id: UInt32 in 1...500 {
            guard let surface = IOSurfaceLookup(id) else { continue }
            let info = FoundSurface(
                id: id,
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface),
                pixelFormat: IOSurfaceGetPixelFormat(surface),
                bytesPerRow: IOSurfaceGetBytesPerRow(surface),
                allocSize: IOSurfaceGetAllocSize(surface),
                seed: IOSurfaceGetSeed(surface),
                planeCount: IOSurfaceGetPlaneCount(surface)
            )
            found.append(info)
        }

        p("  Found \(found.count) surfaces in range 1..500")

        // Group by size
        var sizeGroups: [String: [FoundSurface]] = [:]
        for s in found {
            let key = "\(s.width)×\(s.height)"
            sizeGroups[key, default: []].append(s)
        }

        p("\n  ── By size ──")
        for (size, surfaces) in sizeGroups.sorted(by: { $0.value.count > $1.value.count }) {
            let ids = surfaces.map { "\($0.id)" }.joined(separator: ",")
            let fmt = String(format: "0x%08x", surfaces[0].pixelFormat)
            let planes = surfaces[0].planeCount
            p("  \(size) [\(fmt)] planes=\(planes): \(surfaces.count)x — IDs: \(ids)")
        }

        // ── Step 2: Check for screen-sized surfaces ──
        let screenSized = found.filter { $0.width == screenW && $0.height == screenH }
        let halfScreen = found.filter {
            ($0.width == screenW && $0.height > screenH / 2) ||
            ($0.width > screenW / 2 && $0.height == screenH)
        }
        let large = found.filter { $0.width * $0.height > screenW * screenH / 2 }

        p("\n  Screen-sized (\(screenW)×\(screenH)): \(screenSized.count)")
        for s in screenSized {
            p("    ID \(s.id): seed=\(s.seed) fmt=0x\(String(s.pixelFormat, radix: 16)) alloc=\(s.allocSize)")
        }

        p("  Large (>50% screen): \(large.count)")
        for s in large where !screenSized.contains(where: { $0.id == s.id }) {
            p("    ID \(s.id): \(s.width)×\(s.height) seed=\(s.seed)")
        }

        // ── Step 3: Seed liveness test — which surfaces are being updated? ──
        p("\n  ── Liveness test (seed change over 200ms) ──")

        // Record initial seeds
        var seedMap: [(UInt32, UInt32)] = [] // (id, initialSeed)
        for s in found {
            seedMap.append((s.id, s.seed))
        }

        // Wait 200ms
        Thread.sleep(forTimeInterval: 0.2)

        // Check seeds again
        var liveSurfaces: [UInt32] = []
        for (id, initialSeed) in seedMap {
            guard let surface = IOSurfaceLookup(id) else { continue }
            let newSeed = IOSurfaceGetSeed(surface)
            if newSeed != initialSeed {
                liveSurfaces.append(id)
                let w = IOSurfaceGetWidth(surface)
                let h = IOSurfaceGetHeight(surface)
                let fmt = IOSurfaceGetPixelFormat(surface)
                p("    ⭐️ LIVE ID \(id): \(w)×\(h) fmt=0x\(String(fmt, radix: 16)) seed \(initialSeed)→\(newSeed)")
            }
        }

        if liveSurfaces.isEmpty {
            p("    No surfaces changed seed in 200ms")

            // Try longer wait
            p("    Trying 1 second wait...")
            Thread.sleep(forTimeInterval: 0.8) // total 1s

            for (id, initialSeed) in seedMap {
                guard let surface = IOSurfaceLookup(id) else { continue }
                let newSeed = IOSurfaceGetSeed(surface)
                if newSeed != initialSeed {
                    liveSurfaces.append(id)
                    let w = IOSurfaceGetWidth(surface)
                    let h = IOSurfaceGetHeight(surface)
                    p("    ⭐️ LIVE (1s) ID \(id): \(w)×\(h) seed \(initialSeed)→\(newSeed)")
                }
            }
        }

        // ── Step 4: Pixel comparison for all surfaces ──
        if liveSurfaces.isEmpty {
            p("\n  ── Pixel change test (bypasses seed) ──")
            // Some surfaces might update pixels without updating seed
            var pixelSnapshots: [(UInt32, UInt32)] = [] // (id, pixel sample)
            for s in found.prefix(50) {
                guard let surface = IOSurfaceLookup(s.id) else { continue }
                IOSurfaceLock(surface, .readOnly, nil)
                let pixel = IOSurfaceGetBaseAddress(surface)
                    .assumingMemoryBound(to: UInt32.self)[100]
                IOSurfaceUnlock(surface, .readOnly, nil)
                pixelSnapshots.append((s.id, pixel))
            }

            Thread.sleep(forTimeInterval: 0.2)

            for (id, oldPixel) in pixelSnapshots {
                guard let surface = IOSurfaceLookup(id) else { continue }
                IOSurfaceLock(surface, .readOnly, nil)
                let newPixel = IOSurfaceGetBaseAddress(surface)
                    .assumingMemoryBound(to: UInt32.self)[100]
                IOSurfaceUnlock(surface, .readOnly, nil)
                if newPixel != oldPixel {
                    let w = IOSurfaceGetWidth(surface)
                    let h = IOSurfaceGetHeight(surface)
                    p("    ⭐️ PIXEL CHANGE ID \(id): \(w)×\(h) 0x\(String(oldPixel, radix: 16))→0x\(String(newPixel, radix: 16))")
                    liveSurfaces.append(id)
                }
            }

            if liveSurfaces.isEmpty {
                p("    No pixel changes detected")
            }
        }

        // ── Step 5: Deep inspect any live surfaces ──
        if !liveSurfaces.isEmpty {
            p("\n  ── Deep inspect live surfaces ──")
            for id in Set(liveSurfaces) {
                guard let surface = IOSurfaceLookup(id) else { continue }
                let w = IOSurfaceGetWidth(surface)
                let h = IOSurfaceGetHeight(surface)
                let fmt = IOSurfaceGetPixelFormat(surface)
                let bpr = IOSurfaceGetBytesPerRow(surface)
                let alloc = IOSurfaceGetAllocSize(surface)
                let planes = IOSurfaceGetPlaneCount(surface)

                p("\n    ID \(id): \(w)×\(h)")
                p("    pixelFormat: 0x\(String(fmt, radix: 16))")
                p("    bytesPerRow: \(bpr)")
                p("    allocSize: \(alloc)")
                p("    planeCount: \(planes)")

                // Non-black check
                let nb = countNonBlack(surface)
                p("    non-black: \(nb)/100")

                // Is it screen-sized?
                if w == screenW && h == screenH {
                    p("    ⭐️⭐️⭐️ SCREEN-SIZED LIVE SURFACE!")
                }

                // Create MTLTexture
                let device = MetalContext.shared.device
                let metalFmt: MTLPixelFormat
                switch fmt {
                case 0x42475241: metalFmt = .bgra8Unorm
                case 0x77333072: metalFmt = .bgr10a2Unorm
                default: metalFmt = .bgra8Unorm
                }

                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: metalFmt, width: w, height: h, mipmapped: false
                )
                desc.usage = .shaderRead
                desc.storageMode = .shared
                if let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
                    p("    ✅ MTLTexture: \(tex.width)×\(tex.height)")
                }

                // Track updates over 5 frames
                p("    ── Update frequency (5 checks, 16ms apart) ──")
                var prevSeed = IOSurfaceGetSeed(surface)
                for frame in 0..<5 {
                    Thread.sleep(forTimeInterval: 0.016)
                    let s = IOSurfaceGetSeed(surface)
                    let changed = s != prevSeed
                    p("      frame \(frame): seed=\(s) \(changed ? "CHANGED" : "same")")
                    prevSeed = s
                }
            }
        }

        // ── Step 6: Wider scan for display framebuffer ──
        p("\n  ── Extended scan: IDs 500..2000 (looking for framebuffer) ──")
        var extendedFound = 0
        var largeExtended: [(UInt32, Int, Int)] = [] // (id, w, h)

        for id: UInt32 in 501...2000 {
            guard let surface = IOSurfaceLookup(id) else { continue }
            extendedFound += 1
            let w = IOSurfaceGetWidth(surface)
            let h = IOSurfaceGetHeight(surface)
            if w * h > 500000 { // > 500K pixels
                largeExtended.append((id, w, h))
            }
        }
        p("  Found \(extendedFound) surfaces in 501..2000")
        for (id, w, h) in largeExtended {
            guard let surface = IOSurfaceLookup(id) else { continue }
            let fmt = IOSurfaceGetPixelFormat(surface)
            let nb = countNonBlack(surface)
            p("    ID \(id): \(w)×\(h) fmt=0x\(String(fmt, radix: 16)) \(nb)/100 non-black")
        }
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 10 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    // ── 10.1: IOSurface reuse — does the render server recycle surfaces? ──

    private static func probeIOSurfaceReuse(window: UIWindow) {
        p("\n══ 10.1 IOSurface reuse investigation ══")

        let sel = Selector(("createIOSurfaceWithFrame:"))
        guard window.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(window.method(for: sel), to: Fn.self)

        let frame = CGRect(x: 0, y: 100, width: 200, height: 200)

        // ── Capture 20 surfaces, track their global IDs and addresses ──
        p("  ── 20 consecutive captures ──")

        struct SurfaceInfo {
            let globalId: UInt32
            let allocSize: Int
            let width: Int
            let height: Int
            let pixelFormat: UInt32
            let seed: UInt32
            let ptr: UnsafeMutableRawPointer
        }

        var infos: [SurfaceInfo] = []
        var unmanagedRefs: [Unmanaged<AnyObject>] = []

        for i in 0..<20 {
            guard let unmanaged = fn(window, sel, frame) else { continue }
            let obj = unmanaged.takeUnretainedValue()
            guard CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() else {
                unmanaged.release()
                continue
            }
            let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)

            let info = SurfaceInfo(
                globalId: IOSurfaceGetID(surface),
                allocSize: IOSurfaceGetAllocSize(surface),
                width: IOSurfaceGetWidth(surface),
                height: IOSurfaceGetHeight(surface),
                pixelFormat: IOSurfaceGetPixelFormat(surface),
                seed: IOSurfaceGetSeed(surface),
                ptr: IOSurfaceGetBaseAddress(surface)
            )
            infos.append(info)
            unmanagedRefs.append(unmanaged)

            if i < 5 || i >= 18 {
                p("  [\(i)] id=\(info.globalId) seed=\(info.seed) alloc=\(info.allocSize) ptr=\(info.ptr)")
            } else if i == 5 {
                p("  ... (skipping 5-17)")
            }
        }

        // Check if any IDs repeat
        let uniqueIds = Set(infos.map(\.globalId))
        p("\n  Unique surface IDs: \(uniqueIds.count)/\(infos.count)")
        if uniqueIds.count < infos.count {
            p("  ⭐️ SURFACES ARE RECYCLED!")
            // Find which ones repeat
            var idCounts: [UInt32: Int] = [:]
            for info in infos { idCounts[info.globalId, default: 0] += 1 }
            for (id, count) in idCounts where count > 1 {
                p("    ID \(id) appeared \(count) times")
            }
        } else {
            p("  Each capture creates a new surface")
        }

        // ── Release all but the first, capture again — does it reuse? ──
        p("\n  ── Release test: keep first, release rest ──")
        let firstId = infos.first?.globalId ?? 0
        let firstSurface = unmanagedRefs.first

        // Release all except first
        for i in 1..<unmanagedRefs.count {
            unmanagedRefs[i].release()
        }

        // Capture 5 more — do any reuse released IDs?
        var newIds: [UInt32] = []
        for _ in 0..<5 {
            guard let unmanaged = fn(window, sel, frame) else { continue }
            let obj = unmanaged.takeUnretainedValue()
            if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
                let newId = IOSurfaceGetID(surface)
                newIds.append(newId)
            }
            unmanaged.release()
        }

        let releasedIds = Set(infos.dropFirst().map(\.globalId))
        let reusedIds = Set(newIds).intersection(releasedIds)
        p("  New IDs: \(newIds)")
        p("  Reused from released: \(reusedIds.count)")
        if !reusedIds.isEmpty {
            p("  ⭐️ Render server RECYCLES released surface IDs!")
        }

        // Release first
        firstSurface?.release()

        // ── Can we hold onto an IOSurface and see it update? ──
        p("\n  ── Held surface update test ──")
        guard let holdUnmanaged = fn(window, sel, frame) else { return }
        let holdObj = holdUnmanaged.takeUnretainedValue()
        guard CFGetTypeID(holdObj as CFTypeRef) == IOSurfaceGetTypeID() else {
            holdUnmanaged.release()
            return
        }
        let holdSurface = unsafeBitCast(holdObj, to: IOSurfaceRef.self)
        let holdId = IOSurfaceGetID(holdSurface)

        // Read initial pixels
        let initialSeed = IOSurfaceGetSeed(holdSurface)
        IOSurfaceLock(holdSurface, .readOnly, nil)
        let initialPixel = IOSurfaceGetBaseAddress(holdSurface)
            .assumingMemoryBound(to: UInt32.self)[1000]
        IOSurfaceUnlock(holdSurface, .readOnly, nil)
        p("  Held surface ID=\(holdId), seed=\(initialSeed), pixel[1000]=0x\(String(initialPixel, radix: 16))")

        // Wait and check if seed/pixels change
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let laterSeed = IOSurfaceGetSeed(holdSurface)
            IOSurfaceLock(holdSurface, .readOnly, nil)
            let laterPixel = IOSurfaceGetBaseAddress(holdSurface)
                .assumingMemoryBound(to: UInt32.self)[1000]
            IOSurfaceUnlock(holdSurface, .readOnly, nil)

            p("  After 500ms: seed=\(laterSeed), pixel[1000]=0x\(String(laterPixel, radix: 16))")
            p("  Seed changed: \(laterSeed != initialSeed)")
            p("  Pixel changed: \(laterPixel != initialPixel)")

            if laterSeed != initialSeed || laterPixel != initialPixel {
                p("  ⭐️ HELD SURFACE IS BEING UPDATED BY RENDER SERVER!")
                p("  This means: capture once, read forever — zero allocation!")

                // Verify with MTLTexture
                let device = MetalContext.shared.device
                let fmt = IOSurfaceGetPixelFormat(holdSurface)
                let metalFmt: MTLPixelFormat = fmt == 0x42475241 ? .bgra8Unorm : .bgr10a2Unorm
                let desc = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: metalFmt,
                    width: IOSurfaceGetWidth(holdSurface),
                    height: IOSurfaceGetHeight(holdSurface),
                    mipmapped: false
                )
                desc.usage = .shaderRead
                desc.storageMode = .shared
                if let tex = device.makeTexture(descriptor: desc, iosurface: holdSurface, plane: 0) {
                    p("  ⭐️ MTLTexture from held surface: \(tex.width)×\(tex.height)")
                    p("  Zero-copy, zero-alloc: surface updates → texture updates automatically")
                }
            } else {
                p("  Surface is static snapshot — not updated")
            }

            holdUnmanaged.release()
        }
    }

    // ── 10.2: IOSurface global ID lookup ──

    private static func probeIOSurfaceGlobalLookup(window: UIWindow) {
        p("\n══ 10.2 IOSurface global ID lookup ══")

        let sel = Selector(("createIOSurfaceWithFrame:"))
        guard window.responds(to: sel) else { return }
        typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let fn = unsafeBitCast(window.method(for: sel), to: Fn.self)

        let frame = CGRect(x: 0, y: 100, width: 200, height: 200)

        // Capture a surface, get its global ID
        guard let unmanaged = fn(window, sel, frame) else { return }
        let obj = unmanaged.takeUnretainedValue()
        guard CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() else {
            unmanaged.release()
            return
        }
        let originalSurface = unsafeBitCast(obj, to: IOSurfaceRef.self)
        let globalId = IOSurfaceGetID(originalSurface)
        let w = IOSurfaceGetWidth(originalSurface)
        let h = IOSurfaceGetHeight(originalSurface)
        p("  Original: ID=\(globalId), \(w)×\(h)")

        // ── Try IOSurfaceLookup with the known ID ──
        if let looked = IOSurfaceLookup(globalId) {
            let lw = IOSurfaceGetWidth(looked)
            let lh = IOSurfaceGetHeight(looked)
            let lid = IOSurfaceGetID(looked)
            p("  ⭐️ IOSurfaceLookup(\(globalId)) → \(lw)×\(lh), ID=\(lid)")

            // Are they the same surface?
            let origAddr = IOSurfaceGetBaseAddress(originalSurface)
            IOSurfaceLock(looked, .readOnly, nil)
            let lookAddr = IOSurfaceGetBaseAddress(looked)
            IOSurfaceUnlock(looked, .readOnly, nil)
            p("  Same base address: \(origAddr == lookAddr)")

            // Read pixel from looked-up surface
            IOSurfaceLock(looked, .readOnly, nil)
            let pixel = lookAddr.assumingMemoryBound(to: UInt32.self)[500]
            IOSurfaceUnlock(looked, .readOnly, nil)

            IOSurfaceLock(originalSurface, .readOnly, nil)
            let origPixel = IOSurfaceGetBaseAddress(originalSurface)
                .assumingMemoryBound(to: UInt32.self)[500]
            IOSurfaceUnlock(originalSurface, .readOnly, nil)

            p("  Pixels match: \(pixel == origPixel)")

            if origAddr == lookAddr {
                p("  ⭐️ Same backing memory — IOSurfaceLookup returns the SAME surface!")
            }
        } else {
            p("  ❌ IOSurfaceLookup(\(globalId)) → nil (sandbox blocked?)")
        }

        // ── Try looking up surfaces we DON'T own ──
        p("\n  ── Probing nearby global IDs ──")
        let baseId = globalId
        var foundOther = 0
        for delta in -20...20 where delta != 0 {
            let probeId = UInt32(Int64(baseId) + Int64(delta))
            if let probed = IOSurfaceLookup(probeId) {
                let pw = IOSurfaceGetWidth(probed)
                let ph = IOSurfaceGetHeight(probed)
                p("    ⭐️ ID \(probeId) (delta \(delta)): \(pw)×\(ph)")
                foundOther += 1

                // Check non-black
                let nb = countNonBlack(probed)
                p("      \(nb)/100 non-black")
            }
        }
        p("  Found \(foundOther) other surfaces near our ID")

        // ── Can we create a surface, get its ID, then find it later? ──
        p("\n  ── Surface ID persistence test ──")
        // Release original
        unmanaged.release()

        // Try to look up the now-released surface
        if let zombie = IOSurfaceLookup(globalId) {
            let zw = IOSurfaceGetWidth(zombie)
            let zh = IOSurfaceGetHeight(zombie)
            p("  Released surface still findable: \(zw)×\(zh)")
            p("  (kernel keeps it alive while we hold a reference via lookup)")
        } else {
            p("  Released surface no longer findable (expected)")
        }
    }

    // ── 10.3: ReplayKit capture — CMSampleBuffer → IOSurface ──

    private static func probeReplayKitCapture(window: UIWindow) {
        p("\n══ 10.3 ReplayKit capture probe ══")

        // Check if RPScreenRecorder is available
        guard NSClassFromString("RPScreenRecorder") != nil else {
            p("  ❌ RPScreenRecorder not available")
            return
        }

        p("  RPScreenRecorder available")

        // Check if capture is available (may be restricted)
        let recorder = RPScreenRecorder.shared()
        p("  isAvailable: \(recorder.isAvailable)")
        p("  isRecording: \(recorder.isRecording)")

        // Dump RPScreenRecorder SPI
        p("\n  ── RPScreenRecorder runtime ──")
        let interestingMethods = [
            "startCaptureWithHandler:completionHandler:",
            "_startCapture", "_captureFrame",
            "captureFrameWithCompletionHandler:",
            "_singleFrameCapture", "captureScreenshot",
            "_startCaptureInBackground",
            "_captureIOSurface",
        ]
        for sel in interestingMethods {
            if recorder.responds(to: NSSelectorFromString(sel)) {
                p("    ⭐️ -\(sel)")
            }
        }

        // Check for private capture without UI
        let privateMethods = [
            "_startCaptureWithoutNotification:",
            "_startSilentCapture:",
            "_beginCaptureSession",
            "_captureWithoutIndicator:",
        ]
        for sel in privateMethods {
            if recorder.responds(to: NSSelectorFromString(sel)) {
                p("    ⭐️ SILENT: -\(sel)")
            }
        }

        // Dump class methods
        var count: UInt32 = 0
        if let methods = class_copyMethodList(type(of: recorder), &count) {
            p("\n  All instance methods (\(count)):")
            for i in 0..<Int(count) {
                let name = NSStringFromSelector(method_getName(methods[i]))
                // Only show capture/record related
                let lower = name.lowercased()
                if lower.contains("captur") || lower.contains("record")
                    || lower.contains("sample") || lower.contains("surface")
                    || lower.contains("frame") || lower.contains("start")
                    || lower.contains("handler") {
                    p("    -\(name)")
                }
            }
            free(methods)
        }

        // ── Try startCapture to measure latency and examine the CMSampleBuffer ──
        p("\n  ── startCapture test ──")
        p("  NOTE: This will trigger the system capture consent UI")
        p("  Attempting programmatic capture...")

        var capturedFrameCount = 0
        var firstFrameTime: CFTimeInterval = 0
        let captureStart = CACurrentMediaTime()

        recorder.startCapture { sampleBuffer, sampleBufferType, error in
            guard error == nil else {
                p("  ❌ Capture error: \(error!)")
                return
            }

            guard sampleBufferType == .video else { return }

            capturedFrameCount += 1
            if capturedFrameCount == 1 {
                firstFrameTime = CACurrentMediaTime()
                let latency = (firstFrameTime - captureStart) * 1000
                p("  First frame latency: \(String(format: "%.0f", latency))ms")

                // Examine the CMSampleBuffer
                if let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) {
                    let pixelBuffer = imageBuffer as CVPixelBuffer
                    let pw = CVPixelBufferGetWidth(pixelBuffer)
                    let ph = CVPixelBufferGetHeight(pixelBuffer)
                    let pixFmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
                    p("  CVPixelBuffer: \(pw)×\(ph), fmt=\(pixFmt)")

                    // Check if it's IOSurface-backed
                    if let ioSurface = CVPixelBufferGetIOSurface(pixelBuffer) {
                        let surf = ioSurface.takeUnretainedValue()
                        let surfId = IOSurfaceGetID(surf)
                        let surfW = IOSurfaceGetWidth(surf)
                        let surfH = IOSurfaceGetHeight(surf)
                        p("  ⭐️ IOSurface-backed! ID=\(surfId), \(surfW)×\(surfH)")

                        // Create MTLTexture from it?
                        let device = MetalContext.shared.device
                        let fmt = IOSurfaceGetPixelFormat(surf)
                        let metalFmt: MTLPixelFormat = fmt == 0x42475241 ? .bgra8Unorm : .bgr10a2Unorm
                        let desc = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: metalFmt, width: surfW, height: surfH, mipmapped: false
                        )
                        desc.usage = .shaderRead
                        desc.storageMode = .shared
                        if let tex = device.makeTexture(descriptor: desc, iosurface: surf, plane: 0) {
                            p("  ⭐️ MTLTexture: \(tex.width)×\(tex.height)")
                        }

                        // Check if surface IDs repeat across frames
                        p("  Surface ID from ReplayKit: \(surfId)")
                    }
                }
            }

            if capturedFrameCount == 10 {
                let elapsed = (CACurrentMediaTime() - firstFrameTime) * 1000
                let fps = Double(capturedFrameCount - 1) / (elapsed / 1000.0)
                p("  10 frames in \(String(format: "%.0f", elapsed))ms = \(String(format: "%.1f", fps)) fps")

                // Stop capture
                recorder.stopCapture { error in
                    p("  Capture stopped")
                }
            }
        } completionHandler: { error in
            if let error {
                p("  ❌ startCapture error: \(error)")
                p("  (Expected — requires user consent or entitlement)")
            } else {
                p("  ✅ Capture started")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 9 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    private static func probeCASlotProxy(window: UIWindow) {
        p("\n══ 9.1 CASlotProxy deep investigation ══")

        // ── Step 1: Get a CASlotProxy from replicant ──
        let screen = window.screen
        let snapshotSel = NSSelectorFromString("_snapshotExcludingWindows:withRect:")
        typealias SnapshotFn = @convention(c) (AnyObject, Selector, NSArray?, CGRect) -> AnyObject?
        let snapshotFn = unsafeBitCast(screen.method(for: snapshotSel), to: SnapshotFn.self)

        guard let replicant = snapshotFn(screen, snapshotSel, nil, window.bounds) as? UIView else {
            p("  ❌ No replicant")
            return
        }

        guard let slotProxy = replicant.layer.contents else {
            p("  ❌ No contents")
            return
        }

        let proxyObj = slotProxy as AnyObject
        let proxyCls: AnyClass = type(of: proxyObj)
        p("  Got: \(NSStringFromClass(proxyCls))")
        p("  Description: \(proxyObj)")

        // ── Step 2: Dump CASlotProxy class ──
        p("\n  ── CASlotProxy runtime ──")

        // Class methods
        if let meta = object_getClass(proxyCls) {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(meta, &count) {
                p("  Class methods (\(count)):")
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[i]))
                    let enc = method_getTypeEncoding(methods[i]).map { String(cString: $0) } ?? "?"
                    p("    +\(name)  [\(enc)]")
                }
                free(methods)
            }
        }

        // Instance methods
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(proxyCls, &methodCount) {
            p("  Instance methods (\(methodCount)):")
            for i in 0..<Int(methodCount) {
                let name = NSStringFromSelector(method_getName(methods[i]))
                let enc = method_getTypeEncoding(methods[i]).map { String(cString: $0) } ?? "?"
                p("    -\(name)  [\(enc)]")
            }
            free(methods)
        }

        // Ivars
        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(proxyCls, &ivarCount) {
            p("  Ivars (\(ivarCount)):")
            for i in 0..<Int(ivarCount) {
                let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
                let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                let offset = ivar_getOffset(ivars[i])
                p("    \(name) [\(type)] offset=\(offset)")
            }
            free(ivars)
        }

        // Properties
        var propCount: UInt32 = 0
        if let props = class_copyPropertyList(proxyCls, &propCount) {
            p("  Properties (\(propCount)):")
            for i in 0..<Int(propCount) {
                let name = String(cString: property_getName(props[i]))
                let attrs = property_getAttributes(props[i]).map { String(cString: $0) } ?? "?"
                p("    \(name) [\(attrs)]")
            }
            free(props)
        }

        // Superclass chain
        p("  Superclass chain:")
        var cls: AnyClass? = proxyCls
        while let c = cls {
            p("    \(NSStringFromClass(c))")
            cls = class_getSuperclass(c)
        }

        // ── Step 3: Read internal state ──
        p("\n  ── CASlotProxy internal state ──")

        // Try reading known properties
        let probeKeys = [
            "slotId", "slot", "_slotId", "imageSlot",
            "contextId", "_contextId", "context",
            "surface", "ioSurface", "_ioSurface", "IOSurface",
            "image", "contents", "backingImage",
            "width", "height", "size",
            "rendererId", "layerId",
            "generation", "seed", "version",
            "isValid", "valid",
        ]

        for key in probeKeys {
            if (proxyObj).responds(to: NSSelectorFromString(key)) {
                let val = (proxyObj).value(forKey: key)
                p("    \(key) = \(String(describing: val).prefix(120))")
            }
        }

        // Read raw memory
        p("\n  ── Raw memory (64 bytes) ──")
        let rawPtr = Unmanaged.passUnretained(proxyObj).toOpaque()
        let bytes = rawPtr.assumingMemoryBound(to: UInt8.self)
        for row in 0..<4 {
            let start = row * 16
            var hex = ""
            for i in start..<(start + 16) {
                hex += String(format: "%02x ", bytes[i])
            }
            p("    \(String(format: "%04x", start)): \(hex)")
        }

        // Interpret as words
        p("  As uint64 words:")
        for i in 0..<8 {
            let val = rawPtr.advanced(by: i * 8).assumingMemoryBound(to: UInt64.self).pointee
            p("    [\(i)] 0x\(String(val, radix: 16))")
        }

        // ── Step 4: CAContext.objectForSlot: ──
        p("\n  ── CAContext slot access ──")

        // Get window's CAContext
        if let ctx = window.layer.value(forKey: "context") as? NSObject {
            p("  Context: \(ctx)")
            let ctxId = (ctx.value(forKey: "contextId") as? UInt32) ?? 0
            p("  Context ID: \(ctxId)")

            // Try objectForSlot: — class method on CAContext
            let objForSlotSel = NSSelectorFromString("objectForSlot:")
            if let ctxCls = NSClassFromString("CAContext"), ctxCls.responds(to: objForSlotSel) {
                p("  ✅ +objectForSlot: exists")

                // Try slot IDs from the proxy's raw memory
                // The slot ID is likely a uint32 stored in the proxy
                let u32ptr = rawPtr.assumingMemoryBound(to: UInt32.self)
                for i in 0..<16 {
                    let candidateSlot = u32ptr[i]
                    if candidateSlot > 0 && candidateSlot < 0x10000 {
                        // Plausible slot ID (small positive integer)
                        typealias ObjForSlotFn = @convention(c) (AnyClass, Selector, UInt32) -> AnyObject?
                        let fn = unsafeBitCast(
                            (ctxCls as AnyObject).method(for: objForSlotSel),
                            to: ObjForSlotFn.self
                        )
                        if let slotObj = fn(ctxCls, objForSlotSel, candidateSlot) {
                            let slotType = NSStringFromClass(type(of: slotObj))
                            p("    ⭐️ slot[\(candidateSlot)] (offset \(i*4)) → \(slotType)")

                            // Check if it's IOSurface
                            if CFGetTypeID(slotObj as CFTypeRef) == IOSurfaceGetTypeID() {
                                let surf = unsafeBitCast(slotObj, to: IOSurfaceRef.self)
                                p("    ⭐️⭐️⭐️ IOSurface from slot! \(IOSurfaceGetWidth(surf))×\(IOSurfaceGetHeight(surf))")
                            }
                        }
                    }
                }
            }

            // Try createImageSlot / other slot methods
            let slotMethods = [
                "createImageSlot:hasAlpha:",
                "createSlot", "deleteSlot:",
                "setObject:forSlot:", "objectForSlot:",
                "renderSurface", "_renderSurface",
                "surface", "ioSurface",
            ]
            for sel in slotMethods {
                if ctx.responds(to: NSSelectorFromString(sel)) {
                    p("    ✅ context responds to: \(sel)")
                }
            }
        }

        // ── Step 5: _UIReplicantLayer runtime ──
        p("\n  ── _UIReplicantLayer ──")
        if let repLayerCls = NSClassFromString("_UIReplicantLayer") {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(repLayerCls, &count) {
                p("  Methods (\(count)):")
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[i]))
                    let enc = method_getTypeEncoding(methods[i]).map { String(cString: $0) } ?? "?"
                    p("    -\(name)  [\(enc)]")
                }
                free(methods)
            }

            var iCount: UInt32 = 0
            if let ivars = class_copyIvarList(repLayerCls, &iCount) {
                p("  Ivars (\(iCount)):")
                for i in 0..<Int(iCount) {
                    let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
                    let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                    p("    \(name) [\(type)]")
                }
                free(ivars)
            }
        }

        // ── Step 6: Try to get IOSurface from proxy via CA private C functions ──
        p("\n  ── CA private C functions ──")
        if let qc = dlopen("/System/Library/Frameworks/QuartzCore.framework/QuartzCore", RTLD_NOW) {
            defer { dlclose(qc) }

            let surfaceFuncs = [
                "CASlotProxyGetSurface",
                "CASlotProxyCopySurface",
                "CASlotProxyGetIOSurface",
                "CAImageGetIOSurface",
                "CARenderServerGetIOSurface",
                "CAContextGetSurface",
                "CALayerGetContentsIOSurface",
                "CAImageSlotGetSurface",
            ]
            for sym in surfaceFuncs {
                if let ptr = dlsym(qc, sym) {
                    p("    ⭐️ \(sym) found!")

                    // Try calling with proxy as argument
                    typealias F1 = @convention(c) (AnyObject) -> IOSurfaceRef?
                    let fn1 = unsafeBitCast(ptr, to: F1.self)
                    if let surf = fn1(proxyObj) {
                        let w = IOSurfaceGetWidth(surf)
                        let h = IOSurfaceGetHeight(surf)
                        p("    ⭐️⭐️⭐️ Got IOSurface: \(w)×\(h)!")
                    }
                }
            }

            // Also try with raw pointer
            let ptrFuncs = [
                "CAImageGetSurface",
                "CASlotGetSurface",
            ]
            for sym in ptrFuncs {
                if dlsym(qc, sym) != nil {
                    p("    ⭐️ \(sym) found")
                }
            }
        }

        // ── Step 7: Benchmark if we found a fast path ──
        // (placeholder — filled in if any path works)
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 8 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    private static func probeReplicantExtraction(window: UIWindow) {
        p("\n══ 8.1 _UIReplicantView — what is it, can we get pixels? ══")

        let screen = window.screen
        let snapshotSel = NSSelectorFromString("_snapshotExcludingWindows:withRect:")

        guard screen.responds(to: snapshotSel) else {
            p("  ❌ _snapshotExcludingWindows not found")
            return
        }

        typealias SnapshotFn = @convention(c) (
            AnyObject, Selector, NSArray?, CGRect
        ) -> AnyObject?

        let snapshotFn = unsafeBitCast(screen.method(for: snapshotSel), to: SnapshotFn.self)

        // ── Step 1: Get replicant, dump its internals ──
        let captureRect = window.bounds
        let start = CACurrentMediaTime()
        guard let replicant = snapshotFn(screen, snapshotSel, nil, captureRect) as? UIView else {
            p("  ❌ Returned nil")
            return
        }
        let snapTime = (CACurrentMediaTime() - start) * 1000
        p("  Got: \(NSStringFromClass(type(of: replicant)))")
        p("  Frame: \(replicant.frame), bounds: \(replicant.bounds)")
        p("  Time: \(String(format: "%.2f", snapTime))ms")
        p("  Layer class: \(NSStringFromClass(type(of: replicant.layer)))")

        // Dump layer contents
        let hasContents = replicant.layer.contents != nil
        p("  layer.contents: \(hasContents ? "✅ HAS CONTENTS" : "nil")")
        if hasContents {
            let contentsType = type(of: replicant.layer.contents!)
            p("  contents type: \(contentsType)")

            // If contents is IOSurface...
            if let contentsObj = replicant.layer.contents {
                let typeId = CFGetTypeID(contentsObj as CFTypeRef)
                let ioSurfaceTypeId = IOSurfaceGetTypeID()
                p("  CFTypeID: \(typeId), IOSurface TypeID: \(ioSurfaceTypeId)")
                if typeId == ioSurfaceTypeId {
                    p("  ⭐️⭐️⭐️ CONTENTS IS IOSURFACE!")
                    let surface = unsafeBitCast(contentsObj, to: IOSurfaceRef.self)
                    let w = IOSurfaceGetWidth(surface)
                    let h = IOSurfaceGetHeight(surface)
                    let fmt = IOSurfaceGetPixelFormat(surface)
                    p("  Surface: \(w)×\(h), fmt=0x\(String(fmt, radix: 16))")

                    // Create MTLTexture directly!
                    let device = MetalContext.shared.device
                    let metalFmt: MTLPixelFormat = fmt == 0x42475241 ? .bgra8Unorm : .bgr10a2Unorm
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: metalFmt, width: w, height: h, mipmapped: false
                    )
                    desc.usage = .shaderRead
                    desc.storageMode = .shared
                    if let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
                        p("  ⭐️ MTLTexture: \(tex.width)×\(tex.height) — ZERO COPY from replicant!")
                    }
                }
            }
        }

        // Dump sublayers
        p("\n  ── Layer tree ──")
        dumpLayerTree(replicant.layer, indent: "  ")

        // Dump all properties of _UIReplicantView
        p("\n  ── _UIReplicantView runtime ──")
        var propCount: UInt32 = 0
        if let props = class_copyPropertyList(type(of: replicant), &propCount) {
            for i in 0..<Int(propCount) {
                let name = String(cString: property_getName(props[i]))
                p("    property: \(name)")
            }
            free(props)
        }

        // Key methods
        let interestingMethods = [
            "capturedImage", "image", "snapshotImage", "_snapshotImage",
            "ioSurface", "_ioSurface", "surface",
            "contents", "_contents",
            "sourceView", "originalView", "_sourceView",
        ]
        for sel in interestingMethods {
            if replicant.responds(to: NSSelectorFromString(sel)) {
                p("    ⭐️ responds to: \(sel)")
                // Try calling getters that return objects
                if !sel.contains("set") {
                    let val = replicant.value(forKey: sel)
                    p("      → \(String(describing: val).prefix(100))")
                }
            }
        }

        // ── Step 2: drawHierarchy on replicant ──
        p("\n  ── drawHierarchy on replicant ──")
        let scale = screen.scale
        UIGraphicsBeginImageContextWithOptions(replicant.bounds.size, false, scale)
        let drew = replicant.drawHierarchy(in: replicant.bounds, afterScreenUpdates: false)
        let img1 = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        p("  afterScreenUpdates=false: drew=\(drew), image=\(img1 != nil)")
        if let img = img1 {
            let pct = nonBlackPercent(img)
            p("  Non-black: \(String(format: "%.1f", pct))%")
        }

        UIGraphicsBeginImageContextWithOptions(replicant.bounds.size, false, scale)
        let drew2 = replicant.drawHierarchy(in: replicant.bounds, afterScreenUpdates: true)
        let img2 = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        p("  afterScreenUpdates=true: drew=\(drew2), image=\(img2 != nil)")
        if let img = img2 {
            let pct = nonBlackPercent(img)
            p("  Non-black: \(String(format: "%.1f", pct))%")
        }

        // ── Step 3: layer.render ──
        p("\n  ── layer.render on replicant ──")
        let w = Int(replicant.bounds.width * scale)
        let h = Int(replicant.bounds.height * scale)
        if w > 0 && h > 0 {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.scaleBy(x: scale, y: scale)
                replicant.layer.render(in: ctx)
                if let data = ctx.data {
                    let pixels = data.assumingMemoryBound(to: UInt32.self)
                    let total = w * h
                    let step = max(1, total / 100)
                    var nonBlack = 0
                    for i in stride(from: 0, to: total, by: step) {
                        if pixels[i] != 0 { nonBlack += 1 }
                    }
                    let pct = Double(nonBlack) / Double(total / step) * 100
                    p("  layer.render: \(String(format: "%.1f", pct))% non-black")
                }
            }
        }

        // ── Step 4: Put replicant in a temporary window, IOSurface capture it ──
        p("\n  ── Replicant in temp window → IOSurface ──")
        let tempWindow = UIWindow(windowScene: window.windowScene!)
        tempWindow.frame = window.bounds
        tempWindow.windowLevel = .normal - 1  // below everything
        tempWindow.backgroundColor = .clear
        tempWindow.isHidden = false
        let tempRoot = UIViewController()
        tempRoot.view.backgroundColor = .clear
        tempWindow.rootViewController = tempRoot
        tempRoot.view.addSubview(replicant)
        replicant.frame = tempRoot.view.bounds

        CATransaction.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let ioSel = Selector(("createIOSurfaceWithFrame:"))
            if tempWindow.responds(to: ioSel) {
                typealias Fn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                let fn = unsafeBitCast(tempWindow.method(for: ioSel), to: Fn.self)

                let ioStart = CACurrentMediaTime()
                if let unmanaged = fn(tempWindow, ioSel, tempWindow.bounds) {
                    let ioTime = (CACurrentMediaTime() - ioStart) * 1000
                    let obj = unmanaged.takeUnretainedValue()
                    if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                        let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
                        let sw = IOSurfaceGetWidth(surface)
                        let sh = IOSurfaceGetHeight(surface)
                        let nonBlack = countNonBlack(surface)
                        p("  IOSurface from temp window: \(sw)×\(sh), \(nonBlack)/100 non-black, \(String(format: "%.2f", ioTime))ms")

                        if nonBlack > 0 {
                            p("  ⭐️ Replicant content visible in IOSurface!")
                        }
                    }
                    unmanaged.release()
                } else {
                    p("  createIOSurfaceWithFrame: → nil")
                }
            }

            // ── Step 5: Snapshot excluding overlay ──
            // The key test: can we get main window WITHOUT glass?
            p("\n  ── Snapshot excluding specific windows ──")

            // Find all windows in scene
            let allWindows = tempWindow.windowScene?.windows ?? []
            p("  Windows in scene: \(allWindows.count)")
            for (i, w) in allWindows.enumerated() {
                let cls = NSStringFromClass(type(of: w))
                p("    [\(i)] \(cls) level=\(w.windowLevel.rawValue) hidden=\(w.isHidden)")
            }

            // Exclude temp window → should get main+overlay content
            let r1 = snapshotFn(screen, snapshotSel, [tempWindow] as NSArray, window.bounds)
            if let rep1 = r1 as? UIView {
                let hasC = rep1.layer.contents != nil
                p("  Exclude temp: contents=\(hasC)")
            }

            // Exclude overlay (PassthroughWindow) if it exists
            let overlayWindows = allWindows.filter {
                NSStringFromClass(type(of: $0)).contains("Passthrough")
            }
            if !overlayWindows.isEmpty {
                let r2 = snapshotFn(screen, snapshotSel, overlayWindows as NSArray, window.bounds)
                if let rep2 = r2 as? UIView {
                    let hasC = rep2.layer.contents != nil
                    p("  ⭐️ Exclude overlay: contents=\(hasC)")

                    if hasC {
                        // Put THIS replicant in temp window and IOSurface it
                        for v in tempRoot.view.subviews { v.removeFromSuperview() }
                        if let rep2View = rep2 as? UIView {
                            rep2View.frame = tempRoot.view.bounds
                            tempRoot.view.addSubview(rep2View)
                            CATransaction.flush()

                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                typealias IOFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                                let fn2 = unsafeBitCast(tempWindow.method(for: ioSel), to: IOFn.self)
                                if let unm = fn2(tempWindow, ioSel, tempWindow.bounds) {
                                    let obj = unm.takeUnretainedValue()
                                    if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                                        let s = unsafeBitCast(obj, to: IOSurfaceRef.self)
                                        let nb = countNonBlack(s)
                                        p("  ⭐️ Main-only IOSurface: \(IOSurfaceGetWidth(s))×\(IOSurfaceGetHeight(s)), \(nb)/100 non-black")
                                    }
                                    unm.release()
                                }

                                // ── Step 6: Full pipeline benchmark ──
                                p("\n  ── Full pipeline benchmark ──")
                                p("  snapshot(exclude overlay) → replicant → temp window → IOSurface")
                                var pipelineTimes: [Double] = []
                                for _ in 0..<10 {
                                    let t = CACurrentMediaTime()

                                    // 1. Snapshot excluding overlay
                                    let rep = snapshotFn(screen, snapshotSel,
                                                         overlayWindows as NSArray, window.bounds)

                                    // 2. (would put in window + IOSurface, but that's async)
                                    // For timing, just measure the snapshot part
                                    pipelineTimes.append((CACurrentMediaTime() - t) * 1000)
                                    _ = rep // keep alive
                                }
                                let pAvg = pipelineTimes.reduce(0, +) / Double(pipelineTimes.count)
                                p("  Snapshot only (10x): avg=\(String(format: "%.2f", pAvg))ms")

                                // Compare with createIOSurfaceWithFrame:
                                let winSel2 = Selector(("createIOSurfaceWithFrame:"))
                                typealias WinFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                                let winFn = unsafeBitCast(window.method(for: winSel2), to: WinFn.self)
                                var ioTimes: [Double] = []
                                for _ in 0..<10 {
                                    let t = CACurrentMediaTime()
                                    let r = winFn(window, winSel2, window.bounds)
                                    ioTimes.append((CACurrentMediaTime() - t) * 1000)
                                    r?.release()
                                }
                                let ioAvg = ioTimes.reduce(0, +) / Double(ioTimes.count)
                                p("  createIOSurfaceWithFrame (10x): avg=\(String(format: "%.2f", ioAvg))ms")

                                // Cleanup
                                tempWindow.isHidden = true
                                p("\n  Temp window removed")
                            }
                            return
                        }
                    }
                }
            } else {
                p("  No PassthroughWindow found (glass not active on source window?)")
            }

            // Cleanup
            tempWindow.isHidden = true
            p("\n  Temp window removed")
        }
    }

    private static func dumpLayerTree(_ layer: CALayer, indent: String) {
        let cls = NSStringFromClass(type(of: layer))
        let hasContents = layer.contents != nil
        let contentDesc = hasContents ? " contents=✅" : ""
        p("\(indent)\(cls) \(Int(layer.bounds.width))×\(Int(layer.bounds.height))\(contentDesc)")
        for sub in layer.sublayers ?? [] {
            dumpLayerTree(sub, indent: indent + "  ")
        }
    }

    private static func nonBlackPercent(_ image: UIImage) -> Double {
        guard let cgImg = image.cgImage,
              let data = cgImg.dataProvider?.data,
              let ptr = CFDataGetBytePtr(data)
        else { return 0 }

        let bpp = cgImg.bitsPerPixel / 8
        let total = cgImg.width * cgImg.height
        let step = max(1, total / 100)
        var nonBlack = 0
        for i in stride(from: 0, to: total, by: step) {
            let off = i * bpp
            if ptr[off] != 0 || ptr[off+1] != 0 || ptr[off+2] != 0 {
                nonBlack += 1
            }
        }
        return Double(nonBlack) / Double(total / step) * 100
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 7 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    private static func probeRenderLayerCapture(window: UIWindow) {
        p("\n══ 7.1 CARenderServerRenderLayer / CaptureLayer ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else { return }
        defer { dlclose(qc) }

        let renderPort: UInt32 = {
            if let f = dlsym(qc, "CARenderServerGetPort") {
                return unsafeBitCast(f, to: (@convention(c) () -> UInt32).self)()
            }
            return 0
        }()
        p("  Render port: \(renderPort)")

        // Get layer ID — the render server identifies layers by uint32 ID
        // Try getting it from the window's root layer
        let targetLayer = window.layer

        // CALayer has a private _layerId or we can get the render layer ID
        // from the context. Let's try several approaches.
        var layerId: UInt32 = 0

        // Approach 1: CALayerGetRenderId C function
        if let getIdPtr = dlsym(qc, "CALayerGetRenderId") {
            typealias F = @convention(c) (AnyObject) -> UInt
            let getId = unsafeBitCast(getIdPtr, to: F.self)
            let rid = getId(targetLayer)
            layerId = UInt32(rid & 0xFFFFFFFF)
            p("  CALayerGetRenderId: \(rid) → layerId=\(layerId)")
        }

        // Approach 2: _layerId ivar
        if layerId == 0, let ivar = class_getInstanceVariable(CALayer.self, "_layerId") {
            let offset = ivar_getOffset(ivar)
            let ptr = Unmanaged.passUnretained(targetLayer).toOpaque()
            layerId = ptr.advanced(by: offset).assumingMemoryBound(to: UInt32.self).pointee
            p("  _layerId ivar: \(layerId)")
        }

        // Approach 3: KVC
        if layerId == 0 {
            for key in ["_layerId", "layerId", "renderId", "_renderId"] {
                if targetLayer.responds(to: NSSelectorFromString(key)) {
                    if let val = targetLayer.value(forKey: key) as? UInt32 {
                        layerId = val
                        p("  \(key) KVC: \(layerId)")
                        break
                    }
                }
            }
        }

        // Get context ID
        var contextId: UInt32 = 0
        if let ctx = targetLayer.value(forKey: "context") as? NSObject,
           ctx.responds(to: NSSelectorFromString("contextId")) {
            contextId = (ctx.value(forKey: "contextId") as? UInt32) ?? 0
        }
        p("  Context ID: \(contextId)")

        // Create reusable IOSurface
        let scale = window.screen.scale
        let w = Int(window.bounds.width * scale)
        let h = Int(window.bounds.height * scale)
        let props: [CFString: Any] = [
            kIOSurfaceWidth: w,
            kIOSurfaceHeight: h,
            kIOSurfacePixelFormat: 0x42475241 as UInt32,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: w * 4,
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else {
            p("  ❌ IOSurfaceCreate failed")
            return
        }
        p("  Reusable surface: \(w)×\(h)")

        // ── Try CARenderServerRenderLayer ──
        // Unknown signature — try common patterns from WebKit/RecordMyScreen sources
        // Pattern 1: (port, layerId, contextId, surface, x, y)
        // Pattern 2: (port, contextId, layerId, surface, rect)
        // Pattern 3: (port, surface, contextId, layerId)

        if let renderLayerPtr = dlsym(qc, "CARenderServerRenderLayer") {
            p("\n  ── CARenderServerRenderLayer ──")

            // Clear surface
            IOSurfaceLock(surface, [], nil)
            memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
            IOSurfaceUnlock(surface, [], nil)

            // Try signature: (mach_port_t, uint32_t contextId, uint64_t layerId,
            //                  IOSurfaceRef, CGFloat x, CGFloat y, CGFloat w, CGFloat h)
            // This is a guess based on CARenderServerRenderDisplay pattern

            let signatures: [(String, () -> Void)] = [
                // Sig A: (port, contextId, layerId, surface, x, y)
                ("(port, ctxId, layerId, surface, 0, 0)", {
                    typealias F = @convention(c) (UInt32, UInt32, UInt32, IOSurfaceRef, Int32, Int32) -> Void
                    unsafeBitCast(renderLayerPtr, to: F.self)(renderPort, contextId, layerId, surface, 0, 0)
                }),
                // Sig B: (port, layerId, surface, x, y)
                ("(port, layerId, surface, 0, 0)", {
                    typealias F = @convention(c) (UInt32, UInt32, IOSurfaceRef, Int32, Int32) -> Void
                    unsafeBitCast(renderLayerPtr, to: F.self)(renderPort, layerId, surface, 0, 0)
                }),
                // Sig C: (port, ctxId, layerId64, surface, x, y)
                ("(port, ctxId, layerId64, surface, 0, 0)", {
                    typealias F = @convention(c) (UInt32, UInt32, UInt64, IOSurfaceRef, Int32, Int32) -> Void
                    unsafeBitCast(renderLayerPtr, to: F.self)(renderPort, contextId, UInt64(layerId), surface, 0, 0)
                }),
                // Sig D: (port, ctxId, layerId, surface, rect)
                ("(port, ctxId, layerId, surface, rect)", {
                    typealias F = @convention(c) (UInt32, UInt32, UInt32, IOSurfaceRef, CGRect) -> Void
                    unsafeBitCast(renderLayerPtr, to: F.self)(renderPort, contextId, layerId, surface,
                        CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height))
                }),
            ]

            for (desc, call) in signatures {
                // Clear surface
                IOSurfaceLock(surface, [], nil)
                memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
                IOSurfaceUnlock(surface, [], nil)

                let start = CACurrentMediaTime()
                call()
                let time = (CACurrentMediaTime() - start) * 1000

                let nonBlack = countNonBlack(surface)
                p("    \(desc): \(nonBlack)/100 non-black, \(String(format: "%.2f", time))ms")

                if nonBlack > 0 {
                    p("    ⭐️⭐️⭐️ RENDER LAYER WORKS! Reusable surface, per-layer capture!")

                    // Benchmark
                    var times: [Double] = []
                    for _ in 0..<10 {
                        let t = CACurrentMediaTime()
                        call()
                        times.append((CACurrentMediaTime() - t) * 1000)
                    }
                    let avg = times.reduce(0, +) / 10.0
                    p("    Benchmark (10x): avg=\(String(format: "%.2f", avg))ms")
                    break // Found working signature
                }
            }
        }

        // ── Try CARenderServerCaptureLayer ──
        // CaptureLayer might return an IOSurface instead of writing to one
        if let captureLayerPtr = dlsym(qc, "CARenderServerCaptureLayer") {
            p("\n  ── CARenderServerCaptureLayer ──")

            // Try: returns IOSurfaceRef
            // Sig: (port, ctxId, layerId) → IOSurfaceRef
            typealias CaptureF1 = @convention(c) (UInt32, UInt32, UInt32) -> IOSurfaceRef?
            let capFn1 = unsafeBitCast(captureLayerPtr, to: CaptureF1.self)

            let start = CACurrentMediaTime()
            let result = capFn1(renderPort, contextId, layerId)
            let time = (CACurrentMediaTime() - start) * 1000

            if let capturedSurface = result {
                let cw = IOSurfaceGetWidth(capturedSurface)
                let ch = IOSurfaceGetHeight(capturedSurface)
                let nonBlack = countNonBlack(capturedSurface)
                p("    ⭐️ Got surface: \(cw)×\(ch), \(nonBlack)/100 non-black, \(String(format: "%.2f", time))ms")
            } else {
                p("    Sig1 (port,ctxId,layerId)→surface: nil (\(String(format: "%.2f", time))ms)")
            }

            // Try: (port, ctxId, layerId, rect) → IOSurfaceRef
            typealias CaptureF2 = @convention(c) (UInt32, UInt32, UInt32, CGRect) -> IOSurfaceRef?
            let capFn2 = unsafeBitCast(captureLayerPtr, to: CaptureF2.self)
            let result2 = capFn2(renderPort, contextId, layerId,
                                  CGRect(x: 0, y: 0, width: window.bounds.width, height: window.bounds.height))
            if let s = result2 {
                let nonBlack = countNonBlack(s)
                p("    ⭐️ Sig2 (port,ctxId,layerId,rect): \(IOSurfaceGetWidth(s))×\(IOSurfaceGetHeight(s)), \(nonBlack)/100")
            }
        }

        // ── Try CARenderServerRenderDisplayClientList ──
        if let clientListPtr = dlsym(qc, "CARenderServerRenderDisplayClientList") {
            p("\n  ── CARenderServerRenderDisplayClientList ──")

            // Clear surface
            IOSurfaceLock(surface, [], nil)
            memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
            IOSurfaceUnlock(surface, [], nil)

            // Guess: (port, display, surface, x, y, contextIds, count)
            typealias F = @convention(c) (
                UInt32, CFString, IOSurfaceRef, Int32, Int32,
                UnsafePointer<UInt32>, UInt32
            ) -> Void

            let clientFn = unsafeBitCast(clientListPtr, to: F.self)
            var ids: [UInt32] = [contextId]

            let start = CACurrentMediaTime()
            ids.withUnsafeBufferPointer { buf in
                clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                         buf.baseAddress!, UInt32(buf.count))
            }
            let time = (CACurrentMediaTime() - start) * 1000

            let nonBlack = countNonBlack(surface)
            p("    ClientList(our ctxId): \(nonBlack)/100 non-black, \(String(format: "%.2f", time))ms")

            if nonBlack > 0 {
                p("    ⭐️⭐️⭐️ CLIENT LIST WORKS! Reusable surface + selective context capture!")

                // Benchmark
                var times: [Double] = []
                for _ in 0..<10 {
                    IOSurfaceLock(surface, [], nil)
                    memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
                    IOSurfaceUnlock(surface, [], nil)

                    let t = CACurrentMediaTime()
                    ids.withUnsafeBufferPointer { buf in
                        clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                                 buf.baseAddress!, UInt32(buf.count))
                    }
                    times.append((CACurrentMediaTime() - t) * 1000)
                }
                let avg = times.reduce(0, +) / 10.0
                p("    Benchmark (10x, with clear): avg=\(String(format: "%.2f", avg))ms")

                // Without clear (just overwrite)
                var times2: [Double] = []
                for _ in 0..<10 {
                    let t = CACurrentMediaTime()
                    ids.withUnsafeBufferPointer { buf in
                        clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                                 buf.baseAddress!, UInt32(buf.count))
                    }
                    times2.append((CACurrentMediaTime() - t) * 1000)
                }
                let avg2 = times2.reduce(0, +) / 10.0
                p("    Benchmark (10x, no clear): avg=\(String(format: "%.2f", avg2))ms")

                // Compare with createIOSurfaceWithFrame:
                let winSel = Selector(("createIOSurfaceWithFrame:"))
                typealias WinFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                let winFn = unsafeBitCast(window.method(for: winSel), to: WinFn.self)
                var times3: [Double] = []
                for _ in 0..<10 {
                    let t = CACurrentMediaTime()
                    let r = winFn(window, winSel, window.bounds)
                    times3.append((CACurrentMediaTime() - t) * 1000)
                    r?.release()
                }
                let avg3 = times3.reduce(0, +) / 10.0
                p("    createIOSurfaceWithFrame (10x): avg=\(String(format: "%.2f", avg3))ms")
                p("    Winner: \(avg2 < avg3 ? "⭐️ ClientList" : "createIOSurfaceWithFrame")")
            }
        }
    }

    // ── 7.2: UIScreen._snapshotExcludingWindows:withRect: ──

    private static func probeSnapshotExcludingWindows(window: UIWindow) {
        p("\n══ 7.2 UIScreen._snapshotExcludingWindows:withRect: ══")

        let screen = window.screen
        let sel = NSSelectorFromString("_snapshotExcludingWindows:withRect:")

        guard screen.responds(to: sel) else {
            p("  ❌ _snapshotExcludingWindows:withRect: not found")
            return
        }
        p("  ✅ Method exists")

        // Get type encoding
        if let method = class_getInstanceMethod(type(of: screen), sel) {
            let encoding = method_getTypeEncoding(method)
                .map { String(cString: $0) } ?? "?"
            p("  Type encoding: \(encoding)")
        }

        // Call: exclude nothing first → baseline
        let rect = CGRect(x: 0, y: 100, width: 200, height: 200)

        // The method likely returns a UIImage or IOSurface
        // Try as returning id (UIImage?)
        typealias SnapshotFn = @convention(c) (
            AnyObject, Selector, NSArray?, CGRect
        ) -> AnyObject?

        let imp = screen.method(for: sel)
        let snapshotFn = unsafeBitCast(imp, to: SnapshotFn.self)

        // Baseline: exclude nothing
        let start1 = CACurrentMediaTime()
        let result1 = snapshotFn(screen, sel, nil, rect)
        let time1 = (CACurrentMediaTime() - start1) * 1000

        if let obj = result1 {
            let cls = NSStringFromClass(type(of: obj as AnyObject))
            p("  Exclude none: \(cls), \(String(format: "%.2f", time1))ms")

            if let img = obj as? UIImage {
                p("    UIImage: \(img.size) scale=\(img.scale)")
            }
        } else {
            p("  Exclude none: nil (\(String(format: "%.2f", time1))ms)")
        }

        // Exclude our window
        let start2 = CACurrentMediaTime()
        let result2 = snapshotFn(screen, sel, [window] as NSArray, rect)
        let time2 = (CACurrentMediaTime() - start2) * 1000

        if let obj = result2 {
            let cls = NSStringFromClass(type(of: obj as AnyObject))
            p("  Exclude our window: \(cls), \(String(format: "%.2f", time2))ms")
        } else {
            p("  Exclude our window: nil (\(String(format: "%.2f", time2))ms)")
        }

        // Benchmark if it works
        if result1 != nil {
            var times: [Double] = []
            for _ in 0..<10 {
                let t = CACurrentMediaTime()
                _ = snapshotFn(screen, sel, nil, rect)
                times.append((CACurrentMediaTime() - t) * 1000)
            }
            let avg = times.reduce(0, +) / 10.0
            p("  Benchmark (10x): avg=\(String(format: "%.2f", avg))ms")
        }
    }

    // ── 7.3: CARenderServerRenderDisplayClientList with reusable surface ──

    private static func probeDisplayClientList(window: UIWindow) {
        p("\n══ 7.3 CARenderServerCaptureDisplayClientList ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else { return }
        defer { dlclose(qc) }

        // CaptureDisplayClientList — might return IOSurface (vs Render which writes to one)
        guard let capturePtr = dlsym(qc, "CARenderServerCaptureDisplayClientList") else {
            p("  ❌ CARenderServerCaptureDisplayClientList not found")
            return
        }

        let renderPort: UInt32 = {
            if let f = dlsym(qc, "CARenderServerGetPort") {
                return unsafeBitCast(f, to: (@convention(c) () -> UInt32).self)()
            }
            return 0
        }()

        var contextId: UInt32 = 0
        if let ctx = window.layer.value(forKey: "context") as? NSObject,
           ctx.responds(to: NSSelectorFromString("contextId")) {
            contextId = (ctx.value(forKey: "contextId") as? UInt32) ?? 0
        }

        // "Capture" variants often return a new IOSurface
        // Try: (port, display, clientIds, count) → IOSurfaceRef
        typealias CaptureF1 = @convention(c) (
            UInt32, CFString, UnsafePointer<UInt32>, UInt32
        ) -> Unmanaged<AnyObject>?

        let capFn1 = unsafeBitCast(capturePtr, to: CaptureF1.self)
        var ids: [UInt32] = [contextId]

        let start = CACurrentMediaTime()
        let result = ids.withUnsafeBufferPointer { buf in
            capFn1(renderPort, "LCD" as CFString, buf.baseAddress!, UInt32(buf.count))
        }
        let time = (CACurrentMediaTime() - start) * 1000

        if let unmanaged = result {
            let obj = unmanaged.takeUnretainedValue()
            if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
                let w = IOSurfaceGetWidth(surface)
                let h = IOSurfaceGetHeight(surface)
                let fmt = IOSurfaceGetPixelFormat(surface)
                let nonBlack = countNonBlack(surface)
                p("  ⭐️ Got surface: \(w)×\(h), fmt=0x\(String(fmt, radix: 16)), \(nonBlack)/100 non-black, \(String(format: "%.2f", time))ms")

                if nonBlack > 0 {
                    // Can we make MTLTexture from it?
                    let device = MetalContext.shared.device
                    let metalFmt: MTLPixelFormat = fmt == 0x42475241 ? .bgra8Unorm : .bgr10a2Unorm
                    let desc = MTLTextureDescriptor.texture2DDescriptor(
                        pixelFormat: metalFmt, width: w, height: h, mipmapped: false
                    )
                    desc.usage = .shaderRead
                    desc.storageMode = .shared
                    if let tex = device.makeTexture(descriptor: desc, iosurface: surface, plane: 0) {
                        p("  ⭐️ MTLTexture: \(tex.width)×\(tex.height) \(tex.pixelFormat.rawValue)")
                    }

                    // Benchmark
                    var times: [Double] = []
                    for _ in 0..<10 {
                        let t = CACurrentMediaTime()
                        let r = ids.withUnsafeBufferPointer { buf in
                            capFn1(renderPort, "LCD" as CFString, buf.baseAddress!, UInt32(buf.count))
                        }
                        times.append((CACurrentMediaTime() - t) * 1000)
                        r?.release()
                    }
                    let avg = times.reduce(0, +) / 10.0
                    p("  Benchmark CaptureDisplayClientList (10x): avg=\(String(format: "%.2f", avg))ms")
                }
                unmanaged.release()
            } else {
                p("  Returned non-IOSurface: \(type(of: obj))")
                unmanaged.release()
            }
        } else {
            p("  Sig1 → nil (\(String(format: "%.2f", time))ms)")

            // Try with extra params: (port, display, clientIds, count, x, y)
            typealias CaptureF2 = @convention(c) (
                UInt32, CFString, UnsafePointer<UInt32>, UInt32, Int32, Int32
            ) -> Unmanaged<AnyObject>?

            let capFn2 = unsafeBitCast(capturePtr, to: CaptureF2.self)
            let r2 = ids.withUnsafeBufferPointer { buf in
                capFn2(renderPort, "LCD" as CFString, buf.baseAddress!, UInt32(buf.count), 0, 0)
            }
            if let u = r2 {
                let obj = u.takeUnretainedValue()
                p("  Sig2 → \(type(of: obj))")
                u.release()
            } else {
                p("  Sig2 → nil")
            }
        }
    }

    // ── 7.4: RenderDisplayClientList with REUSABLE surface + MTLTexture ──

    private static func probeRenderDisplayClientListReusable(window: UIWindow) {
        p("\n══ 7.4 RenderDisplayClientList — reusable surface + MTLTexture ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else { return }
        defer { dlclose(qc) }

        guard let clientListPtr = dlsym(qc, "CARenderServerRenderDisplayClientList") else {
            p("  ❌ Symbol not found")
            return
        }

        let renderPort: UInt32 = {
            if let f = dlsym(qc, "CARenderServerGetPort") {
                return unsafeBitCast(f, to: (@convention(c) () -> UInt32).self)()
            }
            return 0
        }()

        var contextId: UInt32 = 0
        if let ctx = window.layer.value(forKey: "context") as? NSObject,
           ctx.responds(to: NSSelectorFromString("contextId")) {
            contextId = (ctx.value(forKey: "contextId") as? UInt32) ?? 0
        }
        p("  contextId: \(contextId), port: \(renderPort)")

        // Create reusable surface matching the glass capture region
        let scale = window.screen.scale
        let captureW = Int(200 * scale)
        let captureH = Int(200 * scale)

        // Try BGRA format first (standard)
        let props: [CFString: Any] = [
            kIOSurfaceWidth: captureW,
            kIOSurfaceHeight: captureH,
            kIOSurfacePixelFormat: 0x42475241 as UInt32,
            kIOSurfaceBytesPerElement: 4,
            kIOSurfaceBytesPerRow: captureW * 4,
        ]
        guard let surface = IOSurfaceCreate(props as CFDictionary) else {
            p("  ❌ IOSurfaceCreate failed")
            return
        }
        p("  Surface: \(captureW)×\(captureH) BGRA")

        typealias ClientListFn = @convention(c) (
            UInt32, CFString, IOSurfaceRef, Int32, Int32,
            UnsafePointer<UInt32>, UInt32
        ) -> Void

        let clientFn = unsafeBitCast(clientListPtr, to: ClientListFn.self)
        var ids: [UInt32] = [contextId]

        // ── Test 1: Basic call ──
        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
        IOSurfaceUnlock(surface, [], nil)

        let start = CACurrentMediaTime()
        ids.withUnsafeBufferPointer { buf in
            clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                     buf.baseAddress!, UInt32(buf.count))
        }
        let time = (CACurrentMediaTime() - start) * 1000

        let nonBlack = countNonBlack(surface)
        p("  Test 1 (basic): \(nonBlack)/100 non-black, \(String(format: "%.2f", time))ms")

        if nonBlack == 0 {
            p("  ❌ No pixels — trying port=0")

            IOSurfaceLock(surface, [], nil)
            memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
            IOSurfaceUnlock(surface, [], nil)

            ids.withUnsafeBufferPointer { buf in
                clientFn(0, "LCD" as CFString, surface, 0, 0,
                         buf.baseAddress!, UInt32(buf.count))
            }
            let nb2 = countNonBlack(surface)
            p("  Test 1b (port=0): \(nb2)/100 non-black")

            if nb2 == 0 {
                p("  ❌ Sandbox blocked")
                return
            }
        }

        // ── Test 2: Create MTLTexture from reusable surface (zero-copy) ──
        p("\n  ── MTLTexture from reusable surface ──")
        let device = MetalContext.shared.device
        let texDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: captureW, height: captureH, mipmapped: false
        )
        texDesc.usage = .shaderRead
        texDesc.storageMode = .shared

        if let texture = device.makeTexture(descriptor: texDesc, iosurface: surface, plane: 0) {
            p("  ✅ MTLTexture: \(texture.width)×\(texture.height)")
            p("  ⭐️ Zero-copy: IOSurface ↔ MTLTexture share same memory")
            p("  ⭐️ No allocation per frame — surface+texture created ONCE!")
        }

        // ── Test 3: Benchmark — render into same surface repeatedly ──
        p("\n  ── Benchmark: repeated render into reusable surface ──")

        // Without memset (just overwrite)
        var times: [Double] = []
        for _ in 0..<20 {
            let t = CACurrentMediaTime()
            ids.withUnsafeBufferPointer { buf in
                clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                         buf.baseAddress!, UInt32(buf.count))
            }
            times.append((CACurrentMediaTime() - t) * 1000)
        }
        let avg = times.reduce(0, +) / Double(times.count)
        let minT = times.min()!
        let maxT = times.max()!
        p("  Reusable (20x): avg=\(String(format: "%.2f", avg))ms min=\(String(format: "%.2f", minT))ms max=\(String(format: "%.2f", maxT))ms")

        // Compare with createIOSurfaceWithFrame: (allocates each time)
        let winSel = Selector(("createIOSurfaceWithFrame:"))
        typealias WinFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let winFn = unsafeBitCast(window.method(for: winSel), to: WinFn.self)
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)

        var winTimes: [Double] = []
        for _ in 0..<20 {
            let t = CACurrentMediaTime()
            let r = winFn(window, winSel, rect)
            winTimes.append((CACurrentMediaTime() - t) * 1000)
            r?.release()
        }
        let winAvg = winTimes.reduce(0, +) / Double(winTimes.count)
        let winMin = winTimes.min()!
        p("  createIOSurfaceWithFrame (20x): avg=\(String(format: "%.2f", winAvg))ms min=\(String(format: "%.2f", winMin))ms")

        if avg > 0 && winAvg > 0 {
            let speedup = winAvg / avg
            p("  Ratio: ClientList is \(String(format: "%.1f", speedup))x \(speedup > 1 ? "faster" : "slower")")
        }

        // ── Test 4: With offset (capture sub-region) ──
        p("\n  ── Sub-region capture (offset) ──")
        // The x,y params in CARenderServerRenderDisplay offset the source
        // Try offsetting to capture just the bottom part of the screen
        let offsetY = Int32(window.bounds.height * scale / 2)

        IOSurfaceLock(surface, [], nil)
        memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
        IOSurfaceUnlock(surface, [], nil)

        ids.withUnsafeBufferPointer { buf in
            clientFn(renderPort, "LCD" as CFString, surface, 0, offsetY,
                     buf.baseAddress!, UInt32(buf.count))
        }
        let nbOffset = countNonBlack(surface)
        p("  Offset y=\(offsetY): \(nbOffset)/100 non-black")

        // ── Test 5: Verify pixels change between frames ──
        p("\n  ── Frame-to-frame consistency ──")
        var prevPixels = readPixelSamples(surface)

        var framesDiffer = 0
        for i in 0..<5 {
            // Small delay to allow render server to update
            Thread.sleep(forTimeInterval: 0.016) // ~1 frame at 60fps

            ids.withUnsafeBufferPointer { buf in
                clientFn(renderPort, "LCD" as CFString, surface, 0, 0,
                         buf.baseAddress!, UInt32(buf.count))
            }

            let curPixels = readPixelSamples(surface)
            let diff = zip(prevPixels, curPixels).filter { $0 != $1 }.count
            let pct = Double(diff) / Double(curPixels.count) * 100
            p("    Frame \(i): \(String(format: "%.1f", pct))% pixels changed")
            if diff > 0 { framesDiffer += 1 }
            prevPixels = curPixels
        }
        p("  Frames with changes: \(framesDiffer)/5")
    }

    private static func readPixelSamples(_ surface: IOSurfaceRef) -> [UInt32] {
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        IOSurfaceLock(surface, .readOnly, nil)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        let total = w * h
        let step = max(1, total / 200)
        var samples: [UInt32] = []
        for i in stride(from: 0, to: total, by: step) {
            samples.append(pixels[i])
        }
        IOSurfaceUnlock(surface, .readOnly, nil)
        return samples
    }

    // ── Helper ──

    private static func countNonBlack(_ surface: IOSurfaceRef) -> Int {
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)
        IOSurfaceLock(surface, .readOnly, nil)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        let total = w * h
        let step = max(1, total / 100)
        var nonBlack = 0
        for i in stride(from: 0, to: total, by: step) {
            if pixels[i] != 0 { nonBlack += 1 }
        }
        IOSurfaceUnlock(surface, .readOnly, nil)
        return nonBlack
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 6 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    // ── 6.1: Dump ALL capture/IOSurface/render related methods ──

    private static func probeAllCaptureSPI(window: UIWindow) {
        p("\n══ 6.1 Capture SPI scan ══")

        let captureKeywords = [
            "IOSurface", "ioSurface", "ioSurf", "Surface", "surface",
            "capture", "Capture", "snapshot", "Snapshot",
            "render", "Render", "screen", "Screen",
            "backdrop", "Backdrop",
        ]

        let classesToScan: [(String, AnyClass)] = [
            ("UIWindow", UIWindow.self),
            ("UIView", UIView.self),
            ("UIScreen", UIScreen.self),
            ("CALayer", CALayer.self),
        ]

        // Also try private classes
        let privateClasses = [
            "CAContext", "CALayerHost", "CAPortalLayer",
            "CABackdropLayer", "UIApplication",
            "_UIRenderLoopObserver",
        ]

        var allClasses = classesToScan
        for name in privateClasses {
            if let cls = NSClassFromString(name) {
                allClasses.append((name, cls))
            }
        }

        for (className, cls) in allClasses {
            var found: [(Bool, String)] = [] // (isClass, name)

            // Class methods
            if let meta = object_getClass(cls) {
                var count: UInt32 = 0
                if let methods = class_copyMethodList(meta, &count) {
                    for i in 0..<Int(count) {
                        let name = NSStringFromSelector(method_getName(methods[i]))
                        for keyword in captureKeywords {
                            if name.contains(keyword) {
                                found.append((true, name))
                                break
                            }
                        }
                    }
                    free(methods)
                }
            }

            // Instance methods
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[i]))
                    for keyword in captureKeywords {
                        if name.contains(keyword) {
                            found.append((false, name))
                            break
                        }
                    }
                }
                free(methods)
            }

            if !found.isEmpty {
                p("\n  \(className) (\(found.count) matches):")
                for (isClass, name) in found.sorted(by: { $0.1 < $1.1 }) {
                    p("    \(isClass ? "+" : "-")\(name)")
                }
            }
        }

        // Special: scan UIView for ANY method with "surface" or "capture"
        // in the full superclass chain
        p("\n  ── UIView full hierarchy scan ──")
        var viewCls: AnyClass? = UIView.self
        while let cls = viewCls {
            var count: UInt32 = 0
            if let methods = class_copyMethodList(cls, &count) {
                for i in 0..<Int(count) {
                    let name = NSStringFromSelector(method_getName(methods[i]))
                    let lower = name.lowercased()
                    if lower.contains("surface") || lower.contains("capture")
                        || lower.contains("iosurface") {
                        p("    \(NSStringFromClass(cls)).-\(name)")
                    }
                }
                free(methods)
            }
            if let meta = object_getClass(cls) {
                var mcount: UInt32 = 0
                if let methods = class_copyMethodList(meta, &mcount) {
                    for i in 0..<Int(mcount) {
                        let name = NSStringFromSelector(method_getName(methods[i]))
                        let lower = name.lowercased()
                        if lower.contains("surface") || lower.contains("capture")
                            || lower.contains("iosurface") {
                            p("    \(NSStringFromClass(cls)).+\(name)")
                        }
                    }
                    free(methods)
                }
            }
            viewCls = class_getSuperclass(cls)
            // Stop at NSObject
            if viewCls == NSObject.self { break }
        }
    }

    // ── 6.2: Layer exclusion from capture ──

    private static func probeLayerExclusion(window: UIWindow) {
        p("\n══ 6.2 Layer exclusion from capture ══")

        // Search for any property/method that could exclude a layer from IOSurface capture
        let exclusionKeywords = [
            "exclude", "Exclude", "hidden", "Hidden",
            "capture", "Capture", "visible", "Visible",
            "snapshot", "Snapshot", "ignore", "Ignore",
            "disableCapture", "preventCapture", "skipCapture",
            "isCaptur", "canCaptur",
        ]

        let layerClasses: [AnyClass] = [
            CALayer.self,
            NSClassFromString("CAPortalLayer"),
            NSClassFromString("CABackdropLayer"),
        ].compactMap { $0 }

        for cls in layerClasses {
            let name = NSStringFromClass(cls)

            // Properties
            var propCount: UInt32 = 0
            if let props = class_copyPropertyList(cls, &propCount) {
                for i in 0..<Int(propCount) {
                    let propName = String(cString: property_getName(props[i]))
                    for keyword in exclusionKeywords {
                        if propName.contains(keyword) {
                            p("  \(name) property: \(propName)")
                            break
                        }
                    }
                }
                free(props)
            }

            // Methods
            var methodCount: UInt32 = 0
            if let methods = class_copyMethodList(cls, &methodCount) {
                for i in 0..<Int(methodCount) {
                    let selName = NSStringFromSelector(method_getName(methods[i]))
                    for keyword in exclusionKeywords {
                        if selName.contains(keyword) {
                            p("  \(name) method: \(selName)")
                            break
                        }
                    }
                }
                free(methods)
            }
        }

        // Brute-force test known exclusion candidates
        p("\n  ── Testing exclusion properties on CALayer ──")
        let testLayer = CALayer()
        let candidates = [
            "disableDisplay", "allowsCapture", "captureEnabled",
            "excludeFromScreenCapture", "preventScreenCapture",
            "hiddenFromCapture", "canBeCaptured", "contentsHidden",
            "screenCaptureProtected", "isExcludedFromCapture",
            "shouldExcludeFromCapture", "capturable",
        ]
        for prop in candidates {
            if testLayer.responds(to: NSSelectorFromString(prop)) {
                let val = testLayer.value(forKey: prop)
                p("    ⭐️ \(prop) = \(String(describing: val))")
            }
        }

        // Also check UIView
        let testView = UIView()
        for prop in candidates {
            if testView.responds(to: NSSelectorFromString(prop)) {
                let val = testView.value(forKey: prop)
                p("    ⭐️ UIView.\(prop) = \(String(describing: val))")
            }
        }

        // Check UIScreen for capture-related
        p("\n  ── UIScreen capture properties ──")
        let screen = window.screen
        let screenProps = [
            "isCaptured", "capturedDidChange", "mirroredScreen",
            "_captureQuality", "captureRect", "_externalDisplay",
        ]
        for prop in screenProps {
            if screen.responds(to: NSSelectorFromString(prop)) {
                let val = screen.value(forKey: prop)
                p("    \(prop) = \(String(describing: val))")
            }
        }
    }

    // ── 6.3: Context ID based capture ──

    private static func probeContextIdCapture(window: UIWindow) {
        p("\n══ 6.3 Context ID capture ══")

        // Get window's context ID
        let contextId: UInt32
        if let ctx = window.layer.value(forKey: "context") as? NSObject,
           ctx.responds(to: NSSelectorFromString("contextId")) {
            contextId = (ctx.value(forKey: "contextId") as? UInt32) ?? 0
            p("  Window context ID: \(contextId) (0x\(String(contextId, radix: 16)))")
        } else {
            // Try alternative: _contextId on layer
            let sel = NSSelectorFromString("_contextId")
            if window.layer.responds(to: sel) {
                contextId = (window.layer.value(forKey: "_contextId") as? UInt32) ?? 0
                p("  Window layer _contextId: \(contextId)")
            } else {
                p("  ❌ Cannot get context ID")
                return
            }
        }

        guard contextId != 0 else {
            p("  ❌ Context ID is 0")
            return
        }

        // Try createIOSurfaceWithContextIds:count:frame:
        let classSel = NSSelectorFromString("createIOSurfaceWithContextIds:count:frame:")
        if UIWindow.responds(to: classSel) {
            p("  ✅ +createIOSurfaceWithContextIds:count:frame: exists")

            typealias Fn = @convention(c) (
                AnyClass, Selector,
                UnsafePointer<UInt32>, UInt, CGRect
            ) -> Unmanaged<AnyObject>?

            let fn = unsafeBitCast(
                (UIWindow.self as AnyObject).method(for: classSel),
                to: Fn.self
            )

            var ids: [UInt32] = [contextId]
            let frame = CGRect(x: 0, y: 100, width: 200, height: 200)

            let start = CACurrentMediaTime()
            let result = ids.withUnsafeBufferPointer { buf in
                fn(UIWindow.self, classSel, buf.baseAddress!, UInt(buf.count), frame)
            }
            let time = (CACurrentMediaTime() - start) * 1000

            if let unmanaged = result {
                let obj = unmanaged.takeUnretainedValue()
                if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                    let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
                    let w = IOSurfaceGetWidth(surface)
                    let h = IOSurfaceGetHeight(surface)
                    p("  ⭐️ Got surface: \(w)×\(h) in \(String(format: "%.2f", time))ms")

                    // Check pixels
                    IOSurfaceLock(surface, .readOnly, nil)
                    let pixels = IOSurfaceGetBaseAddress(surface)
                        .assumingMemoryBound(to: UInt32.self)
                    var nonBlack = 0
                    let total = w * h
                    let step = max(1, total / 100)
                    for i in stride(from: 0, to: total, by: step) {
                        if pixels[i] != 0 { nonBlack += 1 }
                    }
                    IOSurfaceUnlock(surface, .readOnly, nil)
                    p("  Pixels: \(nonBlack)/\(total/step) non-black")

                    // Benchmark vs createIOSurfaceWithFrame:
                    p("\n  ── Benchmark: contextIds vs createIOSurfaceWithFrame: ──")
                    let iterations = 10
                    var ctxTimes: [Double] = []
                    for _ in 0..<iterations {
                        let t = CACurrentMediaTime()
                        let r = ids.withUnsafeBufferPointer { buf in
                            fn(UIWindow.self, classSel, buf.baseAddress!, UInt(buf.count), frame)
                        }
                        ctxTimes.append((CACurrentMediaTime() - t) * 1000)
                        r?.release()
                    }

                    let winSel = Selector(("createIOSurfaceWithFrame:"))
                    typealias WinFn = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                    let winFn = unsafeBitCast(window.method(for: winSel), to: WinFn.self)
                    var winTimes: [Double] = []
                    for _ in 0..<iterations {
                        let t = CACurrentMediaTime()
                        let r = winFn(window, winSel, frame)
                        winTimes.append((CACurrentMediaTime() - t) * 1000)
                        r?.release()
                    }

                    let ctxAvg = ctxTimes.reduce(0, +) / Double(iterations)
                    let winAvg = winTimes.reduce(0, +) / Double(iterations)
                    p("  contextIds: \(String(format: "%.2f", ctxAvg))ms avg")
                    p("  createIOSurfaceWithFrame: \(String(format: "%.2f", winAvg))ms avg")
                }
                unmanaged.release()
            } else {
                p("  ❌ Returned nil (\(String(format: "%.2f", time))ms)")
            }
        } else {
            p("  ❌ +createIOSurfaceWithContextIds:count:frame: not found")
        }

        // Try other variants
        let variants = [
            "createIOSurfaceWithContextIds:count:frame:outTransform:",
            "createIOSurfaceWithContextIds:count:frame:usePurpleGfx:outTransform:",
            "createIOSurfaceOnScreen:withContextIds:count:frame:baseTransform:",
            "createIOSurfaceOnScreen:withContextIds:count:frame:usePurpleGfx:outTransform:",
            "createIOSurfaceFromScreen:",
            "createIOSurfaceFromDisplayConfiguration:",
            "createScreenIOSurface",
        ]
        for sel in variants {
            let exists = UIWindow.responds(to: NSSelectorFromString(sel))
            if exists {
                p("  ✅ +\(sel)")
            }
        }

        // UIView._createIOSurfaceWithPadding:
        p("\n  ── UIView IOSurface methods ──")
        let viewSPIs = [
            "_createIOSurfaceWithPadding:",
            "_createRenderingBufferFromRect:padding:",
            "_snapshotView",
            "_renderInContext:",
        ]
        let testView = window.rootViewController?.view ?? UIView()
        for sel in viewSPIs {
            if testView.responds(to: NSSelectorFromString(sel)) {
                p("  ✅ UIView.-\(sel)")
            }
        }
    }

    // ── 6.4: CARenderServerRenderLayer ──

    private static func probeRenderServerLayer(window: UIWindow) {
        p("\n══ 6.4 CARenderServerRenderLayer ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else { return }
        defer { dlclose(qc) }

        // Scan for ALL CARenderServer* symbols
        let candidates = [
            "CARenderServerRenderLayer",
            "CARenderServerRenderLayerWithTransform",
            "CARenderServerCaptureLayer",
            "CARenderServerCaptureLayerWithTransform",
            "CARenderServerRenderDisplay",
            "CARenderServerRenderDisplayExcludeList",
            "CARenderServerCaptureDisplay",
            "CARenderServerCaptureDisplayExcludeList",
            "CARenderServerRenderDisplayClientList",
            "CARenderServerCaptureDisplayClientList",
            "CARenderServerNew",
            "CARenderServerStart",
            "CARenderServerGetPort",
            "CARenderServerGetServerPort",
            "CARenderServerSetIOSurface",
            "CARenderServerCreateIOSurface",
            "CARenderServerRenderContext",
            "CARenderServerCaptureContext",
        ]

        var foundSymbols: [(String, UnsafeMutableRawPointer)] = []
        for sym in candidates {
            if let ptr = dlsym(qc, sym) {
                foundSymbols.append((sym, ptr))
                p("  ✅ \(sym)")
            }
        }

        if foundSymbols.isEmpty {
            p("  No CARenderServer symbols found")
            return
        }

        // For ExcludeList — this is huge if it works:
        // Capture display EXCLUDING specific context IDs (our overlay!)
        if let excludePtr = dlsym(qc, "CARenderServerRenderDisplayExcludeList") {
            p("\n  ── CARenderServerRenderDisplayExcludeList ──")
            p("  If this works with our overlay contextId, no overlay window needed!")

            // We need to figure out the signature
            // Likely: void(mach_port_t, CFString display, IOSurface, int x, int y,
            //              const uint32_t* excludeContextIds, uint32_t excludeCount)
            // or similar

            // Get render port
            var renderPort: UInt32 = 0
            if let getPortPtr = dlsym(qc, "CARenderServerGetPort") {
                typealias F = @convention(c) () -> UInt32
                renderPort = unsafeBitCast(getPortPtr, to: F.self)()
            }

            // Create test surface
            let scale = window.screen.scale
            let w = 200 * Int(scale)
            let h = 200 * Int(scale)
            let props: [CFString: Any] = [
                kIOSurfaceWidth: w,
                kIOSurfaceHeight: h,
                kIOSurfacePixelFormat: 0x42475241 as UInt32,
                kIOSurfaceBytesPerElement: 4,
                kIOSurfaceBytesPerRow: w * 4,
            ]
            guard let surface = IOSurfaceCreate(props as CFDictionary) else {
                p("  ❌ IOSurfaceCreate failed")
                return
            }

            // Try calling with port=0 (auto) and "LCD"
            // Guess the signature with exclude list
            // Try: (port, display, surface, x, y, excludeIds, excludeCount)
            typealias ExcludeFn7 = @convention(c) (
                UInt32, CFString, IOSurfaceRef, Int32, Int32,
                UnsafePointer<UInt32>?, UInt32
            ) -> Void

            let excludeFn = unsafeBitCast(excludePtr, to: ExcludeFn7.self)

            IOSurfaceLock(surface, [], nil)
            memset(IOSurfaceGetBaseAddress(surface), 0, IOSurfaceGetAllocSize(surface))
            IOSurfaceUnlock(surface, [], nil)

            let start = CACurrentMediaTime()
            excludeFn(renderPort, "LCD" as CFString, surface, 0, 0, nil, 0)
            let time = (CACurrentMediaTime() - start) * 1000

            IOSurfaceLock(surface, .readOnly, nil)
            let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
            let total = w * h
            let step = max(1, total / 100)
            var nonBlack = 0
            for i in stride(from: 0, to: total, by: step) {
                if pixels[i] != 0 { nonBlack += 1 }
            }
            IOSurfaceUnlock(surface, .readOnly, nil)

            p("  ExcludeList(no excludes): \(nonBlack)/\(total/step) non-black, \(String(format: "%.2f", time))ms")

            if nonBlack > 0 {
                p("  ⭐️⭐️⭐️ REUSABLE SURFACE WORKS!")
                p("  This means: pre-allocate surface once, render into it every frame!")

                // Benchmark
                var times: [Double] = []
                for _ in 0..<10 {
                    let t = CACurrentMediaTime()
                    excludeFn(renderPort, "LCD" as CFString, surface, 0, 0, nil, 0)
                    times.append((CACurrentMediaTime() - t) * 1000)
                }
                let avg = times.reduce(0, +) / 10.0
                p("  Benchmark (reusable, 10x): avg=\(String(format: "%.2f", avg))ms")
            }
        }
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 5 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    /// Diff CA_copyRenderValue binary output when changing a key.
    /// If output changes → the key is real (serialized to render server).
    private static func probeRealFilterKeys() {
        p("\n══ 5.1 Diff-based real key discovery ══")

        guard let filterClass = NSClassFromString("CAFilter") else { return }
        let filterWithTypeSel = NSSelectorFromString("filterWithType:")
        let copyRenderSel = NSSelectorFromString("CA_copyRenderValue")

        let targets = [
            "gaussianBlur",
            "chromaticAberration",
            "glassBackground",
            "displacementMap",
            "refraction",
            "liquidGlass",
            "variableBlur",
        ]

        let testKeys = [
            "inputRadius", "inputAmount", "inputScale", "inputStrength",
            "inputSpread", "inputIntensity", "inputOffset",
            "inputChromaticAmount", "inputChromaticSpread",
            "inputDispersion", "inputRefractionStrength",
            "inputDisplacementScale", "inputBlurRadius",
            "inputRedOffset", "inputGreenOffset", "inputBlueOffset",
            "inputWidth", "inputHeight", "inputAngle",
            "inputBias", "inputGain", "inputSamples",
            "inputNormalMap", "inputDirection", "inputColor",
            "inputSDF", "inputCornerRadius",
            "inputSourceSublayerName", "inputNormalsSublayerName",
            "inputValue", "inputFactor", "inputLevel",
            "inputMin", "inputMax", "inputThreshold",
            "inputOpacity", "inputAlpha",
            "inputQuality", "inputNormalized",
        ]

        for typeName in targets {
            p("\n  ── \(typeName) ──")

            // Get baseline render value
            guard let baseFilter = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject,
                  baseFilter.responds(to: copyRenderSel)
            else { continue }

            let baselineBytes = renderValueBytes(of: baseFilter)
            guard !baselineBytes.isEmpty else {
                p("    ❌ baseline CA_copyRenderValue failed")
                continue
            }
            p("    baseline: \(baselineBytes.count) bytes significant")

            var realKeys: [String] = []

            for key in testKeys {
                // Create fresh filter each time
                guard let testFilter = (filterClass as AnyObject)
                        .perform(filterWithTypeSel, with: typeName)?
                        .takeUnretainedValue() as? NSObject
                else { continue }

                // Set the test value
                testFilter.setValue(NSNumber(value: 42.0), forKey: key)

                let testBytes = renderValueBytes(of: testFilter)

                if testBytes != baselineBytes && !testBytes.isEmpty {
                    realKeys.append(key)

                    // Find which bytes changed
                    let diffCount = zip(baselineBytes, testBytes)
                        .filter { $0 != $1 }.count
                    let sizeDiff = testBytes.count - baselineBytes.count
                    p("    ⭐️ \(key) → \(diffCount) bytes changed, size delta: \(sizeDiff)")
                }
            }

            if realKeys.isEmpty {
                p("    No keys affected render value")
            } else {
                p("    REAL KEYS: \(realKeys)")
            }

            // For real keys, test with different values to understand encoding
            for key in realKeys.prefix(5) {
                p("    ── \(key) value sweep ──")
                for testVal in [0.0, 0.5, 1.0, 5.0, 10.0, 50.0, 100.0] as [Double] {
                    guard let sweepFilter = (filterClass as AnyObject)
                            .perform(filterWithTypeSel, with: typeName)?
                            .takeUnretainedValue() as? NSObject
                    else { continue }

                    sweepFilter.setValue(NSNumber(value: testVal), forKey: key)
                    let sweepBytes = renderValueBytes(of: sweepFilter)

                    // Find changed region
                    let diffs = zip(baselineBytes, sweepBytes).enumerated()
                        .filter { $0.element.0 != $0.element.1 }
                    if let firstDiff = diffs.first {
                        // Read as float at that offset
                        let offset = firstDiff.offset
                        let alignedOffset = (offset / 4) * 4
                        if alignedOffset + 4 <= sweepBytes.count {
                            let floatVal = sweepBytes.withUnsafeBytes { buf in
                                buf.load(fromByteOffset: alignedOffset, as: Float.self)
                            }
                            p("      \(key)=\(testVal) → float@\(alignedOffset)=\(floatVal)")
                        }
                    }
                }
            }
        }
    }

    /// Read CA_copyRenderValue into a byte array for comparison.
    private static func renderValueBytes(of filter: NSObject) -> [UInt8] {
        let sel = NSSelectorFromString("CA_copyRenderValue")
        guard filter.responds(to: sel) else { return [] }

        typealias Fn = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
        let fn = unsafeBitCast(filter.method(for: sel), to: Fn.self)
        guard let ptr = fn(filter, sel) else { return [] }

        // Read up to 512 bytes — enough for any filter
        let bytes = UnsafeBufferPointer(
            start: ptr.assumingMemoryBound(to: UInt8.self),
            count: 512
        )
        return Array(bytes)
    }

    /// Visual test: apply filters to portal, capture IOSurface, compare pixels
    private static func probeVisualFilterOnPortal(window: UIWindow) {
        p("\n══ 5.2 Visual filter test on portal ══")

        guard let filterClass = NSClassFromString("CAFilter"),
              let portalClass = NSClassFromString("_UIPortalView") as? UIView.Type
        else {
            p("  ❌ Required classes not found")
            return
        }

        let filterWithTypeSel = NSSelectorFromString("filterWithType:")
        let ioSel = Selector(("createIOSurfaceWithFrame:"))
        guard window.responds(to: ioSel) else {
            p("  ❌ createIOSurfaceWithFrame: not available")
            return
        }

        typealias IOFunc = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
        let ioFn = unsafeBitCast(window.method(for: ioSel), to: IOFunc.self)

        // ── Step 1: Baseline — IOSurface of window WITHOUT portal ──
        let captureRect = CGRect(x: 0, y: 100, width: 200, height: 200)

        let baselinePixels = capturePixelSample(ioFn, window, captureRect)
        p("  Baseline (no portal): \(baselinePixels.count) samples")

        // ── Step 2: Portal without filters ──
        let portal = portalClass.init(frame: captureRect)
        portal.setValue(window, forKey: "sourceView")
        portal.setValue(false, forKey: "matchesPosition")
        portal.setValue(false, forKey: "matchesTransform")
        window.addSubview(portal)
        CATransaction.flush()

        // Give compositor a frame to render
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            let noFilterPixels = capturePixelSample(ioFn, window, captureRect)
            let noFilterDiff = pixelDiff(baselinePixels, noFilterPixels)
            p("  Portal (no filter): diff from baseline = \(String(format: "%.1f", noFilterDiff))%")

            // ── Step 3: gaussianBlur on portal ──
            if let blur = (filterClass as AnyObject)
                .perform(filterWithTypeSel, with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject {

                blur.setValue(20.0, forKey: "inputRadius")
                portal.layer.setValue([blur], forKey: "filters")
                CATransaction.flush()
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                let blurPixels = capturePixelSample(ioFn, window, captureRect)
                let blurDiff = pixelDiff(noFilterPixels, blurPixels)
                p("  Portal + gaussianBlur(20): diff from no-filter = \(String(format: "%.1f", blurDiff))%")
                if blurDiff > 1.0 {
                    p("  ⭐️ BLUR IS VISIBLE IN IOSURFACE! Compositor applied filter to portal!")
                }

                // ── Step 4: chromaticAberration on portal ──
                if let chroma = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: "chromaticAberration")?
                    .takeUnretainedValue() as? NSObject {

                    // Try various parameter names with large values
                    chroma.setValue(50.0, forKey: "inputAmount")
                    chroma.setValue(50.0, forKey: "inputRadius")
                    chroma.setValue(50.0, forKey: "inputScale")
                    portal.layer.setValue([chroma], forKey: "filters")
                    CATransaction.flush()
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    let chromaPixels = capturePixelSample(ioFn, window, captureRect)
                    let chromaDiff = pixelDiff(noFilterPixels, chromaPixels)
                    p("  Portal + chromaticAberration: diff = \(String(format: "%.1f", chromaDiff))%")
                    if chromaDiff > 1.0 {
                        p("  ⭐️ CHROMA IS VISIBLE!")
                    }

                    // ── Step 5: backgroundFilters (blur behind portal) ──
                    portal.layer.setValue(nil, forKey: "filters")
                    if let bgBlur = (filterClass as AnyObject)
                        .perform(filterWithTypeSel, with: "gaussianBlur")?
                        .takeUnretainedValue() as? NSObject {

                        bgBlur.setValue(20.0, forKey: "inputRadius")
                        portal.layer.setValue([bgBlur], forKey: "backgroundFilters")
                        CATransaction.flush()
                    }

                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        let bgBlurPixels = capturePixelSample(ioFn, window, captureRect)
                        let bgBlurDiff = pixelDiff(noFilterPixels, bgBlurPixels)
                        p("  Portal + backgroundFilters(blur): diff = \(String(format: "%.1f", bgBlurDiff))%")
                        if bgBlurDiff > 1.0 {
                            p("  ⭐️ BACKGROUND BLUR IS VISIBLE!")
                        }

                        // ── Step 6: Blur with different radii to confirm it scales ──
                        p("\n  ── Blur radius sweep ──")
                        var lastPixels = noFilterPixels
                        for radius in [0.0, 2.0, 5.0, 10.0, 20.0, 50.0] as [Double] {
                            if let testBlur = (filterClass as AnyObject)
                                .perform(filterWithTypeSel, with: "gaussianBlur")?
                                .takeUnretainedValue() as? NSObject {

                                testBlur.setValue(radius, forKey: "inputRadius")
                                portal.layer.setValue([testBlur], forKey: "filters")
                                CATransaction.flush()
                            }

                            // Tiny delay for compositor
                            Thread.sleep(forTimeInterval: 0.05)

                            let pixels = capturePixelSample(ioFn, window, captureRect)
                            let diffFromBase = pixelDiff(noFilterPixels, pixels)
                            let diffFromPrev = pixelDiff(lastPixels, pixels)
                            p("    radius=\(String(format: "%5.1f", radius)): diff_base=\(String(format: "%5.1f", diffFromBase))% diff_prev=\(String(format: "%5.1f", diffFromPrev))%")
                            lastPixels = pixels
                        }

                        // Cleanup
                        portal.removeFromSuperview()
                        p("\n  Portal removed")
                    }
                }
            }
        }
    }

    /// Capture pixel samples from IOSurface for comparison
    private static func capturePixelSample(
        _ fn: @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?,
        _ window: UIWindow,
        _ rect: CGRect
    ) -> [UInt32] {
        let sel = Selector(("createIOSurfaceWithFrame:"))
        guard let unmanaged = fn(window, sel, rect) else { return [] }
        let obj = unmanaged.takeUnretainedValue()
        guard CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() else {
            unmanaged.release()
            return []
        }

        let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
        let w = IOSurfaceGetWidth(surface)
        let h = IOSurfaceGetHeight(surface)

        IOSurfaceLock(surface, .readOnly, nil)
        let pixels = IOSurfaceGetBaseAddress(surface).assumingMemoryBound(to: UInt32.self)
        let total = w * h
        let step = max(1, total / 200)
        var samples: [UInt32] = []
        samples.reserveCapacity(200)
        for i in stride(from: 0, to: total, by: step) {
            samples.append(pixels[i])
        }
        IOSurfaceUnlock(surface, .readOnly, nil)
        unmanaged.release()

        return samples
    }

    /// Compare two pixel sample arrays, return % difference
    private static func pixelDiff(_ a: [UInt32], _ b: [UInt32]) -> Double {
        guard !a.isEmpty && !b.isEmpty else { return 100.0 }
        let count = min(a.count, b.count)
        var diffs = 0
        for i in 0..<count {
            if a[i] != b[i] { diffs += 1 }
        }
        return Double(diffs) / Double(count) * 100.0
    }

    // ═══════════════════════════════════════════════════════════
    // PHASE 4 (kept for reference)
    // ═══════════════════════════════════════════════════════════

    private static func probeNewFiltersParams() {
        p("\n══ 4.1 New filter parameters (brute-force KVC) ══")

        guard let filterClass = NSClassFromString("CAFilter") else { return }
        let filterWithTypeSel = NSSelectorFromString("filterWithType:")

        // Filters we want to fully explore
        let targets = [
            "chromaticAberration",
            "chromaticAberrationMap",
            "displacementMap",
            "glassBackground",
            "glassForeground",
            "liquidGlass",
            "refraction",
            "glass",
            "variableBlur",
        ]

        // Comprehensive key candidates from known CAFilter/CIFilter conventions
        let candidateKeys: [String] = [
            // Standard CIFilter-style
            "inputRadius", "inputAmount", "inputAngle", "inputCenter",
            "inputScale", "inputIntensity", "inputSharpness",
            "inputColor", "inputColor0", "inputColor1",
            "inputImage", "inputBackgroundImage", "inputMask",
            "inputWidth", "inputHeight", "inputSize",
            "inputOffset", "inputOffsetX", "inputOffsetY",
            "inputStrength", "inputSpread", "inputSamples",
            "inputBias", "inputGain", "inputPower",
            "inputTransform", "inputMatrix",
            // CA-specific
            "inputRadius0", "inputRadius1",
            "inputNormalMap", "inputDisplacementMap", "inputHeightMap",
            "inputRefractiveIndex", "inputRefractionStrength",
            "inputChromaticAmount", "inputChromaticSpread",
            "inputChromaticStrength", "inputChromaticOffset",
            "inputAberrationAmount", "inputAberrationStrength",
            "inputDispersion", "inputWavelength",
            "inputRed", "inputGreen", "inputBlue",
            "inputRedOffset", "inputGreenOffset", "inputBlueOffset",
            "inputRedScale", "inputGreenScale", "inputBlueScale",
            // Glass-specific guesses
            "inputBlurRadius", "inputRefractionRadius",
            "inputGlassAmount", "inputGlassRadius",
            "inputFresnelExponent", "inputIOR",
            "inputSurfaceNormal", "inputEnvironment",
            "inputSDF", "inputSDFTexture", "inputShape",
            "inputDirection", "inputLightDirection", "inputLightPosition",
            "inputHighlightColor", "inputShadowColor",
            "inputVibrancy", "inputTint", "inputTintColor",
            "inputSaturation", "inputBrightness", "inputContrast",
            // Displacement-specific
            "inputDisplacementScale", "inputDisplacementStrength",
            "inputChannelX", "inputChannelY",
            "inputTextureScale", "inputTexture",
            // Blur variants
            "inputQuality", "inputNormalized",
            "inputMaskImage", "inputGradient",
            "inputStartRadius", "inputEndRadius",
            "inputStartPoint", "inputEndPoint",
            // Generic numeric
            "inputValue", "inputFactor", "inputLevel",
            "inputMin", "inputMax", "inputThreshold",
            "inputOpacity", "inputAlpha",
            // CAML / render keys
            "type", "name", "enabled",
            "inputAperture", "inputFocalLength",
            "inputColorMatrix", "inputColorOffset",
            // From ShatteredGlass / SDF pipeline
            "inputSDFScale", "inputSDFOffset",
            "inputSourceSublayerName", "inputNormalsSublayerName",
            "inputCornerRadius", "inputCornerCurve",
            "inputMeshTransform",
        ]

        for typeName in targets {
            guard let filterObj = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject
            else {
                p("  \(typeName): ❌ not found")
                continue
            }

            // Read _type index
            var typeIndex: UInt32 = 0
            if let ivar = class_getInstanceVariable(type(of: filterObj), "_type") {
                let offset = ivar_getOffset(ivar)
                let ptr = Unmanaged.passUnretained(filterObj).toOpaque()
                typeIndex = ptr.advanced(by: offset)
                    .assumingMemoryBound(to: UInt32.self).pointee
            }
            p("\n  ⭐️ \(typeName) (_type=\(typeIndex))")

            // Try every candidate key via KVC
            var foundKeys: [(String, String)] = []
            for key in candidateKeys {
                // Use exception-safe check: responds(to:) for the getter
                let getterSel = NSSelectorFromString(key)
                if filterObj.responds(to: getterSel) {
                    let val = filterObj.value(forKey: key)
                    let desc = describeValue(val)
                    foundKeys.append((key, desc))
                }
            }

            if foundKeys.isEmpty {
                p("    No known keys respond")
            } else {
                for (key, val) in foundKeys {
                    p("    \(key) = \(val)")
                }
            }

            // CAFilter has custom setValue:forKey: — stores to _attr dict.
            // Set a value, read back — if it returns non-nil, the key is accepted.
            p("    ── Writable test (set 1.0, read back) ──")
            let writeTestKeys = [
                "inputRadius", "inputAmount", "inputScale", "inputStrength",
                "inputSpread", "inputIntensity", "inputOffset",
                "inputChromaticAmount", "inputChromaticSpread",
                "inputDispersion", "inputRefractionStrength",
                "inputDisplacementScale", "inputBlurRadius",
                "inputRedOffset", "inputGreenOffset", "inputBlueOffset",
                "inputWidth", "inputHeight", "inputAngle",
                "inputBias", "inputGain", "inputSamples",
                "inputNormalMap", "inputDirection", "inputColor",
                "inputSDF", "inputCornerRadius",
                "inputSourceSublayerName", "inputNormalsSublayerName",
            ]
            for key in writeTestKeys {
                filterObj.setValue(NSNumber(value: 1.0), forKey: key)
                let after = filterObj.value(forKey: key)
                if after != nil {
                    p("    ✅ \(key) → \(describeValue(after))")
                }
            }
        }
    }

    private static func describeValue(_ val: Any?) -> String {
        guard let val else { return "nil" }
        if let num = val as? NSNumber { return "\(num)" }
        if let str = val as? String { return "\"\(str)\"" }
        if let arr = val as? [Any] {
            return "[\(arr.prefix(8).map { describeValue($0) }.joined(separator: ", "))]"
        }
        return "\(type(of: val)): \(val)"
    }

    // ── 4.2: CA_copyRenderValue — binary representation for render server ──

    private static func probeCACopyRenderValue() {
        p("\n══ 4.2 CA_copyRenderValue ══")

        guard let filterClass = NSClassFromString("CAFilter") else { return }
        let filterWithTypeSel = NSSelectorFromString("filterWithType:")

        let targets: [(String, [(String, Any)])] = [
            ("gaussianBlur", [("inputRadius", 10.0)]),
            ("chromaticAberration", []),
            ("glassBackground", []),
            ("displacementMap", []),
        ]

        let copyRenderSel = NSSelectorFromString("CA_copyRenderValue")

        for (typeName, params) in targets {
            guard let filterObj = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject
            else { continue }

            for (key, val) in params {
                filterObj.setValue(val, forKey: key)
            }

            p("\n  ── \(typeName) ──")

            guard filterObj.responds(to: copyRenderSel) else {
                p("    ❌ CA_copyRenderValue not available")
                continue
            }

            // CA_copyRenderValue returns ^{Object=...} — a raw pointer to CA::Render::Object
            // Type encoding: ^{Object=^^?{Atomic={?=i}}b8b24}
            // This is a C pointer, not an ObjC object
            typealias CopyRenderFn = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?
            let imp = filterObj.method(for: copyRenderSel)
            let copyRenderFn = unsafeBitCast(imp, to: CopyRenderFn.self)

            guard let renderObj = copyRenderFn(filterObj, copyRenderSel) else {
                p("    CA_copyRenderValue → nil")
                continue
            }

            p("    CA_copyRenderValue → \(renderObj)")

            // Dump raw memory of the CA::Render::Object
            // Layout hint from type encoding: {Object=^^? {Atomic={?=i}} b8 b24}
            // ^^? = vtable (pointer to pointer to function)
            // Atomic = {?=i} = atomic int (refcount?)
            // b8, b24 = bitfields
            let objBytes = renderObj.assumingMemoryBound(to: UInt8.self)
            p("    Raw memory (256 bytes):")
            for row in 0..<16 {
                let start = row * 16
                var hexPart = ""
                var asciiPart = ""
                for i in start..<(start + 16) {
                    hexPart += String(format: "%02x ", objBytes[i])
                    let c = objBytes[i]
                    asciiPart += (c >= 0x20 && c < 0x7f)
                        ? String(UnicodeScalar(c)) : "."
                }
                p("    \(String(format: "%04x", start)): \(hexPart) |\(asciiPart)|")
            }

            // Try to interpret structure
            // First 8 bytes: likely vtable or type pointer
            let word0 = renderObj.assumingMemoryBound(to: UInt.self).pointee
            let word1 = renderObj.advanced(by: 8).assumingMemoryBound(to: UInt.self).pointee
            let word2 = renderObj.advanced(by: 16).assumingMemoryBound(to: UInt.self).pointee
            let word3 = renderObj.advanced(by: 24).assumingMemoryBound(to: UInt.self).pointee
            p("    word[0] = 0x\(String(word0, radix: 16)) (vtable?)")
            p("    word[1] = 0x\(String(word1, radix: 16)) (refcount/flags?)")
            p("    word[2] = 0x\(String(word2, radix: 16))")
            p("    word[3] = 0x\(String(word3, radix: 16))")

            // Look for the filter type index somewhere in the object
            // We know gaussianBlur = 280 (0x118), so search for it
            let u32ptr = renderObj.assumingMemoryBound(to: UInt32.self)
            for i in 0..<64 {
                let val = u32ptr[i]
                if val > 100 && val < 1000 {
                    p("    u32[\(i)] (offset \(i*4)) = \(val) (0x\(String(val, radix: 16)))")
                }
            }

            // Look for floats (filter params like radius=10.0)
            let f32ptr = renderObj.assumingMemoryBound(to: Float.self)
            for i in 0..<64 {
                let val = f32ptr[i]
                if val > 0.5 && val < 100 && !val.isNaN && !val.isInfinite {
                    p("    f32[\(i)] (offset \(i*4)) = \(val)")
                }
            }
        }
    }

    // ── 4.3: Apply compositor filters to a portal layer ──

    private static func probeFiltersOnPortal(window: UIWindow) {
        p("\n══ 4.3 Compositor filters on portal ══")

        guard let filterClass = NSClassFromString("CAFilter"),
              let portalClass = NSClassFromString("_UIPortalView") as? UIView.Type
        else {
            p("  ❌ Required classes not found")
            return
        }

        let filterWithTypeSel = NSSelectorFromString("filterWithType:")

        // Create portal mirroring the main window
        let portal = portalClass.init(frame: window.bounds)
        portal.setValue(window, forKey: "sourceView")
        portal.setValue(false, forKey: "matchesPosition")
        portal.setValue(false, forKey: "matchesTransform")

        // Place portal in the window (needs to be visible for compositor to render)
        portal.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        portal.alpha = 1.0
        window.addSubview(portal)

        p("  Portal created: \(portal.frame)")
        p("  Portal layer class: \(NSStringFromClass(type(of: portal.layer)))")

        // ── Test 1: Apply chromaticAberration to portal layer ──
        p("\n  ── Test 1: chromaticAberration on portal ──")
        if let chromaFilter = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "chromaticAberration")?
            .takeUnretainedValue() as? NSObject {

            // Try setting various strength values
            for key in ["inputAmount", "inputStrength", "inputRadius",
                        "inputScale", "inputIntensity", "inputSpread"] {
                chromaFilter.setValue(NSNumber(value: 5.0), forKey: key)
                if chromaFilter.value(forKey: key) != nil {
                    p("    ✅ chromaFilter.\(key) = 5.0")
                }
            }

            portal.layer.setValue([chromaFilter], forKey: "filters")
            p("    Applied to portal.layer.filters")

            CATransaction.flush()

            // Check if anything visible happened
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                // Snapshot to check
                let hasFilters = portal.layer.filters != nil
                p("    Portal has filters: \(hasFilters)")
                let filterCount = (portal.layer.value(forKey: "filters") as? [Any])?.count ?? 0
                p("    Filter count: \(filterCount)")
            }
        }

        // ── Test 2: displacementMap on portal layer ──
        p("\n  ── Test 2: displacementMap on portal ──")
        if let dispFilter = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "displacementMap")?
            .takeUnretainedValue() as? NSObject {

            for key in ["inputScale", "inputAmount", "inputStrength",
                        "inputRadius", "inputDisplacementScale"] {
                dispFilter.setValue(NSNumber(value: 20.0), forKey: key)
                if dispFilter.value(forKey: key) != nil {
                    p("    ✅ dispFilter.\(key) = 20.0")
                }
            }
        }

        // ── Test 3: glassBackground on portal ──
        p("\n  ── Test 3: glassBackground on portal ──")
        if let glassFilter = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "glassBackground")?
            .takeUnretainedValue() as? NSObject {

            portal.layer.setValue([glassFilter], forKey: "filters")
            CATransaction.flush()
            p("    Applied glassBackground to portal")
        }

        // ── Test 4: Multiple filters (blur + chromatic) ──
        p("\n  ── Test 4: gaussianBlur + chromaticAberration ──")
        if let blurFilter = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "gaussianBlur")?
            .takeUnretainedValue() as? NSObject,
           let chromaFilter2 = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "chromaticAberration")?
            .takeUnretainedValue() as? NSObject {

            blurFilter.setValue(5.0, forKey: "inputRadius")
            portal.layer.setValue([blurFilter, chromaFilter2], forKey: "filters")
            CATransaction.flush()
            p("    Applied blur+chroma to portal")
        }

        // ── Test 5: Apply filters to portal's CAPortalLayer directly ──
        p("\n  ── Test 5: backgroundFilters on portal ──")
        if let blurBg = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "gaussianBlur")?
            .takeUnretainedValue() as? NSObject {

            blurBg.setValue(10.0, forKey: "inputRadius")
            // backgroundFilters = filters applied to content BEHIND this layer
            portal.layer.setValue([blurBg], forKey: "backgroundFilters")
            CATransaction.flush()
            p("    Applied gaussianBlur as backgroundFilter")
        }

        // ── Test 6: Snapshot portal with filters to check pixel output ──
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            p("\n  ── Test 6: Snapshot portal with filters ──")

            let scale = window.screen.scale
            let w = Int(portal.bounds.width * scale)
            let h = Int(portal.bounds.height * scale)

            // drawHierarchy
            UIGraphicsBeginImageContextWithOptions(portal.bounds.size, false, scale)
            let drew = portal.drawHierarchy(in: portal.bounds, afterScreenUpdates: true)
            let img = UIGraphicsGetImageFromCurrentImageContext()
            UIGraphicsEndImageContext()

            if let cgImg = img?.cgImage {
                let bpp = cgImg.bitsPerPixel / 8
                if let data = cgImg.dataProvider?.data,
                   let ptr = CFDataGetBytePtr(data) {
                    let total = w * h
                    let step = max(1, total / 100)
                    var nonBlack = 0
                    for i in stride(from: 0, to: total, by: step) {
                        let off = i * bpp
                        if ptr[off] != 0 || ptr[off+1] != 0 || ptr[off+2] != 0 {
                            nonBlack += 1
                        }
                    }
                    let pct = Double(nonBlack) / Double(total / step) * 100
                    p("    drawHierarchy: drew=\(drew), \(String(format: "%.1f", pct))% non-black")
                }
            } else {
                p("    drawHierarchy: drew=\(drew), no image")
            }

            // layer.render
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
            ) {
                ctx.scaleBy(x: scale, y: scale)
                portal.layer.render(in: ctx)
                if let data = ctx.data {
                    let pixels = data.assumingMemoryBound(to: UInt32.self)
                    let total = w * h
                    let step = max(1, total / 100)
                    var nonBlack = 0
                    for i in stride(from: 0, to: total, by: step) {
                        if pixels[i] != 0 { nonBlack += 1 }
                    }
                    let pct = Double(nonBlack) / Double(total / step) * 100
                    p("    layer.render: \(String(format: "%.1f", pct))% non-black")
                }
            }

            // ── Test 7: IOSurface capture of window WITH portal+filters ──
            p("\n  ── Test 7: IOSurface capture of window with filtered portal ──")
            let ioSel = Selector(("createIOSurfaceWithFrame:"))
            if window.responds(to: ioSel) {
                typealias Func = @convention(c) (AnyObject, Selector, CGRect) -> Unmanaged<AnyObject>?
                let fn = unsafeBitCast(window.method(for: ioSel), to: Func.self)
                if let unmanaged = fn(window, ioSel, portal.frame) {
                    let obj = unmanaged.takeUnretainedValue()
                    if CFGetTypeID(obj as CFTypeRef) == IOSurfaceGetTypeID() {
                        let surface = unsafeBitCast(obj, to: IOSurfaceRef.self)
                        let sw = IOSurfaceGetWidth(surface)
                        let sh = IOSurfaceGetHeight(surface)

                        IOSurfaceLock(surface, .readOnly, nil)
                        let baseAddr = IOSurfaceGetBaseAddress(surface)
                        let pixels = baseAddr.assumingMemoryBound(to: UInt32.self)
                        let total = sw * sh
                        let step = max(1, total / 100)
                        var nonBlack = 0
                        for i in stride(from: 0, to: total, by: step) {
                            if pixels[i] != 0 { nonBlack += 1 }
                        }
                        IOSurfaceUnlock(surface, .readOnly, nil)
                        let pct = Double(nonBlack) / Double(total / step) * 100
                        p("    IOSurface \(sw)×\(sh): \(String(format: "%.1f", pct))% non-black")
                        p("    ⭐️ If non-black > 0, compositor applied filters to portal in IOSurface!")
                    }
                    unmanaged.release()
                }
            }

            // Cleanup
            portal.removeFromSuperview()
            p("\n  Portal removed")
        }
    }

    // ── ObjC exception safety wrapper ──

    // MARK: - Phase 3 (kept for reference)

    private static func probeCARenderSymbols() {
        p("\n══ 3.1 CA::Render symbol availability ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else {
            p("  ❌ dlopen QuartzCore failed")
            return
        }
        defer { dlclose(qc) }

        // C++ mangled names for CA::Render classes
        let symbols: [(String, String)] = [
            // Encoder
            ("Encoder()",                "_ZN2CA6Render7EncoderC1Ev"),
            ("~Encoder()",               "_ZN2CA6Render7EncoderD1Ev"),
            ("encode_int32",             "_ZN2CA6Render7Encoder12encode_int32Ei"),
            ("encode_uint32",            "_ZN2CA6Render7Encoder13encode_uint32Ej"),
            ("encode_float",             "_ZN2CA6Render7Encoder12encode_floatEf"),
            ("encode_double",            "_ZN2CA6Render7Encoder13encode_doubleEd"),
            ("encode_bytes",             "_ZN2CA6Render7Encoder12encode_bytesEPKvm"),
            // Decoder
            ("Decoder(ptr,len)",         "_ZN2CA6Render7DecoderC1EPKvm"),
            ("decode_int32",             "_ZN2CA6Render7Decoder12decode_int32Ev"),
            ("decode_uint32",            "_ZN2CA6Render7Decoder13decode_uint32Ev"),
            ("decode_float",             "_ZN2CA6Render7Decoder12decode_floatEv"),
            ("decode_bytes",             "_ZN2CA6Render7Decoder12decode_bytesEPvm"),
            // Objects
            ("Object::encode",           "_ZNK2CA6Render6Object6encodeERNS0_7EncoderE"),
            ("Object::decode",           "_ZN2CA6Render6Object6decodeERNS0_7DecoderE"),
            ("Filter::encode",           "_ZNK2CA6Render6Filter6encodeERNS0_7EncoderE"),
            ("Filter::decode",           "_ZN2CA6Render6Filter6decodeERNS0_7DecoderE"),
            ("InterpolatedFunction::encode", "_ZNK2CA6Render22InterpolatedFunction6encodeERNS0_7EncoderE"),
            ("Layer::encode",            "_ZNK2CA6Render5Layer6encodeERNS0_7EncoderE"),
            ("Context::encode",          "_ZNK2CA6Render7Context6encodeERNS0_7EncoderE"),
            // Server
            ("Server::server_thread",    "_ZN2CA6Render6Server13server_threadEPv"),
            ("Server::ReceivedMessage",  "_ZN2CA6Render6Server15ReceivedMessage"),
            ("decode_commands",          "_ZN2CA6Render15decode_commandsE"),
            // Encoder buffer access — try common signatures
            ("Encoder::buffer",          "_ZNK2CA6Render7Encoder6bufferEv"),
            ("Encoder::length",          "_ZNK2CA6Render7Encoder6lengthEv"),
            ("Encoder::grow",            "_ZN2CA6Render7Encoder4growEm"),
        ]

        var found = 0
        for (name, mangled) in symbols {
            let ptr = dlsym(qc, mangled)
            if ptr != nil {
                found += 1
                p("  ✅ \(name)")
            } else {
                // Try without exact signature — partial match via iterate
                p("  ❌ \(name)  [\(mangled)]")
            }
        }
        p("  Found \(found)/\(symbols.count) symbols")

        // Bonus: scan for ANY CA::Render symbols by fuzzy name
        // We can't enumerate dylib symbols with dlsym, but we can try
        // known variants
        p("\n  ── Fuzzy search for Encoder variants ──")
        let fuzzyPrefixes = [
            "_ZN2CA6Render7Encoder",
            "_ZN2CA6Render7Decoder",
            "_ZN2CA6Render6Filter",
            "_ZN2CA6Render6Server",
            "_ZN2CA6Render7Context",
        ]
        let fuzzySuffixes = [
            // encode/decode variants
            "6encodeERNS0_7EncoderE",
            "6decodeERNS0_7DecoderE",
            // common method names
            "4sendEv",
            "5flushEv",
            "6commitEv",
            "6bufferEv",
            "6lengthEv",
            "4dataEv",
            "4sizeEv",
            "4growEm",
            "12encode_int64Ex",
            "13decode_uint32Ev",
            "11encode_portEj",
            "12encode_bytesEPKvm",
        ]
        for prefix in fuzzyPrefixes {
            for suffix in fuzzySuffixes {
                let sym = prefix + suffix
                if dlsym(qc, sym) != nil {
                    p("    ⭐️ \(sym)")
                }
            }
        }

        // Check CARenderServer port availability
        p("\n  ── CARenderServer Mach port ──")
        var renderPort: UInt32 = 0
        // bootstrap_look_up is available from mach/mach.h
        // In Swift we need to call it via the C bridge
        if let getPortPtr = dlsym(qc, "CARenderServerGetPort") {
            typealias F = @convention(c) () -> UInt32
            let port = unsafeBitCast(getPortPtr, to: F.self)()
            p("  CARenderServerGetPort = \(port)")
            renderPort = port
        }
        if let getServerPortPtr = dlsym(qc, "CARenderServerGetServerPort") {
            typealias F = @convention(c) () -> UInt32
            let port = unsafeBitCast(getServerPortPtr, to: F.self)()
            p("  CARenderServerGetServerPort = \(port)")
            if renderPort == 0 { renderPort = port }
        }
    }

    // ── 3.2: Full CAFilter catalog — every type, every inputKey ──

    private static func probeCAFilterCatalog() {
        p("\n══ 3.2 CAFilter full catalog ══")

        guard let filterClass = NSClassFromString("CAFilter") else {
            p("  ❌ CAFilter class not found")
            return
        }

        // Get all filter types
        let typesSel = NSSelectorFromString("filterTypes")
        guard filterClass.responds(to: typesSel),
              let typesResult = (filterClass as AnyObject).perform(typesSel)?.takeUnretainedValue(),
              let types = typesResult as? [String]
        else {
            p("  ❌ +filterTypes failed")
            return
        }

        p("  Total filter types: \(types.count)")

        // Categories for grouping
        let glassRelated = ["glassBackground", "liquidGlass", "glass", "refraction",
                            "backdrop", "materialBackground"]
        let blurRelated = ["gaussianBlur", "variableBlur"]
        let colorRelated = ["colorMatrix", "colorSaturate", "colorBrightness",
                           "vibrantColorMatrix", "vibrantDark", "vibrantLight",
                           "compressLuminance", "luminanceCurveMap", "luminanceToAlpha"]

        let interesting = Set(glassRelated + blurRelated + colorRelated)

        let filterWithTypeSel = NSSelectorFromString("filterWithType:")

        for typeName in types {
            let isInteresting = interesting.contains(typeName)

            guard let filterObj = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject
            else { continue }

            // Get inputKeys
            var inputKeys: [String] = []
            if filterObj.responds(to: NSSelectorFromString("inputKeys")),
               let keys = filterObj.value(forKey: "inputKeys") as? [String] {
                inputKeys = keys
            }

            // Get outputKeys
            var outputKeys: [String] = []
            if filterObj.responds(to: NSSelectorFromString("outputKeys")),
               let keys = filterObj.value(forKey: "outputKeys") as? [String] {
                outputKeys = keys
            }

            if isInteresting {
                // Full dump for glass-related filters
                p("\n  ⭐️ \(typeName)")
                if !inputKeys.isEmpty {
                    p("    inputKeys: \(inputKeys)")
                    // Dump default values for each key
                    for key in inputKeys {
                        let val = filterObj.value(forKey: key)
                        let valStr: String
                        if let arr = val as? [Any] {
                            valStr = "[\(arr.map { "\($0)" }.joined(separator: ", "))]"
                        } else {
                            valStr = String(describing: val)
                        }
                        p("      \(key) = \(valStr)")
                    }
                }
                if !outputKeys.isEmpty {
                    p("    outputKeys: \(outputKeys)")
                }

                // Dump ALL KVC-accessible properties
                p("    ── All properties via runtime ──")
                var propCount: UInt32 = 0
                if let props = class_copyPropertyList(type(of: filterObj), &propCount) {
                    for i in 0..<Int(propCount) {
                        let name = String(cString: property_getName(props[i]))
                        p("      property: \(name)")
                    }
                    free(props)
                }

                // Check for enabled, cachesInputImage, accessibility
                for extra in ["enabled", "cachesInputImage", "accessibility",
                              "type", "name"] {
                    if filterObj.responds(to: NSSelectorFromString(extra)) {
                        let v = filterObj.value(forKey: extra)
                        p("      \(extra) = \(String(describing: v))")
                    }
                }
            } else {
                // One-liner for non-interesting
                let keyStr = inputKeys.isEmpty ? "(none)" : inputKeys.joined(separator: ", ")
                p("  \(typeName): [\(keyStr)]")
            }
        }
    }

    // ── 3.3: CAFilter serialization — copyRenderValue: ──

    private static func probeCAFilterSerialization() {
        p("\n══ 3.3 CAFilter serialization (copyRenderValue:) ══")

        guard let filterClass = NSClassFromString("CAFilter") else { return }

        let testFilters: [(String, [(String, Any)])] = [
            ("gaussianBlur", [("inputRadius", 10.0)]),
            ("colorSaturate", [("inputAmount", 0.5)]),
            ("colorMatrix", []),
        ]

        // Also try glass-related if they exist
        let glassFilters = ["glassBackground", "liquidGlass", "refraction", "glass"]

        let filterWithTypeSel = NSSelectorFromString("filterWithType:")

        for (typeName, params) in testFilters {
            guard let filterObj = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject
            else { continue }

            // Set params
            for (key, val) in params {
                filterObj.setValue(val, forKey: key)
            }

            p("\n  ── \(typeName) ──")

            // Method 1: copyRenderValue: (takes a CA::Render::Encoder*)
            // We don't have a real Encoder yet, but let's check if the method exists
            let copyRenderSel = NSSelectorFromString("copyRenderValue:")
            let hasCopyRender = filterObj.responds(to: copyRenderSel)
            p("    copyRenderValue: \(hasCopyRender ? "✅ exists" : "❌ not found")")

            // Method 2: NSCoding — encode to NSData (safe, no render server needed)
            if filterObj.responds(to: NSSelectorFromString("encodeWithCoder:")) {
                do {
                    let data = try NSKeyedArchiver.archivedData(
                        withRootObject: filterObj,
                        requiringSecureCoding: false
                    )
                    p("    NSCoding size: \(data.count) bytes")
                    // Hex dump first 128 bytes
                    let preview = data.prefix(128)
                    let hex = preview.map { String(format: "%02x", $0) }.joined(separator: " ")
                    p("    hex: \(hex)")

                    // Also dump as property list to see structure
                    if let plist = try? PropertyListSerialization.propertyList(
                        from: data, format: nil
                    ) as? [String: Any] {
                        for (k, v) in plist.sorted(by: { $0.key < $1.key }).prefix(20) {
                            let desc = "\(v)".prefix(80)
                            p("    plist[\(k)] = \(desc)")
                        }
                    }
                } catch {
                    p("    NSCoding error: \(error)")
                }
            }

            // Method 3: Try to get internal _type uint (the index into filter table)
            for ivarName in ["_type", "_flags", "_attr", "_cache"] {
                let ivar = class_getInstanceVariable(type(of: filterObj), ivarName)
                if let ivar {
                    let offset = ivar_getOffset(ivar)
                    let ptr = Unmanaged.passUnretained(filterObj).toOpaque()
                    if ivarName == "_type" || ivarName == "_flags" {
                        let val = ptr.advanced(by: offset)
                            .assumingMemoryBound(to: UInt32.self).pointee
                        p("    \(ivarName) = \(val) (0x\(String(val, radix: 16)))")
                    } else {
                        let val = ptr.advanced(by: offset)
                            .assumingMemoryBound(to: UInt.self).pointee
                        p("    \(ivarName) = 0x\(String(val, radix: 16))\(val == 0 ? " (null)" : "")")
                    }
                }
            }
        }

        // Dump _type for ALL glass-related filters to see their indices
        p("\n  ── Glass filter type indices ──")
        for typeName in glassFilters {
            guard let filterObj = (filterClass as AnyObject)
                    .perform(filterWithTypeSel, with: typeName)?
                    .takeUnretainedValue() as? NSObject
            else {
                p("    \(typeName): ❌ not found")
                continue
            }

            let ivar = class_getInstanceVariable(type(of: filterObj), "_type")
            if let ivar {
                let offset = ivar_getOffset(ivar)
                let ptr = Unmanaged.passUnretained(filterObj).toOpaque()
                let val = ptr.advanced(by: offset)
                    .assumingMemoryBound(to: UInt32.self).pointee
                p("    \(typeName): _type = \(val) (0x\(String(val, radix: 16)))")
            }
        }
    }

    // ── 3.4: CAFilter runtime — all methods on the class ──

    private static func probeCAFilterRuntime() {
        p("\n══ 3.4 CAFilter full runtime dump ══")

        guard let filterClass = NSClassFromString("CAFilter") else { return }

        // Class methods
        p("  ── Class methods ──")
        var classMethodCount: UInt32 = 0
        if let meta = object_getClass(filterClass),
           let methods = class_copyMethodList(meta, &classMethodCount) {
            for i in 0..<Int(classMethodCount) {
                let sel = method_getName(methods[i])
                let name = NSStringFromSelector(sel)
                p("    +\(name)")
            }
            free(methods)
        }
        p("  Total class methods: \(classMethodCount)")

        // Instance methods
        p("\n  ── Instance methods ──")
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(filterClass, &methodCount) {
            for i in 0..<Int(methodCount) {
                let sel = method_getName(methods[i])
                let name = NSStringFromSelector(sel)
                // Get type encoding for interesting methods
                let encoding = method_getTypeEncoding(methods[i])
                    .map { String(cString: $0) } ?? "?"
                p("    -\(name)  [\(encoding)]")
            }
            free(methods)
        }
        p("  Total instance methods: \(methodCount)")

        // Ivars
        p("\n  ── Ivars ──")
        var ivarCount: UInt32 = 0
        if let ivars = class_copyIvarList(filterClass, &ivarCount) {
            for i in 0..<Int(ivarCount) {
                let name = ivar_getName(ivars[i]).map { String(cString: $0) } ?? "?"
                let type = ivar_getTypeEncoding(ivars[i]).map { String(cString: $0) } ?? "?"
                let offset = ivar_getOffset(ivars[i])
                p("    \(name) [\(type)] offset=\(offset)")
            }
            free(ivars)
        }

        // Protocols
        p("\n  ── Protocols ──")
        var protoCount: UInt32 = 0
        if let protos = class_copyProtocolList(filterClass, &protoCount) {
            for i in 0..<Int(protoCount) {
                p("    \(NSStringFromProtocol(protos[i]))")
            }
        }

        // Superclass chain
        p("\n  ── Superclass chain ──")
        var cls: AnyClass? = filterClass
        while let c = cls {
            p("    \(NSStringFromClass(c))")
            cls = class_getSuperclass(c)
        }

        // Check for register/add/plugin type class methods
        p("\n  ── Looking for extensibility hooks ──")
        let hookSelectors = [
            "registerFilterType:", "registerFilter:", "addFilterType:",
            "registerFilterName:constructor:", "pluginFilterTypes",
            "setFilterTypes:", "_registerBuiltinFilters",
            "registerFilterFactory:forType:", "filterClassForType:",
            "_filterImplementationForType:", "filterDescriptionForType:",
        ]
        for selName in hookSelectors {
            let responds = filterClass.responds(to: NSSelectorFromString(selName))
            if responds {
                p("    ⭐️ +\(selName) EXISTS!")
            }
        }

        // Instance hooks
        let instanceHooks = [
            "copyRenderValue:", "copyRenderValue",
            "_renderValue", "_renderFilter", "_renderObject",
            "encodeTo:", "encodeToEncoder:",
            "_copyRenderFilter", "_renderLayerFilter",
            "metalKernel", "metalFunction", "ciFilter",
            "_backingFilter", "_nativeFilter",
        ]
        // Create a dummy filter to test instance methods
        let filterWithTypeSel = NSSelectorFromString("filterWithType:")
        if let dummy = (filterClass as AnyObject)
            .perform(filterWithTypeSel, with: "gaussianBlur")?
            .takeUnretainedValue() as? NSObject {
            for selName in instanceHooks {
                if dummy.responds(to: NSSelectorFromString(selName)) {
                    p("    ⭐️ -\(selName) EXISTS!")
                }
            }
        }
    }

    // ── 3.5: Live CA::Render::Encoder experiment ──

    private static func probeCARenderEncoderLive(window: UIWindow) {
        p("\n══ 3.5 CA::Render::Encoder live experiment ══")

        guard let qc = dlopen(
            "/System/Library/Frameworks/QuartzCore.framework/QuartzCore",
            RTLD_NOW
        ) else {
            p("  ❌ dlopen failed")
            return
        }
        defer { dlclose(qc) }

        // Find Encoder constructor and methods
        // Try multiple mangling variants (ARM64 vs x86_64 can differ)
        let ctorNames = [
            "_ZN2CA6Render7EncoderC1Ev",
            "_ZN2CA6Render7EncoderC2Ev",
        ]
        let dtorNames = [
            "_ZN2CA6Render7EncoderD1Ev",
            "_ZN2CA6Render7EncoderD2Ev",
        ]

        var ctorPtr: UnsafeMutableRawPointer?
        var dtorPtr: UnsafeMutableRawPointer?
        for name in ctorNames {
            if let ptr = dlsym(qc, name) { ctorPtr = ptr; p("  ctor: \(name)"); break }
        }
        for name in dtorNames {
            if let ptr = dlsym(qc, name) { dtorPtr = ptr; p("  dtor: \(name)"); break }
        }

        let encU32Ptr = dlsym(qc, "_ZN2CA6Render7Encoder13encode_uint32Ej")
        let encFloatPtr = dlsym(qc, "_ZN2CA6Render7Encoder12encode_floatEf")
        let encBytesPtr = dlsym(qc, "_ZN2CA6Render7Encoder12encode_bytesEPKvm")
        let encGrowPtr = dlsym(qc, "_ZN2CA6Render7Encoder4growEm")

        p("  encode_uint32: \(encU32Ptr != nil ? "✅" : "❌")")
        p("  encode_float:  \(encFloatPtr != nil ? "✅" : "❌")")
        p("  encode_bytes:  \(encBytesPtr != nil ? "✅" : "❌")")
        p("  grow:          \(encGrowPtr != nil ? "✅" : "❌")")

        guard let ctor = ctorPtr, encU32Ptr != nil else {
            p("  ❌ Missing critical symbols, can't proceed")

            // Fallback: try to find symbols via nm-style iteration
            p("\n  ── Searching for Encoder-like symbols ──")
            // We can try common C function names that might bridge to Encoder
            let cBridgeSymbols = [
                "CARenderEncoderCreate",
                "CARenderEncoderDestroy",
                "CARenderEncoderEncodeUInt32",
                "CARenderEncoderGetData",
                "ca_render_encoder_create",
            ]
            for sym in cBridgeSymbols {
                if dlsym(qc, sym) != nil {
                    p("    ⭐️ \(sym)")
                }
            }
            return
        }

        // Allocate Encoder on the stack (C++ object, unknown size)
        // Start with 256 bytes — way more than needed, Encoder is typically ~48-64 bytes
        let encoderSize = 256
        let encoderBuf = UnsafeMutableRawPointer.allocate(
            byteCount: encoderSize, alignment: 16
        )
        // Zero-fill for safety
        memset(encoderBuf, 0, encoderSize)

        p("\n  ── Creating CA::Render::Encoder ──")

        // Call constructor: Encoder::Encoder()
        // C++ this pointer = encoderBuf
        typealias CtorFn = @convention(c) (UnsafeMutableRawPointer) -> Void
        let ctorFn = unsafeBitCast(ctor, to: CtorFn.self)
        ctorFn(encoderBuf)
        p("  ✅ Encoder constructed")

        // Dump encoder state after construction
        p("  Encoder memory after ctor (first 64 bytes):")
        let bytes = encoderBuf.assumingMemoryBound(to: UInt8.self)
        var hex = ""
        for i in 0..<64 {
            hex += String(format: "%02x ", bytes[i])
            if (i + 1) % 16 == 0 {
                p("    \(hex)")
                hex = ""
            }
        }

        // Try to read buffer pointer and length from known offsets
        // Typical C++ layout: vtable_ptr(8) + buffer_ptr(8) + length(8) + capacity(8)
        // or: buffer_ptr(8) + length(8) + capacity(8) (no vtable if no virtual methods)
        p("\n  ── Encoder internal layout guess ──")
        for offset in stride(from: 0, to: 64, by: 8) {
            let val = encoderBuf.advanced(by: offset)
                .assumingMemoryBound(to: UInt.self).pointee
            p("    offset \(offset): 0x\(String(val, radix: 16))")
        }

        // Encode some test data
        p("\n  ── Encoding test data ──")
        typealias EncU32Fn = @convention(c) (UnsafeMutableRawPointer, UInt32) -> Void
        let encU32 = unsafeBitCast(encU32Ptr!, to: EncU32Fn.self)

        encU32(encoderBuf, 0xCAFE0001)  // magic / command id
        encU32(encoderBuf, 42)           // some value
        p("  Encoded 2x uint32")

        if let fp = encFloatPtr {
            typealias EncFloatFn = @convention(c) (UnsafeMutableRawPointer, Float) -> Void
            let encFloat = unsafeBitCast(fp, to: EncFloatFn.self)
            encFloat(encoderBuf, 3.14159)
            p("  Encoded 1x float")
        }

        // Dump encoder state after encoding
        p("\n  Encoder memory after encoding (first 64 bytes):")
        hex = ""
        for i in 0..<64 {
            hex += String(format: "%02x ", bytes[i])
            if (i + 1) % 16 == 0 {
                p("    \(hex)")
                hex = ""
            }
        }

        // Try to find buffer/length
        p("\n  ── Looking for encoded buffer ──")
        for offset in stride(from: 0, to: 64, by: 8) {
            let val = encoderBuf.advanced(by: offset)
                .assumingMemoryBound(to: UInt.self).pointee
            // Check if any pointer looks like heap (typical heap range)
            if val > 0x1_0000_0000 && val < 0xFFFF_FFFF_FFFF {
                let heapPtr = UnsafeRawPointer(bitPattern: val)
                if let heapPtr {
                    p("    offset \(offset) → heap ptr 0x\(String(val, radix: 16))")
                    // Try to read from it (might contain our encoded data)
                    let heapBytes = heapPtr.assumingMemoryBound(to: UInt8.self)
                    var heapHex = "      "
                    // Read cautiously — just 32 bytes
                    for i in 0..<32 {
                        heapHex += String(format: "%02x ", heapBytes[i])
                    }
                    p(heapHex)

                    // Check if our magic value is in there
                    let firstU32 = heapPtr.assumingMemoryBound(to: UInt32.self).pointee
                    if firstU32 == 0xCAFE0001 {
                        p("    ⭐️ Found our encoded data at offset \(offset)!")
                    }
                }
            }
        }

        // Try buffer()/length() if we found them
        if let bufFnPtr = dlsym(qc, "_ZNK2CA6Render7Encoder6bufferEv") {
            typealias BufFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?
            let bufFn = unsafeBitCast(bufFnPtr, to: BufFn.self)
            if let buf = bufFn(encoderBuf) {
                p("    ⭐️ Encoder::buffer() → \(buf)")
                let bufBytes = buf.assumingMemoryBound(to: UInt8.self)
                var bufHex = "      "
                for i in 0..<32 {
                    bufHex += String(format: "%02x ", bufBytes[i])
                }
                p(bufHex)
            }
        }
        if let lenFnPtr = dlsym(qc, "_ZNK2CA6Render7Encoder6lengthEv") {
            typealias LenFn = @convention(c) (UnsafeMutableRawPointer) -> UInt
            let lenFn = unsafeBitCast(lenFnPtr, to: LenFn.self)
            let len = lenFn(encoderBuf)
            p("    ⭐️ Encoder::length() → \(len) bytes")
        }

        // ── Now the big test: hook CAFilter's render path ──
        p("\n  ── Intercept CAFilter render encoding ──")

        // Create a real layer with a real filter, commit, and see what happens
        let testLayer = CALayer()
        testLayer.frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        testLayer.backgroundColor = UIColor.red.cgColor

        guard let filterClass = NSClassFromString("CAFilter"),
              let filter = (filterClass as AnyObject)
                .perform(NSSelectorFromString("filterWithType:"), with: "gaussianBlur")?
                .takeUnretainedValue() as? NSObject
        else {
            p("  ❌ Can't create CAFilter")
            if let dtor = dtorPtr {
                let dtorFn = unsafeBitCast(dtor, to: CtorFn.self)
                dtorFn(encoderBuf)
            }
            encoderBuf.deallocate()
            return
        }

        filter.setValue(10.0, forKey: "inputRadius")

        // Try calling copyRenderValue: with our encoder
        let copyRenderSel = NSSelectorFromString("copyRenderValue:")
        if filter.responds(to: copyRenderSel) {
            p("  Calling copyRenderValue: with our Encoder...")

            // Reset encoder (reconstruct)
            if let dtor = dtorPtr {
                let dtorFn = unsafeBitCast(dtor, to: CtorFn.self)
                dtorFn(encoderBuf)
            }
            memset(encoderBuf, 0, encoderSize)
            ctorFn(encoderBuf)

            // copyRenderValue: takes a void* (CA::Render::Encoder*)
            typealias CopyRenderFn = @convention(c) (AnyObject, Selector, UnsafeMutableRawPointer) -> Void
            let imp = filter.method(for: copyRenderSel)
            let copyRenderFn = unsafeBitCast(imp, to: CopyRenderFn.self)
            copyRenderFn(filter, copyRenderSel, encoderBuf)

            p("  ✅ copyRenderValue: returned!")

            // Read what was encoded
            if let lenFnPtr = dlsym(qc, "_ZNK2CA6Render7Encoder6lengthEv") {
                typealias LenFn = @convention(c) (UnsafeMutableRawPointer) -> UInt
                let lenFn = unsafeBitCast(lenFnPtr, to: LenFn.self)
                let len = lenFn(encoderBuf)
                p("  Encoded filter data: \(len) bytes")
            }

            if let bufFnPtr = dlsym(qc, "_ZNK2CA6Render7Encoder6bufferEv") {
                typealias BufFn = @convention(c) (UnsafeMutableRawPointer) -> UnsafeRawPointer?
                let bufFn = unsafeBitCast(bufFnPtr, to: BufFn.self)
                if let buf = bufFn(encoderBuf) {
                    // Get length first
                    var totalLen = 64 // default
                    if let lenFnPtr2 = dlsym(qc, "_ZNK2CA6Render7Encoder6lengthEv") {
                        typealias LenFn2 = @convention(c) (UnsafeMutableRawPointer) -> UInt
                        let lenFn2 = unsafeBitCast(lenFnPtr2, to: LenFn2.self)
                        totalLen = min(Int(lenFn2(encoderBuf)), 512)
                    }

                    p("  ⭐️ Filter binary representation (\(totalLen) bytes):")
                    let bufBytes = buf.assumingMemoryBound(to: UInt8.self)
                    for row in 0..<((totalLen + 15) / 16) {
                        let start = row * 16
                        let end = min(start + 16, totalLen)
                        var hexPart = ""
                        var asciiPart = ""
                        for i in start..<end {
                            hexPart += String(format: "%02x ", bufBytes[i])
                            let c = bufBytes[i]
                            asciiPart += (c >= 0x20 && c < 0x7f)
                                ? String(UnicodeScalar(c)) : "."
                        }
                        let pad = String(repeating: "   ", count: 16 - (end - start))
                        p("    \(String(format: "%04x", start)): \(hexPart)\(pad) |\(asciiPart)|")
                    }
                }
            }
        } else {
            p("  ❌ copyRenderValue: not available")
        }

        // Cleanup encoder
        if let dtor = dtorPtr {
            let dtorFn = unsafeBitCast(dtor, to: CtorFn.self)
            dtorFn(encoderBuf)
        }
        encoderBuf.deallocate()

        p("\n  ══ Phase 3 complete ══")
    }
}
