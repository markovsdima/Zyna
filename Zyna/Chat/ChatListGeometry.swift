//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

enum ChatListDestination {
    case preserve
    case end
    case start
    case item(String)
}

/// Geometry is independent of node identity. Replacing or resizing a node
/// must not discard the message used to preserve the viewport.
struct ChatListGeometry {
    let ids: [String]
    let heights: [CGFloat]
    let origins: [CGFloat]
    /// Only unambiguous identities may anchor a viewport or navigation.
    let indices: [String: Int]
    let height: CGFloat

    init(ids: [String] = [], heights: [CGFloat] = []) {
        precondition(ids.count == heights.count)
        self.ids = ids
        self.heights = heights.map { max(0.01, $0.isFinite ? $0 : 1) }
        var origins: [CGFloat] = []
        var y: CGFloat = 0
        for height in self.heights {
            origins.append(y)
            y += height
        }
        self.origins = origins
        self.height = y
        var indices = [String: Int](minimumCapacity: ids.count)
        var duplicates: [String] = []
        for (index, id) in ids.enumerated() {
            if let previous = indices[id] {
                if previous >= 0 { duplicates.append(id) }
                indices[id] = -1
            } else {
                indices[id] = index
            }
        }
        // Keep every row's geometry, but never guess which duplicate is the
        // same message. Index suffixes would change when a page is inserted.
        for id in duplicates { indices.removeValue(forKey: id) }
        self.indices = indices
    }

    func frame(at index: Int, width: CGFloat) -> CGRect {
        CGRect(x: 0, y: origins[index], width: width, height: heights[index])
    }

    func range(in rect: CGRect) -> Range<Int> {
        var low = 0
        var high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] + heights[mid] <= rect.minY { low = mid + 1 } else { high = mid }
        }
        let first = low
        high = ids.count
        while low < high {
            let mid = (low + high) / 2
            if origins[mid] < rect.maxY { low = mid + 1 } else { high = mid }
        }
        return first..<low
    }

    func limits(viewport: CGFloat, insets: UIEdgeInsets) -> ClosedRange<CGFloat> {
        let lower = -insets.top
        return lower...max(lower, height - viewport + insets.bottom)
    }

    /// Sample at commit, so a finger's movement during async preparation is
    /// retained. Prefer a surviving visible item, then the nearest survivor.
    func offset(
        replacing old: ChatListGeometry, current: CGFloat,
        viewport: CGFloat, insets: UIEdgeInsets,
        destination: ChatListDestination
    ) -> CGFloat {
        let limits = limits(viewport: viewport, insets: insets)
        func clamp(_ value: CGFloat) -> CGFloat { min(limits.upperBound, max(limits.lowerBound, value)) }
        switch destination {
        case .end: return limits.upperBound
        case .start: return limits.lowerBound
        case .item(let id):
            guard let index = indices[id] else { return clamp(current) }
            let available = max(0, viewport - insets.top - insets.bottom)
            return clamp(origins[index] - insets.top - max(0, (available - heights[index]) / 2))
        case .preserve:
            let oldLimits = old.limits(viewport: viewport, insets: insets)
            func anchored(_ value: CGFloat) -> CGFloat {
                // Do not snap an active rubber-band back to the edge when a
                // snapshot or late measurement leaves that edge in place.
                if current < oldLimits.lowerBound, value < limits.lowerBound { return value }
                if current > oldLimits.upperBound, value > limits.upperBound { return value }
                return clamp(value)
            }
            let visible = old.range(in: CGRect(
                x: 0, y: current + insets.top, width: 1,
                height: max(1, viewport - insets.top - insets.bottom)
            ))
            for index in visible {
                if old.indices[old.ids[index]] == index, let next = indices[old.ids[index]] {
                    return anchored(current + origins[next] - old.origins[index])
                }
            }
            // A whole visible range may disappear in one update.
            let start = visible.lowerBound
            for distance in 0..<old.ids.count {
                for index in [start + distance, start - distance - 1] where old.ids.indices.contains(index) {
                    if old.indices[old.ids[index]] == index, let next = indices[old.ids[index]] {
                        return anchored(current + origins[next] - old.origins[index])
                    }
                }
            }
            return clamp(current)
        }
    }
}
