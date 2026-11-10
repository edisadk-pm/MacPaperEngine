import MacPaperCore
import SwiftUI

/// Browse and download: pictures from Wallhaven, videos from Pexels. A click downloads and
/// applies in one step; what's already downloaded is marked and applies straight away.
struct OnlinePage: View {
    @ObservedObject var model: AppModel
    @ObservedObject var online: OnlineModel

    var body: some View {
        VStack(spacing: 0) {
            // Search and the Pictures/Videos switch are in the window's toolbar.
            if !online.needsKey {
                TopicChips(online: online)
                    .padding(.horizontal, 17)
                    .padding(.top, 12)
                    .padding(.bottom, 12)
            }

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    if online.needsKey {
                        PexelsKeyCard(online: online)
                    } else {
                        results
                    }
                    Credits(kind: online.kind).padding(.top, 14)
                }
                .padding(.horizontal, 17)
                .padding(.bottom, 22)
            }
            .clipped()
        }
        .onAppear { online.appear() }
    }

    @ViewBuilder private var results: some View {
        switch online.phase {
        case .idle, .loading:
            Card {
                LazyVGrid(columns: TileMetrics.columns, spacing: 14) {
                    ForEach(0..<9, id: \.self) { _ in PlaceholderTile() }
                }
                .padding(12)
            }
            .accessibilityLabel("Loading")
        case .failed(let message):
            MessageCard(symbol: "wifi.exclamationmark", title: "Couldn't load wallpapers", text: message) {
                QuietButton(title: "Try Again", symbol: "arrow.clockwise", prominent: true) { online.reload() }
            }
        default:
            if online.items.isEmpty {
                MessageCard(symbol: "magnifyingglass", title: "No results",
                            text: "Nothing matched “\(online.query)”. Try a broader word.") {
                    QuietButton(title: "Clear Search") { online.search("") }
                }
            } else {
                Card {
                    LazyVGrid(columns: TileMetrics.columns, spacing: 14) {
                        ForEach(online.items) { item in
                            OnlineTile(item: item, model: model, online: online)
                                .onAppear { online.loadMoreIfNeeded(after: item) }
                        }
                    }
                    .padding(12)
                    if online.loadingMore {
                        ProgressView().controlSize(.small).padding(.bottom, 14)
                    }
                }
            }
        }
    }
}

private struct TopicChips: View {
    @ObservedObject var online: OnlineModel

    var body: some View {
        let current = online.query.trimmingCharacters(in: .whitespaces).lowercased()
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                Chip(title: "Popular", selected: current.isEmpty) { online.search("") }
                ForEach(OnlineModel.topics[online.kind] ?? [], id: \.self) { topic in
                    Chip(title: topic, selected: current == topic.lowercased()) { online.search(topic) }
                }
            }
        }
    }
}

private struct OnlineTile: View {
    let item: OnlineItem
    @ObservedObject var model: AppModel
    @ObservedObject var online: OnlineModel
    @State private var hovering = false

    var body: some View {
        let saved = online.libraryItem(for: item)
        let active = saved.map(model.isActive) ?? false
        let progress = online.progress[item.id]

        Button {
            if progress == nil { online.activate(item) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RemoteImage(url: item.thumbnail)
                    .aspectRatio(TileMetrics.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                            .strokeBorder(active ? Theme.accent : Color.white.opacity(hovering ? 0.32 : 0.12),
                                          lineWidth: active ? 2 : 1)
                    }
                    .overlay(alignment: .bottomLeading) { badges.padding(6) }
                    .overlay(alignment: .topTrailing) { corner(saved: saved != nil, active: active).padding(6) }
                    .overlay {
                        if let progress { DownloadRing(progress: progress) }
                    }
                    .scaleEffect(hovering ? 1.015 : 1)
                    .animation(.snappy(duration: 0.15), value: hovering)
                Text(caption(saved: saved))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if hovering, progress == nil, let saved {
                RemoveButton { model.confirmRemove(saved) }.padding(6).transition(.opacity)
            }
        }
        .overlay(alignment: .top) {
            if progress != nil {
                CancelDownloadButton { online.cancelDownload(item) }
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(help(saved: saved != nil, downloading: progress != nil))
        .contextMenu {
            if let saved {
                Button(model.isActive(saved) ? "Turn Off" : "Set as Wallpaper") { model.toggle(saved) }
                Button("Show in Library") { model.page = Page(saved.category) }
                Button("Remove from Library…", role: .destructive) { model.confirmRemove(saved) }
            } else if progress != nil {
                Button("Cancel Download") { online.cancelDownload(item) }
            } else {
                Button("Download and Set as Wallpaper") { online.download(item, apply: true) }
                Button("Download Only") { online.download(item, apply: false) }
            }
            Divider()
            Button("Open on \(item.provider.name)") { NSWorkspace.shared.open(item.pageURL) }
        }
        .accessibilityLabel(caption(saved: saved))
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            if let resolution = Badges.resolution(width: item.width, height: item.height) {
                Badge(text: resolution)
            }
            if let duration = item.duration.flatMap(Badges.duration) { Badge(text: duration) }
        }
    }

    @ViewBuilder private func corner(saved: Bool, active: Bool) -> some View {
        if active {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white, Theme.accent)
        } else if saved {
            Badge(text: "In Library", symbol: "checkmark")
        } else if hovering {
            Image(systemName: "arrow.down.circle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.white, .black.opacity(0.45))
        }
    }

    private func caption(saved: Wallpaper?) -> String {
        if let saved { return saved.name }
        if let author = item.author { return item.title.map { "\($0) · \(author)" } ?? "by \(author)" }
        return item.title ?? "\(item.width) × \(item.height)"
    }

    private func help(saved: Bool, downloading: Bool) -> String {
        if downloading { return "Downloading…" }
        if saved { return "Already in your library. Click to set it as your wallpaper." }
        return "Click to download and set as your wallpaper · \(item.width) × \(item.height)"
    }
}

struct DownloadRing: View {
    let progress: Double

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
            Circle().stroke(Color.white.opacity(0.25), lineWidth: 3).frame(width: 30, height: 30)
            Circle()
                .trim(from: 0, to: max(progress, 0.03))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 30, height: 30)
                .animation(.linear(duration: 0.2), value: progress)
        }
        .clipShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
        .accessibilityLabel("Downloading, \(Int(progress * 100)) percent")
    }
}

