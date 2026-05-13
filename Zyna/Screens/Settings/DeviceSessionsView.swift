//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit

final class DeviceSessionsViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private let refreshControl = UIRefreshControl()
    private var voicePlayerHost: EmbeddedVoiceTopPlayerHost?

    private var devices: [MatrixDevice] = []
    private var currentDeviceId: String?
    private var isLoading = false
    private var errorMessage: String?

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
        loadDevices()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        voicePlayerHost?.refresh()
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
        tableView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refreshPulled), for: .valueChanged)
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
            .title(text: String(localized: "Devices"), subtitle: nil)
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

    @objc private func refreshPulled() {
        loadDevices()
    }

    private func loadDevices() {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        tableView.reloadData()

        Task { [weak self] in
            do {
                let loadedDevices = try await MatrixDeviceService.shared.devices()
                let currentDeviceId = MatrixDeviceService.shared.currentDeviceId
                await MainActor.run {
                    self?.devices = loadedDevices
                    self?.currentDeviceId = currentDeviceId
                    self?.isLoading = false
                    self?.refreshControl.endRefreshing()
                    self?.tableView.reloadData()
                }
            } catch {
                await MainActor.run {
                    self?.errorMessage = error.localizedDescription
                    self?.isLoading = false
                    self?.refreshControl.endRefreshing()
                    self?.tableView.reloadData()
                }
            }
        }
    }

    private func device(at indexPath: IndexPath) -> MatrixDevice? {
        guard !devices.isEmpty, indexPath.row < devices.count else { return nil }
        return devices[indexPath.row]
    }

    private func isCurrentDevice(_ device: MatrixDevice) -> Bool {
        device.deviceId == currentDeviceId
    }

    private func presentActions(for device: MatrixDevice) {
        if isCurrentDevice(device) {
            let alert = UIAlertController(
                title: String(localized: "This Device"),
                message: String(localized: "This is the device you are using now."),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
            return
        }

        let title = device.displayName?.isEmpty == false
            ? device.displayName
            : device.deviceId
        let sheet = UIAlertController(
            title: title,
            message: device.deviceId,
            preferredStyle: .actionSheet
        )
        sheet.addAction(UIAlertAction(title: String(localized: "Sign Out Device"), style: .destructive) { [weak self] _ in
            self?.presentPasswordPrompt(for: device)
        })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))

        if let popover = sheet.popoverPresentationController {
            if let index = devices.firstIndex(of: device),
               let cell = tableView.cellForRow(at: IndexPath(row: index, section: 0)) {
                popover.sourceView = cell
                popover.sourceRect = cell.bounds
            } else {
                popover.sourceView = view
                popover.sourceRect = CGRect(x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
                popover.permittedArrowDirections = []
            }
        }
        present(sheet, animated: true)
    }

    private func presentPasswordPrompt(for device: MatrixDevice) {
        let alert = UIAlertController(
            title: String(localized: "Sign Out Device"),
            message: String(localized: "Enter your current password to sign out this device."),
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = String(localized: "Current Password")
            textField.isSecureTextEntry = true
            textField.textContentType = .password
            textField.returnKeyType = .done
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Sign Out"), style: .destructive) { [weak self, weak alert] _ in
            let password = alert?.textFields?.first?.text ?? ""
            guard !password.isEmpty else {
                self?.presentError(MatrixDeviceServiceError.invalidPassword(String(localized: "Enter your current password.")))
                return
            }
            self?.delete(device: device, password: password)
        })
        present(alert, animated: true)
    }

    private func delete(device: MatrixDevice, password: String) {
        let progress = UIAlertController(
            title: String(localized: "Signing Out"),
            message: nil,
            preferredStyle: .alert
        )
        present(progress, animated: true)

        Task { [weak self, weak progress] in
            do {
                try await MatrixDeviceService.shared.deleteDevice(
                    deviceId: device.deviceId,
                    currentPassword: password
                )
                await MainActor.run {
                    progress?.dismiss(animated: true) {
                        self?.devices.removeAll { $0.deviceId == device.deviceId }
                        self?.tableView.reloadData()
                    }
                }
            } catch {
                await MainActor.run {
                    progress?.dismiss(animated: true) {
                        self?.presentError(error)
                    }
                }
            }
        }
    }

    private func presentError(_ error: Error) {
        let alert = UIAlertController(
            title: String(localized: "Could Not Sign Out Device"),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func title(for device: MatrixDevice) -> String {
        if let displayName = device.displayName?.trimmingCharacters(in: .whitespacesAndNewlines),
           !displayName.isEmpty {
            return displayName
        }
        return String(localized: "Unnamed Device")
    }

    private func detail(for device: MatrixDevice) -> String {
        var parts: [String] = [device.deviceId]
        if isCurrentDevice(device) {
            parts.append(String(localized: "This device"))
        }

        var lines = [parts.joined(separator: " | ")]
        var lastSeenParts: [String] = []
        if let lastSeen = lastSeenText(for: device.lastSeenTimestamp) {
            lastSeenParts.append(lastSeen)
        }
        if let ip = device.lastSeenIp?.trimmingCharacters(in: .whitespacesAndNewlines),
           !ip.isEmpty {
            lastSeenParts.append(ip)
        }
        if !lastSeenParts.isEmpty {
            lines.append(lastSeenParts.joined(separator: " | "))
        }
        return lines.joined(separator: "\n")
    }

    private func lastSeenText(for timestamp: Int64?) -> String? {
        guard let timestamp, timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return String(localized: "Last seen \(formatter.localizedString(for: date, relativeTo: Date()))")
    }
}

extension DeviceSessionsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        devices.isEmpty ? 1 : devices.count
    }

    func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "Signing out another device invalidates the access token associated with that device.")
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let identifier = "deviceCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: identifier)
        cell.backgroundColor = .secondarySystemGroupedBackground
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
        cell.detailTextLabel?.textColor = .secondaryLabel
        cell.detailTextLabel?.numberOfLines = 2
        cell.tintColor = AppColor.accent

        guard let device = device(at: indexPath) else {
            if isLoading {
                cell.textLabel?.text = String(localized: "Loading Devices")
            } else if errorMessage != nil {
                cell.textLabel?.text = String(localized: "Could Not Load Devices")
            } else {
                cell.textLabel?.text = String(localized: "No Devices")
            }
            cell.detailTextLabel?.text = errorMessage
            cell.selectionStyle = errorMessage == nil ? .none : .default
            cell.accessoryType = .none
            return cell
        }

        cell.textLabel?.text = title(for: device)
        cell.detailTextLabel?.text = detail(for: device)
        cell.selectionStyle = .default
        cell.accessoryType = isCurrentDevice(device) ? .checkmark : .disclosureIndicator
        return cell
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)

        guard let device = device(at: indexPath) else {
            if errorMessage != nil {
                loadDevices()
            }
            return
        }
        presentActions(for: device)
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let device = device(at: indexPath), !isCurrentDevice(device) else {
            return nil
        }

        let action = UIContextualAction(
            style: .destructive,
            title: String(localized: "Sign Out")
        ) { [weak self] _, _, completion in
            self?.presentPasswordPrompt(for: device)
            completion(true)
        }

        return UISwipeActionsConfiguration(actions: [action])
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }
}
