//
//  ChatView.swift
//  Zyna
//
//  Created by Dmitry Markovskiy on 04.07.2025.
//

import RxFlow
import RxRelay
import AsyncDisplayKit



final class ChatViewController: ASDKViewController<ASTableNode>, ASTableDataSource, Stepper {
    
    let steps = PublishRelay<Step>()
    
    private var chats: [Message] = []
    private let chatId: String
    
    init(chatId: String) {
        self.chatId = chatId
        super.init(node: ASTableNode())
        
        setupUI()
        setupNavigationBar()
        loadMessages()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    private func setupUI() {
        node.view.separatorStyle = .none
        node.inverted = true
        node.dataSource = self
        title = "Chat \(chatId)"
    }
    
    private func setupNavigationBar() {
        navigationItem.hidesBackButton = true
        
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )
    }
    
    @objc private func backTapped() {
        steps.accept(ChatsStep.back)
    }
    
    private func loadMessages() {
        
        // TODO: Message loading
        
        chats = [
            Message(sentByMe: true, text: "Привет, как дела?"),
            Message(sentByMe: false, text: "Отлично!")
        ].reversed()
    }
    
    // MARK: - ASTableDataSource
    
    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        return chats.count
    }
    
    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let chat = chats[indexPath.row]
        return {
            ChatCellNode(message: chat, screenWidth: ScreenConstants.width)
        }
    }
}
