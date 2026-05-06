//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import AsyncDisplayKit
import MatrixRustSDK

enum ProfileNameColorPalette {
    static let colors: [UIColor] = [
        .systemRed,
        .systemOrange,
        .systemYellow,
        .systemGreen,
        .systemTeal,
        .systemBlue,
        .systemIndigo,
        .systemPurple,
        .systemPink
    ]

    static func title(for color: UIColor) -> String {
        let hexString = color.hexString
        if hexString == UIColor.systemRed.hexString { return String(localized: "Red") }
        if hexString == UIColor.systemOrange.hexString { return String(localized: "Orange") }
        if hexString == UIColor.systemYellow.hexString { return String(localized: "Yellow") }
        if hexString == UIColor.systemGreen.hexString { return String(localized: "Green") }
        if hexString == UIColor.systemTeal.hexString { return String(localized: "Teal") }
        if hexString == UIColor.systemBlue.hexString { return String(localized: "Blue") }
        if hexString == UIColor.systemIndigo.hexString { return String(localized: "Indigo") }
        if hexString == UIColor.systemPurple.hexString { return String(localized: "Purple") }
        if hexString == UIColor.systemPink.hexString { return String(localized: "Pink") }
        return String(localized: "Color")
    }

    static func title(forHexString hexString: String) -> String {
        guard let normalized = ZynaProfileAppearance.normalizedColorHex(hexString) else {
            return hexString
        }
        if let paletteColor = colors.first(where: { $0.hexString == normalized }) {
            return title(for: paletteColor)
        }
        return normalized
    }
}

private struct ProfileNameColorCustomOption: Equatable {
    let id: String
    let title: String
    let hexString: String
    let isSaved: Bool
}

final class ProfileNameColorSettingsViewController: ASDKViewController<SettingsScreenNode> {

    var onBack: (() -> Void)?

    private struct ColorOption {
        let title: String
        let color: UIColor?
    }

    private enum Section {
        case custom
        case standard
    }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let glassTopBar = GlassTopBar()
    private let previewHeaderView = UIView()
    private let themeModeControl = UISegmentedControl(items: [
        String(localized: "Light"),
        String(localized: "Dark")
    ])
    private let previewView = NameColorGroupPreviewView()
    private let explanationLabel = UILabel()
    private let customControlsView = NameColorCustomControlsView()
    private let options: [ColorOption] = [
        ColorOption(title: String(localized: "Default"), color: nil)
    ] + ProfileNameColorPalette.colors.map {
        ColorOption(title: ProfileNameColorPalette.title(for: $0), color: $0)
    }

    private var ownUserId = ""
    private var ownDisplayName = String(localized: "You")
    private var selectedColor: UIColor? {
        didSet {
            previewView.update(displayName: ownDisplayName, userId: ownUserId, color: selectedColor)
        }
    }
    private var didSetInitialPreviewStyle = false
    private var isSaving = false
    private var savedCustomColors: [ProfileNameColorCustomOption] = []
    private var generatedCustomColors: [ProfileNameColorCustomOption] = []
    private var isEditingCustomColors = false

    private var sections: [Section] {
        savedCustomColors.isEmpty ? [.standard] : [.custom, .standard]
    }

    override init() {
        super.init(node: SettingsScreenNode())
        hidesBottomBarWhenPushed = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupTableView()
        setupGlassTopBar()
        loadOwnAppearance()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        setInitialPreviewStyleIfNeeded()
        GlassService.shared.setNeedsCapture()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        tableView.frame = view.bounds
        glassTopBar.updateLayout(in: view)
        updateTableInsets()
        updatePreviewHeaderLayout()
    }

    private func setupTableView() {
        tableView.dataSource = self
        tableView.delegate = self
        tableView.backgroundColor = .appBG
        tableView.separatorStyle = .singleLine
        tableView.contentInsetAdjustmentBehavior = .never
        tableView.rowHeight = 56
        setupPreviewControls()
        setupCustomControls()
        previewHeaderView.addSubview(previewView)
        previewHeaderView.addSubview(customControlsView)
        tableView.tableHeaderView = previewHeaderView
        view.addSubview(tableView)
        node.tableView = tableView
    }

    private func setupPreviewControls() {
        themeModeControl.selectedSegmentIndex = 0
        themeModeControl.addTarget(
            self,
            action: #selector(previewStyleChanged),
            for: .valueChanged
        )
        previewHeaderView.addSubview(themeModeControl)
        explanationLabel.text = String(localized: "Name Color Explanation")
        explanationLabel.font = UIFont.systemFont(ofSize: 13)
        explanationLabel.textColor = .secondaryLabel
        explanationLabel.numberOfLines = 0
        previewHeaderView.addSubview(explanationLabel)
    }

    private func setupCustomControls() {
        customControlsView.onRandomTapped = { [weak self] in
            self?.generateRandomColors()
        }
        customControlsView.onHexTapped = { [weak self] in
            self?.presentHexInput()
        }
        customControlsView.onSaveTapped = { [weak self] in
            self?.presentSaveCustomColor()
        }
        customControlsView.onColorTapped = { [weak self] option in
            self?.selectCustomColor(option)
        }
        reloadSavedCustomColors()
        updateCustomControls()
    }

