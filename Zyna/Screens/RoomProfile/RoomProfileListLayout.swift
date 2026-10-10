// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import UIKit

final class RoomProfileListAttributes: UICollectionViewLayoutAttributes {
    enum DockEdge { case none, top, bottom }
    var dockEdge: DockEdge = .none

    override func copy(with zone: NSZone? = nil) -> Any {
        let result = super.copy(with: zone) as! RoomProfileListAttributes
        result.dockEdge = dockEdge
        return result
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? RoomProfileListAttributes else { return false }
        return dockEdge == other.dockEdge && super.isEqual(object)
    }
}

/// Pins the actual playing cell without changing the flow's content size
/// or allocating a second player. Original geometry still owns anchors.
final class RoomProfileListLayout: UICollectionViewFlowLayout {
    override class var layoutAttributesClass: AnyClass { RoomProfileListAttributes.self }
    var playingPath: IndexPath? {
        didSet {
            guard playingPath != oldValue else { return }
            invalidatePlayers([oldValue, playingPath].compactMap { $0 })
        }
    }
    var visibleInsets = UIEdgeInsets.zero {
        didSet {
            guard visibleInsets != oldValue, let playingPath else { return }
            invalidatePlayers([playingPath])
        }
    }

    static func pinnedFrame(_ original: CGRect, in viewport: CGRect) -> CGRect {
        var frame = original
        frame.origin.y = max(viewport.minY, min(original.minY, viewport.maxY - original.height))
        return frame
    }

    func naturalAttributes(in rect: CGRect) -> [UICollectionViewLayoutAttributes] {
        super.layoutAttributesForElements(in: rect) ?? []
    }

    func naturalAttributes(at path: IndexPath) -> UICollectionViewLayoutAttributes? {
        super.layoutAttributesForItem(at: path)
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        var attributes = naturalAttributes(in: rect)
        guard let playingPath, contains(playingPath),
              let player = layoutAttributesForItem(at: playingPath) else { return attributes }
        attributes.removeAll { $0.representedElementCategory == .cell && $0.indexPath == playingPath }
        if player.frame.intersects(rect) { attributes.append(player) }
        return attributes
    }

    override func layoutAttributesForItem(at indexPath: IndexPath) -> UICollectionViewLayoutAttributes? {
        if indexPath == playingPath, !contains(indexPath) { return nil }
        guard let original = super.layoutAttributesForItem(at: indexPath) else { return nil }
        guard indexPath == playingPath, let collectionView,
              let attributes = original.copy() as? UICollectionViewLayoutAttributes else { return original }
        attributes.frame = Self.pinnedFrame(original.frame, in: collectionView.bounds.inset(by: visibleInsets))
        (attributes as? RoomProfileListAttributes)?.dockEdge = attributes.frame.minY > original.frame.minY ? .top
            : (attributes.frame.minY < original.frame.minY ? .bottom : .none)
        attributes.zIndex = 10
        return attributes
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        super.shouldInvalidateLayout(forBoundsChange: newBounds)
            || (playingPath != nil && collectionView?.bounds != newBounds)
    }

    override func invalidationContext(forBoundsChange newBounds: CGRect) -> UICollectionViewLayoutInvalidationContext {
        let sizeChanged = collectionView?.bounds.size != newBounds.size
        if sizeChanged || super.shouldInvalidateLayout(forBoundsChange: newBounds) {
            let context = super.invalidationContext(forBoundsChange: newBounds)
            if sizeChanged, let flow = context as? UICollectionViewFlowLayoutInvalidationContext {
                flow.invalidateFlowLayoutDelegateMetrics = true
                flow.invalidateFlowLayoutAttributes = true
            }
            return context
        }
        return playerInvalidationContext(playingPath.map { [$0] } ?? [])
    }

    private func contains(_ path: IndexPath) -> Bool {
        guard let collectionView else { return false }
        return path.section < collectionView.numberOfSections
            && path.item < collectionView.numberOfItems(inSection: path.section)
    }

    private func invalidatePlayers(_ paths: [IndexPath]) {
        let paths = paths.filter(contains)
        guard !paths.isEmpty else { return }
        invalidateLayout(with: playerInvalidationContext(paths))
    }

    private func playerInvalidationContext(_ paths: [IndexPath]) -> UICollectionViewFlowLayoutInvalidationContext {
        let context = UICollectionViewFlowLayoutInvalidationContext()
        // A player's display position does not change the flow's metrics.
        // Defaults are true, which would remeasure the entire catalog.
        context.invalidateFlowLayoutDelegateMetrics = false
        context.invalidateFlowLayoutAttributes = false
        context.invalidateItems(at: paths.filter(contains))
        return context
    }
}
