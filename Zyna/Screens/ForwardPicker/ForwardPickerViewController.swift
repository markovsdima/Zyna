//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

/// Modal room picker for message forwarding. Shows the user's room
/// list and calls `onRoomSelected` when a room is tapped.
final class ForwardPickerViewController: ASDKViewController<ASDisplayNode> {

    var onRoomSelected: ((RoomModel) -> Void)?
    var onCancel: (() -> Void)?

    private let tableNode = ASTableNode()
    private var rooms: [RoomModel] = []

    override init() {
        super.init(node: ASDisplayNode())

        node.backgroundColor = .systemBackground
        node.addSubnode(tableNode)
        node.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.tableNode)
        }

        tableNode.dataSource = self
        tableNode.delegate = self
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Forward to..."
        tableNode.view.separatorStyle = .none

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .cancel,
            target: self,
            action: #selector(cancelTapped)
        )

        loadRooms()
    }

    @objc private func cancelTapped() {
        onCancel?()
    }

    private func loadRooms() {
        let service = ZynaRoomListService()
        rooms = service.roomsSubject.value.map { RoomModel(from: $0) }
        tableNode.reloadData()
    }
}

// MARK: - ASTableDataSource & Delegate

extension ForwardPickerViewController: ASTableDataSource, ASTableDelegate {

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        rooms.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let room = rooms[indexPath.row]
        return { RoomsCellNode(chat: room) }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        onRoomSelected?(rooms[indexPath.row])
    }
}