    private func setupGlassTopBar() {
        glassTopBar.backdropClearColor = .appBG
        glassTopBar.sourceView = tableView
        node.addSubnode(glassTopBar)
        node.glassTopBar = glassTopBar
        rebuildGlassTopBar()
    }

    private func rebuildGlassTopBar() {
        let backIcon = AppIcon.chevronBackward.rendered(
            size: 17,
            weight: .semibold,
            color: AppColor.accent
        )
        let doneIcon = AppIcon.checkmark.rendered(
            size: 17,
            weight: .semibold,
            color: isSaving ? .tertiaryLabel : AppColor.accent
        )
        glassTopBar.items = [
            .circleButton(
                icon: backIcon,
                accessibilityLabel: String(localized: "Back"),
                action: { [weak self] in self?.onBack?() }
            ),
            .title(text: String(localized: "Name Color"), subtitle: nil),
            .circleButton(
                icon: doneIcon,
                accessibilityLabel: String(localized: "Done"),
                action: { [weak self] in self?.saveAndClose() }
            )
        ]
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

    private func updatePreviewHeaderLayout() {
        guard tableView.bounds.width > 0 else { return }
        let horizontalInset: CGFloat = 20
        let controlsHeight = customControlsView.preferredHeight
        let contentWidth = tableView.bounds.width - horizontalInset * 2
        let captionSize = explanationLabel.sizeThatFits(
            CGSize(width: contentWidth, height: CGFloat.greatestFiniteMagnitude)
        )
        let captionHeight = ceil(captionSize.height)
        let controlWidth = min(tableView.bounds.width - horizontalInset * 2, 260)
        themeModeControl.frame = CGRect(
            x: (tableView.bounds.width - controlWidth) / 2,
            y: 14,
            width: controlWidth,
            height: 34
        )
        let previewFrame = CGRect(
            x: horizontalInset,
            y: 62,
            width: contentWidth,
            height: 252
        )
        let captionFrame = CGRect(
            x: horizontalInset,
            y: previewFrame.maxY + 10,
            width: contentWidth,
            height: captionHeight
        )
        customControlsView.frame = CGRect(
            x: horizontalInset,
            y: captionFrame.maxY + 14,
            width: contentWidth,
            height: controlsHeight
        )
        let height = customControlsView.frame.maxY + 16
        if previewHeaderView.frame.width != tableView.bounds.width ||
            previewHeaderView.frame.height != height {
            previewHeaderView.frame = CGRect(
                x: 0,
                y: 0,
                width: tableView.bounds.width,
                height: height
            )
            tableView.tableHeaderView = previewHeaderView
        }
        previewView.frame = previewFrame
        explanationLabel.frame = captionFrame
    }

    private func loadOwnAppearance() {
        guard let client = MatrixClientService.shared.client else {
            previewView.update(displayName: ownDisplayName, userId: ownUserId, color: selectedColor)
            return
        }

        let userId = (try? client.userId()) ?? ""
        ownUserId = userId
        ownDisplayName = Self.previewDisplayName(
            cachedDisplayName: OwnProfileCache.shared.displayName(userId: userId),
            userId: userId
        )
        selectedColor = userId.isEmpty
            ? nil
            : ProfileAppearanceService.shared.cachedAppearance(userId: userId)?.nameColor
        previewView.update(displayName: ownDisplayName, userId: ownUserId, color: selectedColor)
        tableView.reloadData()
        updateCustomControls()

        Task { @MainActor in
            let displayName: String? = await Self.loadAndCacheOwnDisplayName(
                client: client,
                userId: userId
            )
            let appearance = userId.isEmpty
                ? nil
                : await ProfileAppearanceService.shared.loadAppearance(userId: userId, force: true)

            ownUserId = userId
            ownDisplayName = Self.previewDisplayName(
                cachedDisplayName: displayName,
                userId: userId
            )
            selectedColor = appearance?.nameColor
            previewView.update(displayName: ownDisplayName, userId: ownUserId, color: selectedColor)
            tableView.reloadData()
            updateCustomControls()
        }
    }

    private static func loadAndCacheOwnDisplayName(client: Client, userId: String) async -> String? {
        guard !userId.isEmpty else { return nil }
        do {
            let displayName = try await client.displayName()
            OwnProfileCache.shared.setDisplayName(displayName, userId: userId)
            return displayName
        } catch {
            return OwnProfileCache.shared.displayName(userId: userId)
        }
    }

    private static func previewDisplayName(cachedDisplayName: String?, userId: String) -> String {
        if let cachedDisplayName, !cachedDisplayName.isEmpty {
            return cachedDisplayName
        }
        return userId.isEmpty ? String(localized: "You") : userId
    }

    private func saveAndClose() {
        guard !isSaving else { return }
        isSaving = true
        rebuildGlassTopBar()

        Task { @MainActor in
            do {
                try await ProfileAppearanceService.shared.saveOwnAppearance(
                    ZynaProfileAppearance(nameColorHex: selectedColor?.hexString)
                )
                onBack?()
            } catch {
                isSaving = false
                rebuildGlassTopBar()
                presentSaveError()
            }
        }
    }

    private func presentSaveError() {
        let alert = UIAlertController(
            title: String(localized: "Unable to Save"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func selectOption(at indexPath: IndexPath) {
        guard indexPath.row < options.count else { return }
        selectedColor = options[indexPath.row].color
        tableView.reloadData()
        updateCustomControls()
    }

    private func optionIsSelected(_ option: ColorOption) -> Bool {
        option.color?.hexString == selectedColor?.hexString
    }

    private func fallbackNameColor() -> UIColor {
        guard !ownUserId.isEmpty else { return MessageCellHelpers.senderColors[1] }
        let index = MessageCellHelpers.stableHash(ownUserId) % MessageCellHelpers.senderColors.count
        return MessageCellHelpers.senderColors[index]
    }

    private func reloadSavedCustomColors() {
        savedCustomColors = ProfileNameCustomColorStore.shared.colors().map {
            ProfileNameColorCustomOption(
                id: $0.id,
                title: $0.name,
                hexString: $0.hexString,
                isSaved: true
            )
        }
    }

    private func updateCustomControls() {
        let selectedHexString = selectedColor?.hexString
        let canSaveSelectedGeneratedColor = selectedHexString.map { selectedHexString in
            generatedCustomColors.contains { $0.hexString == selectedHexString }
        } ?? false
        customControlsView.update(
            options: generatedCustomColors,
            selectedHexString: selectedHexString,
            canSave: canSaveSelectedGeneratedColor
        )
        updatePreviewHeaderLayout()
    }

    private func selectCustomColor(_ option: ProfileNameColorCustomOption) {
        guard let color = UIColor.fromHexString(option.hexString) else { return }
        selectedColor = color
        tableView.reloadData()
        updateCustomControls()
    }

    private func generateRandomColors() {
        generatedCustomColors = (0..<12).map { _ in
            let color = Self.makeRandomNameColor()
            return ProfileNameColorCustomOption(
                id: UUID().uuidString,
                title: color.hexString,
                hexString: color.hexString,
                isSaved: false
            )
        }
        if let first = generatedCustomColors.first {
            selectCustomColor(first)
        } else {
            updateCustomControls()
        }
    }

    private func presentHexInput() {
        let alert = UIAlertController(
            title: String(localized: "Enter Hex Color"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.placeholder = String(localized: "Hex Color Placeholder")
            textField.autocapitalizationType = .allCharacters
            textField.autocorrectionType = .no
            textField.clearButtonMode = .whileEditing
            textField.rightView = Self.makeHexPasteButton(for: textField)
            textField.rightViewMode = .always
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Add"), style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let raw = alert?.textFields?.first?.text,
                  let normalized = ZynaProfileAppearance.normalizedColorHex(raw) else {
                self?.presentInvalidHexError()
                return
            }
            let option = ProfileNameColorCustomOption(
                id: UUID().uuidString,
                title: normalized,
                hexString: normalized,
                isSaved: false
            )
            generatedCustomColors.removeAll { $0.hexString == normalized }
            generatedCustomColors.insert(option, at: 0)
            selectCustomColor(option)
        })
        present(alert, animated: true)
    }

    private static func makeHexPasteButton(for textField: UITextField) -> UIView {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 36, height: 30))
        let button = UIButton(type: .system)
        button.frame = CGRect(x: 4, y: 0, width: 30, height: 30)
        button.setImage(UIImage(systemName: "doc.on.clipboard"), for: .normal)
        button.tintColor = AppColor.accent
        button.accessibilityLabel = String(localized: "Paste")
        button.addAction(UIAction { [weak textField] _ in
            let pasted = UIPasteboard.general.string?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let pasted, !pasted.isEmpty else { return }
            textField?.text = pasted
        }, for: .touchUpInside)
        container.addSubview(button)
        return container
    }

    private func presentInvalidHexError() {
        let alert = UIAlertController(
            title: String(localized: "Invalid Hex Color"),
            message: String(localized: "Use #RRGGBB or RRGGBB."),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }

    private func presentSaveCustomColor() {
        guard let selectedColor else { return }
        let hexString = selectedColor.hexString
        let alert = UIAlertController(
            title: String(localized: "Save Color"),
            message: hexString,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            let paletteTitle = ProfileNameColorPalette.title(forHexString: hexString)
            textField.text = paletteTitle == hexString ? String(localized: "Custom Color") : paletteTitle
            textField.placeholder = String(localized: "Color Name")
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let rawName = alert?.textFields?.first?.text ?? ""
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = trimmed.isEmpty ? hexString : trimmed
            let saved = ProfileNameCustomColorStore.shared.saveColor(name: name, hexString: hexString)
            generatedCustomColors.removeAll { $0.hexString == hexString }
            savedCustomColors.removeAll { $0.hexString == hexString }
            savedCustomColors.insert(
                ProfileNameColorCustomOption(
                    id: saved.id,
                    title: saved.name,
                    hexString: saved.hexString,
                    isSaved: true
                ),
                at: 0
            )
            tableView.reloadData()
            updateCustomControls()
        })
        present(alert, animated: true)
    }

    @objc private func toggleCustomColorEditing() {
        guard !savedCustomColors.isEmpty else { return }
        isEditingCustomColors.toggle()
        tableView.setEditing(isEditingCustomColors, animated: true)
        tableView.reloadData()
    }

    private func presentRenameCustomColor(_ option: ProfileNameColorCustomOption) {
        let alert = UIAlertController(
            title: String(localized: "Rename Color"),
            message: option.hexString,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = option.title
            textField.placeholder = String(localized: "Color Name")
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let self else { return }
            let rawName = alert?.textFields?.first?.text ?? ""
            let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  let index = savedCustomColors.firstIndex(where: { $0.id == option.id }) else {
                return
            }
            ProfileNameCustomColorStore.shared.renameColor(id: option.id, name: trimmed)
            savedCustomColors[index] = ProfileNameColorCustomOption(
                id: option.id,
                title: trimmed,
                hexString: option.hexString,
                isSaved: true
            )
            tableView.reloadData()
        })
        present(alert, animated: true)
    }

    private func presentRenameCustomColor(id: String) {
        guard let option = savedCustomColors.first(where: { $0.id == id }) else { return }
        presentRenameCustomColor(option)
    }

    private func deleteCustomColor(id: String) {
        guard let index = savedCustomColors.firstIndex(where: { $0.id == id }) else { return }
        let removed = savedCustomColors.remove(at: index)
        ProfileNameCustomColorStore.shared.deleteColor(id: removed.id)
        let customSection = sections.firstIndex(of: .custom)
        if savedCustomColors.isEmpty {
            isEditingCustomColors = false
            tableView.setEditing(false, animated: true)
            tableView.reloadData()
        } else if let customSection {
            tableView.deleteRows(at: [IndexPath(row: index, section: customSection)], with: .automatic)
        } else {
            tableView.reloadData()
        }
        updateCustomControls()
    }

    private func persistSavedCustomColors() {
        let colors = savedCustomColors.map {
            ProfileNameCustomColor(id: $0.id, name: $0.title, hexString: $0.hexString)
        }
        ProfileNameCustomColorStore.shared.replaceColors(colors)
    }

    private static func makeRandomNameColor() -> UIColor {
        UIColor(
            hue: CGFloat.random(in: 0...1),
            saturation: CGFloat.random(in: 0.58...0.88),
            brightness: CGFloat.random(in: 0.58...0.86),
            alpha: 1
        )
    }

    private func setInitialPreviewStyleIfNeeded() {
        guard !didSetInitialPreviewStyle else { return }
        didSetInitialPreviewStyle = true
        let style = currentAppUserInterfaceStyle()
        themeModeControl.selectedSegmentIndex = style == .dark ? 1 : 0
        previewView.setPreviewUserInterfaceStyle(style)
    }

    private func currentAppUserInterfaceStyle() -> UIUserInterfaceStyle {
        let style = view.window?.traitCollection.userInterfaceStyle ?? traitCollection.userInterfaceStyle
        return style == .dark ? .dark : .light
    }

    @objc private func previewStyleChanged() {
        let style: UIUserInterfaceStyle = themeModeControl.selectedSegmentIndex == 1 ? .dark : .light
        previewView.setPreviewUserInterfaceStyle(style)
    }

}

extension ProfileNameColorSettingsViewController: UITableViewDataSource, UITableViewDelegate {

