//
// 3D ray-traced glass test — physically correct refraction through a glass volume.
// Different geometries: flat glass, convex lens, concave lens, prism, water drop.
//

import UIKit
import Metal
import QuartzCore

// MARK: - Glass Geometry Presets

enum Glass3DGeometry: String, CaseIterable {
    case flat       = "Flat Glass"
    case convexLens = "Convex Lens"
    case concaveLens = "Concave Lens"
    case planoConvex = "Plano-Convex"
    case waterDrop  = "Water Drop"
    case thickSlab  = "Thick Slab"
    case diamond    = "Diamond"

    var ior: Float {
        switch self {
        case .flat, .convexLens, .concaveLens, .planoConvex, .thickSlab: return 1.5
        case .waterDrop: return 1.33
        case .diamond: return 2.42
        }
    }

    var thickness: Float {
        switch self {
        case .flat: return 0.02
        case .convexLens: return 0.08
        case .concaveLens: return 0.06
        case .planoConvex: return 0.06
        case .waterDrop: return 0.12
        case .thickSlab: return 0.15
        case .diamond: return 0.10
        }
    }

    var curvatureTop: Float {
        switch self {
        case .flat, .thickSlab: return 0.0
        case .convexLens: return 1.0
        case .concaveLens: return -0.5
        case .planoConvex: return 0.8
        case .waterDrop: return 1.5
        case .diamond: return 0.3
        }
    }

    var curvatureBottom: Float {
        switch self {
        case .flat, .planoConvex, .thickSlab: return 0.0
        case .convexLens: return 1.0
        case .concaveLens: return -0.5
        case .waterDrop: return 0.5
        case .diamond: return 0.3
        }
    }

    var edgeRound: Float {
        switch self {
        case .flat: return 0.05
        case .convexLens, .concaveLens: return 0.3
        case .planoConvex: return 0.2
        case .waterDrop: return 0.6
        case .thickSlab: return 0.1
        case .diamond: return 0.15
        }
    }

    var chromaticSpread: Float {
        switch self {
        case .flat: return 0.05
        case .convexLens, .concaveLens, .planoConvex: return 0.08
        case .waterDrop: return 0.03
        case .thickSlab: return 0.06
        case .diamond: return 0.15   // diamond has high dispersion
        }
    }
}

// MARK: - Uniforms (must match Metal struct layout)

struct Glass3DUniforms {
    var resolution: SIMD2<Float> = .zero
    var aspect: Float = 1
    var shapeRect: SIMD4<Float> = .zero
    var cornerRadius: Float = 0
    var ior: Float = 1.5
    var thickness: Float = 0.05
    var curvatureTop: Float = 0
    var curvatureBottom: Float = 0
    var edgeRound: Float = 0.2
    var chromaticSpread: Float = 0.08
    var tintStrength: Float = 0.3
    var tintGray: Float = 0.4
    var fresnelPow: Float = 3.0
    var time: Float = 0
}

// MARK: - Glass3DTestView

/// Self-contained test view: captures background via layer.render, renders 3D glass via Metal.
final class Glass3DTestView: UIView {

    private let metalLayer = CAMetalLayer()
    private var pipeline: MTLRenderPipelineState?
    private var bgTexture: MTLTexture?
    private var bgTextureSize: (Int, Int) = (0, 0)

    var geometry: Glass3DGeometry = .convexLens {
        didSet { setNeedsDisplay() }
    }

    var cornerR: CGFloat = 24

    private weak var sourceWindow: UIWindow?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        let device = MetalContext.shared.device
        metalLayer.device = device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.contentsScale = UIScreen.main.scale
        layer.addSublayer(metalLayer)

        // Build pipeline
        let lib = MetalContext.shared.library
        guard let vert = lib.makeFunction(name: "glass3DVertex"),
              let frag = lib.makeFunction(name: "glass3DFragment") else {
            print("[glass3d] shader functions not found")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vert
        desc.fragmentFunction = frag
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled = true
        desc.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        desc.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha

        pipeline = try? device.makeRenderPipelineState(descriptor: desc)
    }

    private var displayLink: CADisplayLink?

