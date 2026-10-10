// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Immutable month prefix geometry, independent of fetched records or UI.
struct RoomMediaGeometry: Sendable {
    struct Group: Sendable {
        let month: RoomMediaMonth
        let range: Range<Int>
        let top: CGFloat
        let bottom: CGFloat
    }
    let width: CGFloat
    let columns: Int
    let side: CGFloat
    let headerHeight: CGFloat
    let groups: [Group]
    let height: CGFloat
    let count: Int
    static let spacing: CGFloat = 2

    init(months: [RoomMediaMonth], width: CGFloat, columns: Int, scale: CGFloat = 2, headerHeight: CGFloat = 40) {
        self.width = max(1, width)
        self.columns = min(10, max(2, columns))
        self.headerHeight = headerHeight
        side = max(1, floor((self.width - CGFloat(self.columns - 1) * Self.spacing) / CGFloat(self.columns) * scale) / scale)
        var groups: [Group] = []
        var y: CGFloat = 0
        var start = 0
        for month in months where month.count > 0 {
            let rows = (month.count + self.columns - 1) / self.columns
            let bottom = y + headerHeight + Self.spacing + CGFloat(rows) * (side + Self.spacing)
            groups.append(Group(month: month, range: start..<(start + month.count), top: y, bottom: bottom))
            y = bottom
            start += month.count
        }
        self.groups = groups
        height = y
        count = start
    }

    func group(at index: Int) -> Group? {
        guard index >= 0, index < count else { return nil }
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].range.upperBound <= index { low = mid + 1 } else { high = mid }
        }
        return groups[low]
    }

    func frame(at index: Int) -> CGRect? {
        guard let group = group(at: index) else { return nil }
        let local = index - group.range.lowerBound
        return CGRect(x: CGFloat(local % columns) * (side + Self.spacing),
                      y: group.top + headerHeight + Self.spacing + CGFloat(local / columns) * (side + Self.spacing),
                      width: side, height: side)
    }

    func groups(in rect: CGRect) -> ArraySlice<Group> {
        var low = 0, high = groups.count
        while low < high {
            let mid = (low + high) / 2
            if groups[mid].bottom < rect.minY { low = mid + 1 } else { high = mid }
        }
        let start = low
        while low < groups.count, groups[low].top <= rect.maxY { low += 1 }
        return groups[start..<low]
    }

    func range(in rect: CGRect) -> Range<Int> {
        var lower: Int?, upper = 0
        for group in groups(in: rect) {
            let origin = group.top + headerHeight + Self.spacing
            let firstRow = max(0, Int(floor((rect.minY - origin) / (side + Self.spacing))))
            let lastRow = max(0, Int(floor((rect.maxY - origin) / (side + Self.spacing))))
            let first = min(group.range.upperBound, group.range.lowerBound + firstRow * columns)
            let last = min(group.range.upperBound, group.range.lowerBound + (lastRow + 1) * columns)
            guard first < last else { continue }
            lower = lower ?? first
            upper = last
        }
        return (lower ?? 0)..<upper
    }

    func index(at point: CGPoint, nearest: Bool = false) -> Int? {
        guard count > 0 else { return nil }
        let rect = CGRect(x: 0, y: point.y, width: width, height: 0.1)
        guard let group = groups(in: rect).first else { return nearest ? (point.y < 0 ? 0 : count - 1) : nil }
        let y = point.y - group.top - headerHeight - Self.spacing
        guard nearest || y >= 0 else { return nil }
        let row = max(0, Int(floor(y / (side + Self.spacing))))
        let column = min(columns - 1, max(0, Int(floor(point.x / (side + Self.spacing)))))
        let index = min(group.range.upperBound - 1, group.range.lowerBound + row * columns + column)
        guard nearest || frame(at: index)?.contains(point) == true else { return nil }
        return index
    }
}