private struct PlaceholderTile: View {
    @State private var pulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                .fill(Color.white.opacity(pulse ? 0.09 : 0.04))
                .aspectRatio(TileMetrics.aspectRatio, contentMode: .fit)
            RoundedRectangle(cornerRadius: 3).fill(Color.white.opacity(0.06)).frame(width: 70, height: 9)
                .padding(.leading, 2).padding(.vertical, 2)
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

/// Thumbnails from the web, kept in memory while the window is open and on disk by URLCache.
struct RemoteImage: View {
    let url: URL
    @State private var image: NSImage?

    private static let cache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 240
        return cache
    }()

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill().transition(.opacity)
                }
            }
            .clipped()
            .task(id: url) {
                if let cached = Self.cache.object(forKey: url as NSURL) {
                    image = cached
                    return
                }
                guard let (data, _) = try? await OnlineHTTP.session.data(from: url),
                      let loaded = NSImage(data: data) else { return }
                Self.cache.setObject(loaded, forKey: url as NSURL)
                withAnimation(.easeOut(duration: 0.2)) { image = loaded }
            }
    }
}

private struct MessageCard<Actions: View>: View {
    let symbol: String
    let title: String
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        Card {
            VStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 24, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .padding(.bottom, 2)
                Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
                Text(text)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                HStack(spacing: 8) { actions }.padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .padding(.horizontal, 20)
        }
    }
}

/// Pexels needs a free key. Asked for here, where it's needed, and checked before it's kept.
private struct PexelsKeyCard: View {
    @ObservedObject var online: OnlineModel
    @State private var key = ""
    @State private var checking = false
    @State private var error: String?

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    GlyphTile(symbol: "play.rectangle.fill", colors: Theme.rose, size: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Video wallpapers from Pexels")
                            .font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
                        Text("Thousands of free videos. Pexels asks for a free API key, which takes about a minute to get.")
                            .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Step(number: 1, text: "Create a free Pexels account and request a key.")
                    Step(number: 2, text: "Copy the key shown on the API page.")
                    Step(number: 3, text: "Paste it below.")
                }
                .padding(.leading, 2)

                HStack(spacing: 8) {
                    TextField("Pexels API key", text: $key)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Theme.primary)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(error == nil ? Theme.cardStroke : Color.red.opacity(0.7), lineWidth: 1)
                        }
                        .onSubmit(save)
                    if checking {
                        ProgressView().controlSize(.small).frame(width: 60)
                    } else {
                        QuietButton(title: "Save", prominent: true, action: save)
                    }
                }
                if let error {
                    Text(error).font(.system(size: 11)).foregroundStyle(Color(red: 1, green: 0.45, blue: 0.45))
                }

                HStack(spacing: 8) {
                    QuietButton(title: "Get a Free Key", symbol: "arrow.up.right") {
                        NSWorkspace.shared.open(Pexels.keyPage)
                    }
                    Spacer()
                    Text("Kept on this Mac. Only sent to Pexels.")
                        .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            .padding(16)
        }
    }

    private func save() {
        guard !checking else { return }
        checking = true
        error = nil
        Task {
            error = await online.saveKey(key)
            checking = false
        }
    }
}

private struct Step: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Text("\(number)")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(Theme.primary)
                .frame(width: 18, height: 18)
                .background(Color.white.opacity(0.12), in: Circle())
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
    }
}

private struct Credits: View {
    let kind: OnlineModel.Kind

    var body: some View {
        HStack(spacing: 4) {
            Spacer()
            if kind == .pictures {
                Text("Pictures from")
                Link("Wallhaven", destination: URL(string: "https://wallhaven.cc")!)
                Text("· uploaded by its community, check each one's licence before sharing")
            } else {
                Text("Videos provided by")
                Link("Pexels", destination: Pexels.home)
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary.opacity(0.85))
        .tint(Theme.primary)
        .lineLimit(1)
    }
}
