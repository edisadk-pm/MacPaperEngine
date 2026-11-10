import MacPaperCore
import SwiftUI

/// The page area to the right of the sidebar.
struct DetailView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            switch model.page {
            case .videos: LibraryPage(model: model, category: .videos)
            case .dynamic: LibraryPage(model: model, category: .dynamic)
            case .pictures: LibraryPage(model: model, category: .pictures)
            case .online: OnlinePage(model: model, online: model.online)
            case .displays: DisplaysPage(model: model)
            case .playback: PlaybackPage(model: model)
            case .power: PowerPage(model: model)
            case .general: GeneralPage(model: model)
            case .stats: StatsPage(model: model)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeView(text: notice)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.25), value: model.notice)
        .background(Theme.tint.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .alert("MacPaper", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.alert ?? "")
        }
    }
}

private struct NoticeView: View {
    let text: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.white, Theme.accent)
            Text(text).lineLimit(1)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.primary)
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1) }
        .shadow(color: .black.opacity(0.3), radius: 10, y: 4)
    }
}

/// The sidebar column. It sits on the system's own sidebar material, under the toolbar.
struct SidebarView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader("Library", first: true)
            SidebarRow(page: .videos, count: model.count(.videos), model: model)
            SidebarRow(page: .dynamic, count: model.count(.dynamic), model: model)
            SidebarRow(page: .pictures, count: model.count(.pictures), model: model)

            SidebarHeader("Discover")
            SidebarRow(page: .online, model: model)

            SidebarHeader("Settings")
            SidebarRow(page: .displays, model: model)
            SidebarRow(page: .playback, model: model)
            SidebarRow(page: .power, model: model)
            SidebarRow(page: .general, model: model)
            SidebarRow(page: .stats, model: model)

            Spacer(minLength: 12)
            NowPlayingCard(model: model)
        }
        .padding(.top, 2)
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .preferredColorScheme(.dark)
    }
}

private struct SidebarHeader: View {
    let title: String
    var first = false
    init(_ title: String, first: Bool = false) {
        self.title = title
        self.first = first
    }

    var body: some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.sectionLabel.opacity(0.85))
            .padding(.leading, 8)
            .padding(.top, first ? 4 : 14)
            .padding(.bottom, 5)
    }
}

private struct SidebarRow: View {
    let page: Page
    var count: Int?
    @ObservedObject var model: AppModel
    @State private var hovering = false

    var body: some View {
        let selected = model.page == page
        Button {
            model.page = page
        } label: {
            HStack(spacing: 8) {
                GlyphTile(symbol: page.symbol, colors: page.colors)
                Text(page.title).font(Theme.body).foregroundStyle(Theme.primary)
                Spacer()
                if let count {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(selected ? Theme.selection : hovering ? Color.white.opacity(0.05) : .clear,
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityLabel(count.map { "\(page.title), \($0) wallpapers" } ?? page.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// What's on the desktop right now, with the one switch that turns it all off.
private struct NowPlayingCard: View {
    @ObservedObject var model: AppModel
    @State private var hovering = false

    private var statusText: String {
        guard model.settings.enabled else { return "Off" }
        guard model.currentWallpaper != nil else { return "Choose one" }
        switch model.status.state {
        case .idle: return "Starting"
        default: return model.status.label
        }
    }

    private var statusColor: Color {
        guard model.settings.enabled, model.currentWallpaper != nil else { return Theme.secondary.opacity(0.6) }
        switch model.status.state {
        case .playing, .still: return Color(red: 0.30, green: 0.85, blue: 0.45)
        case .paused: return Color(red: 1.0, green: 0.72, blue: 0.25)
        default: return Theme.secondary.opacity(0.6)
        }
    }

    private func helpText(for wallpaper: Wallpaper?) -> String {
        var lines: [String] = []
        if model.settings.enabled, model.status.state == .paused { lines.append("Paused: \(model.status.detail)") }
        if let wallpaper { lines.append("Show “\(wallpaper.name)” in \(AppModel.title(for: wallpaper.category))") }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        let wallpaper = model.currentWallpaper
        HStack(spacing: 9) {
            Button {
                if let wallpaper { model.page = Page(wallpaper.category) }
            } label: {
                HStack(spacing: 9) {
                    Group {
                        if let wallpaper {
                            ThumbnailView(wallpaper: wallpaper)
                        } else {
                            Color.white.opacity(0.06)
                                .overlay {
                                    Image(systemName: "photo.on.rectangle")
                                        .font(.system(size: 12))
                                        .foregroundStyle(Theme.secondary)
                                }
                        }
                    }
                    .frame(width: 42, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .opacity(model.settings.enabled ? 1 : 0.45)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(wallpaper?.name ?? "None")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.primary)
                            .lineLimit(1)
                        HStack(spacing: 4) {
                            Circle().fill(statusColor).frame(width: 6, height: 6)
                            Text(statusText)
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(helpText(for: wallpaper))

            Switch(isOn: Binding(
                get: { model.settings.enabled },
                set: { value in
                    model.mutate { $0.settings.enabled = value }
                    if value { model.ensureEngineRunning() }
                }
            ), label: "Wallpaper")
        }
        .padding(8)
        .background(Color.white.opacity(hovering ? 0.09 : 0.065),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .onHover { hovering = $0 }
    }
}
