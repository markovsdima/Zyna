//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class WaveformNode: ASDisplayNode {

    // MARK: - Draw Parameters

    final class DrawParams: NSObject {
        let samples: [UInt16]
        let progress: Float
        let filledColor: UIColor
        let unfilledColor: UIColor
        let barWidth: CGFloat
        let barSpacing: CGFloat
        let cornerRadius: CGFloat

        init(samples: [UInt16], progress: Float, filledColor: UIColor, unfilledColor: UIColor,
             barWidth: CGFloat, barSpacing: CGFloat, cornerRadius: CGFloat) {
            self.samples = samples
            self.progress = progress
            self.filledColor = filledColor
            self.unfilledColor = unfilledColor
            self.barWidth = barWidth
            self.barSpacing = barSpacing
            self.cornerRadius = cornerRadius
        }
    }

    // MARK: - State

    private var samples: [UInt16]
    private var progress: Float = 0
    private let filledColor: UIColor
    private let unfilledColor: UIColor

    // MARK: - Constants

    private static let barWidth: CGFloat = 3
    private static let barSpacing: CGFloat = 2
    private static let cornerRadius: CGFloat = 1.5

    // MARK: - Init

    init(samples: [UInt16], filledColor: UIColor, unfilledColor: UIColor) {
        self.samples = samples
        self.filledColor = filledColor
        self.unfilledColor = unfilledColor
        super.init()
        isOpaque = false
    }

    // MARK: - Public

    func updateProgress(_ progress: Float) {
        guard self.progress != progress else { return }
        self.progress = progress
        setNeedsDisplay()
    }

    // MARK: - Drawing

    override func drawParameters(forAsyncLayer layer: _ASDisplayLayer) -> NSObjectProtocol? {
        DrawParams(
            samples: samples,
            progress: progress,
            filledColor: filledColor,
            unfilledColor: unfilledColor,
            barWidth: Self.barWidth,
            barSpacing: Self.barSpacing,
            cornerRadius: Self.cornerRadius
        )
    }

    override class func draw(_ bounds: CGRect, withParameters parameters: Any?,
                              isCancelled isCancelledBlock: () -> Bool, isRasterizing: Bool) {
        if isCancelledBlock() { return }
        guard let params = parameters as? DrawParams,
              let ctx = UIGraphicsGetCurrentContext(),
              !params.samples.isEmpty else { return }

        let barCount = params.samples.count
        let filledCount = Int(params.progress * Float(barCount))

        for i in 0..<barCount {
            if isCancelledBlock() { return }

            let height = max(3, CGFloat(params.samples[i]) / 1024.0 * bounds.height)
            let x = CGFloat(i) * (params.barWidth + params.barSpacing)
            let y = (bounds.height - height) / 2
            let rect = CGRect(x: x, y: y, width: params.barWidth, height: height)

            let color = i < filledCount ? params.filledColor : params.unfilledColor
            ctx.setFillColor(color.cgColor)

            let path = UIBezierPath(roundedRect: rect, cornerRadius: params.cornerRadius)
            ctx.addPath(path.cgPath)
            ctx.fillPath()
        }
    }

    // MARK: - Sizing

    static func size(for barCount: Int) -> CGSize {
        let width = CGFloat(barCount) * (barWidth + barSpacing) - barSpacing
        return CGSize(width: width, height: 20)
    }
}
