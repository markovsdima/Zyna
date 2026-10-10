//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Easing shared by Core Animation, UIKit, and capture geometry.
enum GlassAnimationCurve {
    case easeOut
    case easeInOut

    var timingFunction: CAMediaTimingFunction {
        CAMediaTimingFunction(name: self == .easeOut ? .easeOut : .easeInEaseOut)
    }

    var animationOptions: UIView.AnimationOptions {
        self == .easeOut ? .curveEaseOut : .curveEaseInOut
    }

    func value(at progress: Double) -> CGFloat {
        guard progress > 0 else { return 0 }
        guard progress < 1 else { return 1 }
        let x1 = self == .easeOut ? 0.0 : 0.42
        let x2 = 0.58
        var low = 0.0
        var high = 1.0
        for _ in 0..<18 {
            let t = (low + high) * 0.5
            let s = 1 - t
            let x = 3 * s * s * t * x1 + 3 * s * t * t * x2 + t * t * t
            if x < progress { low = t } else { high = t }
        }
        let t = (low + high) * 0.5
        return CGFloat(3 * (1 - t) * t * t + t * t * t)
    }
}
