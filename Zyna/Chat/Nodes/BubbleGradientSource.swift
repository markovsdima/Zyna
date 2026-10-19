//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

class PortalSourceView: UIView {

    private final class PortalReference {
        weak var portal: PortalView?

        init(portal: PortalView) {
            self.portal = portal
        }
    }

    private var portalReferences: [PortalReference] = []

    func addPortal(_ portal: PortalView) {
        compactPortalReferences()
        guard !portalReferences.contains(where: { $0.portal === portal }) else {
            portal.sourceView = self
            return
        }
        portalReferences.append(PortalReference(portal: portal))
        portal.sourceView = self
    }

    func removePortal(_ portal: PortalView) {
        compactPortalReferences()
        portalReferences.removeAll { $0.portal === portal }
        if portal.sourceView === self {
            portal.sourceView = nil
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        requestPortalReload()
    }

    func requestPortalReload() {
        compactPortalReferences()
        guard window != nil else { return }
        for reference in portalReferences {
            guard let portal = reference.portal else { continue }
            portal.sourceView = self
        }
    }

    private func compactPortalReferences() {
        portalReferences.removeAll { $0.portal == nil }
    }
}

final class BubbleGradientCanvasView: UIView {

    // Keep the original path available for device A/B measurements.
#if DEBUG
    static let captureImageCacheEnabled = ProcessInfo.processInfo.environment["GLASS_GRADIENT_CACHE"] != "0"
#else
    static let captureImageCacheEnabled = true
#endif

    private struct CaptureImage {
        let bounds: CGRect
        let scale: CGFloat
        let image: CGImage
    }

    private let gradientLayer = CAGradientLayer()
    private let colorProvider: (UITraitCollection) -> [UIColor]
    private var captureImage: CaptureImage?

