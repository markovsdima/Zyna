import Combine
import UIKit

// MARK: - ScanReviewViewControllerDelegate

protocol ScanReviewViewControllerDelegate: AnyObject {
    func scanReviewDidSave(_ controller: ScanReviewViewController)
    func scanReviewDidRequestAddPages(_ controller: ScanReviewViewController)
    func scanReviewDidRequestEditCorners(_ controller: ScanReviewViewController, at index: Int)
    func scanReviewDidRequestRetake(_ controller: ScanReviewViewController, at index: Int)
    func scanReviewDidDeletePage(_ controller: ScanReviewViewController, at index: Int)
}

// MARK: - ScanReviewViewController

final class ScanReviewViewController: UIViewController {

    // MARK: - Types

    private enum ThumbnailSection { case pages }

    private enum ThumbnailItem: Hashable {
        case page(UUID)
        case addPage
    }

    private enum PreviewSection { case pages }

    // MARK: - Dependencies

    weak var delegate: ScanReviewViewControllerDelegate?
    private let viewModel: ScanReviewViewModel

    // MARK: - Data Sources

    private var thumbnailDataSource: UICollectionViewDiffableDataSource<ThumbnailSection, ThumbnailItem>!
    private var previewDataSource: UICollectionViewDiffableDataSource<PreviewSection, UUID>!
    private var cancellables = Set<AnyCancellable>()

    /// Prevents circular scroll updates when the user is swiping the preview.
    private var isSyncingPreviewScroll = false

    // MARK: - UI