    func numberOfSections(in tableView: UITableView) -> Int {
        sections.count
    }

    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        switch sections[section] {
        case .custom:
            return savedCustomColors.count
        case .standard:
            return options.count
        }
    }

    func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        switch sections[section] {
        case .custom:
            return nil
        case .standard:
            return String(localized: "Standard Colors")
        }
    }

    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        guard sections[section] == .custom else { return nil }
        let header = NameColorCustomSectionHeaderView()
        header.titleLabel.text = String(localized: "My Colors")
        header.editButton.setTitle(
            isEditingCustomColors ? String(localized: "Done") : String(localized: "Edit"),
            for: .normal
        )
        header.editButton.addTarget(self, action: #selector(toggleCustomColorEditing), for: .touchUpInside)
        return header
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        sections[section] == .custom ? 42 : 34
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        switch sections[indexPath.section] {
        case .custom:
            return customColorCell(for: indexPath, in: tableView)
        case .standard:
            return standardColorCell(for: indexPath, in: tableView)
        }
    }

    private func standardColorCell(for indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let identifier = "standardNameColorCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        let option = options[indexPath.row]

        cell.textLabel?.text = option.title
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.detailTextLabel?.text = nil
        cell.imageView?.image = ProfileNameColorSwatchImage.make(
            color: option.color,
            fallbackColor: fallbackNameColor()
        )
        cell.accessoryType = optionIsSelected(option) ? .checkmark : .none
        cell.tintColor = AppColor.accent
        cell.selectionStyle = .default
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    private func customColorCell(for indexPath: IndexPath, in tableView: UITableView) -> UITableViewCell {
        let identifier = "customNameColorCell"
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .value1, reuseIdentifier: identifier)
        let option = savedCustomColors[indexPath.row]

        cell.textLabel?.text = option.title
        cell.textLabel?.font = UIFont.systemFont(ofSize: 17)
        cell.detailTextLabel?.text = option.hexString
        cell.detailTextLabel?.font = UIFont.systemFont(ofSize: 13)
        cell.imageView?.image = ProfileNameColorSwatchImage.make(
            color: UIColor.fromHexString(option.hexString),
            fallbackColor: fallbackNameColor()
        )
        cell.accessoryType = isEditingCustomColors
            ? .none
            : (option.hexString == selectedColor?.hexString ? .checkmark : .none)
        cell.editingAccessoryView = isEditingCustomColors
            ? makeCustomColorEditingAccessory(option: option)
            : nil
        cell.showsReorderControl = isEditingCustomColors
        cell.tintColor = AppColor.accent
        cell.selectionStyle = .default
        cell.backgroundColor = .secondarySystemGroupedBackground
        return cell
    }

    private func makeCustomColorEditingAccessory(option: ProfileNameColorCustomOption) -> UIView {
        let view = NameColorEditingAccessoryView()
        view.onRename = { [weak self] in
            self?.presentRenameCustomColor(id: option.id)
        }
        view.onDelete = { [weak self] in
            self?.deleteCustomColor(id: option.id)
        }
        return view
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch sections[indexPath.section] {
        case .custom:
            if isEditingCustomColors {
                presentRenameCustomColor(savedCustomColors[indexPath.row])
            } else {
                selectCustomColor(savedCustomColors[indexPath.row])
            }
        case .standard:
            selectOption(at: indexPath)
        }
    }

    func tableView(_ tableView: UITableView, accessoryButtonTappedForRowWith indexPath: IndexPath) {
        guard sections[indexPath.section] == .custom else { return }
        presentRenameCustomColor(savedCustomColors[indexPath.row])
    }

    func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        isEditingCustomColors && sections[indexPath.section] == .custom
    }

    func tableView(
        _ tableView: UITableView,
        editingStyleForRowAt indexPath: IndexPath
    ) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    func tableView(
        _ tableView: UITableView,
        leadingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        emptySwipeActions()
    }

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        emptySwipeActions()
    }

    func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        sections[indexPath.section] == .custom
    }

    func tableView(
        _ tableView: UITableView,
        targetIndexPathForMoveFromRowAt sourceIndexPath: IndexPath,
        toProposedIndexPath proposedDestinationIndexPath: IndexPath
    ) -> IndexPath {
        sections[proposedDestinationIndexPath.section] == .custom
            ? proposedDestinationIndexPath
            : sourceIndexPath
    }

    func tableView(
        _ tableView: UITableView,
        moveRowAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sections[sourceIndexPath.section] == .custom,
              sections[destinationIndexPath.section] == .custom else { return }
        let moved = savedCustomColors.remove(at: sourceIndexPath.row)
        savedCustomColors.insert(moved, at: destinationIndexPath.row)
        persistSavedCustomColors()
    }

    func tableView(
        _ tableView: UITableView,
        commit editingStyle: UITableViewCell.EditingStyle,
        forRowAt indexPath: IndexPath
    ) {
        return
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        GlassService.shared.setNeedsCapture()
    }

    private func emptySwipeActions() -> UISwipeActionsConfiguration {
        let configuration = UISwipeActionsConfiguration(actions: [])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }
}

