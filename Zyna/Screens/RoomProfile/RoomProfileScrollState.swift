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
    private(set) var headerHeight: CGFloat = 220

    struct Transition {
        let source: Section
        let collapse: CGFloat
    }

    func depth(for section: Section) -> CGFloat { depths[section, default: 0] }

    mutating func resizeHeader(to height: CGFloat) {
        let height = max(1, height)
        let scale = height / headerHeight
        collapse *= scale
        if let transition {
            self.transition = Transition(source: transition.source, collapse: transition.collapse * scale)
        }
        headerHeight = height
    }

    mutating func scroll(to normalizedOffset: CGFloat) {
        guard transition == nil else { return }
        // Zoom may move the content anchor while a partially open header
        // stays in place. Consume subsequent motion without a header jump.
        let depth = depth(for: selected)
        let delta = normalizedOffset - collapse - depth
        if delta >= 0 {
            let headerDelta = min(headerHeight - collapse, delta)
            collapse += headerDelta
            depths[selected] = depth + delta - headerDelta
        } else {
            let contentDelta = min(depth, -delta)
            depths[selected] = depth - contentDelta
            collapse = max(0, collapse + delta + contentDelta)
        }
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
        collapse = headerHeight
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
