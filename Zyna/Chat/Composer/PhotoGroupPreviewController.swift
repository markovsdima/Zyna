//
// Copyright 2026 Dmitry Markovsky
// SPDX-License-Identifier: AGPL-3.0-only
//

import UIKit

final class PhotoGroupPreviewController: UIViewController {

    var onDiscard: (() -> Void)?
    var onSend: (([ChatComposerAttachmentDraft], String, CaptionPlacement, MediaGroupLayoutOverride?) -> Void)?

    private var attachments: [ChatComposerAttachmentDraft]
    private var captionText: String
    private var captionPlacement: CaptionPlacement
    private var layoutOverride: MediaGroupLayoutOverride?

    private let dimView = UIView()
    private let cardView = UIView()
    private let blurView = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterialDark))
    private let closeButton = UIButton(type: .system)
    private let resetLayoutButton = UIButton(type: .system)
    private let previewView = PhotoGroupBubblePreviewView()
    private let captionBackgroundView = UIView()
    private let captionLabel = UILabel()
    private let captionTextView = CenteredCaptionTextView()
    private let thumbnailsLayout = UICollectionViewFlowLayout()
    private lazy var thumbnailsView = UICollectionView(frame: .zero, collectionViewLayout: thumbnailsLayout)
    private let discardButton = UIButton(type: .system)
    private let sendButton = UIButton(type: .system)
    private var cardBottomConstraint: NSLayoutConstraint?
    private var previewHeightConstraint: NSLayoutConstraint?
    private var captionHeightConstraint: NSLayoutConstraint?
    private var thumbnailsHeightConstraint: NSLayoutConstraint?
    private var buttonsTopToThumbnailsConstraint: NSLayoutConstraint?
    private var buttonsTopToCaptionConstraint: NSLayoutConstraint?
    private var keyboardObservers: [NSObjectProtocol] = []
    private let thumbnailDragStartFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let thumbnailReorderFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let resetLayoutFeedback = UIImpactFeedbackGenerator(style: .rigid)
    private var lastThumbnailHoverIndexPath: IndexPath?

    private var usesThumbnailStrip: Bool {
        attachments.count > PhotoGroupLayout.maxVisibleItems
    }

    init(
        attachments: [ChatComposerAttachmentDraft],
        initialCaption: String,
        initialCaptionPlacement: CaptionPlacement
    ) {
        self.attachments = attachments
        self.captionText = initialCaption
        self.captionPlacement = initialCaptionPlacement
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
        updatePreview()
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
    }

    deinit {
        keyboardObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func setupViews() {
        view.backgroundColor = .clear

        dimView.backgroundColor = UIColor.black.withAlphaComponent(0.5)
        dimView.translatesAutoresizingMaskIntoConstraints = false
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

        var resetButtonConfig = UIButton.Configuration.plain()
        resetButtonConfig.image = UIImage(
            systemName: "arrow.counterclockwise",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        )
        resetButtonConfig.title = String(localized: "Reset")
        resetButtonConfig.baseForegroundColor = .white
        resetButtonConfig.imagePadding = 4
        resetButtonConfig.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 10, bottom: 6, trailing: 10)
        resetLayoutButton.translatesAutoresizingMaskIntoConstraints = false
        resetLayoutButton.configuration = resetButtonConfig
        resetLayoutButton.backgroundColor = UIColor.white.withAlphaComponent(0.12)
        resetLayoutButton.layer.cornerRadius = 15
        resetLayoutButton.layer.cornerCurve = .continuous
        resetLayoutButton.isHidden = true
        resetLayoutButton.addTarget(self, action: #selector(resetLayoutTapped), for: .touchUpInside)
        cardView.addSubview(resetLayoutButton)

        previewView.translatesAutoresizingMaskIntoConstraints = false
        previewView.onRemoveAttachment = { [weak self] index in
            self?.removeAttachment(at: index)
        }
        previewView.onMoveAttachment = { [weak self] sourceIndex, destinationIndex in
            guard let self,
                  self.attachments.indices.contains(sourceIndex),
                  self.attachments.indices.contains(destinationIndex) else { return }
            let attachment = self.attachments.remove(at: sourceIndex)
            self.attachments.insert(attachment, at: destinationIndex)
        }
        previewView.onCaptionPlacementChanged = { [weak self] placement in
            self?.captionPlacement = placement
        }
        previewView.onLayoutOverrideChanged = { [weak self] layoutOverride in
            self?.layoutOverride = layoutOverride
            self?.updateResetLayoutButtonState()
        }
        cardView.addSubview(previewView)

        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.text = String(localized: "Caption")
        captionLabel.font = UIFont.systemFont(ofSize: 13, weight: .medium)
        captionLabel.textColor = UIColor.white.withAlphaComponent(0.72)
        cardView.addSubview(captionLabel)

        captionBackgroundView.translatesAutoresizingMaskIntoConstraints = false
        captionBackgroundView.backgroundColor = UIColor.black.withAlphaComponent(0.18)
        captionBackgroundView.layer.cornerRadius = 18
        captionBackgroundView.layer.cornerCurve = .continuous
        captionBackgroundView.layer.borderWidth = 1
        captionBackgroundView.layer.borderColor = UIColor.white.withAlphaComponent(0.08).cgColor
        cardView.addSubview(captionBackgroundView)

        captionTextView.translatesAutoresizingMaskIntoConstraints = false
        captionTextView.backgroundColor = .clear
        captionTextView.textColor = .white
        captionTextView.font = UIFont.systemFont(ofSize: 16)
        captionTextView.delegate = self
        captionTextView.isScrollEnabled = true
        captionTextView.showsVerticalScrollIndicator = false
        captionTextView.text = captionText
        captionTextView.returnKeyType = .default
        captionBackgroundView.addSubview(captionTextView)

        thumbnailsLayout.scrollDirection = .horizontal
        thumbnailsLayout.minimumInteritemSpacing = 8
        thumbnailsLayout.minimumLineSpacing = 8
        thumbnailsLayout.itemSize = CGSize(width: 72, height: 72)

        thumbnailsView.translatesAutoresizingMaskIntoConstraints = false
        thumbnailsView.backgroundColor = .clear
        thumbnailsView.showsHorizontalScrollIndicator = false
        thumbnailsView.alwaysBounceHorizontal = true
        thumbnailsView.dataSource = self
        thumbnailsView.delegate = self
        thumbnailsView.dragInteractionEnabled = false
        thumbnailsView.register(PhotoGroupThumbnailCell.self, forCellWithReuseIdentifier: PhotoGroupThumbnailCell.reuseIdentifier)
        cardView.addSubview(thumbnailsView)

        let reorderGesture = UILongPressGestureRecognizer(target: self, action: #selector(handleThumbnailReorder(_:)))
        thumbnailsView.addGestureRecognizer(reorderGesture)

        discardButton.translatesAutoresizingMaskIntoConstraints = false
        discardButton.setTitle(String(localized: "Discard"), for: .normal)
        discardButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        discardButton.setTitleColor(.white, for: .normal)
        discardButton.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        discardButton.layer.cornerRadius = 22
        discardButton.layer.cornerCurve = .continuous
        discardButton.addTarget(self, action: #selector(discardTapped), for: .touchUpInside)
        cardView.addSubview(discardButton)

        sendButton.translatesAutoresizingMaskIntoConstraints = false
        sendButton.setTitle(String(localized: "Send"), for: .normal)
        sendButton.titleLabel?.font = UIFont.systemFont(ofSize: 16, weight: .semibold)
        sendButton.setTitleColor(AppColor.onAccent, for: .normal)
        sendButton.backgroundColor = AppColor.accent
        sendButton.layer.cornerRadius = 22
        sendButton.layer.cornerCurve = .continuous
        sendButton.addTarget(self, action: #selector(sendTapped), for: .touchUpInside)
        cardView.addSubview(sendButton)

        let cardBottomConstraint = cardView.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor,
            constant: -12
        )
        self.cardBottomConstraint = cardBottomConstraint

        let previewHeightConstraint = previewView.heightAnchor.constraint(equalToConstant: 332)
        previewHeightConstraint.priority = .defaultHigh
        self.previewHeightConstraint = previewHeightConstraint

        let captionHeightConstraint = captionBackgroundView.heightAnchor.constraint(equalToConstant: 54)
        self.captionHeightConstraint = captionHeightConstraint

        let thumbnailsHeightConstraint = thumbnailsView.heightAnchor.constraint(equalToConstant: 72)
        self.thumbnailsHeightConstraint = thumbnailsHeightConstraint

        let buttonsTopToThumbnailsConstraint = discardButton.topAnchor.constraint(
            equalTo: thumbnailsView.bottomAnchor,
            constant: 18
        )
        self.buttonsTopToThumbnailsConstraint = buttonsTopToThumbnailsConstraint

        let buttonsTopToCaptionConstraint = discardButton.topAnchor.constraint(
            equalTo: captionBackgroundView.bottomAnchor,
            constant: 18
        )
        self.buttonsTopToCaptionConstraint = buttonsTopToCaptionConstraint

        NSLayoutConstraint.activate([
            dimView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dimView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dimView.topAnchor.constraint(equalTo: view.topAnchor),
            dimView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            cardView.topAnchor.constraint(greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            cardBottomConstraint,

            blurView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: cardView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            closeButton.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -16),
            closeButton.topAnchor.constraint(equalTo: cardView.topAnchor, constant: 16),
            closeButton.widthAnchor.constraint(equalToConstant: 36),
            closeButton.heightAnchor.constraint(equalToConstant: 36),

            resetLayoutButton.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 16),
            resetLayoutButton.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            resetLayoutButton.heightAnchor.constraint(equalToConstant: 30),

            previewView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 20),
            previewView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -20),
            previewView.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 12),
            previewHeightConstraint,

            captionLabel.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            captionLabel.topAnchor.constraint(equalTo: previewView.bottomAnchor, constant: 18),

            captionBackgroundView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            captionBackgroundView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            captionBackgroundView.topAnchor.constraint(equalTo: captionLabel.bottomAnchor, constant: 8),
            captionHeightConstraint,

            captionTextView.leadingAnchor.constraint(equalTo: captionBackgroundView.leadingAnchor),
            captionTextView.trailingAnchor.constraint(equalTo: captionBackgroundView.trailingAnchor),
            captionTextView.topAnchor.constraint(equalTo: captionBackgroundView.topAnchor),
            captionTextView.bottomAnchor.constraint(equalTo: captionBackgroundView.bottomAnchor),

            thumbnailsView.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            thumbnailsView.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            thumbnailsView.topAnchor.constraint(equalTo: captionBackgroundView.bottomAnchor, constant: 16),
            thumbnailsHeightConstraint,

            discardButton.leadingAnchor.constraint(equalTo: previewView.leadingAnchor),
            discardButton.heightAnchor.constraint(equalToConstant: 44),
            discardButton.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -18),

            sendButton.trailingAnchor.constraint(equalTo: previewView.trailingAnchor),
            sendButton.heightAnchor.constraint(equalTo: discardButton.heightAnchor),
            sendButton.leadingAnchor.constraint(equalTo: discardButton.trailingAnchor, constant: 12),
            sendButton.widthAnchor.constraint(equalTo: discardButton.widthAnchor)
        ])

        sendButton.topAnchor.constraint(equalTo: discardButton.topAnchor).isActive = true
        buttonsTopToCaptionConstraint.isActive = true

        previewView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        previewView.setContentHuggingPriority(.defaultLow, for: .vertical)
        captionBackgroundView.setContentCompressionResistancePriority(.required, for: .vertical)
        captionBackgroundView.setContentHuggingPriority(.required, for: .vertical)
        captionTextView.setContentCompressionResistancePriority(.required, for: .vertical)
        captionTextView.setContentHuggingPriority(.required, for: .vertical)
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
        previewHeightConstraint?.constant = previewHeight(forBottomInset: effectiveBottomInset)

        let options = UIView.AnimationOptions(rawValue: curveRaw << 16)
        UIView.animate(withDuration: duration, delay: 0, options: options) {
            self.view.layoutIfNeeded()
        }
    }

    private func previewHeight(forBottomInset bottomInset: CGFloat) -> CGFloat {
        let verticalMargin: CGFloat = 12
        let closeButtonTopPadding: CGFloat = 16
        let closeButtonHeight: CGFloat = 36
        let previewTopSpacing: CGFloat = 12
        let captionTopPadding: CGFloat = 18
        let captionSpacing: CGFloat = 8
        let captionFieldHeight: CGFloat = 54
        let buttonsTopPadding: CGFloat = 18
        let buttonsHeight: CGFloat = 44
        let buttonsBottomPadding: CGFloat = 18

        let availableCardHeight =
            view.bounds.height
            - view.safeAreaInsets.top
            - bottomInset
            - verticalMargin
        let topSectionHeight = closeButtonTopPadding + closeButtonHeight + previewTopSpacing
        let bottomSectionHeight =
            captionTopPadding
            + captionLabel.font.lineHeight
            + captionSpacing
            + captionFieldHeight
            + (usesThumbnailStrip ? 16 + 72 : 0)
            + buttonsTopPadding
            + buttonsHeight
            + buttonsBottomPadding
        let availablePreviewHeight = availableCardHeight - topSectionHeight - bottomSectionHeight
        return min(332, max(84, floor(availablePreviewHeight)))
    }

    private func updatePreview() {
        layoutOverride = PhotoGroupLayout.sanitizedLayoutOverride(
            layoutOverride,
            itemCount: attachments.count
        )
        updateResetLayoutButtonState()
        previewView.isDirectEditingEnabled = !usesThumbnailStrip
        previewView.isCaptionPlacementEditingEnabled = !attachments.isEmpty
        previewView.update(
            attachments: attachments,
            captionText: captionText,
            captionPlacement: captionPlacement,
            layoutOverride: layoutOverride
        )
        thumbnailsView.isHidden = !usesThumbnailStrip
        thumbnailsHeightConstraint?.constant = usesThumbnailStrip ? 72 : 0
        buttonsTopToThumbnailsConstraint?.isActive = usesThumbnailStrip
        buttonsTopToCaptionConstraint?.isActive = !usesThumbnailStrip
        let bottomInset = max(12, -(cardBottomConstraint?.constant ?? -12))
        previewHeightConstraint?.constant = previewHeight(forBottomInset: bottomInset)
        sendButton.isEnabled = !attachments.isEmpty
        sendButton.alpha = attachments.isEmpty ? 0.5 : 1
        thumbnailsView.reloadData()
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

    @objc private func resetLayoutTapped() {
        guard layoutOverride != nil else { return }
        layoutOverride = nil
        resetLayoutFeedback.impactOccurred(intensity: 0.9)
        updatePreview()
    }

    private func updateResetLayoutButtonState() {
        let canShowResetButton =
            !usesThumbnailStrip
            && PhotoGroupLayout.supportsInteractiveLayout(for: attachments.count)
        resetLayoutButton.isHidden = !canShowResetButton
        resetLayoutButton.isEnabled = canShowResetButton && layoutOverride != nil
        resetLayoutButton.alpha = canShowResetButton
            ? (layoutOverride == nil ? 0.55 : 1)
            : 0
    }

    @objc private func sendTapped() {
        guard !attachments.isEmpty else { return }
        let attachments = self.attachments
        let captionText = self.captionText
        let captionPlacement = self.captionPlacement
        let layoutOverride = self.layoutOverride
        dismiss(animated: true) { [onSend] in
            onSend?(attachments, captionText, captionPlacement, layoutOverride)
        }
    }

    @objc private func handleThumbnailReorder(_ gesture: UILongPressGestureRecognizer) {
        let location = gesture.location(in: thumbnailsView)
        switch gesture.state {
        case .began:
            guard let indexPath = thumbnailsView.indexPathForItem(at: location) else { return }
            lastThumbnailHoverIndexPath = indexPath
            thumbnailDragStartFeedback.impactOccurred(intensity: 0.9)
            thumbnailReorderFeedback.prepare()
            thumbnailsView.beginInteractiveMovementForItem(at: indexPath)
        case .changed:
            if let indexPath = thumbnailsView.indexPathForItem(at: location),
               indexPath != lastThumbnailHoverIndexPath {
                lastThumbnailHoverIndexPath = indexPath
                thumbnailReorderFeedback.impactOccurred(intensity: 0.9)
                thumbnailReorderFeedback.prepare()
            }
            thumbnailsView.updateInteractiveMovementTargetPosition(location)
        case .ended:
            lastThumbnailHoverIndexPath = nil
            thumbnailsView.endInteractiveMovement()
            updatePreview()
        default:
            lastThumbnailHoverIndexPath = nil
            thumbnailsView.cancelInteractiveMovement()
        }
    }

    private func removeAttachment(at index: Int) {
        guard attachments.indices.contains(index) else { return }
        attachments.remove(at: index)
        layoutOverride = PhotoGroupLayout.sanitizedLayoutOverride(
            layoutOverride,
            itemCount: attachments.count
        )
        if attachments.isEmpty {
            dismiss(animated: true) { [onDiscard] in
                onDiscard?()
            }
            return
        }
        updatePreview()
    }
}