private enum ProfileNameColorSwatchImage {
    static func make(color: UIColor?, fallbackColor: UIColor, size: CGFloat = 34) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        return renderer.image { context in
            let rect = CGRect(x: 0, y: 0, width: size, height: size)
            let circleRect = rect.insetBy(dx: 2, dy: 2)

            if let color {
                context.cgContext.setFillColor(color.cgColor)
                context.cgContext.fillEllipse(in: circleRect)
            } else {
                drawAutomaticSwatch(in: circleRect, context: context.cgContext)
            }

            context.cgContext.setStrokeColor(UIColor.separator.cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.strokeEllipse(in: circleRect.insetBy(dx: 0.5, dy: 0.5))

            if color == nil {
                context.cgContext.setStrokeColor(fallbackColor.cgColor)
                context.cgContext.setLineWidth(3)
                context.cgContext.strokeEllipse(in: circleRect.insetBy(dx: 4, dy: 4))
            }
        }
    }

    private static func drawAutomaticSwatch(in rect: CGRect, context: CGContext) {
        let colors = MessageCellHelpers.senderColors
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2
        for (index, color) in colors.enumerated() {
            let start = CGFloat(index) / CGFloat(colors.count) * CGFloat.pi * 2
            let end = CGFloat(index + 1) / CGFloat(colors.count) * CGFloat.pi * 2
            context.move(to: center)
            context.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: false)
            context.closePath()
            context.setFillColor(color.cgColor)
            context.fillPath()
        }
    }
}

