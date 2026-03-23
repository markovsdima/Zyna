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

// MARK: - BackdropProbe

enum BackdropProbe {

    private static func p(_ msg: String) {
        print("[probe] \(msg)")
    }

    static func run(in hostView: UIView) {
        guard let window = hostView.window else { return }
        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
        p("  PHASE 2: Testing all hot leads")
        p("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")

        probeCARenderServerDeep(window: window)

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
}
