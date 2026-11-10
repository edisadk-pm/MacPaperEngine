import MacPaperCore
import SwiftUI
import UniformTypeIdentifiers

/// One of the three library tabs. Each shows only its own kind of wallpaper, and the add
/// button offers only that kind of file, though a file dropped anywhere lands in the right tab.
struct LibraryPage: View {
    @ObservedObject var model: AppModel
    let category: Wallpaper.Category
    @State private var dropTargeted = false

    private var page: Page { Page(category) }

    var body: some View {
        PageScaffold(page: page) {
            if model.showsDisplayPicker {
                SectionLabel("Applying To").padding(.top, -17)
                PillPicker(
                    options: model.displays.map { (value: $0.id, label: $0.name) },
                    selection: Binding(
                        get: { model.assignmentTarget ?? "" },
                        set: { model.targetDisplay = $0 }
                    ))
            }

            switch category {
            case .videos:
                if !FootageCatalog.all.isEmpty {
                    WallpaperSection(title: "Abstract", detail: "Included with MacPaper", first: true,
                                     items: FootageCatalog.all, model: model)
                }
                UserSection(title: "Your Videos", detail: "Videos, GIFs and downloads",
                            first: FootageCatalog.all.isEmpty, category: category,
                            items: model.userVideos, model: model)
            case .dynamic:
                DynamicExplainer(model: model).padding(.top, model.showsDisplayPicker ? 17 : 0)
                if !IncludedDynamicCatalog.all.isEmpty {
                    WallpaperSection(title: "Included with MacPaper", items: IncludedDynamicCatalog.all, model: model)
                }
                UserSection(title: "Yours", detail: ".heic files you add", category: category,
                            items: model.userDynamic, model: model)
            case .pictures:
                UserSection(title: "Your Pictures", detail: nil, first: true, category: category,
                            items: model.userPictures, model: model)
            }
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
                    .background(Theme.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
                    .padding(8)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers)
            return true
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) {
        for provider in providers {
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                Task { @MainActor in model.importFiles([url]) }
            }
        }
    }
}

enum TileMetrics {
    static let aspectRatio: CGFloat = 1.6
    static let radius: CGFloat = 10
    static let columns = [GridItem(.adaptive(minimum: 140, maximum: 280), spacing: 12, alignment: .top)]
}

private struct WallpaperSection: View {
    let title: String
    var detail: String?
    var first = false
    let items: [Wallpaper]
    @ObservedObject var model: AppModel

    var body: some View {
        SectionLabel(title, detail: detail).padding(.top, first && !model.showsDisplayPicker ? -17 : 0)
        Card {
            LazyVGrid(columns: TileMetrics.columns, spacing: 14) {
                ForEach(items) { WallpaperTile(wallpaper: $0, model: model) }
            }
            .padding(12)
        }
    }
}

/// A section the user adds to: ends with an add tile, or explains itself when empty.
private struct UserSection: View {
    let title: String
    let detail: String?
    var first = false
    let category: Wallpaper.Category
    let items: [Wallpaper]
    @ObservedObject var model: AppModel

    var body: some View {
        SectionLabel(title, detail: detail).padding(.top, first && !model.showsDisplayPicker ? -17 : 0)
        Card {
            // Dynamic has plenty above it already, so an empty "Yours" is just the add tile.
            if items.isEmpty && model.importing == 0 && category != .dynamic {
                EmptyLibrary(category: category, model: model)
            } else {
                LazyVGrid(columns: TileMetrics.columns, spacing: 14) {
                    ForEach(items) { WallpaperTile(wallpaper: $0, model: model) }
                    AddTile(category: category, model: model)
                }
                .padding(12)
            }
        }
    }
}

private struct EmptyLibrary: View {
    let category: Wallpaper.Category
    @ObservedObject var model: AppModel

