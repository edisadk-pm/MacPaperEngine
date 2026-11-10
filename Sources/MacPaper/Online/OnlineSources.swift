import Foundation
import MacPaperCore

/// A wallpaper offered by an online source, before it is downloaded.
struct OnlineItem: Identifiable, Hashable {
    let provider: Wallpaper.Source.Provider
    let remoteID: String
    var id: String { "\(provider.rawValue).\(remoteID)" }

    let thumbnail: URL
    let pageURL: URL
    let file: URL
    let width: Int
    let height: Int
    /// Videos only.
    let duration: Double?
    let author: String?
    /// Known up front for Pexels, which puts it in the page address. Wallhaven's comes from its
    /// tags at download time.
    let title: String?

    var source: Wallpaper.Source {
        Wallpaper.Source(provider: provider, remoteID: remoteID, pageURL: pageURL, author: author)
    }
}

struct OnlineResults {
    let items: [OnlineItem]
    let hasMore: Bool
}

enum OnlineError: LocalizedError {
    case badKey, rateLimited, offline
    case server(provider: String, status: Int)
    case unreadable(provider: String)

    var errorDescription: String? {
        switch self {
        case .badKey: "Pexels didn't accept this API key. Check that it was copied in full."
        case .rateLimited: "Too many requests in a short time. Wait a minute and try again."
        case .offline: "You appear to be offline."
        case .server(let provider, let status): "\(provider) isn't responding right now (error \(status))."
        case .unreadable(let provider): "\(provider) sent a reply MacPaper couldn't read."
        }
    }
}