private final class NameColorEditingAccessoryView: UIView {
    var onRename: (() -> Void)?
    var onDelete: (() -> Void)?

    private let renameButton = UIButton(type: .system)
    private let deleteButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: CGRect(x: 0, y: 0, width: 76, height: 34))
        setupButton(
            renameButton,
            icon: AppIcon.pencil.rendered(size: 15, weight: .semibold, color: AppColor.accent),
            accessibilityLabel: String(localized: "Rename"),
            action: #selector(renameTapped)
        )
        setupButton(
            deleteButton,
            icon: AppIcon.trash.rendered(size: 17, weight: .semibold, color: AppColor.destructive),
            accessibilityLabel: String(localized: "Delete"),
            action: #selector(deleteTapped)
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: 76, height: 34)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        renameButton.frame = CGRect(x: 0, y: 0, width: 34, height: 34)
        deleteButton.frame = CGRect(x: 42, y: 0, width: 34, height: 34)
    }

    private func setupButton(
        _ button: UIButton,
        icon: UIImage,
        accessibilityLabel: String,
        action: Selector
    ) {
        button.setImage(icon, for: .normal)
        button.backgroundColor = .tertiarySystemGroupedBackground
        button.layer.cornerRadius = 17
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.accessibilityLabel = accessibilityLabel
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    @objc private func renameTapped() {
        onRename?()
    }

    @objc private func deleteTapped() {
        onDelete?()
    }
}