extension PhotoGroupPreviewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        captionText = textView.text ?? ""
        captionTextView.updateVerticalTextInset()
        previewView.update(
            attachments: attachments,
            captionText: captionText,
            captionPlacement: captionPlacement,
            layoutOverride: layoutOverride
        )
    }
}

extension PhotoGroupPreviewController: UICollectionViewDataSource, UICollectionViewDelegateFlowLayout {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        attachments.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: PhotoGroupThumbnailCell.reuseIdentifier,
            for: indexPath
        ) as? PhotoGroupThumbnailCell else {
            return UICollectionViewCell()
        }

        let attachment = attachments[indexPath.item]
        cell.configure(with: attachment.previewImage)
        cell.onRemove = { [weak self] in
            self?.removeAttachment(at: indexPath.item)
        }
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        canMoveItemAt indexPath: IndexPath
    ) -> Bool {
        true
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        let attachment = attachments.remove(at: sourceIndexPath.item)
        attachments.insert(attachment, at: destinationIndexPath.item)
    }
}

private final class PhotoGroupThumbnailCell: UICollectionViewCell {
    static let reuseIdentifier = "PhotoGroupThumbnailCell"

    var onRemove: (() -> Void)?

    private let imageView = UIImageView()
    private let removeButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentView.clipsToBounds = false

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.layer.cornerRadius = 18
        imageView.layer.cornerCurve = .continuous
        imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
        contentView.addSubview(imageView)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        removeButton.setImage(
            UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)),
            for: .normal
        )
        removeButton.tintColor = .white
        removeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
        removeButton.layer.cornerRadius = 12
        removeButton.layer.cornerCurve = .continuous
        removeButton.addTarget(self, action: #selector(removeTapped), for: .touchUpInside)
        contentView.addSubview(removeButton)

        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            removeButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.heightAnchor.constraint(equalToConstant: 24),
            removeButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            removeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(with image: UIImage?) {
        imageView.image = image
    }

    @objc private func removeTapped() {
        onRemove?()
    }
}

