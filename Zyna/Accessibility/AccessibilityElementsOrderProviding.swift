//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

/// Implemented by composite controls that need a stable VoiceOver order
/// for their internal elements.
protocol AccessibilityElementsOrderProviding {
    var accessibilityElementsInOrder: [Any] { get }
}

enum AccessibilityElementOrder {
    private static let visibleAlphaThreshold: CGFloat = 0.01

    static func appendVisibleView(_ view: UIView?, to elements: inout [Any]) {
        guard let view,
              view.superview != nil,
              !view.isHidden,
              view.alpha > visibleAlphaThreshold else {
            return
        }
        elements.append(view)
    }

    static func appendElement(_ element: Any?, to elements: inout [Any]) {
        guard let element else { return }
        if let view = element as? UIView {
            appendVisibleView(view, to: &elements)
        } else {
            elements.append(element)
        }
    }

    static func appendProvider(
        _ provider: AccessibilityElementsOrderProviding?,
        fallbackView: @autoclosure () -> UIView? = nil,
        to elements: inout [Any]
    ) {
        guard let provider else {
            appendVisibleView(fallbackView(), to: &elements)
            return
        }

        let previousCount = elements.count
        provider.accessibilityElementsInOrder.forEach {
            appendElement($0, to: &elements)
        }
        if elements.count == previousCount {
            appendVisibleView(fallbackView(), to: &elements)
        }
    }

    static func firstVisibleView(in provider: AccessibilityElementsOrderProviding) -> UIView? {
        provider.accessibilityElementsInOrder.compactMap { element in
            guard let view = element as? UIView,
                  view.superview != nil,
                  !view.isHidden,
                  view.alpha > visibleAlphaThreshold else {
                return nil
            }
            return view
        }.first
    }
}