private final class NameColorCustomSectionHeaderView: UIView {
    let titleLabel = UILabel()
    let editButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .secondaryLabel
        editButton.titleLabel?.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        addSubview(titleLabel)
        addSubview(editButton)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 20
        let buttonWidth: CGFloat = 80
        titleLabel.frame = CGRect(
            x: horizontalInset,
            y: bounds.height - 28,
            width: max(0, bounds.width - horizontalInset * 2 - buttonWidth),
            height: 22
        )
        editButton.frame = CGRect(
            x: bounds.width - horizontalInset - buttonWidth,
            y: bounds.height - 32,
            width: buttonWidth,
            height: 30
        )
    }
}

private final class NameColorCustomControlsView: UIView {

    var onRandomTapped: (() -> Void)?
    var onHexTapped: (() -> Void)?
    var onSaveTapped: (() -> Void)?
    var onColorTapped: ((ProfileNameColorCustomOption) -> Void)?

    private let randomButton = UIButton(type: .system)
    private let hexButton = UIButton(type: .system)
    private let saveButton = UIButton(type: .system)
    private let scrollView = UIScrollView()
    private var colorButtons: [UIButton] = []
    private var options: [ProfileNameColorCustomOption] = []
    private var selectedHexString: String?

    var preferredHeight: CGFloat {
        options.isEmpty ? 36 : 132
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let diceIcon = UIImage(
            systemName: "die.face.5.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        )
        setupButton(
            randomButton,
            title: String(localized: "Random"),
            icon: diceIcon,
            action: #selector(randomTapped)
        )
        setupButton(
            hexButton,
            title: String(localized: "Enter Hex"),
            action: #selector(hexTapped)
        )
        setupButton(
            saveButton,
            title: String(localized: "Save Color"),
            action: #selector(saveTapped)
        )

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        options: [ProfileNameColorCustomOption],
        selectedHexString: String?,
        canSave: Bool
    ) {
        self.options = options
        self.selectedHexString = selectedHexString
        saveButton.isEnabled = canSave && selectedHexString != nil
        saveButton.alpha = saveButton.isEnabled ? 1.0 : 0.45
        rebuildColorButtons()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let buttonGap: CGFloat = 10
        let buttonWidth = floor((bounds.width - buttonGap) / 2)
        randomButton.frame = CGRect(x: 0, y: 0, width: buttonWidth, height: 36)
        hexButton.frame = CGRect(x: buttonWidth + buttonGap, y: 0, width: buttonWidth, height: 36)

        let showsPalette = !options.isEmpty
        scrollView.isHidden = !showsPalette
        saveButton.isHidden = !showsPalette
        guard showsPalette else { return }

        scrollView.frame = CGRect(x: 0, y: 48, width: bounds.width, height: 42)
        saveButton.frame = CGRect(x: 0, y: 96, width: bounds.width, height: 36)

        let swatchSize: CGFloat = 38
        let spacing: CGFloat = 10
        var x: CGFloat = 0
        for button in colorButtons {
            button.frame = CGRect(x: x, y: 2, width: swatchSize, height: swatchSize)
            x += swatchSize + spacing
        }
        scrollView.contentSize = CGSize(width: max(scrollView.bounds.width + 1, x - spacing), height: 42)
    }

    private func setupButton(_ button: UIButton, title: String, icon: UIImage? = nil, action: Selector) {
        var attributedTitle = AttributedString(title)
        attributedTitle.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        var configuration = UIButton.Configuration.filled()
        configuration.attributedTitle = attributedTitle
        configuration.image = icon
        configuration.imagePlacement = .leading
        configuration.imagePadding = icon == nil ? 0 : 6
        configuration.baseForegroundColor = AppColor.accent
        configuration.baseBackgroundColor = .secondarySystemGroupedBackground
        configuration.background.cornerRadius = 8
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 10)
        button.configuration = configuration
        button.layer.cornerRadius = 8
        button.layer.cornerCurve = .continuous
        button.clipsToBounds = true
        button.addTarget(self, action: action, for: .touchUpInside)
        addSubview(button)
    }