private final class PhotoGroupBubblePreviewView: UIView {
    var onRemoveAttachment: ((Int) -> Void)?
    var onMoveAttachment: ((Int, Int) -> Void)?
    var onCaptionPlacementChanged: ((CaptionPlacement) -> Void)?
    var onLayoutOverrideChanged: ((MediaGroupLayoutOverride?) -> Void)?

    var isDirectEditingEnabled = true {
        didSet {
            guard isDirectEditingEnabled != oldValue else { return }
            if !isDirectEditingEnabled {
                cancelActiveDrag()
            }
            updateEditingControls()
        }
    }

    var isCaptionPlacementEditingEnabled = true {
        didSet {
            guard isCaptionPlacementEditingEnabled != oldValue else { return }
            if !isCaptionPlacementEditingEnabled {
                cancelActiveCaptionDrag()
            }
            updateEditingControls()
        }
    }

    private let bubbleView = UIView()
    private let mediaContainerView = UIView()
    private let captionContainerView = UIView()
    private let captionLabel = UILabel()
    private let overflowLabel = UILabel()
    private let primaryDividerGuideView = UIView()
    private let secondaryDividerGuideView = UIView()
    private let primaryHandleView = DividerHandleView(axis: .horizontal)
    private let secondaryHandleView = DividerHandleView(axis: .vertical)
    private var imageViews: [UIImageView] = []
    private var removeButtons: [UIButton] = []
    private var attachments: [ChatComposerAttachmentDraft] = []
    private var captionText = ""
    private var captionPlacement: CaptionPlacement = .bottom
    private var layoutOverride: MediaGroupLayoutOverride?
    private var slotFrames: [CGRect] = []
    private var captionFrame: CGRect = .zero
    private let dragStartFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let reorderFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let captionDragStartFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let captionPlacementFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let layoutDragStartFeedback = UIImpactFeedbackGenerator(style: .medium)
    private lazy var reorderGesture = UILongPressGestureRecognizer(
        target: self,
        action: #selector(handleReorderGesture(_:))
    )
    private lazy var captionPanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleCaptionDrag(_:))
    )
    private lazy var primaryHandlePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handlePrimaryLayoutDrag(_:))
    )
    private lazy var secondaryHandlePanGesture = UIPanGestureRecognizer(
        target: self,
        action: #selector(handleSecondaryLayoutDrag(_:))
    )
    private var draggedIndex: Int?
    private var dragSnapshotView: UIImageView?
    private var dragTouchOffset = CGPoint.zero
    private var captionSnapshotView: UIView?
    private var captionDragTouchOffset = CGPoint.zero

    override init(frame: CGRect) {
        super.init(frame: frame)

        bubbleView.backgroundColor = AppColor.bubbleBackgroundOutgoing
        bubbleView.layer.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
        bubbleView.layer.cornerCurve = .continuous
        bubbleView.clipsToBounds = true
        addSubview(bubbleView)

        captionContainerView.clipsToBounds = true
        captionContainerView.addGestureRecognizer(captionPanGesture)
        bubbleView.addSubview(captionContainerView)

        captionLabel.numberOfLines = 3
        captionLabel.font = UIFont.systemFont(ofSize: 15)
        captionLabel.textColor = .white
        captionContainerView.addSubview(captionLabel)

        mediaContainerView.clipsToBounds = true
        bubbleView.addSubview(mediaContainerView)
        mediaContainerView.addGestureRecognizer(reorderGesture)

        overflowLabel.isHidden = true
        overflowLabel.textAlignment = .center
        overflowLabel.font = UIFont.systemFont(ofSize: 22, weight: .bold)
        overflowLabel.textColor = .white
        overflowLabel.backgroundColor = UIColor.black.withAlphaComponent(0.38)
        overflowLabel.clipsToBounds = true
        overflowLabel.layer.cornerCurve = .continuous
        mediaContainerView.addSubview(overflowLabel)

        primaryDividerGuideView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        primaryDividerGuideView.layer.cornerRadius = 1
        primaryDividerGuideView.isUserInteractionEnabled = false
        mediaContainerView.addSubview(primaryDividerGuideView)

        secondaryDividerGuideView.backgroundColor = UIColor.white.withAlphaComponent(0.16)
        secondaryDividerGuideView.layer.cornerRadius = 1
        secondaryDividerGuideView.isUserInteractionEnabled = false
        mediaContainerView.addSubview(secondaryDividerGuideView)

        primaryHandleView.addGestureRecognizer(primaryHandlePanGesture)
        mediaContainerView.addSubview(primaryHandleView)

        secondaryHandleView.addGestureRecognizer(secondaryHandlePanGesture)
        mediaContainerView.addSubview(secondaryHandleView)

        for _ in 0..<4 {
            let imageView = UIImageView()
            imageView.contentMode = .scaleAspectFill
            imageView.clipsToBounds = true
            imageView.layer.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
            imageView.layer.cornerCurve = .continuous
            imageView.backgroundColor = UIColor.white.withAlphaComponent(0.08)
            mediaContainerView.addSubview(imageView)
            imageViews.append(imageView)

            let removeButton = UIButton(type: .system)
            removeButton.setImage(
                UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold)),
                for: .normal
            )
            removeButton.tintColor = .white
            removeButton.backgroundColor = UIColor.black.withAlphaComponent(0.55)
            removeButton.layer.cornerRadius = 12
            removeButton.layer.cornerCurve = .continuous
            removeButton.addTarget(self, action: #selector(removeTapped(_:)), for: .touchUpInside)
            mediaContainerView.addSubview(removeButton)
            removeButtons.append(removeButton)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        attachments: [ChatComposerAttachmentDraft],
        captionText: String,
        captionPlacement: CaptionPlacement,
        layoutOverride: MediaGroupLayoutOverride?
    ) {
        self.attachments = attachments
        self.captionText = captionText
        self.captionPlacement = captionPlacement
        self.layoutOverride = PhotoGroupLayout.sanitizedLayoutOverride(
            layoutOverride,
            itemCount: attachments.count
        )
        updateCaptionPreview()
        updateEditingControls()
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        bubbleView.frame = bounds
        let captionHeight = resolvedCaptionHeight()
        let mediaHeight = max(0, bounds.height - captionHeight)
        if captionPlacement == .top {
            captionFrame = CGRect(x: 0, y: 0, width: bounds.width, height: captionHeight).integral
            mediaContainerView.frame = CGRect(
                x: 0,
                y: captionHeight,
                width: bounds.width,
                height: mediaHeight
            ).integral
        } else {
            mediaContainerView.frame = CGRect(
                x: 0,
                y: 0,
                width: bounds.width,
                height: mediaHeight
            ).integral
            captionFrame = CGRect(
                x: 0,
                y: mediaContainerView.frame.maxY,
                width: bounds.width,
                height: captionHeight
            ).integral
        }
        captionContainerView.frame = attachments.isEmpty ? .zero : captionFrame
        captionLabel.frame = captionContainerView.bounds.inset(by: UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
        captionContainerView.alpha = captionSnapshotView == nil ? 1 : 0.2

        let displayAttachments = Array(attachments.prefix(PhotoGroupLayout.maxVisibleItems))
        let displayImages = displayAttachments.map(\.previewImage)
        for (index, imageView) in imageViews.enumerated() {
            imageView.isHidden = index >= displayImages.count
            if index < displayImages.count {
                imageView.image = displayImages[index]
            }
        }

        slotFrames = PhotoGroupLayout.frames(
            in: mediaContainerView.bounds,
            itemCount: displayImages.count,
            layoutOverride: layoutOverride
        )
        for (index, imageView) in imageViews.enumerated() {
            imageView.frame = index < slotFrames.count ? slotFrames[index] : .zero
            imageView.alpha = dragSnapshotView != nil && draggedIndex == index ? 0.22 : 1
            if index < slotFrames.count {
                let roundedCorners = PhotoGroupLayout.roundedCorners(
                    for: index,
                    itemCount: displayImages.count,
                    hasHeader: false,
                    captionPlacement: captionPlacement
                )
                imageView.layer.maskedCorners = roundedCorners.caCornerMask
            }
        }

        for (index, removeButton) in removeButtons.enumerated() {
            let isVisible = isDirectEditingEnabled && index < slotFrames.count
            removeButton.isHidden = !isVisible
            guard isVisible else { continue }
            let frame = slotFrames[index]
            removeButton.tag = index
            removeButton.frame = CGRect(
                x: frame.maxX - 30,
                y: frame.minY + 6,
                width: 24,
                height: 24
            )
        }

        let overflowCount = attachments.count - displayImages.count
        if overflowCount > 0, let lastImageView = imageViews.prefix(displayImages.count).last {
            overflowLabel.isHidden = false
            overflowLabel.text = "+\(overflowCount)"
            overflowLabel.frame = lastImageView.frame
            overflowLabel.layer.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
            overflowLabel.layer.maskedCorners = lastImageView.layer.maskedCorners
        } else {
            overflowLabel.isHidden = true
        }

        layoutInteractiveControls()
    }

    private func updateEditingControls() {
        reorderGesture.isEnabled = isDirectEditingEnabled && attachments.count > 1
        captionPanGesture.isEnabled = isCaptionPlacementEditingEnabled && !attachments.isEmpty
        let canEditLayout = isDirectEditingEnabled
            && PhotoGroupLayout.supportsInteractiveLayout(for: attachments.count)
            && attachments.count <= PhotoGroupLayout.maxVisibleItems
        primaryHandlePanGesture.isEnabled = canEditLayout
        secondaryHandlePanGesture.isEnabled = canEditLayout && attachments.count == 3
        removeButtons.forEach { $0.isHidden = !isDirectEditingEnabled }
        primaryHandleView.isHidden = !canEditLayout
        primaryDividerGuideView.isHidden = !canEditLayout
        let showsSecondaryControls = canEditLayout && attachments.count == 3
        secondaryHandleView.isHidden = !showsSecondaryControls
        secondaryDividerGuideView.isHidden = !showsSecondaryControls
        setNeedsLayout()
    }

    private func updateCaptionPreview() {
        let normalizedCaption = captionText
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let isPlaceholder = normalizedCaption.isEmpty
        captionLabel.text = isPlaceholder ? String(localized: "Caption") : normalizedCaption
        captionLabel.textColor = UIColor.white.withAlphaComponent(isPlaceholder ? 0.58 : 1)
    }

    private func resolvedCaptionHeight() -> CGFloat {
        guard !attachments.isEmpty else { return 0 }
        let maxHeight = max(44, bounds.height - 84)
        let fittingSize = CGSize(width: max(0, bounds.width - 24), height: CGFloat.greatestFiniteMagnitude)
        let labelHeight = ceil(captionLabel.sizeThatFits(fittingSize).height)
        return min(max(44, labelHeight + 20), maxHeight)
    }

    private func mediaIndex(at location: CGPoint) -> Int? {
        slotFrames.firstIndex(where: { $0.insetBy(dx: -8, dy: -8).contains(location) })
    }

    private func layoutInteractiveControls() {
        let canEditLayout = isDirectEditingEnabled
            && PhotoGroupLayout.supportsInteractiveLayout(for: attachments.count)
            && attachments.count <= PhotoGroupLayout.maxVisibleItems
            && !slotFrames.isEmpty

        guard canEditLayout else {
            primaryHandleView.frame = .zero
            secondaryHandleView.frame = .zero
            primaryDividerGuideView.frame = .zero
            secondaryDividerGuideView.frame = .zero
            return
        }

        let handleSize = CGSize(width: 32, height: 32)
        let guideThickness = max(2, PhotoGroupLayout.spacing)
        mediaContainerView.bringSubviewToFront(primaryDividerGuideView)
        mediaContainerView.bringSubviewToFront(secondaryDividerGuideView)
        mediaContainerView.bringSubviewToFront(primaryHandleView)
        mediaContainerView.bringSubviewToFront(secondaryHandleView)

        let primaryDividerCenterX = slotFrames[0].maxX + (PhotoGroupLayout.spacing / 2)
        primaryDividerGuideView.frame = CGRect(
            x: round(primaryDividerCenterX - guideThickness / 2),
            y: 0,
            width: guideThickness,
            height: mediaContainerView.bounds.height
        )
        primaryHandleView.frame = CGRect(
            x: round(primaryDividerCenterX - handleSize.width / 2),
            y: round(mediaContainerView.bounds.midY - handleSize.height / 2),
            width: handleSize.width,
            height: handleSize.height
        )

        guard attachments.count == 3, slotFrames.count >= 3 else {
            secondaryDividerGuideView.frame = .zero
            secondaryHandleView.frame = .zero
            return
        }

        let secondaryDividerCenterY = slotFrames[1].maxY + (PhotoGroupLayout.spacing / 2)
        secondaryDividerGuideView.frame = CGRect(
            x: slotFrames[1].minX,
            y: round(secondaryDividerCenterY - guideThickness / 2),
            width: slotFrames[1].width,
            height: guideThickness
        )
        secondaryHandleView.frame = CGRect(
            x: round(slotFrames[1].midX - handleSize.width / 2),
            y: round(secondaryDividerCenterY - handleSize.height / 2),
            width: handleSize.width,
            height: handleSize.height
        )
    }

    private func updateLayoutOverride(
        primarySplitPermille: Int? = nil,
        secondarySplitPermille: Int? = nil
    ) {
        let itemCount = attachments.count
        guard PhotoGroupLayout.supportsInteractiveLayout(for: itemCount) else { return }

        let resolvedPrimary = primarySplitPermille
            ?? PhotoGroupLayout.resolvedPrimarySplitPermille(
                for: itemCount,
                layoutOverride: layoutOverride
            )
        let resolvedSecondary = secondarySplitPermille
            ?? PhotoGroupLayout.resolvedSecondarySplitPermille(
                for: itemCount,
                layoutOverride: layoutOverride
            )

        guard let resolvedPrimary else { return }

        let nextOverride = PhotoGroupLayout.sanitizedLayoutOverride(
            MediaGroupLayoutOverride(
                primarySplitPermille: resolvedPrimary,
                secondarySplitPermille: itemCount == 3 ? resolvedSecondary : nil
            ),
            itemCount: itemCount
        )

        guard nextOverride != layoutOverride else { return }
        layoutOverride = nextOverride
        onLayoutOverrideChanged?(nextOverride)
        updateEditingControls()
        setNeedsLayout()
        layoutIfNeeded()
    }

    private func cancelActiveDrag() {
        guard let draggedIndex else { return }
        imageViews.indices.forEach { imageViews[$0].alpha = 1 }
        if let dragSnapshotView {
            let targetFrame = slotFrames.indices.contains(draggedIndex) ? slotFrames[draggedIndex] : .zero
            UIView.animate(withDuration: 0.18, animations: {
                dragSnapshotView.transform = .identity
                dragSnapshotView.frame = targetFrame
                dragSnapshotView.alpha = 0
            }) { _ in
                dragSnapshotView.removeFromSuperview()
            }
        }
        self.draggedIndex = nil
        self.dragSnapshotView = nil
        self.dragTouchOffset = .zero
        setNeedsLayout()
    }

    private func cancelActiveCaptionDrag() {
        guard let captionSnapshotView else { return }
        setNeedsLayout()
        layoutIfNeeded()
        UIView.animate(withDuration: 0.18, animations: {
            captionSnapshotView.transform = .identity
            captionSnapshotView.frame = self.captionFrame
            captionSnapshotView.alpha = 0
        }) { _ in
            captionSnapshotView.removeFromSuperview()
        }
        self.captionSnapshotView = nil
        self.captionDragTouchOffset = .zero
        captionContainerView.alpha = 1
    }

    @objc private func removeTapped(_ sender: UIButton) {
        onRemoveAttachment?(sender.tag)
    }

    @objc private func handleReorderGesture(_ gesture: UILongPressGestureRecognizer) {
        guard isDirectEditingEnabled, attachments.count > 1 else { return }

        let location = gesture.location(in: mediaContainerView)
        switch gesture.state {
        case .began:
            guard let index = mediaIndex(at: location),
                  imageViews.indices.contains(index) else { return }

            let sourceView = imageViews[index]
            let snapshot = UIImageView(image: sourceView.image)
            snapshot.frame = sourceView.frame
            snapshot.contentMode = .scaleAspectFill
            snapshot.clipsToBounds = true
            snapshot.layer.cornerRadius = MessageCellHelpers.mediaBubbleCornerRadius
            snapshot.layer.cornerCurve = .continuous
            snapshot.layer.maskedCorners = sourceView.layer.maskedCorners
            mediaContainerView.addSubview(snapshot)

            draggedIndex = index
            dragSnapshotView = snapshot
            dragTouchOffset = CGPoint(
                x: location.x - sourceView.center.x,
                y: location.y - sourceView.center.y
            )
            sourceView.alpha = 0.22
            dragStartFeedback.impactOccurred(intensity: 0.9)
            reorderFeedback.prepare()

            UIView.animate(withDuration: 0.16) {
                snapshot.transform = CGAffineTransform(scaleX: 1.03, y: 1.03)
            }

        case .changed:
            guard let snapshot = dragSnapshotView,
                  let currentIndex = draggedIndex else { return }

            snapshot.center = CGPoint(
                x: location.x - dragTouchOffset.x,
                y: location.y - dragTouchOffset.y
            )

            guard let targetIndex = mediaIndex(at: location),
                  targetIndex != currentIndex,
                  attachments.indices.contains(currentIndex),
                  attachments.indices.contains(targetIndex) else { return }

            let attachment = attachments.remove(at: currentIndex)
            attachments.insert(attachment, at: targetIndex)
            draggedIndex = targetIndex
            onMoveAttachment?(currentIndex, targetIndex)
            setNeedsLayout()
            reorderFeedback.impactOccurred(intensity: 0.9)
            reorderFeedback.prepare()

            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseInOut]) {
                self.layoutIfNeeded()
            }

        default:
            guard let snapshot = dragSnapshotView,
                  let draggedIndex else {
                cancelActiveDrag()
                return
            }

            let targetFrame = slotFrames.indices.contains(draggedIndex) ? slotFrames[draggedIndex] : .zero
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                snapshot.transform = .identity
                snapshot.frame = targetFrame
            } completion: { _ in
                snapshot.removeFromSuperview()
            }

            self.draggedIndex = nil
            self.dragSnapshotView = nil
            self.dragTouchOffset = .zero
            imageViews.indices.forEach { imageViews[$0].alpha = 1 }
            setNeedsLayout()
        }
    }

    @objc private func handleCaptionDrag(_ gesture: UIPanGestureRecognizer) {
        guard isCaptionPlacementEditingEnabled, !attachments.isEmpty else { return }

        let location = gesture.location(in: bubbleView)
        switch gesture.state {
        case .began:
            guard captionFrame.insetBy(dx: -8, dy: -8).contains(location),
                  let snapshot = captionContainerView.snapshotView(afterScreenUpdates: true) else { return }
            snapshot.frame = captionFrame
            bubbleView.addSubview(snapshot)
            captionSnapshotView = snapshot
            captionDragTouchOffset = CGPoint(
                x: location.x - snapshot.center.x,
                y: location.y - snapshot.center.y
            )
            captionContainerView.alpha = 0.2
            captionDragStartFeedback.impactOccurred(intensity: 0.9)
            captionPlacementFeedback.prepare()

            UIView.animate(withDuration: 0.16) {
                snapshot.transform = CGAffineTransform(scaleX: 1.02, y: 1.02)
            }

        case .changed:
            guard let snapshot = captionSnapshotView else { return }
            snapshot.center = CGPoint(
                x: bubbleView.bounds.midX,
                y: location.y - captionDragTouchOffset.y
            )

            let targetPlacement: CaptionPlacement = snapshot.center.y < bubbleView.bounds.midY ? .top : .bottom
            guard targetPlacement != captionPlacement else { return }
            captionPlacement = targetPlacement
            onCaptionPlacementChanged?(targetPlacement)
            captionPlacementFeedback.impactOccurred(intensity: 0.9)
            captionPlacementFeedback.prepare()
            setNeedsLayout()
            layoutIfNeeded()

        default:
            guard let snapshot = captionSnapshotView else {
                cancelActiveCaptionDrag()
                return
            }
            setNeedsLayout()
            layoutIfNeeded()
            UIView.animate(withDuration: 0.18, delay: 0, options: [.curveEaseOut]) {
                snapshot.transform = .identity
                snapshot.frame = self.captionFrame
            } completion: { _ in
                snapshot.removeFromSuperview()
            }
            captionSnapshotView = nil
            captionDragTouchOffset = .zero
            captionContainerView.alpha = 1
        }
    }

    @objc private func handlePrimaryLayoutDrag(_ gesture: UIPanGestureRecognizer) {
        guard isDirectEditingEnabled,
              PhotoGroupLayout.supportsInteractiveLayout(for: attachments.count)
        else { return }

        let location = gesture.location(in: mediaContainerView)
        switch gesture.state {
        case .began:
            layoutDragStartFeedback.impactOccurred(intensity: 0.9)
        case .changed:
            let totalWidth = max(1, mediaContainerView.bounds.width - PhotoGroupLayout.spacing)
            let leftWidth = location.x - (PhotoGroupLayout.spacing / 2)
            let permille = Int(round((leftWidth / totalWidth) * CGFloat(PhotoGroupLayout.splitScale)))
            updateLayoutOverride(primarySplitPermille: permille)
        default:
            break
        }
    }

    @objc private func handleSecondaryLayoutDrag(_ gesture: UIPanGestureRecognizer) {
        guard isDirectEditingEnabled, attachments.count == 3 else { return }

        let location = gesture.location(in: mediaContainerView)
        switch gesture.state {
        case .began:
            layoutDragStartFeedback.impactOccurred(intensity: 0.9)
        case .changed:
            let totalHeight = max(1, mediaContainerView.bounds.height - PhotoGroupLayout.spacing)
            let topHeight = location.y - (PhotoGroupLayout.spacing / 2)
            let permille = Int(round((topHeight / totalHeight) * CGFloat(PhotoGroupLayout.splitScale)))
            updateLayoutOverride(secondarySplitPermille: permille)
        default:
            break
        }
    }

}

