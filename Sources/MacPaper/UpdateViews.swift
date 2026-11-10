import AppKit
import SwiftUI

/// General > Updates.
struct UpdatesCard: View {
    @ObservedObject var updater: Updater

    private var status: String {
        guard updater.isAvailable else { return "Development build: updates are off" }
        switch updater.phase {
        case .idle: return updater.lastChecked.map { "Last checked \($0.formatted(.relative(presentation: .named)))" } ?? "Not checked yet"
        case .checking: return "Checking…"
        case .upToDate: return "Up to date"
        case .available(let version): return "Version \(version) is available"
        case .downloading(let version, let progress): return "Downloading \(version)… \(Int(progress * 100))%"
        case .ready(let version): return "Version \(version) installs when you close this window"
        case .installing: return "Installing…"
        case .failed(let message): return message
        }
    }

    var body: some View {
        Card {
            Row(symbol: "arrow.triangle.2.circlepath", colors: Theme.sky, title: "Version \(updater.version)",
                subtitle: status) {
                switch updater.phase {
                case .ready:
                    QuietButton(title: "Restart Now", prominent: true) { updater.installNow() }
                case .available:
                    QuietButton(title: "Download", prominent: true) { updater.downloadAvailable() }
                case .checking, .downloading, .installing:
                    ProgressView().controlSize(.small)
                default:
                    QuietButton(title: "Check Now") { updater.check(userInitiated: true) }
                        .disabled(!updater.isAvailable)
                }
            }
            RowDivider()
            Row(symbol: "arrow.down.app.fill", colors: Theme.green, title: "Updates", subtitle: updater.mode.detail) {
                PillPicker(options: Updater.Mode.allCases.map { (value: $0, label: $0.shortTitle) },
                           selection: $updater.mode)
                .fixedSize()
            }
            RowDivider()
            Row(symbol: "link", title: "Release Notes") {
                QuietButton(title: "Open") { NSWorkspace.shared.open(Updater.releasesPage) }
            }
        }
    }
}

/// Presents the first-launch sheet over the page area.
struct UpdateIntroPresenter: ViewModifier {
    @ObservedObject var updater: Updater

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(get: { updater.showsIntro },
                                           set: { if !$0 { updater.finishIntro() } })) {
            UpdateIntroSheet(updater: updater)
        }
    }
}

/// Shown once: the app keeps itself up to date, and how far it should go on its own.
struct UpdateIntroSheet: View {
    @ObservedObject var updater: Updater

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) {
                    Text("MacPaperEngine keeps itself up to date")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text("New versions come from the app's GitHub page. Each is checked against its published checksum and code signature before it's kept, and it's swapped in when you close this window, so the wallpaper is back within seconds.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Card {
                ForEach(Array(Updater.Mode.allCases.enumerated()), id: \.element) { index, mode in
                    if index > 0 { RowDivider(inset: 38) }
                    ModeOption(mode: mode, selected: updater.mode == mode) { updater.mode = mode }
                }
            }

            HStack {
                Text("You can change this in General > Updates.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                Button("Continue") { updater.finishIntro() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
            }
        }
        .padding(22)
        .frame(width: 470)
        .preferredColorScheme(.dark)
    }
}

private struct ModeOption: View {
    let mode: Updater.Mode
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Theme.accent : Theme.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title).font(Theme.body).foregroundStyle(Theme.primary)
                        if mode == .automatic {
                            Text("Recommended")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.secondary)
                                .padding(.horizontal, 6)
                                .frame(height: 16)
                                .background(Color.white.opacity(0.1), in: Capsule())
                        }
                    }
                    Text(mode.detail).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(hovering ? Color.white.opacity(0.04) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Above Now Playing: an update on its way, or what's new once one is installed. Nothing the
/// rest of the time.
struct UpdateSidebarCard: View {
    @ObservedObject var updater: Updater
    /// Opens What's New on the About page.
    var showWhatsNew: () -> Void

    var body: some View {
        Group {
            switch updater.phase {
            case .available(let version) where updater.snoozedVersion != version:
                SidebarNote(symbol: "arrow.down", title: "Update Available",
                            text: "Version \(version) is out.",
                            link: NoteLink(title: "What's new", external: true) {
                                NSWorkspace.shared.open(updater.releasePage(for: version))
                            }) {
                    QuietButton(title: "Download", prominent: true) { updater.downloadAvailable() }
                    QuietButton(title: "Later") { updater.snooze() }
                }
            case .downloading(let version, let progress):
                SidebarNote(symbol: "arrow.down", title: "Downloading \(version)") {
                    ProgressView(value: progress).progressViewStyle(.linear).tint(Theme.accent)
                }
            case .ready(let version):
                SidebarNote(symbol: "checkmark", title: "Update Ready",
                            text: "Version \(version) installs when you close this window.") {
                    QuietButton(title: "Restart Now", prominent: true) { updater.installNow() }
                }
            case .installing:
                SidebarNote(symbol: "arrow.triangle.2.circlepath", title: "Installing Update…") {
                    ProgressView().progressViewStyle(.linear).tint(Theme.accent)
                }
            default:
                if let whatsNew = updater.whatsNew {
                    SidebarNote(symbol: "sparkles", title: "Updated to \(whatsNew.version)",
                                text: whatsNew.notes.isEmpty ? nil : whatsNew.notes,
                                link: NoteLink(title: "What's new", external: false, action: showWhatsNew)) {
                        QuietButton(title: "OK") { updater.dismissWhatsNew() }
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.25), value: updater.phase)
        .animation(.snappy(duration: 0.25), value: updater.whatsNew)
    }
}

private struct NoteLink {
    let title: String
    /// Opens a web page, rather than a page of this window.
    let external: Bool
    let action: () -> Void
}

private struct SidebarNote<Actions: View>: View {
    let symbol: String
    let title: String
    var text: String?
    var link: NoteLink?
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                GlyphTile(symbol: symbol, colors: Theme.sky, size: 18)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                    .lineLimit(1)
            }
            if let text {
                Text(text)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link {
                Button(action: link.action) {
                    Text("\(link.title) \(Image(systemName: link.external ? "arrow.up.forward" : "chevron.forward"))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -3)
            }
            HStack(spacing: 6) { actions }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.065), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }
}