    private func rebuildColorButtons() {
        colorButtons.forEach { $0.removeFromSuperview() }
        colorButtons = options.enumerated().map { index, option in
            let button = UIButton(type: .custom)
            button.tag = index
            button.accessibilityLabel = option.title
            button.layer.cornerRadius = 7
            button.layer.cornerCurve = .continuous
            button.layer.borderWidth = option.hexString == selectedHexString ? 3 : 1
            button.layer.borderColor = (option.hexString == selectedHexString ? AppColor.accent : UIColor.separator).cgColor
            button.backgroundColor = UIColor.fromHexString(option.hexString)
            button.addTarget(self, action: #selector(colorTapped(_:)), for: .touchUpInside)
            scrollView.addSubview(button)
            return button
        }
    }

    @objc private func randomTapped() {
        onRandomTapped?()
    }

    @objc private func hexTapped() {
        onHexTapped?()
    }

    @objc private func saveTapped() {
        onSaveTapped?()
    }

    @objc private func colorTapped(_ sender: UIButton) {
        guard sender.tag < options.count else { return }
        onColorTapped?(options[sender.tag])
    }
}

private final class NameColorGroupPreviewView: UIView {

    private let peerOne = PreviewIncomingClusterView(
        sender: "Mira",
        userId: "@mira:zyna.local",
        senderColor: .systemPurple,
        messages: [
            PreviewIncomingClusterView.Message(
                body: String(localized: "Can you check this?"),
                time: "12:40",
                widthRatio: 0.72
            )
        ]
    )
    private let ownCluster = PreviewIncomingClusterView(
        sender: String(localized: "You"),
        userId: "",
        senderColor: .systemBlue,
        messages: [
            PreviewIncomingClusterView.Message(
                body: String(localized: "I picked this name color."),
                time: "12:41",
                widthRatio: 0.92
            ),
            PreviewIncomingClusterView.Message(
                body: String(localized: "This is how it looks in groups."),
                time: "12:42",
                widthRatio: 0.82
            )
        ]
    )
    private let peerTwo = PreviewIncomingClusterView(
        sender: "Alex",
        userId: "@alex:zyna.local",
        senderColor: .systemTeal,
        messages: [
            PreviewIncomingClusterView.Message(
                body: String(localized: "Ship it."),
                time: "12:43",
                widthRatio: 0.52
            )
        ]
    )

    private var displayName = String(localized: "You")
    private var userId = ""
    private var selectedColor: UIColor?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = AppColor.chatBackground
        layer.cornerRadius = 8
        layer.cornerCurve = .continuous
        clipsToBounds = true
        addSubview(peerOne)
        addSubview(ownCluster)
        addSubview(peerTwo)
        update(displayName: displayName, userId: userId, color: selectedColor)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(displayName: String, userId: String, color: UIColor?) {
        self.displayName = displayName
        self.userId = userId
        self.selectedColor = color
        ownCluster.update(
            sender: displayName,
            userId: userId,
            senderColor: color ?? fallbackNameColor()
        )
    }

    func setPreviewUserInterfaceStyle(_ style: UIUserInterfaceStyle) {
        overrideUserInterfaceStyle = style
        applyColors()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 14
        let contentWidth = min(bounds.width - horizontalInset * 2, 322)
        peerOne.frame = CGRect(
            x: horizontalInset,
            y: 12,
            width: contentWidth,
            height: 58
        )
        ownCluster.frame = CGRect(
            x: horizontalInset,
            y: 76,
            width: contentWidth,
            height: 114
        )
        peerTwo.frame = CGRect(
            x: horizontalInset,
            y: 196,
            width: contentWidth,
            height: 50
        )
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) != false else {
            return
        }
        applyColors()
    }

    private func applyColors() {
        backgroundColor = AppColor.chatBackground
        peerOne.applyColors()
        ownCluster.applyColors()
        peerTwo.applyColors()
    }

    private func fallbackNameColor() -> UIColor {
        guard !userId.isEmpty else { return MessageCellHelpers.senderColors[1] }
        let index = MessageCellHelpers.stableHash(userId) % MessageCellHelpers.senderColors.count
        return MessageCellHelpers.senderColors[index]
    }
}

private final class PreviewIncomingClusterView: UIView {

