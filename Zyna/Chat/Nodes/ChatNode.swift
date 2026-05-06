//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class ChatNode: ASDisplayNode {
    let tableNode = ASTableNode()
    let paintSplashHostView = UIView()
    private let bubbleGradientHostView = UIView()
    private let bubbleGradientSources: [BubbleGradientRole: BubbleGradientSource]

    /// Set by ChatViewController. Used to put glass bars first in the
    /// accessibility tree so VoiceOver hit-tests the bars before the
    /// table cells visually behind them (the bars are transparent glass).
    weak var glassNavBar: ASDisplayNode?
    weak var glassInputBar: ASDisplayNode?

    /// Set by ChatViewController. The scroll-to-live floating button lives
    /// at this node's view level (not inside the input bar) so its tap
    /// target works when positioned above the bar's bounds.
    weak var scrollButtonTap: UIView?

    override init() {
        let theme = ChatBubbleThemeStore.shared.selectedTheme
        var sources: [BubbleGradientRole: BubbleGradientSource] = [:]
        for role in BubbleGradientRole.allCases {
            sources[role] = BubbleGradientSource(
                colorProvider: { traits in
                    role.colors(traits: traits, outgoingTheme: theme)
                },
                start: role == .outgoing ? theme.startPoint : CGPoint(x: 0.0, y: 0.0),
                end: role == .outgoing ? theme.endPoint : CGPoint(x: 1.0, y: 1.0)
            )
        }
        self.bubbleGradientSources = sources
        super.init()
        addSubnode(tableNode)
        tableNode.inverted = true
        backgroundColor = AppColor.chatBackground
        tableNode.backgroundColor = AppColor.chatBackground
        bubbleGradientHostView.backgroundColor = .clear
        bubbleGradientHostView.isUserInteractionEnabled = false
        paintSplashHostView.backgroundColor = .clear
        paintSplashHostView.isOpaque = false
        paintSplashHostView.isUserInteractionEnabled = false
    }

    override func didLoad() {
        super.didLoad()
        view.insertSubview(bubbleGradientHostView, belowSubview: tableNode.view)
        view.insertSubview(paintSplashHostView, aboveSubview: tableNode.view)
        for role in BubbleGradientRole.allCases {
            guard let source = bubbleGradientSources[role] else { continue }
            bubbleGradientHostView.addSubview(source)
        }
    }

    override func layout() {
        super.layout()
        tableNode.frame = bounds
        bubbleGradientHostView.frame = bounds
        paintSplashHostView.frame = bounds
        for source in bubbleGradientSources.values {
            source.frame = bubbleGradientHostView.bounds
        }
    }

    func bubbleGradientSource(for message: ChatMessage) -> PortalSourceView? {
        guard message.zynaAttributes.color == nil else { return nil }
        return bubbleGradientSources[message.isOutgoing ? .outgoing : .incoming]
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let nav = glassNavBar?.view, nav.superview === view {
                elements.append(nav)
            }
            if let input = glassInputBar?.view, input.superview === view {
                elements.append(input)
            }
            if let tap = scrollButtonTap, tap.superview === view, tap.alpha > 0 {
                elements.append(tap)
            }
            elements.append(tableNode.view)
            return elements
        }
        set { }
    }
}
