//
// Full Telegram contest winner glass: portal + mesh + chroma split + overlays.
// Zero-capture approach — everything compositor-side.
//

import UIKit

// MARK: - Public API

enum MeshPortalTest {

    static func install(in parentView: UIView, sourceWindow: UIWindow) {
        let glassFrame = CGRect(x: 20, y: 120, width: parentView.bounds.width - 40, height: 120)
        let config = GlassConfig.regular(cornerRadius: 24, isDark: false)

        let glass = MeshGlassView(frame: glassFrame)
        parentView.addSubview(glass)
        glass.configure(sourceWindow: sourceWindow, config: config)

        print("[meshtest] Installed: \(Int(glassFrame.width))×\(Int(glassFrame.height)) grid=\(config.gridSize)")

        // Benchmark mesh generation
        let iterations = 100
        let start = CACurrentMediaTime()
        for _ in 0..<iterations {
            glass.regenerateMesh()
        }
        let elapsed = (CACurrentMediaTime() - start) * 1000
        print("[meshtest] Mesh generation: \(String(format: "%.3f", elapsed / Double(iterations)))ms (\(iterations)x)")
    }
}

// MARK: - Configuration (matching Telegram winner values)

private struct GlassConfig {
    var gridSize: Int
    var refraction: CGFloat
    var depth: CGFloat
    var cornerRadius: CGFloat

    // Chromatic aberration via separate portals
    var dispersionAmount: CGFloat // 0 = off

    // Overlays
    var overlayColor: UIColor?
    var blurIntensity: CGFloat
    var blurStyle: UIBlurEffect.Style

    // Spectral border
    var spectralBorderWidth: CGFloat
    var spectralBorderIntensity: Float

    // Subtle chroma/specular
    var chromaBiasAlpha: CGFloat
    var specularAlpha: CGFloat

    static func regular(cornerRadius: CGFloat, isDark: Bool) -> GlassConfig {
        GlassConfig(
            gridSize: 16,
            refraction: 26,
            depth: 10,
            cornerRadius: cornerRadius,
            dispersionAmount: 0, // set >0 to enable chroma split
            overlayColor: nil,  // no tint — see pure portal + refraction
            blurIntensity: 0,  // no blur — see pure refraction
            blurStyle: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight,
            spectralBorderWidth: 2,
            spectralBorderIntensity: isDark ? 0.3 : 1.0,
            chromaBiasAlpha: isDark ? 0.016 : 0.014,
            specularAlpha: isDark ? 0.004 : 0.016
        )
    }

    static func tabbar(cornerRadius: CGFloat, isDark: Bool) -> GlassConfig {
        GlassConfig(
            gridSize: 20,
            refraction: 32,
            depth: 14,
            cornerRadius: cornerRadius,
            dispersionAmount: 0,
            overlayColor: isDark
                ? UIColor(white: 26.0/255, alpha: 0.6)
                : UIColor(white: 250.0/255, alpha: 0.79),
            blurIntensity: isDark ? 0.11 : 0.1,
            blurStyle: isDark ? .systemChromeMaterialDark : .systemChromeMaterialLight,
            spectralBorderWidth: 2,
            spectralBorderIntensity: isDark ? 0.15 : 1.0,
            chromaBiasAlpha: isDark ? 0.016 : 0.014,
            specularAlpha: isDark ? 0.004 : 0.016
        )
    }

    static func withChroma(cornerRadius: CGFloat, isDark: Bool) -> GlassConfig {
        var c = regular(cornerRadius: cornerRadius, isDark: isDark)
        c.dispersionAmount = 100
        c.gridSize = 20
        return c
    }
}

// MARK: - MeshGlassView

private class MeshGlassView: UIView {

    private var config: GlassConfig?
    private weak var sourceWindow: UIWindow?

    // Layer hierarchy
    private let clippingView = UIView()
    private let clippingMask = CAShapeLayer()
    private let rootContainer = UIView()

    // Portals
    private var mainPortal: UIView?
    private var warmPortal: UIView?    // red channel (chroma)
    private var coldPortal: UIView?    // blue channel (chroma)
    private let chromaContainer = UIView()

    // Overlays
    private var tintView: UIView?
    private var frostView: LowIntensityBlur?
    private var chromaBiasView: UIView?
    private var specularView: UIView?
    private var spectralBorderView: UIView?

