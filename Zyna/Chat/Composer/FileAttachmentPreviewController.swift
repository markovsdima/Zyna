//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit
import UniformTypeIdentifiers

final class FileAttachmentPreviewController: UIViewController {

    var onDiscard: (() -> Void)?
    var onSend: (([ChatComposerAttachmentDraft], String) -> Void)?

    private var attachments: [ChatComposerAttachmentDraft]
    private var captionText: String

    private let dimView = UIView()
    private let cardView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let closeButton = UIButton(type: .system)
    private let listLayout = UICollectionViewFlowLayout()
    private lazy var listView = UICollectionView(frame: .zero, collectionViewLayout: listLayout)
    private let captionBackgroundView = UIView()
    private let captionLabel = UILabel()
    private let captionTextView = FileCaptionTextView()
    private let discardButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var cardBottomConstraint: NSLayoutConstraint?
    private var listHeightConstraint: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []
    private let dragStartFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let reorderFeedback = UIImpactFeedbackGenerator(style: .medium)
    private var lastHoverIndexPath: IndexPath?

    init(attachments: [ChatComposerAttachmentDraft], initialCaption: String) {
        self.attachments = attachments
        self.captionText = initialCaption
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .crossDissolve
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupViews()
        updateContent()
        startObservingKeyboard()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captionTextView.becomeFirstResponder()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        captionBackgroundView.layer.cornerRadius = floor(captionBackgroundView.bounds.height / 2)
        captionTextView.updateVerticalTextInset()
        updateLayoutMetrics(bottomInset: max(12, -(cardBottomConstraint?.constant ?? -12)))
    }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func setupViews() {
        view.backgroundColor = .clear

        dimView.translatesAutoresizingMaskIntoConstraints = false
        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        view.addSubview(dimView)

        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(closeTapped))
        dimView.addGestureRecognizer(dismissTap)

        cardView.translatesAutoresizingMaskIntoConstraints = false
        cardView.layer.cornerRadius = 30
        cardView.layer.cornerCurve = .continuous
        cardView.clipsToBounds = true
        view.addSubview(cardView)

        blurView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(blurView)

