// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Content depth is independent of the shared header's geometry.
/// The controller owns this state for the lifetime of one open profile.
struct RoomProfileScrollState {
    enum Section: Int, CaseIterable { case media, files }

    private(set) var selected: Section = .media
    private(set) var collapse: CGFloat = 0
    private(set) var depths: [Section: CGFloat] = [:]
    private(set) var transition: Transition?
    private var regularHeaderHeight: CGFloat = 220
    private(set) var avatarExpansionHeight: CGFloat = 0
    var headerHeight: CGFloat { regularHeaderHeight + avatarExpansionHeight }
    var avatarProgress: CGFloat {
        guard avatarExpansionHeight > 0 else { return 0 }
        return max(0, min(1, 1 - collapse / avatarExpansionHeight))
    }
    var regularCollapse: CGFloat { max(0, collapse - avatarExpansionHeight) }
    var regularCollapseProgress: CGFloat { regularCollapse / regularHeaderHeight }

    struct Transition {
        let source: Section
        let collapse: CGFloat
    }

    func depth(for section: Section) -> CGFloat { depths[section, default: 0] }

    mutating func resizeHeader(to height: CGFloat, avatarExpansionHeight: CGFloat? = nil) {
        let height = max(1, height)
        let expansion = max(0, avatarExpansionHeight ?? self.avatarExpansionHeight)
        // Reserve the expanded geometry once. The ordinary circular header
        // starts after this segment; rows keep the same screen position.
        func remap(_ value: CGFloat) -> CGFloat {
            if self.avatarExpansionHeight > 0, value < self.avatarExpansionHeight {
                return value / self.avatarExpansionHeight * expansion
            }
            return expansion + (value - self.avatarExpansionHeight) / regularHeaderHeight * height
        }
        collapse = remap(collapse)
        if let transition {
            self.transition = Transition(source: transition.source, collapse: remap(transition.collapse))
        }
        regularHeaderHeight = height
        self.avatarExpansionHeight = expansion
    }

    mutating func scroll(to normalizedOffset: CGFloat, avatarScrollSpeed: CGFloat = 1) {
        guard transition == nil else { return }
        // Zoom may move the content anchor while a partially open header
        // stays in place. Consume subsequent motion without a header jump.
        let depth = depth(for: selected)
        let delta = normalizedOffset - collapse - depth
        let speed = max(1, avatarScrollSpeed)
        if delta >= 0 {
            // Consume the photo segment in finger space, then return to
            // ordinary scrolling in the same update without a boundary jump.
            let avatarDelta = min(max(0, avatarExpansionHeight - collapse) / speed, delta)
            collapse += avatarDelta * speed
            let remaining = delta - avatarDelta
            let headerDelta = min(headerHeight - collapse, remaining)
            collapse += headerDelta
            depths[selected] = depth + remaining - headerDelta
        } else {
            let contentDelta = min(depth, -delta)
            depths[selected] = depth - contentDelta
            let remaining = -delta - contentDelta
            let headerDelta = min(max(0, collapse - avatarExpansionHeight), remaining)
            collapse -= headerDelta
            collapse = max(0, collapse - (remaining - headerDelta) * speed)
        }
    }

    mutating func setHeaderCollapse(_ collapse: CGFloat) {
        guard transition == nil else { return }
        self.collapse = min(headerHeight, max(0, collapse))
    }

    mutating func restoreDepth(_ depth: CGFloat, for section: Section) {
        depths[section] = max(0, depth)
    }

    mutating func beginTransition() {
        guard transition == nil else { return }
        transition = Transition(source: selected, collapse: collapse)
    }

    mutating func transition(to target: Section, progress: CGFloat) {
        guard let transition else { return }
        let targetCollapse = depth(for: target) > 0 ? headerHeight : transition.collapse
        let fraction = min(1, max(0, progress))
        collapse = transition.collapse + (targetCollapse - transition.collapse) * fraction
    }

    mutating func finishTransition(at section: Section) {
        guard let transition else { return }
        selected = section
        collapse = section == transition.source
            ? transition.collapse
            : (depth(for: section) > 0 ? headerHeight : transition.collapse)
        self.transition = nil
    }

    mutating func scrollToBeginning() {
        depths[selected] = 0
        collapse = avatarExpansionHeight
    }
}

/// A visible event, not an SDK timeline ID or an absolute pixel offset.
struct RoomProfileAnchor: Equatable {
    let id: String
    let previousIndex: Int
    let offset: CGFloat

    func resolve(in ids: [String]) -> Int? {
        guard !ids.isEmpty else { return nil }
        return ids.firstIndex(of: id) ?? min(previousIndex, ids.count - 1)
    }
}
