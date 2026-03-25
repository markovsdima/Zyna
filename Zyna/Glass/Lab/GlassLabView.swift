//
// Drop-in test bench for glass capture experiments.
//
// Usage:
//     let lab = GlassLabView()
//     window.addSubview(lab)
//     lab.show(in: window)
//
// Tap the method label to cycle: IOSurface → layer.render → full-window → Portal.
// Console shows [glass-lab] capture timing per method.
//

import UIKit
import Metal
import MetalPerformanceShaders

/// Self-contained glass test rect with switchable capture backend.
/// Add to any window to compare capture methods side-by-side with timing.
final class GlassLabView: UIView {

    private let captureManager = ScreenCaptureManager()
    private let renderer = GlassRenderer()
    private let methodLabel = UILabel()
    private var displayLinkToken: DisplayLinkToken?
    private weak var sourceWindow: UIWindow?

    // Timing
    private var tickCount = 0
    private var totalCapture: Double = 0
    private var totalRender: Double = 0
    private var statsTimestamp: CFTimeInterval = 0

    // Glass rect: centered, 300x200pt
    private let glassSize = CGSize(width: 300, height: 200)

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = true

        methodLabel.textColor = .white
        methodLabel.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
        methodLabel.textAlignment = .center
        methodLabel.backgroundColor = UIColor.black.withAlphaComponent(0.6)
        methodLabel.layer.cornerRadius = 8
        methodLabel.clipsToBounds = true
        addSubview(methodLabel)

        updateLabel()

        let tap = UITapGestureRecognizer(target: self, action: #selector(cycleMethod))
        methodLabel.isUserInteractionEnabled = true
        methodLabel.addGestureRecognizer(tap)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Show the lab view in the given window.
    func show(in window: UIWindow) {
        sourceWindow = window
        frame = window.bounds
        autoresizingMask = [.flexibleWidth, .flexibleHeight]

        // Renderer sits inside us
        let center = CGPoint(x: bounds.midX - glassSize.width / 2,
                             y: bounds.midY - glassSize.height / 2)
        renderer.frame = CGRect(origin: center, size: glassSize)
        addSubview(renderer)

        // Label below glass
        methodLabel.frame = CGRect(x: bounds.midX - 120, y: renderer.frame.maxY + 12, width: 240, height: 32)

        window.addSubview(self)
        startLoop()
    }

    /// Remove from window and stop rendering.
    func dismiss() {
        displayLinkToken?.invalidate()
        displayLinkToken = nil
        removeFromSuperview()
    }

    @objc private func cycleMethod() {
        let all = CaptureMethod.allCases
        let idx = all.firstIndex(of: captureManager.method) ?? 0
        captureManager.method = all[(idx + 1) % all.count]
        updateLabel()
        // Reset stats
        tickCount = 0
        totalCapture = 0
        totalRender = 0
        statsTimestamp = CACurrentMediaTime()
        print("[glass-lab] switched to \(captureManager.method)")
    }

    private func updateLabel() {
        methodLabel.text = "  \(captureManager.method)  "
    }

    private func startLoop() {
        statsTimestamp = CACurrentMediaTime()
        displayLinkToken = DisplayLinkDriver.shared.subscribe(rate: .fps(120)) { [weak self] _ in
            self?.tick()
        }
    }

    private func tick() {
        guard let window = sourceWindow else { return }

        let scale = window.screen.scale
        let glassFrame = renderer.frame

        // Capture frame with padding
        let padding: CGFloat = 20
        let captureFrame = CGRect(
            x: max(glassFrame.origin.x - padding, 0),
            y: max(glassFrame.origin.y - padding, 0),
            width: min(glassFrame.width + padding * 2, window.bounds.width),
            height: min(glassFrame.height + padding * 2, window.bounds.height)
        )

        // Hide ourselves during capture so we don't capture the glass rect
        renderer.isHidden = true
        methodLabel.isHidden = true

        let capStart = CACurrentMediaTime()
        let texture = captureManager.capture(frame: captureFrame, from: window)
        let capTime = CACurrentMediaTime() - capStart

        renderer.isHidden = false
        methodLabel.isHidden = false

        guard let tex = texture else { return }

        var shapes = GlassRenderer.ShapeParams()
        shapes.shape0 = SIMD4<Float>(
            Float((glassFrame.origin.x - captureFrame.origin.x) / captureFrame.width),
            Float((glassFrame.origin.y - captureFrame.origin.y) / captureFrame.height),
            Float(glassFrame.width / captureFrame.width),
            Float(glassFrame.height / captureFrame.height)
        )
        shapes.shape0cornerR = Float(20 * scale) / Float(captureFrame.height * scale)
        shapes.shapeCount = 1

        renderer.frame = captureFrame
        renderer.contentScaleFactor = scale

        let renStart = CACurrentMediaTime()
        renderer.render(with: tex, shapes: shapes, isHDR: tex.pixelFormat == .bgr10a2Unorm)
        let renTime = CACurrentMediaTime() - renStart

        tickCount += 1
        totalCapture += capTime
        totalRender += renTime

        let now = CACurrentMediaTime()
        if now - statsTimestamp >= 1.0 {
            let n = Double(tickCount)
            let capAvg = totalCapture / n * 1000
            let renAvg = totalRender / n * 1000
            print("[glass-lab] [\(captureManager.method)] active=\(tickCount) capture=\(String(format: "%.2f", capAvg))ms render=\(String(format: "%.2f", renAvg))ms total=\(String(format: "%.2f", capAvg + renAvg))ms")
            tickCount = 0
            totalCapture = 0
            totalRender = 0
            statsTimestamp = now
        }
    }
}
