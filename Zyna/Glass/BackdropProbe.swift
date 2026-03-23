//
//  BackdropProbe.swift
//  Zyna
//
//  Probe v6: Intercept _mt_applyMaterialDescription to understand
//  how UIKit activates CABackdropLayer on iOS 26.
//

import UIKit
import ObjectiveC
import QuartzCore
import MetalKit
import IOSurface

// MARK: - BackdropProbe

enum BackdropProbe {

    private static func p(_ msg: String) {
        print("[glass] \(msg)")
    }

    static func run(in hostView: UIView) {
        p("━━━ PROBE v6: MaterialDescription (iOS \(UIDevice.current.systemVersion)) ━━━")

        probeMaterialDescriptionIntercept()
        probeMTMethods(in: hostView)

        p("━━━ DONE ━━━")
    }

    // MARK: - 1. Intercept mt_applyMaterialDescription on live UIVisualEffectView

    static func probeMaterialDescriptionIntercept() {
        p("── 1. Intercept mt_applyMaterialDescription ──")

        // Create a UIVisualEffectView — this triggers the internal MaterialKit setup
        let vev = UIVisualEffectView(effect: UIBlurEffect(style: .regular))
        vev.frame = CGRect(x: 0, y: 0, width: 200, height: 200)

        guard let backdropView = vev.subviews.first else {
            p("  ❌ No backdrop subview")
            return
        }

        let backdropLayer = backdropView.layer
        p("  Backdrop layer type: \(NSStringFromClass(type(of: backdropLayer)))")

        // Check all _mt_ methods on the layer and try to read their state
        let mtMethods = [
            "mt_applyMaterialDescription:removingIfIdentity:",
            "_mt_applyFilterDescription:remainingExistingFilters:filterOrder:removingIfIdentity:",
            "_mt_configureFilterOfType:ifNecessaryWithFilterOrder:",
            "_mt_configureFilterOfType:ifNecessaryWithName:andFilterOrder:",
            "_mt_setValue:forFilterOfType:valueKey:filterOrder:removingIfIdentity:",
            "_mt_setColorMatrix:withName:filterOrder:removingIfIdentity:",
            "_mt_removeFilterOfType:ifNecessaryWithName:",
            "_mt_removeFilterOfTypeIfNecessary:",
        ]

        for method in mtMethods {
            let responds = backdropLayer.responds(to: NSSelectorFromString(method))
            p("  \(responds ? "✅" : "❌") \(method)")
        }

        // Look for MaterialDescription-related classes
        let mdClassNames = [
            "MTMaterialDescription",
            "MTMaterial",
            "MTMaterialSettings",
            "MTMaterialRecipe",
            "MTMaterialConfiguration",
            "_MTBackdropCompoundEffect",
            "_MTBackdropEffect",
            "_UIBackdropEffect",
            "_UIBackdropEffectDescription",
            "MTCoreMaterialDescription",
            "MTVisualStyling",
            "MTVisualStylingDescription",
        ]

        p("")
        p("  MaterialDescription classes:")
        for name in mdClassNames {
            if let cls = NSClassFromString(name) {
                p("    ✅ \(name)")
                dumpClassAPI(cls, indent: "      ")
            }
        }
    }

    // MARK: - 2. Try calling _mt_ methods directly

