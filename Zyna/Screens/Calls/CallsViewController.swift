//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine

final class CallsScreenNode: ASDisplayNode {
    weak var tableNode: ASTableNode?
    weak var voicePlayerView: UIView?

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let player = voicePlayerView,
               player.superview === view,
               !player.isHidden,
               player.alpha > 0.01 {
                elements.append(player)
            }
            if let tableView = tableNode?.view, tableView.superview === view {
                elements.append(tableView)
            }
            return elements
        }
        set { }
    }
}

final class CallsViewController: ASDKViewController<CallsScreenNode> {

    private let viewModel = CallsViewModel()
    private let tableNode = ASTableNode()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?
    private var cancellables = Set<AnyCancellable>()

    var onCallTapped: ((String) -> Void)? {
        get { viewModel.onCallTapped }
        set { viewModel.onCallTapped = newValue }
    }

    init(audioPlayer: AudioPlayerService? = nil) {
        super.init(node: CallsScreenNode())
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        title = "Calls"
        setupTableNode()
        bindViewModel()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.reload()
        voicePlayerHost?.refresh()
        GlassService.shared.setNeedsCapture()
    }

    private func setupTableNode() {
        tableNode.delegate = self
        tableNode.dataSource = self
        tableNode.backgroundColor = .systemBackground
        node.backgroundColor = .systemBackground
        node.automaticallyManagesSubnodes = true
        node.tableNode = tableNode

        node.layoutSpecBlock = { [weak self] _, _ in
            guard let self else { return ASLayoutSpec() }
            return ASWrapperLayoutSpec(layoutElement: self.tableNode)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableNode.view.separatorStyle = .none
        setupVoicePlayerHost()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        voicePlayerHost?.layout()
    }

    private func bindViewModel() {
        viewModel.$calls
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.tableNode.reloadData()
            }
            .store(in: &cancellables)
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
    }
}

// MARK: - ASTableDataSource & ASTableDelegate

extension CallsViewController: ASTableDataSource, ASTableDelegate {

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.calls.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let model = viewModel.calls[indexPath.row]
        return { [weak self] in
            let cell = CallsCellNode(model: model)
            cell.onCallButtonTapped = { [weak self] in
                self?.viewModel.call(at: indexPath.row)
            }
            return cell
        }
    }

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        viewModel.call(at: indexPath.row)
    }
}
