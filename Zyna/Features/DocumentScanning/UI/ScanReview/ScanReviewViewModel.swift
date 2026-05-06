import Combine
import UIKit

final class ScanReviewViewModel {

    // MARK: - Types

    private struct PageItem {
        let id: UUID
        var image: UIImage
    }

    // MARK: - Published

    @Published private(set) var pageIds: [UUID] = []
    @Published private(set) var selectedPageId: UUID?

    // MARK: - Private State

    private var pages: [PageItem] = []
    private var imageCache: [UUID: UIImage] = [:]

    // MARK: - Init

    init(pages: [UIImage]) {
        self.pages = pages.map { PageItem(id: UUID(), image: $0) }
        rebuildCache()
        if let first = self.pages.first {
            selectedPageId = first.id
        }
    }

    // MARK: - Read Access

    var pageCount: Int { pages.count }

    var selectedIndex: Int {
        guard let id = selectedPageId else { return 0 }
        return pages.firstIndex(where: { $0.id == id }) ?? 0
    }

    var selectedImage: UIImage? {
        guard let id = selectedPageId else { return nil }
        return imageCache[id]
    }

    var pageIndicatorText: String {
        "Page \(selectedIndex + 1) of \(pageCount)"
    }

    func image(for id: UUID) -> UIImage? {
        imageCache[id]
    }

    // MARK: - Mutations

    func insertPage(_ image: UIImage) {
        let item = PageItem(id: UUID(), image: image)
        pages.append(item)
        imageCache[item.id] = image
        pageIds = pages.map(\.id)
        selectedPageId = item.id
    }

    func updatePage(at index: Int, image: UIImage) {
        guard index < pages.count else { return }
        pages[index].image = image
        imageCache[pages[index].id] = image

        if pages[index].id == selectedPageId {
            // Force selectedPageId re-publish so preview updates
            selectedPageId = pages[index].id
        }
        pageIds = pages.map(\.id)
    }

    func deletePage(at index: Int) -> Bool {
        guard index < pages.count else { return false }
        let removedId = pages[index].id
        pages.remove(at: index)
        imageCache.removeValue(forKey: removedId)

        if pages.isEmpty {
            selectedPageId = nil
            pageIds = []
            return true
        }

        let newIndex = min(index, pages.count - 1)
        selectedPageId = pages[newIndex].id
        pageIds = pages.map(\.id)
        return true
    }

    func selectPage(at index: Int) {
        guard index < pages.count else { return }
        selectedPageId = pages[index].id
    }

    func selectPage(id: UUID) {
        guard pages.contains(where: { $0.id == id }) else { return }
        selectedPageId = id
    }

    // MARK: - Private

    private func rebuildCache() {
        imageCache = [:]
        for page in pages {
            imageCache[page.id] = page.image
        }
        pageIds = pages.map(\.id)
    }
}
