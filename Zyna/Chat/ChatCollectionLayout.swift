//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import UIKit

/// A single column of Texture's already measured cells. Both the datasource
/// and viewport are sampled at the UIKit commit, after asynchronous layout.
/// No node creation, measurement, or hierarchy traversal occurs on scroll.
final class ChatCollectionLayout: UICollectionViewLayout, ASCollectionViewLayoutFacilitatorProtocol {
    final class Batch {
        let preservesViewport: Bool
        init(preservesViewport: Bool) { self.preservesViewport = preservesViewport }
    }

    private struct Transition {
        let geometry: ChatListGeometry
        let offset: CGFloat
        let preservesViewport: Bool
        var appliedShift: CGFloat = 0
    }

    weak var textureNode: ASCollectionNode?
    var onGeometryShift: ((CGFloat) -> Void)?
    private(set) var geometry = ChatListGeometry()
    private var queuedBatches: [Batch] = []
    private var transition: Transition?
    private var targetOffset: CGPoint?
    private var needsGeometry = true
    private var layoutWidth: CGFloat = 0
    private var measuredElements: ASElementMap?
    private var needsMeasurement = true

    func enqueueBatch(preservesViewport: Bool) -> Batch {
        let batch = Batch(preservesViewport: preservesViewport)
        queuedBatches.append(batch)
        return batch
    }

    func complete(_ batch: Batch) {
        // Texture can skip a UIKit batch while an initial reload is pending.
        // Its completion must retire only that batch's queued policy.
        queuedBatches.removeAll { $0 === batch }
    }

    override var collectionViewContentSize: CGSize {
        CGSize(width: collectionView?.bounds.width ?? 0, height: geometry.height)
    }

    override func prepare() {
        super.prepare()
        guard needsGeometry, collectionView != nil else { return }
        needsGeometry = false
        geometry = measuredGeometry()
        updateTarget()
    }

    private func measuredGeometry() -> ChatListGeometry {
        guard let map = textureNode?.visibleElements, let view = collectionView else { return ChatListGeometry() }
        guard needsMeasurement || measuredElements !== map || layoutWidth != view.bounds.width else { return geometry }
        // visibleElements is Texture's committed UIKit map. Reading the
        // controller's current rows here would race its next pending update.
        // Retain the map itself so identity cannot be reused between passes.
        // A late relayout can change sizes without replacing this map.
        measuredElements = map
        layoutWidth = view.bounds.width
        needsMeasurement = false
        let elements = map.itemElements
        let ids = elements.map { $0.nodeIfAllocated?.chatListIdentifier ?? String(describing: ObjectIdentifier($0)) }
        let heights = elements.map { max(0.01, $0.nodeIfAllocated?.calculatedSize.height ?? 0.01) }
        return ChatListGeometry(ids: ids, heights: heights)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        geometry.range(in: rect).compactMap {
            layoutAttributesForItem(at: IndexPath(item: $0, section: 0))
        }
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        guard indexPath.section == 0, geometry.ids.indices.contains(indexPath.item) else { return nil }
        let attributes = UICollectionViewLayoutAttributes(forCellWith: indexPath)
        attributes.frame = geometry.frame(at: indexPath.item, width: layoutWidth)
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        newBounds.width != layoutWidth
    }

    override func invalidateLayout(with context: UICollectionViewLayoutInvalidationContext) {
        needsGeometry = true
        super.invalidateLayout(with: context)
    }

    func collectionViewWillPerformBatchUpdates() {
        guard let view = collectionView else { return }
        let policy = queuedBatches.isEmpty ? nil : queuedBatches.removeFirst()
        transition = Transition(
            geometry: geometry, offset: view.contentOffset.y,
            preservesViewport: policy?.preservesViewport
                ?? (view.contentOffset.y > -view.adjustedContentInset.top + 2)
        )
        targetOffset = nil
        needsGeometry = true
    }

    override func prepare(forCollectionViewUpdates updateItems: [UICollectionViewUpdateItem]) {
        super.prepare(forCollectionViewUpdates: updateItems)
        // UIKit may have called prepare() already, or may call it next.
        // The facilitator retained the old geometry before Texture committed.
        needsGeometry = true
        prepare()
    }

    private func updateTarget() {
        guard var transition, let view = collectionView else { return }
        let y = transition.preservesViewport ? geometry.offset(
            replacing: transition.geometry, current: transition.offset,
            viewport: view.bounds.height, insets: view.adjustedContentInset,
            destination: .preserve
        ) : transition.offset
        targetOffset = CGPoint(x: view.contentOffset.x, y: y)
        let shift = y - transition.offset
        let delta = shift - transition.appliedShift
        transition.appliedShift = shift
        self.transition = transition
        if abs(delta) > 0.01 { onGeometryShift?(delta) }
    }

    override func targetContentOffset(forProposedContentOffset proposedContentOffset: CGPoint) -> CGPoint {
        targetOffset ?? proposedContentOffset
    }

    override func finalizeCollectionViewUpdates() {
        super.finalizeCollectionViewUpdates()
        transition = nil
        targetOffset = nil
    }

    func collectionViewWillEditCells(atIndexPaths indexPaths: [Any], batched: Bool) {
        guard !batched else { return }
        needsMeasurement = true
        needsGeometry = true
        guard transition == nil, let view = collectionView else { return }
        // Texture has measured a late size change (for example, media). No
        // datasource batch follows this notification; compensate through the
        // invalidation context, not a second contentOffset setter.
        let next = measuredGeometry()
        let target = next.offset(
            replacing: geometry, current: view.contentOffset.y,
            viewport: view.bounds.height, insets: view.adjustedContentInset,
            destination: .preserve
        )
        let shift = view.contentOffset.y > -view.adjustedContentInset.top + 2
            ? target - view.contentOffset.y : 0
        let context = UICollectionViewLayoutInvalidationContext()
        context.contentOffsetAdjustment.y = shift
        geometry = next
        invalidateLayout(with: context)
        if abs(shift) > 0.01 { onGeometryShift?(shift) }
    }

    func collectionViewWillEditSections(at indexes: IndexSet, batched: Bool) {}
}
