//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import Combine
import MatrixRustSDK

final class MembersListViewController: ASDKViewController<MembersListNode>, ASTableDataSource, ASTableDelegate {

    var onBack: (() -> Void)?
    var onSelectUser: ((String) -> Void)?

    private let viewModel: MembersListViewModel
    private var cancellables = Set<AnyCancellable>()
    private let glassTopBar = GlassTopBar()

    init(room: Room) {
        self.viewModel = MembersListViewModel(room: room)
        super.init(node: MembersListNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()

        node.tableNode.dataSource = self
        node.tableNode.delegate = self
        node.tableNode.view.separatorStyle = .none
        node.tableNode.view.contentInsetAdjustmentBehavior = .never

        setupGlassTopBar()

        viewModel.$rows
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.node.tableNode.reloadData()
            }
            .store(in: &cancellables)

        // Presence ticks bypass reloadData — we walk visible cells and
        // mutate the status line in place. Otherwise every tick tears
        // down all visible nodes (CONVENTIONS.md "Room list updates").
        viewModel.presenceTicks
            .receive(on: DispatchQueue.main)
            .sink { [weak self] statuses in
                self?.applyPresenceToVisibleCells(statuses)
            }
            .store(in: &cancellables)
    }

    private func applyPresenceToVisibleCells(_ statuses: [String: UserPresence]) {
        for indexPath in node.tableNode.indexPathsForVisibleRows() {
            guard indexPath.row < viewModel.rows.count,
                  case .member(let model) = viewModel.rows[indexPath.row],
                  let cell = node.tableNode.nodeForRow(at: indexPath) as? MemberCellNode
            else { continue }
            cell.updatePresence(statuses[model.userId])
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        glassTopBar.updateLayout(in: view)
        let top = glassTopBar.coveredHeight
        if node.tableNode.contentInset.top != top {
            node.tableNode.contentInset.top = top
            node.tableNode.view.verticalScrollIndicatorInsets.top = top
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        GlassService.shared.setNeedsCapture()
    }

    // MARK: - Scroll

    /// Glass capture is trigger-driven; without this the bar freezes.
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    // MARK: - Top bar

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .systemBackground
        glassTopBar.sourceView = node.tableNode.view
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.rendered(size: 17, weight: .semibold, color: AppColor.accent)
        // Items ordering matters: GlassTopBar uses the first .title or
        // .flexibleSpace as its divider, so .title must come right after
        // the left buttons — otherwise its shape/frame aren't drawn.
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Members"), subtitle: nil)
        ]
    }

    // MARK: - Data source

    func tableNode(_ tableNode: ASTableNode, numberOfRowsInSection section: Int) -> Int {
        viewModel.rows.count
    }

    func tableNode(_ tableNode: ASTableNode, nodeBlockForRowAt indexPath: IndexPath) -> ASCellNodeBlock {
        let row = viewModel.rows[indexPath.row]
        switch row {
        case .header(let title):
            return { Self.makeHeaderCell(title: title) }
        case .member(let model):
            return { MemberCellNode(model: model) }
        }
    }

    // MARK: - Delegate

    func tableNode(_ tableNode: ASTableNode, didSelectRowAt indexPath: IndexPath) {
        tableNode.deselectRow(at: indexPath, animated: true)
        guard indexPath.row < viewModel.rows.count else { return }
        if case .member(let model) = viewModel.rows[indexPath.row] {
            onSelectUser?(model.userId)
        }
    }

    func tableNode(_ tableNode: ASTableNode, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard indexPath.row < viewModel.rows.count else { return false }
        if case .header = viewModel.rows[indexPath.row] { return false }
        return true
    }

    // MARK: - Header row factory

    private static func makeHeaderCell(title: String) -> ASCellNode {
        let cell = ZynaCellNode()
        cell.selectionStyle = .none
        cell.backgroundColor = .systemGroupedBackground
        cell.automaticallyManagesSubnodes = true
        cell.isAccessibilityElement = true
        cell.accessibilityTraits = .header
        cell.accessibilityLabel = title

        let label = ASTextNode()
        label.attributedText = NSAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: UIFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: UIColor.secondaryLabel,
                .kern: 0.4
            ]
        )

        cell.layoutSpecBlock = { _, _ in
            ASInsetLayoutSpec(
                insets: UIEdgeInsets(top: 16, left: 16, bottom: 6, right: 16),
                child: label
            )
        }
        return cell
    }
}

// MARK: - Accessibility

extension MembersListViewController: AccessibilityFocusProviding {
    /// First element VO focuses on after push: the back button.
    var initialAccessibilityFocus: UIView? {
        glassTopBar.accessibilityElementsInOrder.first
    }
}