    private lazy var previewCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = 0
        layout.minimumInteritemSpacing = 0

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.isPagingEnabled = true
        cv.backgroundColor = Colors.background
        cv.showsHorizontalScrollIndicator = false
        cv.delegate = self
        return cv
    }()

    private let pageIndicatorLabel: UILabel = {
        let label = UILabel()
        label.font = Fonts.caption
        label.textColor = Colors.textSecondary
        label.textAlignment = .center
        return label
    }()

    private let actionBar = UIView()

    private let editCornersButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "crop", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        config.title = "Edit Corners"
        config.imagePadding = 4
        config.baseForegroundColor = Colors.accent
        let btn = UIButton(configuration: config)
        btn.titleLabel?.font = Fonts.button
        return btn
    }()

    private let retakeButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "camera", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        config.title = "Retake"
        config.imagePadding = 4
        config.baseForegroundColor = Colors.accent
        let btn = UIButton(configuration: config)
        btn.titleLabel?.font = Fonts.button
        return btn
    }()

    private let deleteButton: UIButton = {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "trash", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        config.baseForegroundColor = .systemRed
        return UIButton(configuration: config)
    }()

    private lazy var thumbnailCollectionView: UICollectionView = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = UIEdgeInsets(top: 0, left: 16, bottom: 0, right: 16)

        let cv = UICollectionView(frame: .zero, collectionViewLayout: layout)
        cv.backgroundColor = .clear
        cv.showsHorizontalScrollIndicator = false
        cv.delegate = self
        return cv
    }()

    // MARK: - Init

    init(pages: [UIImage]) {
        self.viewModel = ScanReviewViewModel(pages: pages)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        setupUI()
        setupDataSources()
        bindViewModel()
        applySnapshots()
        updateIndicator()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        let thumbnailStripH: CGFloat = 88
        let actionBarH: CGFloat = 44
        let indicatorH: CGFloat = 20
        let spacing: CGFloat = 12
        let bounds = view.bounds
        let safe = view.safeAreaInsets

        thumbnailCollectionView.frame = CGRect(
            x: 0,
            y: bounds.height - safe.bottom - 8 - thumbnailStripH,
            width: bounds.width,
            height: thumbnailStripH
        )

        actionBar.frame = CGRect(
            x: 24,
            y: thumbnailCollectionView.frame.minY - spacing - actionBarH,
            width: max(0, bounds.width - 48),
            height: actionBarH
        )

        editCornersButton.sizeToFit()
        editCornersButton.frame.origin = CGPoint(
            x: 0,
            y: floor((actionBar.bounds.height - editCornersButton.bounds.height) / 2)
        )

        retakeButton.sizeToFit()
        retakeButton.frame.origin = CGPoint(
            x: editCornersButton.frame.maxX + 16,
            y: floor((actionBar.bounds.height - retakeButton.bounds.height) / 2)
        )

        deleteButton.sizeToFit()
        deleteButton.frame.origin = CGPoint(
            x: actionBar.bounds.width - deleteButton.bounds.width,
            y: floor((actionBar.bounds.height - deleteButton.bounds.height) / 2)
        )

        pageIndicatorLabel.frame = CGRect(
            x: 0,
            y: actionBar.frame.minY - spacing - indicatorH,
            width: bounds.width,
            height: indicatorH
        )

        let previewY = safe.top + 8
        previewCollectionView.frame = CGRect(
            x: 16,
            y: previewY,
            width: max(0, bounds.width - 32),
            height: max(0, pageIndicatorLabel.frame.minY - 8 - previewY)
        )

        // Invalidate preview layout when bounds change (rotation, initial layout)
        previewCollectionView.collectionViewLayout.invalidateLayout()

        // Ensure correct page is visible after layout
        scrollPreviewToSelectedPage(animated: false)
    }

    // MARK: - Public

    func updatePage(at index: Int, image: UIImage) {
        viewModel.updatePage(at: index, image: image)
    }

    func insertPage(_ image: UIImage) {
        viewModel.insertPage(image)
    }

    // MARK: - Setup

    private func setupUI() {
        title = "Review"
        view.backgroundColor = .systemBackground

        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Save",
            style: .done,
            target: self,
            action: #selector(saveTapped)
        )
        navigationItem.hidesBackButton = true
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "chevron.left"),
            style: .plain,
            target: self,
            action: #selector(backTapped)
        )

        view.addSubview(previewCollectionView)
        view.addSubview(pageIndicatorLabel)
        view.addSubview(actionBar)
        view.addSubview(thumbnailCollectionView)

        actionBar.addSubview(editCornersButton)
        actionBar.addSubview(retakeButton)
        actionBar.addSubview(deleteButton)

        editCornersButton.addTarget(self, action: #selector(editCornersTapped), for: .touchUpInside)
        retakeButton.addTarget(self, action: #selector(retakeTapped), for: .touchUpInside)
        deleteButton.addTarget(self, action: #selector(deleteTapped), for: .touchUpInside)
    }

    private func setupDataSources() {
        // -- Preview --
        let previewReg = UICollectionView.CellRegistration<PreviewPageCell, UUID> {
            [weak self] cell, _, id in
            cell.configure(with: self?.viewModel.image(for: id))
        }

        previewDataSource = UICollectionViewDiffableDataSource(collectionView: previewCollectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: previewReg, for: indexPath, item: id)
        }

        // -- Thumbnails --
        let thumbnailReg = UICollectionView.CellRegistration<ThumbnailCell, UUID> {
            [weak self] cell, _, id in
            guard let self else { return }
            cell.configure(with: self.viewModel.image(for: id), isSelected: id == self.viewModel.selectedPageId)
        }

        let addPageReg = UICollectionView.CellRegistration<AddPageCell, ThumbnailItem> { _, _, _ in }

        thumbnailDataSource = UICollectionViewDiffableDataSource(collectionView: thumbnailCollectionView) {
            collectionView, indexPath, item in
            switch item {
            case .page(let id):
                return collectionView.dequeueConfiguredReusableCell(using: thumbnailReg, for: indexPath, item: id)
            case .addPage:
                return collectionView.dequeueConfiguredReusableCell(using: addPageReg, for: indexPath, item: item)
            }
        }
    }

    private func bindViewModel() {
        viewModel.$pageIds
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applySnapshots()
                self?.updateIndicator()
            }
            .store(in: &cancellables)

        viewModel.$selectedPageId
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.updateIndicator()
                self.reconfigureVisibleThumbnails()
                self.scrollThumbnailToSelectedPage()
                if !self.isSyncingPreviewScroll {
                    self.scrollPreviewToSelectedPage(animated: true)
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - State

    private func updateIndicator() {
        pageIndicatorLabel.text = viewModel.pageIndicatorText
    }

    private func applySnapshots() {
        // Preview
        var previewSnapshot = NSDiffableDataSourceSnapshot<PreviewSection, UUID>()
        previewSnapshot.appendSections([.pages])
        previewSnapshot.appendItems(viewModel.pageIds, toSection: .pages)
        previewDataSource.apply(previewSnapshot, animatingDifferences: false)

        // Thumbnails
        var thumbSnapshot = NSDiffableDataSourceSnapshot<ThumbnailSection, ThumbnailItem>()
        thumbSnapshot.appendSections([.pages])
        let items: [ThumbnailItem] = viewModel.pageIds.map { .page($0) } + [.addPage]
        thumbSnapshot.appendItems(items, toSection: .pages)
        thumbnailDataSource.apply(thumbSnapshot, animatingDifferences: false)
    }

    private func reconfigureVisibleThumbnails() {
        var snapshot = thumbnailDataSource.snapshot()
        let pageItems = snapshot.itemIdentifiers.filter {
            if case .page = $0 { return true }
            return false
        }
        snapshot.reconfigureItems(pageItems)
        thumbnailDataSource.apply(snapshot, animatingDifferences: false)
    }

    private func scrollThumbnailToSelectedPage() {
        let index = viewModel.selectedIndex
        guard index < viewModel.pageCount else { return }
        thumbnailCollectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredHorizontally,
            animated: true
        )
    }

    private func scrollPreviewToSelectedPage(animated: Bool) {
        let index = viewModel.selectedIndex
        guard index < viewModel.pageCount else { return }
        previewCollectionView.scrollToItem(
            at: IndexPath(item: index, section: 0),
            at: .centeredHorizontally,
            animated: animated
        )
    }

    // MARK: - Actions

    @objc private func saveTapped() {
        delegate?.scanReviewDidSave(self)
    }

    @objc private func backTapped() {
        delegate?.scanReviewDidRequestAddPages(self)
    }

    @objc private func editCornersTapped() {
        delegate?.scanReviewDidRequestEditCorners(self, at: viewModel.selectedIndex)
    }

    @objc private func retakeTapped() {
        delegate?.scanReviewDidRequestRetake(self, at: viewModel.selectedIndex)
    }

    @objc private func deleteTapped() {
        let index = viewModel.selectedIndex
        delegate?.scanReviewDidDeletePage(self, at: index)
        _ = viewModel.deletePage(at: index)
    }
}

// MARK: - UICollectionViewDelegateFlowLayout

extension ScanReviewViewController: UICollectionViewDelegateFlowLayout {

    func collectionView(
        _ collectionView: UICollectionView,
        layout collectionViewLayout: UICollectionViewLayout,
        sizeForItemAt indexPath: IndexPath
    ) -> CGSize {
        if collectionView === previewCollectionView {
            return collectionView.bounds.size
        }
        return CGSize(width: 60, height: 80)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard collectionView === thumbnailCollectionView,
              let item = thumbnailDataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .page(let id):
            viewModel.selectPage(id: id)
        case .addPage:
            delegate?.scanReviewDidRequestAddPages(self)
        }
    }

    // MARK: - Swipe-to-page

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        guard scrollView === previewCollectionView else { return }
        let pageWidth = scrollView.bounds.width
        guard pageWidth > 0 else { return }
        let pageIndex = Int(round(scrollView.contentOffset.x / pageWidth))
        guard pageIndex != viewModel.selectedIndex else { return }

        isSyncingPreviewScroll = true
        viewModel.selectPage(at: pageIndex)
        isSyncingPreviewScroll = false
    }
}
