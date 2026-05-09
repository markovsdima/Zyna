//
// Copyright 2025 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class SettingsScreenNode: ASDisplayNode {
    weak var glassTopBar: GlassTopBar?
    weak var tableView: UITableView?
    weak var voicePlayerView: UIView?

    override init() {
        super.init()
        backgroundColor = .appBG
    }

    override var accessibilityElements: [Any]? {
        get {
            var elements: [Any] = []
            if let player = voicePlayerView,
               player.superview === view,
               !player.isHidden,
               player.alpha > 0.01 {
                elements.append(player)
            }
            if let glassTopBar, glassTopBar.view.superview === view {
                elements.append(contentsOf: glassTopBar.accessibilityElementsInOrder)
            }
            if let tableView, tableView.superview === view {
                elements.append(tableView)
            }
            return elements
        }
        set { }
    }
}

final class SettingsViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?
    var onThemeTapped: (() -> Void)?
    var onNameColorTapped: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case appearance
        case diagnostics

        var title: String {
            switch self {
            case .appearance:
                return String(localized: "Appearance")
            case .diagnostics:
                return String(localized: "Diagnostics")
            }
        }

        var rows: [Row] {
            switch self {
            case .appearance:
                return [.chatTheme, .nameColor]
            case .diagnostics:
                return [.repairLocalMessageCache]
            }
        }
    }

    private enum Row {
        case chatTheme
        case nameColor
        case repairLocalMessageCache
    }

    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()

    init(audioPlayer: AudioPlayerService? = nil) {
        super.init(node: SettingsScreenNode())
        self.voicePlayerHost = audioPlayer.map {
            EmbeddedVoiceTopPlayerHost(viewController: self, audioPlayer: $0)
        }
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        setupVoicePlayerHost()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
        tableView.reloadData()
        refreshOwnAppearance()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        voicePlayerHost?.layout()
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .appBG
        tableView.separatorStyle = .singleLine
        tableView.contentInsetAdjustmentBehavior = .never
        view.addSubview(tableView)
        node.tableView = tableView
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = tableView
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar

        let backIcon = AppIcon.chevronBackward.template(
            size: 17,
            weight: .semibold
        )
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Settings"), subtitle: nil)
        ]
    }

    private func setupVoicePlayerHost() {
        voicePlayerHost?.onVisibilityChanged = { [weak self] in
            self?.view.setNeedsLayout()
            GlassService.shared.setNeedsCapture()
        }
        voicePlayerHost?.install()
        node.voicePlayerView = voicePlayerHost?.accessibilityView
    }

    private func updateTableInsets() {
        let top = glassTopBar.coveredHeight
        if abs(tableView.contentInset.top - top) > 0.5 {
            tableView.contentInset.top = top
            tableView.verticalScrollIndicatorInsets.top = top
        }
        let bottom = max(view.safeAreaInsets.bottom + 16, 16)
        if abs(tableView.contentInset.bottom - bottom) > 0.5 {
            tableView.contentInset.bottom = bottom
            tableView.verticalScrollIndicatorInsets.bottom = bottom
        }
    }

    private func refreshOwnAppearance() {
        guard let userId = try? MatrixClientService.shared.client?.userId(),
              !userId.isEmpty else {
            return
        }
        Task { [weak self] in
            _ = await ProfileAppearanceService.shared.loadAppearance(userId: userId)
            await MainActor.run {
                self?.tableView.reloadRows(at: [IndexPath(row: 1, section: Section.appearance.rawValue)], with: .none)
            }
        }
    }

    private var nameColorSummary: String {
        guard let userId = try? MatrixClientService.shared.client?.userId(),
              let appearance = ProfileAppearanceService.shared.cachedAppearance(userId: userId),
              let nameColorHex = appearance.nameColorHex else {
            return String(localized: "Default")
        }
        return ProfileNameColorPalette.title(forHexString: nameColorHex)
    }
}

extension SettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        (Section(rawValue: section) ?? .appearance).rows.count
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        (Section(rawValue: section) ?? .appearance).title
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let section = Section(rawValue: indexPath.section) ?? .appearance
        let row = section.rows[indexPath.row]
        let identifier = row == .repairLocalMessageCache ? "subtitleCell" : "valueCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(
                style: row == .repairLocalMessageCache ? .subtitle : .value1,
                reuseIdentifier: identifier
            )
        switch row {
        case .chatTheme:
            cell.textLabel?.text = String(localized: "Chat Theme")
            cell.detailTextLabel?.text = ChatBubbleThemeStore.shared.selectedTheme.title
            cell.accessoryType = .disclosureIndicator
        case .nameColor:
            cell.textLabel?.text = String(localized: "Name Color")
            cell.detailTextLabel?.text = nameColorSummary
            cell.accessoryType = .disclosureIndicator
        case .repairLocalMessageCache:
            cell.textLabel?.text = String(localized: "Repair Local Message Cache")
            cell.detailTextLabel?.text = String(localized: "Fix duplicate or stuck local timeline rows")
            cell.accessoryType = .none
        }
        cell.selectionStyle = .default
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let section = Section(rawValue: indexPath.section) ?? .appearance
        let row = section.rows[indexPath.row]
        switch row {
        case .chatTheme:
            onThemeTapped?()
        case .nameColor:
            onNameColorTapped?()
        case .repairLocalMessageCache:
            confirmRepairLocalMessageCache()
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}

// MARK: - Local Timeline Repair

private extension SettingsViewController {

    func confirmRepairLocalMessageCache() {
        let alert = UIAlertController(
            title: String(localized: "Repair Local Message Cache"),
            message: String(localized: "This fixes local duplicate or stuck timeline rows. It does not delete messages from Matrix."),
            preferredStyle: .alert
        )
        alert.addAction(
            UIAlertAction(title: String(localized: "Cancel"), style: .cancel)
        )
        alert.addAction(
            UIAlertAction(title: String(localized: "Repair"), style: .default) { [weak self] _ in
                self?.repairLocalMessageCache()
            }
        )
        present(alert, animated: true)
    }

    func repairLocalMessageCache() {
        let progress = UIAlertController(
            title: String(localized: "Repairing"),
            message: nil,
            preferredStyle: .alert
        )
        present(progress, animated: true)

        Task { [weak self, weak progress] in
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try TimelineRepairService.shared.repairLocalTimelineCache()
                }.value
                await MainActor.run {
                    progress?.dismiss(animated: true) {
                        self?.presentRepairResult(result)
                    }
                }
            } catch {
                await MainActor.run {
                    progress?.dismiss(animated: true) {
                        self?.presentRepairError(error)
                    }
                }
            }
        }
    }

    func presentRepairResult(_ result: TimelineRepairResult) {
        let message: String
        if result.didChange {
            message = String(
                localized: "Updated messages: \(result.updatedMessages)\nDeleted local duplicates: \(result.deletedLocalMessages)\nUpdated envelope items: \(result.updatedEnvelopeItems)\nRetired envelopes: \(result.retiredEnvelopes)"
            )
        } else {
            message = String(localized: "No local timeline issues found.")
        }

        let alert = UIAlertController(
            title: String(localized: "Repair Complete"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    func presentRepairError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Repair Failed"),
            message: String(describing: error),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