/// Network access for the Online page. Only the app window uses it; the engine never goes online.
enum OnlineHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        let cache = Paths.root.appendingPathComponent("Cache", isDirectory: true)
        configuration.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 200 << 20, directory: cache)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        // A generic client name: nothing about the user or this Mac.
        configuration.httpAdditionalHeaders = ["User-Agent": "MacPaper/1.0"]
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func json(_ request: URLRequest, provider: String) async throws -> Any {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .notConnectedToInternet || error.code == .networkConnectionLost {
            throw OnlineError.offline
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        switch status {
        case 200..<300: break
        case 401, 403: throw OnlineError.badKey
        case 429: throw OnlineError.rateLimited
        default: throw OnlineError.server(provider: provider, status: status)
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: data) else {
            throw OnlineError.unreadable(provider: provider)
        }
        return parsed
    }

    /// Downloads into MacPaper's own folder and reports progress on the main actor.
    static func download(_ url: URL, progress: @escaping @MainActor (Double) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: Paths.downloads, withIntermediateDirectories: true)
        let ext = url.pathExtension.isEmpty ? "dat" : url.pathExtension.lowercased()
        let destination = Paths.downloads.appendingPathComponent("\(UUID().uuidString).\(ext)")

        final class Box: @unchecked Sendable {
            var observation: NSKeyValueObservation?
            var task: URLSessionDownloadTask?
        }
        let box = Box()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                let task = session.downloadTask(with: url) { temporary, response, error in
                    box.observation = nil
                    if let error {
                        switch (error as? URLError)?.code {
                        case .cancelled?: continuation.resume(throwing: CancellationError())
                        case .notConnectedToInternet?: continuation.resume(throwing: OnlineError.offline)
                        default: continuation.resume(throwing: error)
                        }
                        return
                    }
                    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                    guard (200..<300).contains(status), let temporary else {
                        continuation.resume(throwing: OnlineError.server(provider: url.host ?? "The server", status: status))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: temporary, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                box.observation = task.progress.observe(\.fractionCompleted) { value, _ in
                    let fraction = value.fractionCompleted
                    Task { @MainActor in progress(fraction) }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.task?.cancel()
        }
    }
}

// MARK: - Wallhaven

/// Wallhaven's public API needs no account. Only images marked safe for work are requested.
enum Wallhaven {
    private static let api = URL(string: "https://wallhaven.cc/api/v1/")!

    static func search(query: String, page: Int) async throws -> OnlineResults {
        var components = URLComponents(url: api.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        components.queryItems = [
            URLQueryItem(name: "categories", value: "111"),
            URLQueryItem(name: "purity", value: "100"),
            URLQueryItem(name: "atleast", value: "1920x1080"),
            URLQueryItem(name: "ratios", value: "landscape"),
            URLQueryItem(name: "sorting", value: trimmed.isEmpty ? "toplist" : "relevance"),
            URLQueryItem(name: "page", value: String(page)),
        ] + (trimmed.isEmpty ? [URLQueryItem(name: "topRange", value: "1M")] : [URLQueryItem(name: "q", value: trimmed)])

        let json = try await OnlineHTTP.json(URLRequest(url: components.url!), provider: "Wallhaven")
        guard let root = json as? [String: Any], let data = root["data"] as? [[String: Any]] else {
            throw OnlineError.unreadable(provider: "Wallhaven")
        }
        let items = data.compactMap { entry -> OnlineItem? in
            guard let id = entry["id"] as? String,
                  (entry["purity"] as? String) == "sfw",
                  let page = (entry["url"] as? String).flatMap(URL.init(string:)),
                  let file = (entry["path"] as? String).flatMap(URL.init(string:)),
                  let thumbs = entry["thumbs"] as? [String: String],
                  let thumbnail = (thumbs["large"] ?? thumbs["original"]).flatMap(URL.init(string:)) else { return nil }
            return OnlineItem(provider: .wallhaven, remoteID: id, thumbnail: thumbnail, pageURL: page, file: file,
                              width: entry["dimension_x"] as? Int ?? 0, height: entry["dimension_y"] as? Int ?? 0,
                              duration: nil, author: nil, title: nil)
        }
        let meta = root["meta"] as? [String: Any]
        let last = meta?["last_page"] as? Int ?? page
        return OnlineResults(items: items, hasMore: page < last)
    }

    /// The name and uploader for one wallpaper. Best effort: the download goes ahead without them.
    static func details(id: String) async -> (title: String?, author: String?) {
        guard let json = try? await OnlineHTTP.json(URLRequest(url: api.appendingPathComponent("w/\(id)")), provider: "Wallhaven"),
              let data = (json as? [String: Any])?["data"] as? [String: Any] else { return (nil, nil) }
        let tag = (data["tags"] as? [[String: Any]])?.first?["name"] as? String
        let author = (data["uploader"] as? [String: Any])?["username"] as? String
        return (tag.map(capitalizedWords), author)
    }

    private static func capitalizedWords(_ text: String) -> String {
        text.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
    }
}

// MARK: - Pexels

/// Pexels' API needs a free key, sent with each request.
enum Pexels {
    private static let api = URL(string: "https://api.pexels.com/videos/")!
    static let keyPage = URL(string: "https://www.pexels.com/api/new/")!
    static let home = URL(string: "https://www.pexels.com")!

    /// `maxWidth` is the widest display, so the file picked is as sharp as the screen and no
    /// heavier: a 4K file costs twice the memory to play.
    static func search(query: String, page: Int, key: String, maxWidth: Int) async throws -> OnlineResults {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        var components: URLComponents
        if trimmed.isEmpty {
            components = URLComponents(url: api.appendingPathComponent("popular"), resolvingAgainstBaseURL: false)!
            components.queryItems = [URLQueryItem(name: "min_width", value: "1920")]
        } else {
            components = URLComponents(url: api.appendingPathComponent("search"), resolvingAgainstBaseURL: false)!
            components.queryItems = [
                URLQueryItem(name: "query", value: trimmed),
                URLQueryItem(name: "orientation", value: "landscape"),
                URLQueryItem(name: "size", value: "medium"),
            ]
        }
        components.queryItems! += [
            URLQueryItem(name: "per_page", value: "24"),
            URLQueryItem(name: "page", value: String(page)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "Authorization")

        let json = try await OnlineHTTP.json(request, provider: "Pexels")
        guard let root = json as? [String: Any], let videos = root["videos"] as? [[String: Any]] else {
            throw OnlineError.unreadable(provider: "Pexels")
        }
        let items = videos.compactMap { item(from: $0, maxWidth: maxWidth) }
        return OnlineResults(items: items, hasMore: root["next_page"] != nil && !videos.isEmpty)
    }

    private static func item(from entry: [String: Any], maxWidth: Int) -> OnlineItem? {
        guard let id = (entry["id"] as? Int).map(String.init),
              let width = entry["width"] as? Int, let height = entry["height"] as? Int, width > height,
              let page = (entry["url"] as? String).flatMap(URL.init(string:)),
              let image = (entry["image"] as? String).flatMap(URL.init(string:)),
              let files = entry["video_files"] as? [[String: Any]] else { return nil }

        let candidates = files.compactMap { file -> (width: Int, height: Int, link: URL)? in
            guard (file["file_type"] as? String) == "video/mp4",
                  let width = file["width"] as? Int, let height = file["height"] as? Int, width > 0,
                  let link = (file["link"] as? String).flatMap(URL.init(string:)) else { return nil }
            return (width, height, link)
        }
        let limit = max(maxWidth, 1920)
        guard let chosen = candidates.filter({ $0.width <= limit }).max(by: { $0.width < $1.width })
                ?? candidates.min(by: { $0.width < $1.width }) else { return nil }

        let user = entry["user"] as? [String: Any]
        return OnlineItem(provider: .pexels, remoteID: id, thumbnail: smaller(image), pageURL: page, file: chosen.link,
                          width: chosen.width, height: chosen.height,
                          duration: (entry["duration"] as? NSNumber)?.doubleValue,
                          author: user?["name"] as? String, title: title(from: page))
    }

    /// Pexels' preview images are 1200 pixels wide; tiles need less than half that.
    private static func smaller(_ url: URL) -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let items = components.queryItems, items.contains(where: { $0.name == "w" }) else { return url }
        components.queryItems = items.map { item in
            switch item.name {
            case "w": URLQueryItem(name: "w", value: "560")
            case "h": URLQueryItem(name: "h", value: "350")
            default: item
            }
        }
        return components.url ?? url
    }

    /// `…/video/aerial-view-of-a-forest-1234567/` reads as "Aerial view of a forest".
    private static func title(from page: URL) -> String? {
        var words = page.lastPathComponent.split(separator: "-").map(String.init)
        if let last = words.last, last.allSatisfy(\.isNumber) { words.removeLast() }
        guard !words.isEmpty else { return nil }
        let sentence = words.joined(separator: " ")
        return sentence.prefix(1).uppercased() + sentence.dropFirst()
    }
}
