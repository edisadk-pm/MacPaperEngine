import AppKit
import Combine
import MacPaperCore

@MainActor
final class OnlineModel: ObservableObject {
    enum Kind: String, CaseIterable {
        case pictures, videos

        var provider: Wallpaper.Source.Provider { self == .pictures ? .wallhaven : .pexels }
    }

    enum Phase: Equatable {
        case idle, loading, loaded, failed(String)
    }

    @Published var kind: Kind = Kind(rawValue: UserDefaults.standard.string(forKey: "onlineKind") ?? "") ?? .pictures {
        didSet {
            guard kind != oldValue else { return }
            UserDefaults.standard.set(kind.rawValue, forKey: "onlineKind")
            query = ""
            reload()
        }
    }
    @Published var query = ""
    @Published private(set) var items: [OnlineItem] = []
    @Published private(set) var phase = Phase.idle
    @Published private(set) var loadingMore = false
    /// Downloads in flight, by item, from 0 to 1.
    @Published private(set) var progress: [String: Double] = [:]

    static let topics: [Kind: [String]] = [
        .pictures: ["Nature", "Space", "Abstract", "Minimal", "Mountains", "City", "Ocean", "Dark"],
        .videos: ["Nature", "Abstract", "Ocean", "Space", "Rain", "Clouds", "City", "Fire"],
    ]

    private weak var app: AppModel?
    private var page = 1
    private var hasMore = false
    private var generation = 0
    private var loadTask: Task<Void, Never>?
    private var debounce: Task<Void, Never>?
    private var downloads: [String: Task<Void, Never>] = [:]

    init(app: AppModel) {
        self.app = app
    }

    var needsKey: Bool { kind == .videos && (app?.pexelsKey.isEmpty ?? true) }

    // MARK: - Loading

    func appear() {
        if items.isEmpty, phase != .loading { reload() }
    }

    func queryChanged() {
        debounce?.cancel()
        debounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            self?.reload()
        }
    }

    func search(_ text: String) {
        debounce?.cancel()
        query = text
        reload()
    }

    func reload() {
        debounce?.cancel()
        loadTask?.cancel()
        generation += 1
        items = []
        page = 1
        hasMore = false
        loadingMore = false
        guard !needsKey else {
            phase = .idle
            return
        }
        phase = .loading
        fetch(page: 1)
    }

    func loadMoreIfNeeded(after item: OnlineItem) {
        guard hasMore, !loadingMore, phase == .loaded,
              let position = items.firstIndex(of: item), position >= items.count - 6 else { return }
        loadingMore = true
        fetch(page: page + 1)
    }

    private func fetch(page: Int) {
        let ticket = generation
        let kind = kind
        let query = query
        let key = app?.pexelsKey ?? ""
        let width = Self.widestDisplay
        loadTask = Task { [weak self] in
            do {
                let results = kind == .pictures
                    ? try await Wallhaven.search(query: query, page: page)
                    : try await Pexels.search(query: query, page: page, key: key, maxWidth: width)
                guard let self, ticket == self.generation else { return }
                let known = Set(self.items.map(\.id))
                self.items += results.items.filter { !known.contains($0.id) }
                self.page = page
                self.hasMore = results.hasMore
                self.phase = .loaded
                self.loadingMore = false
            } catch {
                guard let self, ticket == self.generation, !Task.isCancelled else { return }
                self.loadingMore = false
                if page == 1 {
                    self.phase = .failed(error.localizedDescription)
                } else {
                    // The results already shown stay; scrolling to the end again retries.
                    self.app?.show(notice: "Couldn't load more: \(error.localizedDescription)")
                }
            }
        }
    }

    private static var widestDisplay: Int {
        NSScreen.screens.map { Int($0.frame.width * $0.backingScaleFactor) }.max() ?? 1920
    }

    // MARK: - Pexels key

    /// Checks a key with one real request before keeping it.
    func saveKey(_ candidate: String) async -> String? {
        let key = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Paste your key first." }
        do {
            _ = try await Pexels.search(query: "", page: 1, key: key, maxWidth: Self.widestDisplay)
            app?.pexelsKey = key
            reload()
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Downloading

    func libraryItem(for item: OnlineItem) -> Wallpaper? {
        app?.libraryItem(for: item.provider, remoteID: item.remoteID)
    }

    /// A click: applies what's already downloaded, otherwise downloads and then applies.
    func activate(_ item: OnlineItem) {
        if let existing = libraryItem(for: item) {
            app?.toggle(existing)
        } else {
            download(item, apply: true)
        }
    }

    func download(_ item: OnlineItem, apply: Bool) {
        guard downloads[item.id] == nil, libraryItem(for: item) == nil else { return }
        progress[item.id] = 0
        downloads[item.id] = Task { [weak self] in
            defer {
                self?.downloads[item.id] = nil
                self?.progress[item.id] = nil
            }
            do {
                var title = item.title
                var source = item.source
                if item.provider == .wallhaven {
                    let details = await Wallhaven.details(id: item.remoteID)
                    title = details.title
                    source.author = details.author
                }
                let file = try await OnlineHTTP.download(item.file) { fraction in
                    // Keeps the ring from looking finished while the file is still being added.
                    self?.progress[item.id] = min(fraction, 0.97)
                }
                defer { try? FileManager.default.removeItem(at: file) }
                let name = title ?? "\(item.provider.name) \(item.remoteID)"
                let wallpaper = try await Importer.importFile(file, name: name, source: source)
                guard let app = self?.app else { return }
                app.mutate { $0.library.append(wallpaper) }
                if apply {
                    app.apply(wallpaper)
                    app.show(notice: "Now showing “\(wallpaper.name)”")
                } else {
                    app.show(notice: "Added “\(wallpaper.name)” to \(AppModel.title(for: wallpaper.category))")
                }
            } catch is CancellationError {
            } catch {
                self?.app?.alert = "“\(item.title ?? item.remoteID)” couldn't be downloaded. \(error.localizedDescription)"
            }
        }
    }

    func cancelDownload(_ item: OnlineItem) {
        downloads[item.id]?.cancel()
    }
}
