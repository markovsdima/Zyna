//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import RxFlow
import RxRelay

// MARK: - Chat Model

struct Chat {
    let id: String
    let name: String
    let lastMessage: String
    let timestamp: String
    let avatarColor: UIColor
    let isOnline: Bool
    let unreadCount: Int
    let avatarInitials: String
}

// MARK: - Mock Data

class MockChatData {
    static let shared = MockChatData()
    
    private let colors: [UIColor] = [
        .systemBlue, .systemGreen, .systemOrange, .systemRed,
        .systemPurple, .systemTeal, .systemIndigo, .systemPink
    ]
    
    private let names = [
        "Alice Johnson", "Bob Smith", "Charlie Brown", "Diana Prince",
        "Edward Norton", "Fiona Apple", "George Lucas", "Helen Keller",
        "Ivan Petrov", "Julia Roberts", "Kevin Hart", "Lisa Simpson"
    ]
    
    private let messages = [
        "Hey! How are you doing today?",
        "Thanks for the help yesterday 🙏",
        "Are we still meeting tomorrow?",
        "Just finished watching that movie you recommended",
        "Check out this cool photo I took!",
        "Running a bit late, be there in 10 minutes",
        "Happy birthday! 🎉🎂",
        "Let's grab coffee sometime this week",
        "Did you see the news about the new update?",
        "Working from home today, how about you?"
    ]
    
    lazy var chats: [Chat] = {
        return (0..<12).map { index in
            let name = names[index]
            let initials = name.split(separator: " ").compactMap { $0.first }.map(String.init).joined()
            
            return Chat(
                id: "chat_\(index)",
                name: name,
                lastMessage: messages[index % messages.count],
                timestamp: generateTimestamp(for: index),
                avatarColor: colors[index % colors.count],
                isOnline: Bool.random(),
                unreadCount: index % 3 == 0 ? Int.random(in: 1...9) : 0,
                avatarInitials: initials
            )
        }
    }()
    
    private func generateTimestamp(for index: Int) -> String {
        let formatter = DateFormatter()
        let calendar = Calendar.current
        let now = Date()
        
        switch index % 4 {
        case 0:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: now)
        case 1:
            formatter.dateFormat = "HH:mm"
            return formatter.string(from: calendar.date(byAdding: .hour, value: -2, to: now) ?? now)
        case 2:
            return "Yesterday"
        default:
            formatter.dateFormat = "MMM dd"
            return formatter.string(from: calendar.date(byAdding: .day, value: -Int.random(in: 2...7), to: now) ?? now)
        }
    }
}

// MARK: - Chat Cell Node

class ChatListCellNode: ASCellNode {
    
    private let chat: Chat
    private let avatarNode = ASDisplayNode()
    private let nameNode = ASTextNode()
    private let messageNode = ASTextNode()
    private let timestampNode = ASTextNode()
    private let onlineIndicatorNode = ASDisplayNode()
    private let unreadBadgeNode = ASDisplayNode()
    private let unreadCountNode = ASTextNode()
    private let separatorNode = ASDisplayNode()
    
    init(chat: Chat) {
        self.chat = chat
        super.init()
        
        setupNodes()
        setupLayout()
    }
    