    static func probeMTMethods(in hostView: UIView) {
        p("── 2. Call _mt_ methods on CABackdropLayer ──")

        guard let backdropCls = NSClassFromString("CABackdropLayer") as? CALayer.Type else { return }

        // Create a fresh backdrop layer
        let layer = backdropCls.init()
        layer.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        layer.setValue(true, forKey: "enabled")
        layer.setValue(UUID().uuidString, forKey: "groupName")

        // First, let's see what UIVisualEffectView's backdrop layer looks like
        // after it's been set up
        let vev = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
        vev.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        hostView.addSubview(vev)

        guard let liveBackdropView = vev.subviews.first else { return }
        let liveLayer = liveBackdropView.layer

        p("  Live backdrop layer filters:")
        if let filters = liveLayer.filters as? [NSObject] {
            for filter in filters {
                let type = (filter.responds(to: NSSelectorFromString("type")))
                    ? (filter.value(forKey: "type") as? String ?? "?") : "?"
                let name = (filter.responds(to: NSSelectorFromString("name")))
                    ? (filter.value(forKey: "name") as? String ?? "?") : "?"
                p("    type=\(type) name=\(name)")

                // Dump all KVC values on the filter
                dumpFilterValues(filter)
            }
        }

        p("")
        p("  Live backdrop layer KVC state:")
        let keys = [
            "enabled", "captureOnly", "groupName", "groupNamespace",
            "scale", "backdropRect", "marginWidth", "zoom",
            "allowsInPlaceFiltering", "reducesCaptureBitDepth",
            "ignoresScreenClip", "updateRate", "tracksLuma",
            "disableFilterCache", "preallocatesScreenArea",
        ]
        for key in keys {
            if liveLayer.responds(to: NSSelectorFromString(key)) {
                let val = liveLayer.value(forKey: key)
                p("    \(key) = \(String(describing: val))")
            }
        }

        // Now try to copy the live layer's exact configuration to our fresh layer
        p("")
        p("  Copying live layer config to fresh CABackdropLayer...")

        for key in keys {
            if liveLayer.responds(to: NSSelectorFromString(key)),
               layer.responds(to: NSSelectorFromString("set\(key.prefix(1).uppercased())\(key.dropFirst()):")) {
                let val = liveLayer.value(forKey: key)
                layer.setValue(val, forKey: key)
            }
        }

        // Copy filters
        if let filters = liveLayer.filters {
            layer.filters = filters
        }

        // Copy backgroundFilters
        if let bgFilters = liveLayer.backgroundFilters {
            layer.backgroundFilters = bgFilters
        }

        // Add to view hierarchy
        hostView.layer.addSublayer(layer)
        CATransaction.flush()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let hasContents = layer.contents != nil
            p("  Fresh layer with copied config: contents=\(hasContents)")

            if hasContents {
                p("  ⭐️⭐️⭐️ BACKDROP ACTIVATED!")
            }

            // Also try: what if we call mt_applyMaterialDescription with a live effect?
            // Look for the visual styling on the UIVisualEffectView
            let vevObj = vev as NSObject

            // _UIVisualEffectViewBackdropConfig or similar
            let configSelectors = [
                "_effectConfig",
                "_backdropViewLayer",
                "_effectDescriptor",
                "effectView",
                "_backgroundEffects",
                "_contentEffects",
            ]
            for selName in configSelectors {
                if vevObj.responds(to: NSSelectorFromString(selName)) {
                    let val = vevObj.value(forKey: selName)
                    p("  vev.\(selName) = \(String(describing: val))")
                }
            }

            // Check _UIVisualEffectBackdropView for config methods
            let bdView = liveBackdropView as NSObject
            let bdSelectors = [
                "_applyRequestedFilterEffects",
                "_updateFilters",
                "_backdropLayer",
                "filters",
                "_currentFilterEntries",
                "_updateForCurrentEffect",
                "_effectDescriptor",
            ]
            for selName in bdSelectors {
                if bdView.responds(to: NSSelectorFromString(selName)) {
                    p("  backdropView responds to \(selName)")
                    // Only read properties, not trigger methods
                    if !selName.hasPrefix("_apply") && !selName.hasPrefix("_update") {
                        let val = bdView.value(forKey: selName)
                        p("    = \(String(describing: val))")
                    }
                }
            }

            layer.removeFromSuperlayer()
            vev.removeFromSuperview()
        }
    }

    // MARK: - Helpers

    private static func dumpClassAPI(_ cls: AnyClass, indent: String = "  ") {
        // Instance methods — only interesting ones
        var methodCount: UInt32 = 0
        if let methods = class_copyMethodList(cls, &methodCount) {
            var interesting: [String] = []
            for i in 0..<Int(methodCount) {
                let name = NSStringFromSelector(method_getName(methods[i]))
                if name.contains("material") || name.contains("backdrop") ||
                   name.contains("description") || name.contains("recipe") ||
                   name.contains("init") || name.contains("filter") ||
                   name.contains("effect") || name.contains("apply") ||
                   name.contains("styling") || name.contains("layer") ||
                   name.contains("config") || name.contains("capture") {
                    interesting.append(name)
                }
            }
            if !interesting.isEmpty {
                p("\(indent)methods: \(interesting)")
            }
            free(methods)
        }

        // Properties
        var propCount: UInt32 = 0
        if let props = class_copyPropertyList(cls, &propCount) {
            var propNames: [String] = []
            for i in 0..<Int(propCount) {
                propNames.append(String(cString: property_getName(props[i])))
            }
            if !propNames.isEmpty {
                p("\(indent)props: \(propNames)")
            }
            free(props)
        }
    }

    private static func dumpFilterValues(_ filter: NSObject) {
        // Try common input keys
        let inputKeys = [
            "inputRadius", "inputAmount", "inputValues",
            "inputColor", "inputColorMatrix", "inputScale",
            "inputBias", "inputIntensity", "inputQuality",
        ]
        for key in inputKeys {
            if filter.responds(to: NSSelectorFromString(key)) {
                let val = filter.value(forKey: key)
                p("      \(key) = \(String(describing: val))")
            }
        }
    }
}
