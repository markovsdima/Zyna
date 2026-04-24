//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum PhotoGroupLayout {

    static let spacing: CGFloat = 2
    static let maxVisibleItems = 4

    static func visibleItemCount(for totalCount: Int) -> Int {
        min(max(totalCount, 0), maxVisibleItems)
    }

    static func preferredMediaHeight(
        for width: CGFloat,
        itemCount: Int,
        primaryAspectRatio: CGFloat?
    ) -> CGFloat {
        let resolvedCount = max(1, itemCount)
        switch resolvedCount {
        case 1:
            if let primaryAspectRatio,
               primaryAspectRatio > 0 {
                return min(width / primaryAspectRatio, MessageCellHelpers.maxImageBubbleHeight)
            }
            return min(width * 0.78, MessageCellHelpers.maxImageBubbleHeight)
        case 2:
            return min(width * 0.74, MessageCellHelpers.maxImageBubbleHeight)
        case 3:
            return min(width * 0.82, MessageCellHelpers.maxImageBubbleHeight)
        default:
            return min(width, MessageCellHelpers.maxImageBubbleHeight)
        }
    }

    static func frames(in bounds: CGRect, itemCount: Int) -> [CGRect] {
        let visibleCount = visibleItemCount(for: itemCount)
        let spacing = Self.spacing

        switch visibleCount {
        case 0:
            return []
        case 1:
            return [bounds.integral]
        case 2:
            let itemWidth = (bounds.width - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: itemWidth, height: bounds.height).integral,
                CGRect(x: itemWidth + spacing, y: 0, width: itemWidth, height: bounds.height).integral
            ]
        case 3:
            let leftWidth = bounds.width * 0.6
            let rightWidth = bounds.width - leftWidth - spacing
            let rightHeight = (bounds.height - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height).integral,
                CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: rightHeight).integral,
                CGRect(x: leftWidth + spacing, y: rightHeight + spacing, width: rightWidth, height: rightHeight).integral
            ]
        default:
            let itemWidth = (bounds.width - spacing) / 2
            let itemHeight = (bounds.height - spacing) / 2
            return [
                CGRect(x: 0, y: 0, width: itemWidth, height: itemHeight).integral,
                CGRect(x: itemWidth + spacing, y: 0, width: itemWidth, height: itemHeight).integral,
                CGRect(x: 0, y: itemHeight + spacing, width: itemWidth, height: itemHeight).integral,
                CGRect(x: itemWidth + spacing, y: itemHeight + spacing, width: itemWidth, height: itemHeight).integral
            ]
        }
    }

    static func roundedCorners(
        for index: Int,
        itemCount: Int,
        hasHeader: Bool,
        captionPlacement: CaptionPlacement?
    ) -> UIRectCorner {
        let visibleCount = visibleItemCount(for: itemCount)
        var corners: UIRectCorner

        switch visibleCount {
        case 1:
            corners = .allCorners
        case 2:
            corners = index == 0
                ? [.topLeft, .bottomLeft]
                : [.topRight, .bottomRight]
        case 3:
            switch index {
            case 0:
                corners = [.topLeft, .bottomLeft]
            case 1:
                corners = [.topRight]
            default:
                corners = [.bottomRight]
            }
        default:
            switch index {
            case 0:
                corners = [.topLeft]
            case 1:
                corners = [.topRight]
            case 2:
                corners = [.bottomLeft]
            default:
                corners = [.bottomRight]
            }
        }

        if hasHeader {
            corners.remove(.topLeft)
            corners.remove(.topRight)
        }
        if captionPlacement == .top {
            corners.remove(.topLeft)
            corners.remove(.topRight)
        } else if captionPlacement == .bottom {
            corners.remove(.bottomLeft)
            corners.remove(.bottomRight)
        }
        return corners
    }
}