    private func setupNodes() {
        // Avatar
        avatarNode.backgroundColor = chat.avatarColor
        avatarNode.cornerRadius = 25
        avatarNode.borderWidth = 0.5
        avatarNode.borderColor = UIColor.separator.cgColor
        
        // Avatar initials
        let avatarText = ASTextNode()
        avatarText.attributedText = NSAttributedString(
            string: chat.avatarInitials,
            attributes: [
                .font: UIFont.systemFont(ofSize: 18, weight: .medium),
                .foregroundColor: UIColor.white
            ]
        )
        avatarNode.addSubnode(avatarText)
        avatarText.style.preferredSize = CGSize(width: 50, height: 50)
        avatarText.style.layoutPosition = CGPoint(x: 0, y: 0)
        
        // Name
        nameNode.attributedText = NSAttributedString(
            string: chat.name,
            attributes: [
                .font: UIFont.systemFont(ofSize: 16, weight: .semibold),
                .foregroundColor: UIColor.label
            ]
        )
        nameNode.maximumNumberOfLines = 1
        nameNode.truncationMode = .byTruncatingTail
        
        // Message
        messageNode.attributedText = NSAttributedString(
            string: chat.lastMessage,
            attributes: [
                .font: UIFont.systemFont(ofSize: 14, weight: .regular),
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        messageNode.maximumNumberOfLines = 2
        messageNode.truncationMode = .byTruncatingTail
        
        // Timestamp
        timestampNode.attributedText = NSAttributedString(
            string: chat.timestamp,
            attributes: [
                .font: UIFont.systemFont(ofSize: 12, weight: .regular),
                .foregroundColor: UIColor.tertiaryLabel
            ]
        )
        timestampNode.maximumNumberOfLines = 1
        
        // Online indicator
        if chat.isOnline {
            onlineIndicatorNode.backgroundColor = UIColor.systemGreen
            onlineIndicatorNode.cornerRadius = 6
            onlineIndicatorNode.borderWidth = 2
            onlineIndicatorNode.borderColor = UIColor.systemBackground.cgColor
        }
        
        // Unread badge
        if chat.unreadCount > 0 {
            unreadBadgeNode.backgroundColor = UIColor.systemBlue
            unreadBadgeNode.cornerRadius = 10
            
            unreadCountNode.attributedText = NSAttributedString(
                string: "\(chat.unreadCount)",
                attributes: [
                    .font: UIFont.systemFont(ofSize: 12, weight: .medium),
                    .foregroundColor: UIColor.white
                ]
            )
        }
        
        // Separator
        separatorNode.backgroundColor = UIColor.separator
        
        // Add subnodes
        addSubnode(avatarNode)
        addSubnode(nameNode)
        addSubnode(messageNode)
        addSubnode(timestampNode)
        
        if chat.isOnline {
            addSubnode(onlineIndicatorNode)
        }
        
        if chat.unreadCount > 0 {
            addSubnode(unreadBadgeNode)
            addSubnode(unreadCountNode)
        }
        
        addSubnode(separatorNode)
    }
    
    private func setupLayout() {
        automaticallyManagesSubnodes = true
    }
    
    override func layoutSpecThatFits(_ constrainedSize: ASSizeRange) -> ASLayoutSpec {
        // Avatar with online indicator
        let avatarWithIndicator: ASLayoutSpec
        if chat.isOnline {
            onlineIndicatorNode.style.preferredSize = CGSize(width: 12, height: 12)
            onlineIndicatorNode.style.layoutPosition = CGPoint(x: 38, y: 38)
            avatarWithIndicator = ASAbsoluteLayoutSpec(children: [avatarNode, onlineIndicatorNode])
        } else {
            avatarWithIndicator = ASWrapperLayoutSpec(layoutElement: avatarNode)
        }
        
        avatarNode.style.preferredSize = CGSize(width: 50, height: 50)
        
        // Right side content (timestamp and unread badge)
        var rightElements: [ASLayoutElement] = [timestampNode]
        
        if chat.unreadCount > 0 {
            unreadBadgeNode.style.preferredSize = CGSize(width: 20, height: 20)
            unreadCountNode.style.layoutPosition = CGPoint(x: 0, y: 0)
            
            let badgeWithCount = ASAbsoluteLayoutSpec(
                sizing: .sizeToFit,
                children: [unreadBadgeNode, unreadCountNode]
            )
            rightElements.append(badgeWithCount)
        }
        
        let rightStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 4,
            justifyContent: .start,
            alignItems: .end,
            children: rightElements
        )
        
        // Text content (name and message)
        let textStack = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 2,
            justifyContent: .start,
            alignItems: .start,
            children: [nameNode, messageNode]
        )
        textStack.style.flexShrink = 1
        
        // Main content (avatar + text + right side)
        let mainContent = ASStackLayoutSpec(
            direction: .horizontal,
            spacing: 12,
            justifyContent: .start,
            alignItems: .start,
            children: [avatarWithIndicator, textStack, rightStack]
        )
        
        // Separator
        separatorNode.style.preferredSize = CGSize(width: constrainedSize.max.width, height: 0.5)
        separatorNode.style.layoutPosition = CGPoint(x: 0, y: 0)
        
        // Cell content with separator
        let cellContent = ASStackLayoutSpec(
            direction: .vertical,
            spacing: 0,
            justifyContent: .start,
            alignItems: .stretch,
            children: [mainContent]
        )
        
        let cellWithSeparator = ASAbsoluteLayoutSpec(children: [cellContent, separatorNode])
        
        return ASInsetLayoutSpec(
            insets: UIEdgeInsets(top: 12, left: 16, bottom: 12, right: 16),
            child: cellWithSeparator
        )
    }
    