    private var text: (title: String, body: String) {
        switch category {
        case .videos: ("No videos yet", "Add MP4, MOV or GIF files, drop them here, or find videos online.")
        case .dynamic: ("No dynamic wallpapers", "Add a .heic dynamic wallpaper, like the ones macOS uses, or drop one here.")
        case .pictures: ("No pictures yet", "Add your own, drop them anywhere in this window, or browse thousands online.")
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            GlyphTile(symbol: Page(category).symbol, colors: Page(category).colors, size: 36)
                .padding(.bottom, 2)
            Text(text.title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(text.body)
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)
            HStack(spacing: 8) {
                QuietButton(title: "Add…", symbol: "plus") { model.presentImportPanel(for: category) }
                if category != .dynamic {
                    QuietButton(title: "Browse Online", symbol: "globe", prominent: true) {
                        model.online.kind = category == .videos ? .videos : .pictures
                        model.page = .online
                    }
                }
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
        .padding(.horizontal, 20)
    }
}

struct WallpaperTile: View {
    let wallpaper: Wallpaper
    @ObservedObject var model: AppModel
    @State private var hovering = false
    @State private var schedule: DynamicSchedule?

    var body: some View {
        let active = model.isActive(wallpaper)
        Button {
            model.toggle(wallpaper)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailView(wallpaper: wallpaper)
                    .aspectRatio(TileMetrics.aspectRatio, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                            .strokeBorder(active ? Theme.accent : Color.white.opacity(hovering ? 0.32 : 0.12),
                                          lineWidth: active ? 2 : 1)
                    }
                    .overlay(alignment: .topTrailing) {
                        if active {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white, Theme.accent)
                                .padding(6)
                        }
                    }
                    .overlay(alignment: .bottomLeading) {
                        badges.padding(6)
                    }
                    .scaleEffect(hovering ? 1.015 : 1)
                    .animation(.snappy(duration: 0.15), value: hovering)
                Text(wallpaper.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(active ? Theme.primary : Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Outside the tile's own button, so a click here removes rather than applies.
        .overlay(alignment: .topLeading) {
            if wallpaper.isRemovable, hovering {
                RemoveButton { model.confirmRemove(wallpaper) }
                    .padding(6)
                    .transition(.opacity)
            }
        }
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(helpText)
        .task(id: wallpaper.id) {
            guard wallpaper.kind == .dynamic, let url = wallpaper.fileURL else { return }
            schedule = await Task.detached(priority: .utility) { DynamicSchedule.read(from: url) }.value
        }
        .contextMenu { menu(active: active) }
        .accessibilityLabel(wallpaper.name)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    @ViewBuilder private var badges: some View {
        HStack(spacing: 4) {
            switch wallpaper.kind {
            case .video:
                if let progress = model.smoothing[wallpaper.id] {
                    Badge(text: "Smoothing loop \(Int(progress * 100))%", symbol: "infinity")
                }
                if wallpaper.animated == true { Badge(text: "GIF") }
                if let resolution = Badges.resolution(width: wallpaper.width, height: wallpaper.height) {
                    Badge(text: resolution)
                }
                if let duration = Badges.duration(wallpaper.duration) { Badge(text: duration) }
            case .dynamic:
                if let schedule {
                    switch schedule.mode {
                    case .solar: Badge(text: "Sun", symbol: "sun.max.fill")
                    case .timeOfDay: Badge(text: "24h", symbol: "clock.fill")
                    case .appearance: Badge(text: "Light/Dark", symbol: "circle.lefthalf.filled")
                    }
                }
            case .image:
                if let resolution = Badges.resolution(width: wallpaper.width, height: wallpaper.height) {
                    Badge(text: resolution)
                }
            }
        }
    }

    private var helpText: String {
        var parts = [wallpaper.name]
        if let schedule { parts.append(schedule.summary) }
        if wallpaper.width > 0 { parts.append("\(wallpaper.width) × \(wallpaper.height)") }
        if let source = wallpaper.source {
            parts.append(source.author.map { "by \($0) on \(source.provider.name)" } ?? "from \(source.provider.name)")
        }
        if wallpaper.isIncluded { parts.append("Included with MacPaper") }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private func menu(active: Bool) -> some View {
        Button(active ? "Turn Off" : "Set as Wallpaper") { model.toggle(wallpaper) }
        if let url = wallpaper.fileURL, !wallpaper.isBuiltInFootage {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        if let source = wallpaper.source, let page = source.pageURL {
            Button("Open on \(source.provider.name)") { NSWorkspace.shared.open(page) }
        }
        if wallpaper.isRemovable {
            Divider()
            Button("Remove from Library…", role: .destructive) { model.confirmRemove(wallpaper) }
        }
    }
}

/// The small × in a tile's corner for wallpapers the user added.
struct RemoveButton: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(hovering ? Color.red.opacity(0.85) : Color.black.opacity(0.6), in: Circle())
                .overlay { Circle().strokeBorder(Color.white.opacity(0.25), lineWidth: 0.5) }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Remove from Library")
        .accessibilityLabel("Remove from Library")
    }
}

struct ThumbnailView: View {
    let wallpaper: Wallpaper
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                }
            }
            .clipped()
            .task(id: wallpaper.id) {
                let url = await Thumbnails.ensure(wallpaper)
                image = NSImage(contentsOf: url)
            }
    }
}

private struct AddTile: View {
    let category: Wallpaper.Category
    @ObservedObject var model: AppModel
    @State private var hovering = false

    private var caption: String {
        switch category {
        case .videos: "Add Video or GIF"
        case .dynamic: "Add Dynamic"
        case .pictures: "Add Picture"
        }
    }

    var body: some View {
        Button {
            model.presentImportPanel(for: category)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                    .fill(Color.white.opacity(hovering ? 0.09 : 0.04))
                    .overlay {
                        RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                    .overlay {
                        if model.importing > 0 {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "plus")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(Theme.secondary)
                        }
                    }
                    .aspectRatio(TileMetrics.aspectRatio, contentMode: .fit)
                Text(model.importing > 0 ? "Importing…" : caption)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Or drop files anywhere on this page")
    }
}