    override init(frame: CGRect) {
        super.init(frame: frame)

        clippingMask.fillColor = UIColor.black.cgColor
        clippingView.layer.mask = clippingMask
        clippingView.addSubview(rootContainer)
        addSubview(clippingView)
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(sourceWindow: UIWindow, config: GlassConfig) {
        self.sourceWindow = sourceWindow
        self.config = config

        let size = bounds.size
        let b = CGRect(origin: .zero, size: size)

        clippingView.frame = b
        rootContainer.frame = b

        // ── Main portal ──
        if mainPortal == nil {
            mainPortal = makePortal(source: sourceWindow)
            rootContainer.addSubview(mainPortal!)
        }
        mainPortal?.frame = b

        // ── Chromatic aberration (3 portals) ──
        if config.dispersionAmount > 0 {
            if warmPortal == nil {
                warmPortal = makePortal(source: sourceWindow)
                applyColorFilter(to: warmPortal!, warm: true, isDark: config.overlayColor != nil)
                warmPortal!.layer.compositingFilter = "screen"
                warmPortal!.alpha = 0.3
                chromaContainer.addSubview(warmPortal!)
            }
            if coldPortal == nil {
                coldPortal = makePortal(source: sourceWindow)
                applyColorFilter(to: coldPortal!, warm: false, isDark: config.overlayColor != nil)
                coldPortal!.layer.compositingFilter = "screen"
                coldPortal!.alpha = 0.3
                chromaContainer.addSubview(coldPortal!)
            }
            if chromaContainer.superview == nil {
                rootContainer.insertSubview(chromaContainer, belowSubview: mainPortal!)
            }
            chromaContainer.frame = b
            warmPortal?.frame = b
            coldPortal?.frame = b
        }

        // ── Overlay tint ──
        if let color = config.overlayColor {
            if tintView == nil {
                tintView = UIView()
                clippingView.addSubview(tintView!)
            }
            tintView!.frame = b
            tintView!.backgroundColor = color
        }

        // ── Frost (low-intensity blur) ──
        if config.blurIntensity > 0 {
            if frostView == nil {
                frostView = LowIntensityBlur(
                    effect: UIBlurEffect(style: config.blurStyle),
                    intensity: config.blurIntensity
                )
                clippingView.addSubview(frostView!)
            }
            frostView!.frame = b
        }

        // ── Chroma bias (subtle color dodge) ──
        if config.chromaBiasAlpha > 0 {
            if chromaBiasView == nil {
                chromaBiasView = UIView()
                chromaBiasView!.layer.compositingFilter = "colorDodgeBlendMode"
                clippingView.addSubview(chromaBiasView!)
            }
            chromaBiasView!.frame = b
            chromaBiasView!.backgroundColor = UIColor(white: 1, alpha: config.chromaBiasAlpha)
        }

        // ── Specular (subtle screen blend) ──
        if config.specularAlpha > 0 {
            if specularView == nil {
                specularView = UIView()
                specularView!.layer.compositingFilter = "screenBlendMode"
                clippingView.addSubview(specularView!)
            }
            specularView!.frame = b
            specularView!.backgroundColor = UIColor(white: 1, alpha: config.specularAlpha)
        }

        // ── Spectral border (edge highlight gradient) ──
        if config.spectralBorderWidth > 0 {
            if spectralBorderView == nil {
                let container = UIView(frame: b)
                let gradient = CAGradientLayer()
                gradient.frame = b
                gradient.startPoint = CGPoint(x: 1.06, y: 1.06)
                gradient.endPoint = CGPoint(x: -0.06, y: -0.06)
                gradient.colors = [1.0, 0.8, 0.0, 0.6, 0.8].map {
                    UIColor.white.withAlphaComponent(CGFloat($0)).cgColor
                }
                gradient.locations = [0.0, 0.35, 0.5, 0.7, 1.0]
                gradient.opacity = config.spectralBorderIntensity
                gradient.compositingFilter = "screen"

                let mask = CAShapeLayer()
                mask.fillColor = nil
                mask.strokeColor = UIColor.black.cgColor
                mask.lineWidth = config.spectralBorderWidth
                mask.path = UIBezierPath(
                    roundedRect: b, cornerRadius: config.cornerRadius
                ).cgPath
                gradient.mask = mask

                container.layer.addSublayer(gradient)
                clippingView.addSubview(container)
                spectralBorderView = container
            }
        }

        // ── Clipping mask ──
        clippingMask.path = UIBezierPath(
            roundedRect: b, cornerRadius: config.cornerRadius
        ).cgPath

        // ── Apply mesh transform ──
        regenerateMesh()
    }

    func regenerateMesh() {
        guard let config, bounds.width > 0, bounds.height > 0 else { return }
        let size = bounds.size
        let sdf = computeSDF(size: size, config: config)

        applyMesh(to: mainPortal, sdf: sdf, config: config, refractionMult: 1.0, size: size)

        if config.dispersionAmount > 0 {
            let warmMult = 1.0 + config.dispersionAmount * 0.003
            let coldMult = 1.0 + config.dispersionAmount * 0.005
            applyMesh(to: warmPortal, sdf: sdf, config: config, refractionMult: warmMult, size: size)
            applyMesh(to: coldPortal, sdf: sdf, config: config, refractionMult: coldMult, size: size)
        }
    }

    // MARK: - Portal creation

    private func makePortal(source: UIWindow) -> UIView? {
        guard let cls = NSClassFromString("_UIPortalView") as? UIView.Type else { return nil }
        let portal = cls.init(frame: bounds)
        portal.setValue(source, forKey: "sourceView")
        portal.setValue(true, forKey: "matchesPosition")
        portal.setValue(true, forKey: "matchesTransform")
        portal.setValue(false, forKey: "matchesAlpha")
        portal.setValue(false, forKey: "allowsHitTesting")
        return portal
    }

    private func applyColorFilter(to view: UIView, warm: Bool, isDark: Bool) {
        guard let filterClass = NSClassFromString("CAFilter"),
              let filter = (filterClass as AnyObject)
                .perform(NSSelectorFromString("filterWithType:"), with: "colorMatrix")?
                .takeUnretainedValue() as? NSObject
        else { return }

        // CAColorMatrix: 4x5 matrix (20 floats)
        // Row order: R, G, B, A — each has 5 values (mult for RGBA + bias)
        var matrix = [Float](repeating: 0, count: 20)
        // Identity diagonal
        matrix[0] = 1; matrix[6] = 1; matrix[12] = 1; matrix[17] = 1

        if isDark {
            // Dark: warm = keep G, remove R,B. Cold: keep R,G, remove B
            if warm {
                matrix[4] = -1   // R bias
                matrix[14] = -1  // B bias
            } else {
                matrix[9] = 0    // keep
                matrix[14] = -1  // B bias
            }
        } else {
            // Light: warm = remove R, keep G,B. Cold: keep R, remove G, keep B
            if warm {
                matrix[4] = -1   // R bias
            } else {
                matrix[9] = -1   // G bias
            }
        }

        let value = NSValue(bytes: &matrix, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
        filter.setValue(value, forKey: "inputColorMatrix")
        view.layer.setValue([filter], forKey: "filters")
    }

    // MARK: - SDF

    private struct SDFData {
        let dist: [CGFloat]
        let normX: [CGFloat]
        let normY: [CGFloat]
        let cols: Int
        let rows: Int
    }

    private func computeSDF(size: CGSize, config: GlassConfig) -> SDFData {
        let cols = config.gridSize
        let rows = config.gridSize
        let gridW = cols + 1
        let gridH = rows + 1
        let count = gridW * gridH

        var dist = [CGFloat](repeating: 0, count: count)
        var normX = [CGFloat](repeating: 0, count: count)
        var normY = [CGFloat](repeating: 0, count: count)

        let halfW = size.width / 2
        let halfH = size.height / 2
        let cr = min(config.cornerRadius, min(halfW, halfH))

        // Safe zone optimization (skip interior)
        let safeMargin = config.depth + cr
        let safeMinX = safeMargin
        let safeMaxX = size.width - safeMargin
        let safeMinY = safeMargin
        let safeMaxY = size.height - safeMargin
        let hasSafe = safeMaxX > safeMinX && safeMaxY > safeMinY

        for r in 0..<gridH {
            for c in 0..<gridW {
                let px = CGFloat(c) / CGFloat(cols) * size.width
                let py = CGFloat(r) / CGFloat(rows) * size.height
                let idx = r * gridW + c

                // Safe zone — deep interior, no refraction needed
                if hasSafe && px > safeMinX && px < safeMaxX && py > safeMinY && py < safeMaxY {
                    dist[idx] = -(config.depth + 1)
                    continue
                }

                // SDF rounded rect (Telegram's exact method)
                let p = CGPoint(x: px - halfW, y: py - halfH)
                let sx: CGFloat = p.x < 0 ? -1 : 1
                let sy: CGFloat = p.y < 0 ? -1 : 1
                let ax = abs(p.x)
                let ay = abs(p.y)
                let inner = CGPoint(x: halfW - cr, y: halfH - cr)
                let qx = ax - inner.x
                let qy = ay - inner.y

                let d: CGFloat
                let lnx: CGFloat
                let lny: CGFloat

                if qx > 0 && qy > 0 {
                    let cornerLen = sqrt(qx * qx + qy * qy)
                    d = cornerLen - cr
                    lnx = cornerLen > 0 ? qx / cornerLen : 0.7071
                    lny = cornerLen > 0 ? qy / cornerLen : 0.7071
                } else if qx > qy {
                    d = qx - cr
                    lnx = 1; lny = 0
                } else {
                    d = qy - cr
                    lnx = 0; lny = 1
                }

                dist[idx] = d
                normX[idx] = lnx * sx
                normY[idx] = lny * sy
            }
        }

        return SDFData(dist: dist, normX: normX, normY: normY, cols: cols, rows: rows)
    }

    // MARK: - Mesh Transform

    private func applyMesh(to view: UIView?, sdf: SDFData, config: GlassConfig, refractionMult: CGFloat, size: CGSize) {
        guard let view else { return }

        let cols = sdf.cols
        let rows = sdf.rows
        let gridW = cols + 1
        let refraction = config.refraction * refractionMult

        let scale = UIScreen.main.scale
        view.layer.contentsScale = scale
        view.layer.rasterizationScale = scale

        // Build vertex data: 5 CGFloats per vertex (from.x, from.y, to.x, to.y, to.z)
        let vertexCount = (rows + 1) * (cols + 1)
        var vertexData = [CGFloat](repeating: 0, count: vertexCount * 5)

        for r in 0...rows {
            for c in 0...cols {
                let u = CGFloat(c) / CGFloat(cols)
                let v = CGFloat(r) / CGFloat(rows)
                let idx = r * gridW + c

                let distFromEdge = -sdf.dist[idx]
                let fromU: CGFloat
                let fromV: CGFloat

                if distFromEdge > config.depth {
                    fromU = u; fromV = v
                } else {
                    let t = distFromEdge / config.depth
                    let effect = (1 - t) * (1 - t)
                    let offsetPx = refraction * effect
                    fromU = u - (sdf.normX[idx] * offsetPx) / size.width
                    fromV = v - (sdf.normY[idx] * offsetPx) / size.height
                }

                let base = idx * 5
                vertexData[base] = fromU
                vertexData[base + 1] = fromV
                vertexData[base + 2] = u
                vertexData[base + 3] = v
                vertexData[base + 4] = 0
            }
        }

        // Build face data: 4 uint32 indices + 4 float weights = 32 bytes per face
        let faceCount = rows * cols
        var faceData = [(UInt32, UInt32, UInt32, UInt32, Float, Float, Float, Float)]()
        faceData.reserveCapacity(faceCount)

        for r in 0..<rows {
            for c in 0..<cols {
                let i0 = UInt32(r * gridW + c)
                let i1 = i0 + 1
                let i2 = UInt32((r + 1) * gridW + c + 1)
                let i3 = i2 - 1
                faceData.append((i0, i1, i2, i3, 0, 0, 0, 0))
            }
        }

        // Create CAMeshTransform via runtime
        guard let meshClass = NSClassFromString("CAMeshTransform") else { return }
        let sel = NSSelectorFromString("meshTransformWithVertexCount:vertices:faceCount:faces:depthNormalization:")
        guard meshClass.responds(to: sel) else { return }

        let transform = vertexData.withUnsafeBufferPointer { vBuf in
            faceData.withUnsafeBufferPointer { fBuf in
                typealias Fn = @convention(c) (
                    AnyClass, Selector,
                    UInt, UnsafeRawPointer,
                    UInt, UnsafeRawPointer,
                    NSString
                ) -> AnyObject?

                let fn = unsafeBitCast(
                    (meshClass as AnyObject).method(for: sel), to: Fn.self
                )
                return fn(
                    meshClass, sel,
                    UInt(vertexCount), vBuf.baseAddress!,
                    UInt(faceCount), fBuf.baseAddress!,
                    "kCAMeshTransformDepthNormalizationNone" as NSString
                )
            }
        }

        if let transform {
            view.layer.setValue(transform, forKey: "meshTransform")
        }
    }
}

// MARK: - Low-intensity blur

private class LowIntensityBlur: UIVisualEffectView {
    private var animator: UIViewPropertyAnimator?

    init(effect: UIVisualEffect, intensity: CGFloat) {
        super.init(effect: nil)
        let anim = UIViewPropertyAnimator(duration: 1, curve: .linear) {
            self.effect = effect
        }
        anim.fractionComplete = intensity
        anim.pausesOnCompletion = true
        animator = anim
    }

    required init?(coder: NSCoder) { fatalError() }
    deinit { animator?.stopAnimation(true) }
}