    func configure(sourceWindow: UIWindow) {
        self.sourceWindow = sourceWindow
        let link = CADisplayLink(target: self, selector: #selector(displayLinkFired))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func displayLinkFired() {
        render()
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSublayers(of layer: CALayer) {
        super.layoutSublayers(of: layer)
        metalLayer.frame = bounds
        metalLayer.drawableSize = CGSize(
            width: bounds.width * metalLayer.contentsScale,
            height: bounds.height * metalLayer.contentsScale
        )
    }

    func render() {
        guard let sourceWindow, let pipeline,
              bounds.width > 0, bounds.height > 0 else { return }

        // ── Capture background ──
        // Capture exactly the glass rect — no padding needed.
        // Refraction reads beyond glass edge, but clamp_to_edge handles border pixels.
        let scale = sourceWindow.screen.scale
        let captureFrame = sourceWindow.convert(bounds, from: self)

        let w = Int(captureFrame.width * scale)
        let h = Int(captureFrame.height * scale)
        guard w > 0, h > 0 else { return }

        let bytesPerRow = w * 4
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        ctx.translateBy(x: -captureFrame.origin.x * scale, y: (captureFrame.origin.y + captureFrame.height) * scale)
        ctx.scaleBy(x: scale, y: -scale)
        let srcLayer = sourceWindow.layer.presentation() ?? sourceWindow.layer
        srcLayer.render(in: ctx)

        guard let data = ctx.data else { return }

        // Reuse texture
        let device = MetalContext.shared.device
        if w != bgTextureSize.0 || h != bgTextureSize.1 {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: w, height: h, mipmapped: false
            )
            desc.usage = .shaderRead
            desc.storageMode = .shared
            bgTexture = device.makeTexture(descriptor: desc)
            bgTextureSize = (w, h)
        }
        bgTexture?.replace(
            region: MTLRegionMake2D(0, 0, w, h),
            mipmapLevel: 0, withBytes: data, bytesPerRow: bytesPerRow
        )

        guard let bgTex = bgTexture,
              let drawable = metalLayer.nextDrawable(),
              let cmdBuf = MetalContext.shared.commandQueue.makeCommandBuffer()
        else { return }

        // ── Build uniforms ──
        let geo = geometry
        let drawW = Float(metalLayer.drawableSize.width)
        let drawH = Float(metalLayer.drawableSize.height)

        // Glass = full drawable. UV space = texture space = 1:1.
        let glassInCapture = CGRect(x: 0, y: 0, width: 1, height: 1)

        var uniforms = Glass3DUniforms()
        uniforms.resolution = SIMD2<Float>(drawW, drawH)
        uniforms.aspect = drawW / drawH
        uniforms.shapeRect = SIMD4<Float>(
            Float(glassInCapture.origin.x),
            Float(glassInCapture.origin.y),
            Float(glassInCapture.width),
            Float(glassInCapture.height)
        )
        uniforms.cornerRadius = Float(cornerR * scale) / Float(h)
        uniforms.ior = geo.ior
        uniforms.thickness = geo.thickness
        uniforms.curvatureTop = geo.curvatureTop
        uniforms.curvatureBottom = geo.curvatureBottom
        uniforms.edgeRound = geo.edgeRound
        uniforms.chromaticSpread = geo.chromaticSpread
        uniforms.tintStrength = 0.3
        uniforms.tintGray = 0.38
        uniforms.fresnelPow = 3.0
        uniforms.time = Float(CACurrentMediaTime())

        // ── Render ──
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0)

        guard let enc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentBytes(&uniforms, length: MemoryLayout<Glass3DUniforms>.stride, index: 0)
        enc.setFragmentTexture(bgTex, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        enc.endEncoding()

        cmdBuf.present(drawable)
        cmdBuf.commit()
    }
}

// MARK: - Test Installer

enum Glass3DTest {

    static func install(in parentView: UIView, sourceWindow: UIWindow) -> Glass3DTestView {
        let glassFrame = CGRect(x: 20, y: 120, width: parentView.bounds.width - 40, height: 140)

        let glass = Glass3DTestView(frame: glassFrame)
        glass.configure(sourceWindow: sourceWindow)
        glass.geometry = .convexLens
        glass.layer.cornerRadius = 24
        glass.clipsToBounds = true
        parentView.addSubview(glass)


        // Add a cycle button to switch geometries
        let cycleBtn = UIButton(type: .system)
        cycleBtn.setTitle("Lens ▸", for: .normal)
        cycleBtn.titleLabel?.font = .systemFont(ofSize: 13, weight: .medium)
        cycleBtn.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        cycleBtn.setTitleColor(.white, for: .normal)
        cycleBtn.layer.cornerRadius = 14
        cycleBtn.frame = CGRect(x: glassFrame.maxX - 90, y: glassFrame.maxY + 8, width: 80, height: 28)

        var geoIndex = 1 // start at convexLens
        let allGeos = Glass3DGeometry.allCases
        cycleBtn.addAction(UIAction { _ in
            geoIndex = (geoIndex + 1) % allGeos.count
            glass.geometry = allGeos[geoIndex]
            cycleBtn.setTitle("\(allGeos[geoIndex].rawValue) ▸", for: .normal)
            glass.render()
        }, for: .touchUpInside)

        parentView.addSubview(cycleBtn)

        print("[glass3d] Installed: \(glass.geometry.rawValue), IOR=\(glass.geometry.ior)")
        return glass
    }
}