        closeButton.translatesAutoresizingMaskIntoConstraints = false
        closeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal
        )
        closeButton.tintColor = .white
        closeButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        closeButton.layer.cornerRadius = 18
        closeButton.layer.cornerCurve = .continuous
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        cardView.addSubview(closeButton)

        listLayout.scrollDirection = .vertical
        listLayout.minimumLineSpacing = 10
        listLayout.sectionInset = .zero
        listLayout.itemSize = CGSize(width: 100, height: 64)

        listView.translatesAutoresizingMaskIntoConstraints = false
        listView.backgroundColor = .clear
        listView.alwaysBounceVertical = true
        listView.showsVerticalScrollIndicator = false
        listView.dataSource = self
        listView.delegate = self
        listView.contentInset = .zero
        listView.register(FileAttachmentPreviewCell.self, forCellWithReuseIdentifier: FileAttachmentPreviewCell.reuseIdentifier)
        cardView.addSubview(listView)

        let reorderGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleReorderGesture(_:)))
        listView.addGestureRecognizer(reorderGesture)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.text = String(localized: "Caption")
        captionLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        cardView.addSubview(captionLabel)

        captionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        captionBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        captionBackgroundView.layer.cornerCurve = .continuous
        captionBackgroundView.layer.borderWidth = 1
        captionBackgroundView.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        cardView.addSubview(captionBackgroundView)

        captionTextView.translatesAutoresizingMaskIntoConstraints = false
        captionTextView.backgroundColor = .clear
        captionTextView.textColor = .white
        captionTextView.font = UIFont.systemFont(ofSize: 16)
        captionTextView.delegate = self
        captionTextView.returnKeyType = .default
        captionTextView.text = captionText
        captionTextView.tintColor = .white
        cardView.addSubview(captionTextView)

        discardButton.translatesAutoresizingMaskIntoConstraints = false
        discardButton.setTitle(String(localized: "Discard"), for: .normal)
        discardButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        discardButton.setTitleColor(UIColor.white.withAlphaComponent(0.9), for: .normal)
        discardButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        discardButton.layer.cornerRadius = 22
        discardButton.layer.cornerCurve = .continuous
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)
        cardView.addSubview(discardButton)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle(String(localized: "Send"), for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 17, weight: .semibold)
        sendButton.setTitleColor(.black, for: .normal)
        sendButton.backgroundColor = .white
        sendButton.layer.cornerRadius = 22
        sendButton.layer.cornerCurve = .continuous
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        cardView.addSubview(sendButton)

        cardBottomConstraint = cardView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12)
        listHeightConstraint = listView.heightAnchor.constraint(equalToConstant: 180)

        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 12),
            cardView.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -12),
            cardView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            cardView.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            cardView.widthAnchor.constraint(equalTo: view.widthAnchor, constant: -24).withPriority(.defaultHigh),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cardBottomConstraint!,

            blurView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: cardView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            closeButton.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            listView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 16),
            listView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            listView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            listHeightConstraint!,

            captionLabel.topAnchor.constraint(equalTo: listView.bottomAnchor, constant: 18),
            captionLabel.leadingAnchor.constraint(equalTo: listView.leadingAnchor, constant: 4),
            captionLabel.trailingAnchor.constraint(equalTo: listView.trailingAnchor),

            captionBackgroundView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 8),
            captionBackgroundView.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            captionBackgroundView.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            captionBackgroundView.heightAnchor.constraint(equalToConstant: 54),

            captionTextView.leadingAnchor.constraint(equalTo: captionBackgroundView.leadingAnchor),
            captionTextView.trailingAnchor.constraint(equalTo: captionBackgroundView.trailingAnchor),
            captionTextView.topAnchor.constraint(equalTo: captionBackgroundView.topAnchor),
            captionTextView.bottomAnchor.constraint(equalTo: captionBackgroundView.bottomAnchor),

            discardButton.topAnchor.constraint(equalTo: captionBackgroundView.bottomAnchor, constant: 18),
            discardButton.leadingAnchor.constraint(equalTo: listView.leadingAnchor),
            discardButton.heightAnchor.constraint(equalToConstant: 44),
            discardButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),

            sendButton.topAnchor.constraint(equalTo: discardButton.topAnchor),
            sendButton.trailingAnchor.constraint(equalTo: listView.trailingAnchor),
            sendButton.heightAnchor.constraint(equalTo: discardButton.heightAnchor),
            sendButton.leadingAnchor.constraint(greaterThanOrEqualTo: discardButton.trailingAnchor, constant: 12),
            sendButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 108)
        ])
    }

    private func updateContent() {
        sendButton.isEnabled = !attachments.isEmpty
        sendButton.alpha = attachments.isEmpty ? 0.5 : 1
        listView.reloadData()
        updateLayoutMetrics(bottomInset: max(12, -(cardBottomConstraint?.constant ?? -12)))
    }

    private func updateLayoutMetrics(bottomInset: CGFloat) {
        let listHeight = listHeight(forBottomInset: bottomInset)
        if listHeightConstraint?.constant != listHeight {
            listHeightConstraint?.constant = listHeight
        }
    }

    private func listHeight(forBottomInset bottomInset: CGFloat) -> CGFloat {
        let verticalMargin: CGFloat = 12
        let closeButtonTopPadding: CGFloat = 16
        let closeButtonHeight: CGFloat = 36
        let listTopSpacing: CGFloat = 16
        let topSectionHeight = closeButtonTopPadding + closeButtonHeight + listTopSpacing
        let captionTopPadding: CGFloat = 18
        let captionSpacing: CGFloat = 8
        let captionFieldHeight: CGFloat = 54
        let buttonsTopPadding: CGFloat = 18
        let buttonsHeight: CGFloat = 44
        let buttonsBottomPadding: CGFloat = 18
        let bottomSectionHeight =
            captionTopPadding
            + captionLabel.font.lineHeight
            + captionSpacing
            + captionFieldHeight
            + buttonsTopPadding
            + buttonsHeight
            + buttonsBottomPadding
        let availableCardHeight =
            view.bounds.height
            - view.safeAreaInsets.top
            - bottomInset
            - verticalMargin
        let availableListHeight = max(96, floor(availableCardHeight - topSectionHeight - bottomSectionHeight))
        let rowHeight: CGFloat = 64
        let spacing: CGFloat = 10
        let desiredHeight = attachments.reduce(CGFloat(0)) { partial, _ in
            partial + rowHeight + (partial == 0 ? 0 : spacing)
        }
        return min(max(96, desiredHeight), min(320, availableListHeight))
    }

    private func startObservingKeyboard() {
        let center = NotificationCenter.default
        let willChange = center.addObserver(
            forName: UIResponder.keyboardWillChangeFrameNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboard(notification)
        }
        let willHide = center.addObserver(
            forName: UIResponder.keyboardWillHideNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            self?.handleKeyboard(notification)
        }
        keyboardObservers = [willChange, willHide]
    }

    private func handleKeyboard(_ notification: Notification) {
        guard let endFrameValue = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue,
              let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double,
              let curveRaw = notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt
        else { return }

        let endFrame = view.convert(endFrameValue.cgRectValue, from: nil)
        let keyboardOverlap = max(0, view.bounds.maxY - endFrame.minY)
        let effectiveBottomInset = max(12, keyboardOverlap - view.safeAreaInsets.bottom + 12)

        cardBottomConstraint?.constant = -effectiveBottomInset
        updateLayoutMetrics(bottomInset: effectiveBottomInset)

        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    private func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        if attachments.isEmpty {
            dismiss(animated: true) { [onDiscard] in
                onDiscard?()
            }
            return
        }
        updateContent()
    }

    @objc private func closeTapped() {
        dismiss(animated: true) { [onDiscard] in
            onDiscard?()
        }
    }

    @objc private func discardTapped() {
        dismiss(animated: true) { [onDiscard] in
            onDiscard?()
        }
    }

    @objc private func sendTapped() {
        guard !attachments.isEmpty else { return }
        let attachments = self.attachments
        let captionText = self.captionText
        dismiss(animated: true) { [onSend] in
            onSend?(attachments, captionText)
        }
    }

    @objc private func handleReorderGesture(_ gesture: UILongPressGestureRecognizer) {
        guard attachments.count > 1 else { return }
        let location = gesture.location(in: listView)
        switch gesture.state {
        case .began:
            guard let indexPath = listView.indexPathForItem(at: location) else { return }
            lastHoverIndexPath = indexPath
            dragStartFeedback.impactOccurred(intensity: 0.9)
            reorderFeedback.prepare()
            listView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            listView.updateInteractiveMovementTargetPosition(location)
            if let indexPath = listView.indexPathForItem(at: location),
               indexPath != lastHoverIndexPath {
                reorderFeedback.impactOccurred(intensity: 0.9)
                reorderFeedback.prepare()
                lastHoverIndexPath = indexPath
            }
        case .ended:
            listView.endInteractiveMovement()
            lastHoverIndexPath = nil
        default:
            listView.cancelInteractiveMovement()
            lastHoverIndexPath = nil
        }
    }
}