    override func didLoad() {
        super.didLoad()
        backgroundColor = UIColor.systemBackground
        
        // Add subtle highlight effect
        let highlightedBackground = UIView()
        highlightedBackground.backgroundColor = UIColor.systemGray6
        selectedBackgroundView = highlightedBackground
    }
}

// MARK: - Chats List Controller
class ChatsListViewController: ASDKViewController<ASDisplayNode>, Stepper {
    
    let steps = PublishRelay<Step>()
    
    private let tableNode = ASTableNode()
    private var chats: [Chat] = []
    
    override init() {
        super.init(node: BaseNode())
        
        setupTableNode()
        loadMockData()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupTableNode() {
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = UIColor.systemBackground
        tableNode.view.separatorStyle = .none
        //tableNode.separatorStyle = .none
        //tableNode.view.contentInsetAdjustmentBehavior = .never
        node.addSubnode(tableNode)
        node.backgroundColor = UIColor.systemBackground
        
        tableNode.view.refreshControl = UIRefreshControl()
        tableNode.view.refreshControl?.addTarget(self, action: #selector(handleRefresh), for: .valueChanged)
    }
    
    private func loadMockData() {
        chats = MockChatData.shared.chats
        tableNode.reloadData()
    }
    
    @objc private func handleRefresh() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.tableNode.view.refreshControl?.endRefreshing()
            // загрузка новых данных
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        navigationController?.navigationBar.prefersLargeTitles = false
        navigationItem.largeTitleDisplayMode = .never
        // Add compose button
        let composeButton = UIBarButtonItem(
            barButtonSystemItem: .compose,
            target: self,
            action: #selector(composeButtonTapped)
        )
        navigationItem.rightBarButtonItem = composeButton
    }
    
    @objc private func composeButtonTapped() {
        print("Compose button tapped")
        // Emit navigation step to create new chat
        //steps.accept(MainStep.createNewChat)
    }
    
    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        tableNode.frame = node.bounds
    }
}

// MARK: - Table Node Data Source & Delegate
extension ChatsListViewController: ASTableDataSource, ASTableDelegate {
    
    func numberOfSections(in tableNode: ASTableNode) -> Int {
        return 1
    }
    
    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        return chats.count
    }
    
    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let chat = chats[indexPath.row]
        return {
            return ChatListCellNode(chat: chat)
        }
    }
    
    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        
        let selectedChat = chats[indexPath.row]
        print("Selected chat: \(selectedChat.name)")
        
        // Emit navigation step to open chat
        //steps.accept(MainStep.openChat(chatId: selectedChat.id))
        steps.accept(ChatsStep.chat)
    }
}

extension ChatsListViewController {
    func tableNode(_ tableNode: ASTableNode, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }
    
    func tableNode(_ tableNode: ASTableNode, commitEditingStyle editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            chats.remove(at: indexPath.row)
            tableNode.deleteRows(at: [indexPath], with: .fade)
        }
    }
}