private final class DividerHandleView: UIView {
    enum Axis {
        case horizontal
        case vertical
    }

    var axis: Axis {
        didSet { setNeedsDisplay() }
    }

    init(axis: Axis) {
        self.axis = axis
        super.init(frame: .zero)
        isOpaque = false
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.setShadow(offset: .zero, blur: 6, color: UIColor.black.withAlphaComponent(0.35).cgColor)
        UIColor.white.withAlphaComponent(0.96).setFill()

        let center = CGPoint(x: rect.midX, y: rect.midY)
        let size: CGFloat = 6
        let gap: CGFloat = 2

        let firstPath = UIBezierPath()
        let secondPath = UIBezierPath()

        switch axis {
        case .horizontal:
            firstPath.move(to: CGPoint(x: center.x - gap, y: center.y))
            firstPath.addLine(to: CGPoint(x: center.x - gap - size, y: center.y - size))
            firstPath.addLine(to: CGPoint(x: center.x - gap - size, y: center.y + size))
            firstPath.close()

            secondPath.move(to: CGPoint(x: center.x + gap, y: center.y))
            secondPath.addLine(to: CGPoint(x: center.x + gap + size, y: center.y - size))
            secondPath.addLine(to: CGPoint(x: center.x + gap + size, y: center.y + size))
            secondPath.close()
        case .vertical:
            firstPath.move(to: CGPoint(x: center.x, y: center.y - gap))
            firstPath.addLine(to: CGPoint(x: center.x - size, y: center.y - gap - size))
            firstPath.addLine(to: CGPoint(x: center.x + size, y: center.y - gap - size))
            firstPath.close()

            secondPath.move(to: CGPoint(x: center.x, y: center.y + gap))
            secondPath.addLine(to: CGPoint(x: center.x - size, y: center.y + gap + size))
            secondPath.addLine(to: CGPoint(x: center.x + size, y: center.y + gap + size))
            secondPath.close()
        }

        firstPath.fill()
        secondPath.fill()
        context.restoreGState()
    }
}

private extension UIRectCorner {
    var caCornerMask: CACornerMask {
        var mask: CACornerMask = []
        if contains(.topLeft) { mask.insert(.layerMinXMinYCorner) }
        if contains(.topRight) { mask.insert(.layerMaxXMinYCorner) }
        if contains(.bottomLeft) { mask.insert(.layerMinXMaxYCorner) }
        if contains(.bottomRight) { mask.insert(.layerMaxXMaxYCorner) }
        return mask
    }
}

private final class CenteredCaptionTextView: UITextView {
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