extension FileAttachmentPreviewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        attachments.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: FileAttachmentPreviewCell.reuseIdentifier,
            for: indexPath
        ) as? FileAttachmentPreviewCell else {
            return UICollectionViewCell()
        }

        let attachment = attachments[indexPath.item]
        cell.configure(with: attachment)
        cell.onRemove = { [weak self, weak collectionView, weak cell] in
            guard let self,
                  let collectionView,
                  let cell,
                  let currentIndexPath = collectionView.indexPath(for: cell) else { return }
            self.removeAttachment(at: currentIndexPath.item)
        }
        return cell
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        attachments.count > 1
    }

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        CGSize(width: collectionView.bounds.width, height: 64)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard attachments.indices.contains(sourceIndexPath.item),
              attachments.indices.contains(destinationIndexPath.item) else { return }
        let attachment = attachments.remove(at: sourceIndexPath.item)
        attachments.insert(attachment, at: destinationIndexPath.item)
        updateContent()
    }
}

extension FileAttachmentPreviewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        captionText = textView.text ?? ""
        captionTextView.updateVerticalTextInset()
    }
}

private final class FileAttachmentPreviewCell: UICollectionViewCell {
    static let reuseIdentifier = "FileAttachmentPreviewCell"

    var onRemove: (() -> Void)?

