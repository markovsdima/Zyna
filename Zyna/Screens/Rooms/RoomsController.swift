//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

class RoomsViewController: ASDKViewController<ASDisplayNode> {

    private let viewModel = RoomsViewModel()
    private let tableNode = ASTableNode()
    private var cancellables = Set<AnyCancellable>()
    private lazy var fpsBooster = ScrollFPSBooster(hostView: tableNode.view)

    var onChatSelected: ((Room) -> Void)? {
        get { viewModel.onChatSelected }
        set { viewModel.onChatSelected = newValue }
    }

    var onComposeTapped: (() -> Void)?

    override init() {
        super.init(node: ScreenNode())

        setupTableNode()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupTableNode() {
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = UIColor.systemBackground
        node.backgroundColor = UIColor.systemBackground

        node.layoutSpecBlock = { [weak self] _, constrainedSize in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.tableNode)
        }
    }

    private func bindViewModel() {
        viewModel.onTableUpdate = { [weak self] update in
            self?.applyTableUpdate(update)
        }

        MatrixClientService.shared.stateSubject
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                switch state {
                case .syncing:
                    self?.title = "Chats"
                case .error:
                    self?.title = "Connection error"
                default:
                    self?.title = "Connecting..."
                }
            }
            .store(in: &cancellables)
    }

    private func applyTableUpdate(_ update: RoomsTableUpdate) {
        switch update {
        case .none:
            break
        case .reload:
            tableNode.reloadData()
        case .batch(let deletions, let insertions, let reloads):
            tableNode.performBatch(animated: true, updates: {
                if !deletions.isEmpty {
                    tableNode.deleteRows(at: deletions, with: .fade)
                }
                if !insertions.isEmpty {
                    tableNode.insertRows(at: insertions, with: .fade)
                }
                if !reloads.isEmpty {
                    tableNode.reloadRows(at: reloads, with: .none)
                }
            }, completion: nil)
        case .partialReload(let indexPaths):
            tableNode.reloadRows(at: indexPaths, with: .none)
        }
    }

override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.registerPresence()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.unregisterPresence()
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        // UIKit view access — safe in viewDidLoad (main thread, view loaded)
        tableNode.view.separatorStyle = .none
        let composeButton = UIBarButtonItem(
            barButtonSystemItem: .compose,
            target: self,
            action: #selector(composeButtonTapped)
        )
        navigationItem.rightBarButtonItem = composeButton
    }

    @objc private func composeButtonTapped() {
        onComposeTapped?()
    }
}

// MARK: - Table Node Data Source & Delegate

extension RoomsViewController: ASTableDataSource, ASTableDelegate {

    func numberOfSections(in tableNode: ASTableNode) -> Int {
        return 1
    }

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        return viewModel.chats.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let chat = viewModel.chats[indexPath.row]
        return {
            return RoomsCellNode(chat: chat)
        }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        viewModel.selectChat(at: indexPath.row)
    }
}

extension RoomsViewController {
    func tableNode(_ tableNode: ASTableNode, canEditRowAt indexPath: IndexPath) -> Bool {
        return true
    }

    func tableNode(_ tableNode: ASTableNode, commitEditingStyle editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .delete {
            viewModel.deleteChat(at: indexPath.row)
            tableNode.deleteRows(at: [indexPath], with: .fade)
        }
    }
}

// MARK: - 120fps Scroll Boost

extension RoomsViewController {
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            fpsBooster.start()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fpsBooster.stop()
    }
}
