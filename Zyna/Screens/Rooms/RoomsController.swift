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
        super.init(node: RoomsScreenNode())

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

        // Manual subnode management — automaticallyManagesSubnodes
        // would fight with our manual frame setting in viewDidLayoutSubviews.
        node.automaticallyManagesSubnodes = false
        node.addSubnode(tableNode)
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
                    self?.glassTopBar.subtitle = nil
                case .error:
                    self?.glassTopBar.subtitle = "Connection error"
                default:
                    self?.glassTopBar.subtitle = "Connecting..."
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
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        viewModel.unregisterPresence()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableNode.view.separatorStyle = .none
        tableNode.view.keyboardDismissMode = .onDrag

        let tap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        tap.cancelsTouchesInView = false
        tableNode.view.addGestureRecognizer(tap)

        setupHeaderBar()
    }

    @objc private func dismissKeyboard() {
        view.endEditing(true)
    }

    // MARK: - Glass Top Bar

    private let glassTopBar = GlassTopBar()

    private func setupHeaderBar() {
        glassTopBar.sourceView = tableNode.view
        glassTopBar.backdropClearColor = .systemBackground

        let composeIcon = AppIcon.compose.rendered(size: 17, weight: .medium, color: AppColor.accent)

        glassTopBar.items = [
            .title(text: "Chats test", subtitle: nil),
            .circleButton(icon: composeIcon, accessibilityLabel: "New message", action: { [weak self] in
                self?.onComposeTapped?()
            })
        ]

        node.addSubnode(glassTopBar)
        (node as? RoomsScreenNode)?.glassTopBar = glassTopBar
        (node as? RoomsScreenNode)?.tableNode = tableNode
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableNode.frame = node.bounds
        glassTopBar.updateLayout(in: view)

        let covered = glassTopBar.coveredHeight
        if tableNode.contentInset.top != covered {
            tableNode.contentInset.top = covered
            tableNode.view.verticalScrollIndicatorInsets.top = covered
        }
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
        view.endEditing(true)
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
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if decelerate {
            fpsBooster.start()
        }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        fpsBooster.stop()
    }
}

// MARK: - Screen node with accessibility-friendly element order

/// Glass top bar must be first in the accessibility tree so VoiceOver
/// hit-tests it before the table cells visually behind it.
final class RoomsScreenNode: ScreenNode {
    weak var glassTopBar: ASDisplayNode?
    weak var tableNode: ASDisplayNode?

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let bar = glassTopBar?.view, bar.superview === view {
                elements.append(bar)
            }
            if let table = tableNode?.view {
                elements.append(table)
            }
            return elements
        }
        set { }
    }
}