    struct Message {
        let body: String
        let time: String
        let widthRatio: CGFloat
    }

    private var sender: String {
        didSet { senderLabel.text = sender }
    }

    private var senderColor: UIColor {
        didSet { senderLabel.textColor = senderColor }
    }

    private var userId: String
    private let messages: [Message]
    private let avatarDiameter: CGFloat = 32
    private let avatarImageView = UIImageView()
    private let senderLabel = UILabel()
    private let bubbles: [PreviewGroupBubbleView]

    init(sender: String, userId: String, senderColor: UIColor, messages: [Message]) {
        self.sender = sender
        self.userId = userId
        self.senderColor = senderColor
        self.messages = messages
        self.bubbles = messages.map { PreviewGroupBubbleView(body: $0.body, time: $0.time) }
        super.init(frame: .zero)

        avatarImageView.contentMode = .scaleAspectFill
        addSubview(avatarImageView)

        senderLabel.text = sender
        senderLabel.font = UIFont.systemFont(ofSize: 13, weight: .semibold)
        senderLabel.textColor = senderColor
        senderLabel.lineBreakMode = .byTruncatingTail
        addSubview(senderLabel)

        bubbles.forEach(addSubview)
        updateAvatar()
        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(sender: String, userId: String, senderColor: UIColor) {
        self.sender = sender
        self.userId = userId
        self.senderColor = senderColor
        updateAvatar()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let contentX = avatarDiameter + 4
        let contentWidth = max(0, bounds.width - contentX)
        senderLabel.frame = CGRect(
            x: contentX + 12,
            y: 0,
            width: max(0, contentWidth - 12),
            height: 16
        )

        var y: CGFloat = 18
        for (index, bubble) in bubbles.enumerated() {
            let ratio = messages[index].widthRatio
            let maxBubbleWidth = min(contentWidth * ratio, 248)
            let bubbleSize = bubble.preferredSize(maxWidth: maxBubbleWidth)
            bubble.frame = CGRect(x: contentX, y: y, width: bubbleSize.width, height: bubbleSize.height)
            y += bubbleSize.height + 4
        }

        avatarImageView.frame = CGRect(
            x: 0,
            y: max(0, y - 4 - avatarDiameter),
            width: avatarDiameter,
            height: avatarDiameter
        )
    }

    func applyColors() {
        bubbles.forEach { $0.applyColors() }
    }

    private func updateAvatar() {
        let avatarUserId = userId.isEmpty ? "@you:zyna.local" : userId
        let avatar = AvatarViewModel(
            userId: avatarUserId,
            displayName: sender,
            mxcAvatarURL: nil,
            colorOverrideHex: senderColor.hexString
        )
        avatarImageView.image = avatar.circleImage(diameter: avatarDiameter, fontSize: 13)
    }
}

private final class PreviewGroupBubbleView: UIView {

    private let bodyLabel = UILabel()
    private let timeLabel = UILabel()

    init(body: String, time: String) {
        super.init(frame: .zero)

        layer.cornerRadius = MessageCellHelpers.bubbleCornerRadius
        layer.cornerCurve = .continuous
        clipsToBounds = true

        bodyLabel.text = body
        bodyLabel.font = UIFont.systemFont(ofSize: 16)
        bodyLabel.numberOfLines = 1
        bodyLabel.lineBreakMode = .byTruncatingTail
        addSubview(bodyLabel)

        timeLabel.text = time
        timeLabel.font = UIFont.systemFont(ofSize: 11)
        timeLabel.textAlignment = .right
        addSubview(timeLabel)

        applyColors()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let horizontalInset: CGFloat = 12
        let timeWidth: CGFloat = 42
        let bodyHeight = ceil(bodyLabel.font.lineHeight)
        let timeHeight = ceil(timeLabel.font.lineHeight)
        let textWidth = max(0, bounds.width - horizontalInset * 2 - timeWidth - 4)
        bodyLabel.frame = CGRect(
            x: horizontalInset,
            y: 7,
            width: textWidth,
            height: bodyHeight
        )
        timeLabel.frame = CGRect(
            x: bounds.width - horizontalInset - timeWidth,
            y: bounds.height - 7 - timeHeight,
            width: timeWidth,
            height: timeHeight
        )
    }

    func preferredSize(maxWidth: CGFloat) -> CGSize {
        let horizontalInset: CGFloat = 12
        let timeSpacing: CGFloat = 6
        let bodyWidth = ceil(bodyLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude)).width)
        let timeWidth = ceil(timeLabel.sizeThatFits(CGSize(width: maxWidth, height: .greatestFiniteMagnitude)).width)
        let naturalWidth = horizontalInset * 2 + bodyWidth + timeSpacing + timeWidth
        return CGSize(
            width: min(maxWidth, max(68, naturalWidth)),
            height: 36
        )
    }

    func applyColors() {
        backgroundColor = AppColor.bubbleBackgroundIncoming
        bodyLabel.textColor = AppColor.bubbleForegroundIncoming
        timeLabel.textColor = AppColor.bubbleTimestampIncoming
    }
}
