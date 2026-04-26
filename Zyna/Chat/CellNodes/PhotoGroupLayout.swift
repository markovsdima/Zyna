//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum PhotoGroupLayout {

    static let spacing: CGFloat = 2
    static let maxVisibleItems = 4
    static let splitScale = 1000

    private struct ResolvedLayoutMetrics {
        let primarySplitPermille: Int
        let secondarySplitPermille: Int?
    }

    static func supportsInteractiveLayout(for itemCount: Int) -> Bool {
        let visibleCount = visibleItemCount(for: itemCount)
        return visibleCount == 2 || visibleCount == 3
    }

    static func sanitizedLayoutOverride(
        _ layoutOverride: MediaGroupLayoutOverride?,
        itemCount: Int
    ) -> MediaGroupLayoutOverride? {
        let visibleCount = visibleItemCount(for: itemCount)
        guard supportsInteractiveLayout(for: visibleCount),
              let metrics = layoutMetrics(itemCount: visibleCount, layoutOverride: layoutOverride)
        else {
            return nil
        }

        let defaultPrimary = defaultPrimarySplitPermille(for: visibleCount)
        let defaultSecondary = defaultSecondarySplitPermille(for: visibleCount)
        if metrics.primarySplitPermille == defaultPrimary,
           metrics.secondarySplitPermille == defaultSecondary {
            return nil
        }

        return MediaGroupLayoutOverride(
            primarySplitPermille: metrics.primarySplitPermille,
            secondarySplitPermille: metrics.secondarySplitPermille
        )
    }

    static func resolvedPrimarySplitPermille(
        for itemCount: Int,
        layoutOverride: MediaGroupLayoutOverride?
    ) -> Int? {
        layoutMetrics(itemCount: itemCount, layoutOverride: layoutOverride)?.primarySplitPermille
    }

    static func resolvedSecondarySplitPermille(
        for itemCount: Int,
        layoutOverride: MediaGroupLayoutOverride?
    ) -> Int? {
        layoutMetrics(itemCount: itemCount, layoutOverride: layoutOverride)?.secondarySplitPermille
    }

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

    static func frames(
        in bounds: CGRect,
        itemCount: Int,
        layoutOverride: MediaGroupLayoutOverride? = nil
    ) -> [CGRect] {
        let visibleCount = visibleItemCount(for: itemCount)
        let spacing = Self.spacing
        let metrics = layoutMetrics(itemCount: visibleCount, layoutOverride: layoutOverride)

        switch visibleCount {
        case 0:
            return []
        case 1:
            return [bounds.integral]
        case 2:
            let primarySplit = CGFloat(metrics?.primarySplitPermille ?? defaultPrimarySplitPermille(for: 2))
                / CGFloat(splitScale)
            let totalWidth = bounds.width - spacing
            let leftWidth = totalWidth * primarySplit
            let rightWidth = totalWidth - leftWidth
            return [
                CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height).integral,
                CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: bounds.height).integral
            ]
        case 3:
            let primarySplit = CGFloat(metrics?.primarySplitPermille ?? defaultPrimarySplitPermille(for: 3))
                / CGFloat(splitScale)
            let secondarySplit = CGFloat(metrics?.secondarySplitPermille ?? defaultSecondarySplitPermille(for: 3) ?? splitScale / 2)
                / CGFloat(splitScale)
            let totalWidth = bounds.width - spacing
            let totalHeight = bounds.height - spacing
            let leftWidth = totalWidth * primarySplit
            let rightWidth = totalWidth - leftWidth
            let topRightHeight = totalHeight * secondarySplit
            let bottomRightHeight = totalHeight - topRightHeight
            return [
                CGRect(x: 0, y: 0, width: leftWidth, height: bounds.height).integral,
                CGRect(x: leftWidth + spacing, y: 0, width: rightWidth, height: topRightHeight).integral,
                CGRect(x: leftWidth + spacing, y: topRightHeight + spacing, width: rightWidth, height: bottomRightHeight).integral
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

    private static func layoutMetrics(
        itemCount: Int,
        layoutOverride: MediaGroupLayoutOverride?
    ) -> ResolvedLayoutMetrics? {
        let visibleCount = visibleItemCount(for: itemCount)
        switch visibleCount {
        case 2:
            let primary = clampPrimarySplitPermille(
                layoutOverride?.primarySplitPermille ?? defaultPrimarySplitPermille(for: 2),
                itemCount: 2
            )
            return ResolvedLayoutMetrics(
                primarySplitPermille: primary,
                secondarySplitPermille: nil
            )
        case 3:
            let primary = clampPrimarySplitPermille(
                layoutOverride?.primarySplitPermille ?? defaultPrimarySplitPermille(for: 3),
                itemCount: 3
            )
            let secondary = clampSecondarySplitPermille(
                layoutOverride?.secondarySplitPermille ?? defaultSecondarySplitPermille(for: 3) ?? 500,
                itemCount: 3
            )
            return ResolvedLayoutMetrics(
                primarySplitPermille: primary,
                secondarySplitPermille: secondary
            )
        default:
            return nil
        }
    }

    private static func defaultPrimarySplitPermille(for itemCount: Int) -> Int {
        switch visibleItemCount(for: itemCount) {
        case 2:
            return 500
        case 3:
            return 600
        default:
            return 500
        }
    }

    private static func defaultSecondarySplitPermille(for itemCount: Int) -> Int? {
        switch visibleItemCount(for: itemCount) {
        case 3:
            return 500
        default:
            return nil
        }
    }

    private static func clampPrimarySplitPermille(_ value: Int, itemCount: Int) -> Int {
        switch visibleItemCount(for: itemCount) {
        case 2:
            return min(max(value, 350), 650)
        case 3:
            return min(max(value, 420), 720)
        default:
            return value
        }
    }

    private static func clampSecondarySplitPermille(_ value: Int, itemCount: Int) -> Int {
        switch visibleItemCount(for: itemCount) {
        case 3:
            return min(max(value, 280), 720)
        default:
            return value
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