    init(
        colorProvider: @escaping (UITraitCollection) -> [UIColor],
        start: CGPoint,
        end: CGPoint
    ) {
        self.colorProvider = colorProvider
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        gradientLayer.startPoint = start
        gradientLayer.endPoint = end
        layer.addSublayer(gradientLayer)
        updateGradientColors()
        NotificationCenter.default.addObserver(
            self, selector: #selector(clearCaptureImage),
            name: UIApplication.didReceiveMemoryWarningNotification, object: nil
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if gradientLayer.frame != bounds {
            gradientLayer.frame = bounds
            clearCaptureImage()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { clearCaptureImage() }
    }

    @objc private func clearCaptureImage() {
        captureImage = nil
    }

    /// Rasterize only settled local content. Ancestor motion is applied by
    /// the capture renderer, so scrolling/shrink do not invalidate the image.
    /// Return nil while presentation colors or geometry differ from model.
    func imageForCapture(
        of sourceLayer: CALayer, scale requestedScale: CGFloat,
        colorSpace: CGColorSpace = CGColorSpaceCreateDeviceRGB()
    ) -> CGImage? {
        guard Self.captureImageCacheEnabled,
              sourceLayer.model() === layer, sourceLayer.bounds == bounds,
              !bounds.isEmpty, requestedScale.isFinite, requestedScale > 0,
              colorSpace.model == .rgb,
              layer.animationKeys()?.isEmpty != false,
              gradientLayer.animationKeys()?.isEmpty != false else { return nil }

        if sourceLayer !== layer {
            guard let presentedGradient = sourceLayer.sublayers?.first as? CAGradientLayer,
                  presentedGradient.frame == gradientLayer.frame,
                  (presentedGradient.colors as NSArray?) == (gradientLayer.colors as NSArray?),
                  presentedGradient.locations == gradientLayer.locations else { return nil }
        }

        // Integral scales avoid rebuilds from floating-point noise in the
        // affine projection. Reuse a sharper image for lower-resolution work.
        let scale = max(1, ceil(requestedScale - 0.001))
        // CA interpolates stops in the destination color space. Reusing a
        // P3 raster in the glass's RGB context would change the gradient.
        if let captureImage, captureImage.bounds == bounds, captureImage.scale >= scale,
           let cachedSpace = captureImage.image.colorSpace, CFEqual(cachedSpace, colorSpace) {
            return captureImage.image
        }
        // Bound raster area (~32 MiB of RGBA pixels per source).
        let pixels = ceil(bounds.width * scale) * ceil(bounds.height * scale)
        guard pixels.isFinite, pixels <= 8_388_608 else { return nil }

#if DEBUG && GLASS_PROFILING
        let cacheStart = GlassCaptureProfiler.shared.captureTimer()
        defer { GlassCaptureProfiler.shared.endCacheBuild(since: cacheStart) }
#endif
        guard let context = CGContext(
            data: nil, width: Int(ceil(bounds.width * scale)), height: Int(ceil(bounds.height * scale)),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.translateBy(x: 0, y: CGFloat(context.height))
        context.scaleBy(x: scale, y: -scale)
        context.translateBy(x: -bounds.minX, y: -bounds.minY)
        layer.render(in: context)
        guard let cgImage = context.makeImage() else { return nil }
        captureImage = CaptureImage(bounds: bounds, scale: scale, image: cgImage)
        return cgImage
    }

    func drawCaptureImage(of sourceLayer: CALayer, in context: CGContext) -> Bool {
        let transform = context.ctm
        let scale = max(hypot(transform.a, transform.b), hypot(transform.c, transform.d))
        guard let colorSpace = context.colorSpace,
              let image = imageForCapture(of: sourceLayer, scale: scale, colorSpace: colorSpace) else { return false }
        context.saveGState()
        // CGImage drawing is Y-up; the cached image uses UIKit's Y-down
        // coordinates. Preserve the source bounds origin as well as its size.
        context.translateBy(x: sourceLayer.bounds.minX, y: sourceLayer.bounds.maxY)
        context.scaleBy(x: 1, y: -1)
        context.draw(image, in: CGRect(origin: .zero, size: sourceLayer.bounds.size))
        context.restoreGState()
        return true
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        updateGradientColors()
    }

    private func updateGradientColors() {
        let colors = colorProvider(traitCollection)
        gradientLayer.colors = colors.map {
            $0.resolvedColor(with: traitCollection).cgColor
        }
        gradientLayer.locations = BubbleGradientStops.layerLocations(for: colors.count)
        clearCaptureImage()
    }
}

/// Shared per-role source host. The portal mirrors this host, not the
/// gradient view directly. That keeps source/content concerns separate
/// from portal delivery and matches Telegram's `PortalSourceView` model.
final class BubbleGradientSource: PortalSourceView {

    private let gradientView: BubbleGradientCanvasView

    init(
        colorProvider: @escaping (UITraitCollection) -> [UIColor],
        start: CGPoint = CGPoint(x: 0.0, y: 0.0),
        end: CGPoint = CGPoint(x: 1.0, y: 1.0)
    ) {
        self.gradientView = BubbleGradientCanvasView(
            colorProvider: colorProvider,
            start: start,
            end: end
        )
        super.init(frame: .zero)
        alpha = 0.0
        backgroundColor = .clear
        isUserInteractionEnabled = false
        addSubview(gradientView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) not supported")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        gradientView.frame = bounds
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        requestPortalReload()
    }
}

private struct BubbleRGBA {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat
}

private extension UIColor {
    func resolvedRGBA(with traits: UITraitCollection) -> BubbleRGBA {
        let resolved = resolvedColor(with: traits)
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return BubbleRGBA(red: red, green: green, blue: blue, alpha: alpha)
        }
        var white: CGFloat = 0
        if resolved.getWhite(&white, alpha: &alpha) {
            return BubbleRGBA(red: white, green: white, blue: white, alpha: alpha)
        }
        return BubbleRGBA(red: 0, green: 0, blue: 0, alpha: 1)
    }
}

enum BubbleGradientRole: CaseIterable, Hashable {
    case incoming
    case outgoing

    func colors(traits: UITraitCollection, outgoingTheme: ChatBubbleTheme) -> [UIColor] {
        switch self {
        case .outgoing:
            return outgoingTheme.outgoingGradientColors
        case .incoming:
            let surface = AppColor.bubbleBackgroundIncoming.resolvedColor(with: traits)
            let isDark = traits.userInterfaceStyle == .dark
            return [
                Self.mix(surface, with: UIColor.white, ratio: isDark ? 0.10 : 0.18, traits: traits),
                surface,
                Self.mix(surface, with: UIColor.black, ratio: isDark ? 0.18 : 0.08, traits: traits)
            ]
        }
    }

    private static func mix(_ color: UIColor, with other: UIColor, ratio: CGFloat, traits: UITraitCollection) -> UIColor {
        let clampedRatio = max(0, min(1, ratio))
        let base = color.resolvedRGBA(with: traits)
        let target = other.resolvedRGBA(with: traits)
        let inverse = 1 - clampedRatio
        return UIColor(
            red: base.red * inverse + target.red * clampedRatio,
            green: base.green * inverse + target.green * clampedRatio,
            blue: base.blue * inverse + target.blue * clampedRatio,
            alpha: base.alpha * inverse + target.alpha * clampedRatio
        )
    }
}