    private let backgroundCard = UIView()
    private let iconBackgroundView = UIView()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()
    private let removeButton = UIButton(type: .system)
    private var iconWidthConstraint: NSLayoutConstraint!
    private var iconHeightConstraint: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)

        contentView.backgroundColor = .clear

        backgroundCard.translatesAutoresizingMaskIntoConstraints = false
        backgroundCard.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        backgroundCard.layer.cornerRadius = 20
        backgroundCard.layer.cornerCurve = .continuous
        backgroundCard.layer.borderWidth = 1
        backgroundCard.layer.borderColor = UIColor.white.withAlphaComponent(0.06).cgColor
        contentView.addSubview(backgroundCard)

        iconBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        iconBackgroundView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        iconBackgroundView.layer.cornerRadius = 14
        iconBackgroundView.layer.cornerCurve = .continuous
        backgroundCard.addSubview(iconBackgroundView)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .white
        iconBackgroundView.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.numberOfLines = 1
        backgroundCard.addSubview(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = UIColor.white.withAlphaComponent(0.62)
        subtitleLabel.numberOfLines = 1
        backgroundCard.addSubview(subtitleLabel)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)),
            for: .normal
        )
        removeButton.tintColor = .white
        removeButton.backgroundColor = UIColor.white.withAlphaComponent(0.14)
        removeButton.layer.cornerRadius = 14
        removeButton.layer.cornerCurve = .continuous
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        backgroundCard.addSubview(removeButton)

        iconWidthConstraint = iconView.widthAnchor.constraint(equalToConstant: 20)
        iconHeightConstraint = iconView.heightAnchor.constraint(equalToConstant: 20)

        NSLayoutConstraint.activate([
            backgroundCard.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backgroundCard.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backgroundCard.topAnchor.constraint(equalTo: contentView.topAnchor),
            backgroundCard.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            iconBackgroundView.leadingAnchor.constraint(equalTo: backgroundCard.leadingAnchor, constant: 12),
            iconBackgroundView.centerYAnchor.constraint(equalTo: backgroundCard.centerYAnchor),
            iconBackgroundView.widthAnchor.constraint(equalToConstant: 40),
            iconBackgroundView.heightAnchor.constraint(equalToConstant: 40),

            iconView.centerXAnchor.constraint(equalTo: iconBackgroundView.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackgroundView.centerYAnchor),
            iconWidthConstraint,
            iconHeightConstraint,

            removeButton.trailingAnchor.constraint(equalTo: backgroundCard.trailingAnchor, constant: -12),
            removeButton.centerYAnchor.constraint(equalTo: backgroundCard.centerYAnchor),
            removeButton.widthAnchor.constraint(equalToConstant: 28),
            removeButton.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: iconBackgroundView.trailingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: removeButton.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: backgroundCard.topAnchor, constant: 12),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            subtitleLabel.bottomAnchor.constraint(lessThanOrEqualTo: backgroundCard.bottomAnchor, constant: -12)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with attachment: ChatComposerAttachmentDraft) {
        titleLabel.text = attachment.title
        subtitleLabel.text = attachment.subtitle
        if let previewImage = attachment.previewImage {
            iconView.image = previewImage
            iconView.contentMode = .scaleAspectFill
            iconView.clipsToBounds = true
            iconView.layer.cornerRadius = 10
            iconView.tintColor = nil
            iconWidthConstraint.constant = 40
            iconHeightConstraint.constant = 40
            iconBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        } else {
            iconView.image = resolvedIcon(for: attachment)
            iconView.contentMode = .scaleAspectFit
            iconView.clipsToBounds = false
            iconView.layer.cornerRadius = 0
            iconView.tintColor = .white
            iconWidthConstraint.constant = 20
            iconHeightConstraint.constant = 20
            iconBackgroundView.backgroundColor = UIColor.white.withAlphaComponent(0.1)
        }
    }

    @objc private func removeTapped() {
        onRemove?()
    }

    private func resolvedIcon(for attachment: ChatComposerAttachmentDraft) -> UIImage? {
        guard case .file(let url) = attachment.payload else {
            return UIImage(systemName: "doc.fill")
        }

        let type = UTType(filenameExtension: url.pathExtension)
        let iconName: String
        if type?.conforms(to: .pdf) == true {
            iconName = "doc.richtext.fill"
        } else if type?.conforms(to: .image) == true {
            iconName = "photo.fill"
        } else if type?.conforms(to: .audiovisualContent) == true || type?.conforms(to: .movie) == true {
            iconName = "video.fill"
        } else if type?.conforms(to: .audio) == true {
            iconName = "music.note"
        } else if type?.conforms(to: .archive) == true {
            iconName = "archivebox.fill"
        } else if type?.conforms(to: .plainText) == true || type?.conforms(to: .text) == true {
            iconName = "doc.text.fill"
        } else {
            iconName = "doc.fill"
        }

        return UIImage(systemName: iconName)
    }
}

private final class FileCaptionTextView: UITextView {
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        textContainerInset = UIEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        self.textContainer.lineFragmentPadding = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func updateVerticalTextInset() {
        guard let font, bounds.height > 0 else { return }
        layoutManager.ensureLayout(for: textContainer)
        let usedHeight = max(font.lineHeight, ceil(layoutManager.usedRect(for: textContainer).height))
        let verticalInset = max(0, floor((bounds.height - usedHeight) / 2))
        let newInsets = UIEdgeInsets(
            top: verticalInset,
            left: 12,
            bottom: verticalInset,
            right: 12
        )
        if textContainerInset != newInsets {
            textContainerInset = newInsets
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateVerticalTextInset()
    }
}

private extension NSLayoutConstraint {
    func withPriority(_ priority: UILayoutPriority) -> NSLayoutConstraint {
        self.priority = priority
        return self
    }
}
