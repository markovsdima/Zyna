// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only

import AsyncDisplayKit

/// One fixed column layout during a pinch. Only this surface's transform
/// and opacity animate; its items never travel between grid positions.
@MainActor
final class RoomMediaZoomSurface {
    let node = ASDisplayNode()
    let geometry: RoomMediaGeometry
    private var tiles: [Int: RoomMediaTileLayer] = [:]
    private var spareTiles: [RoomMediaTileLayer] = []
    private var months: [String: ASTextNode] = [:]
    private let footer = ASTextNode()
    private var footerDisplayRequested = false
    private var range: Range<Int> = 0..<0

    init(geometry: RoomMediaGeometry, footerText: NSAttributedString?) {
        self.geometry = geometry
        // Texture hosts the handful of month/footer labels; photographs
        // remain shared-image layers without individual views.
        node.isUserInteractionEnabled = false
        node.clipsToBounds = true
        node.layer.anchorPoint = .zero
        node.layer.allowsGroupOpacity = true
        footer.maximumNumberOfLines = 4
        footer.attributedText = footerText
        footer.frame = CGRect(x: 16, y: geometry.height, width: max(1, geometry.width - 32), height: 104)
        node.addSubnode(footer)
    }

    var tileCount: Int { tiles.count }

    func frame(at index: Int, in layer: CALayer) -> CGRect? {
        tiles[index].map { node.layer.convert($0.frame, to: layer) }
    }

    func updateImage(at index: Int, from source: RoomMediaTileLayer) {
        tiles[index]?.copyPresentation(from: source)
    }

    func update(transform: CGAffineTransform, viewport: CGRect, opacity: CGFloat,
                source: (Int) -> RoomMediaTileLayer?) {
        let nativeViewport = viewport.applying(transform.inverted())
        // Clip and composite only a viewport-sized surface. A deep catalog
        // must never allocate a full-content opacity/rasterization texture.
        node.bounds = nativeViewport
        node.position = viewport.origin
        node.layer.setAffineTransform(CGAffineTransform(scaleX: transform.a, y: transform.d))
        node.layer.opacity = Float(opacity)
        if !footerDisplayRequested, nativeViewport.intersects(footer.frame) {
            footerDisplayRequested = true
            footer.recursivelyEnsureDisplaySynchronously(false)
        }

        let range = geometry.range(in: nativeViewport.insetBy(dx: 0, dy: -40 / transform.d))
        if self.range != range {
            self.range = range
            for index in Array(tiles.keys) where !range.contains(index) {
                if let tile = tiles.removeValue(forKey: index) {
                    tile.removeFromSuperlayer(); tile.reset()
                    if spareTiles.count < 32 { spareTiles.append(tile) }
                }
            }
            for index in range where tiles[index] == nil {
                guard let frame = geometry.frame(at: index) else { continue }
                let tile = spareTiles.popLast() ?? RoomMediaTileLayer()
                tile.frame = frame
                if let source = source(index) { tile.copyPresentation(from: source) }
                tiles[index] = tile
                node.layer.insertSublayer(tile, at: 0)
            }
        }

        let groups = geometry.groups(in: nativeViewport)
        let ids = Set(groups.map { $0.month.id })
        for id in Array(months.keys) where !ids.contains(id) { months.removeValue(forKey: id)?.removeFromSupernode() }
        for group in groups where months[group.month.id] == nil {
            let text = ASTextNode()
            text.maximumNumberOfLines = 1
            text.attributedText = NSAttributedString(string: group.month.title, attributes: [
                .font: UIFont.preferredFont(forTextStyle: .subheadline), .foregroundColor: UIColor.label
            ])
            text.frame = CGRect(x: 16, y: group.top + 10, width: max(1, geometry.width - 32), height: geometry.headerHeight - 10)
            months[group.month.id] = text
            node.addSubnode(text)
            // Queue the first paint explicitly: this custom viewport moves
            // through layer transforms. Never wait for text drawing on main.
            text.recursivelyEnsureDisplaySynchronously(false)
        }
    }
}
