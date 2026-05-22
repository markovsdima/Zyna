//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SpacePlaceholderViewController: ASDKViewController<SpacePlaceholderScreenNode> {

    var onBack: (() -> Void)?

    private let space: RoomModel
    private let glassTopBar = GlassTopBar()

    init(space: RoomModel) {
        self.space = space
        super.init(node: SpacePlaceholderScreenNode(space: space))
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupGlassTopBar()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.captureFor(duration: 0.5)
        GlassService.shared.setNeedsCapture()
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .systemBackground
        glassTopBar.sourceView = node.contentNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.template(size: 17, weight: .semibold)
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(
                text: space.name.isEmpty ? String(localized: "Untitled") : space.name,
                subtitle: String(localized: "Storyline")
            )
        ]
    }
}

final class SpacePlaceholderScreenNode: ScreenNode {
    fileprivate weak var glassTopBar: ASDisplayNode?
    fileprivate let contentNode: SpacePlaceholderContentNode

    init(space: RoomModel) {
        self.contentNode = SpacePlaceholderContentNode(space: space)
        super.init()
        automaticallyManagesSubnodes = false
        addSubnode(contentNode)
    }

    override func layout() {
        super.layout()
        contentNode.frame = bounds
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            elements.append(contentNode.view)
            return elements
        }
        set { }
    }
}

private final class SpacePlaceholderContentNode: ASDisplayNode {
    private let bodyNode = ASTextNode()

    init(space: RoomModel) {
        super.init()
        automaticallyManagesSubnodes = true
        backgroundColor = .systemBackground
        setupNodes()
    }

    private func setupNodes() {
        bodyNode.attributedText = NSAttributedString(
            string: String(localized: "Chats and tracks will appear here."),
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        bodyNode.maximumNumberOfLines = 0
        bodyNode.style.maxWidth = ASDimension(unit: .points, value: 280)
    }

    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        let stack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .center,
            alignItems: .center,
            children: [bodyNode]
        )
        stack.style.flexGrow = 1
        stack.style.flexShrink = 1

        let centered = ASCenterLayoutSpec(
            centeringOptions: .XY,
            sizingOptions: [],
            child: stack
        )

        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 96, left: 24, bottom: 48, right: 24),
            child: centered
        )
    }
}
