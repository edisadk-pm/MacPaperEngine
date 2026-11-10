import AppKit
import MacPaperCore
import SwiftUI

extension AppModel {
    func binding<Value>(_ keyPath: WritableKeyPath<WallpaperSettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.settings[keyPath: keyPath] },
            set: { value in self.mutate { $0.settings[keyPath: keyPath] = value } }
        )
    }
}

struct DisplaysPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PageScaffold(page: .displays) {
            Card {
                Row(title: "Same Wallpaper on All Displays") {
                    Switch(isOn: model.binding(\.sameOnAllDisplays))
                }
            }

            SectionLabel("Connected")
            Card {
                ForEach(Array(model.displays.enumerated()), id: \.element.id) { index, display in
                    if index > 0 { RowDivider() }
                    Button {
                        model.targetDisplay = display.id
                        model.page = model.state.wallpaper(forDisplay: display.id).map { Page($0.category) } ?? .videos
                    } label: {
                        Row(symbol: "display", title: display.name,
                            subtitle: display.pixels + (display.isMain ? " · Main" : "")) {
                            HStack(spacing: 6) {
                                ValueText(model.state.wallpaper(forDisplay: display.id)?.name ?? "None")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            SectionLabel("Lock Screen")
            Card {
                Row(symbol: "lock.fill", title: "Play on Lock Screen", subtitle: model.lockScreenSummary) {
                    Switch(isOn: model.binding(\.lockScreen))
                }
            }
        }
    }
}

struct PlaybackPage: View {
    @ObservedObject var model: AppModel

    private var smoothSubtitle: String {
        if model.settings.smoothLoops, !model.smoothing.isEmpty {
            let done = model.smoothing.values.reduce(0, +) / Double(model.smoothing.count)
            return "Preparing your videos… \(Int(done * 100))%"
        }
        return "Blends each video's end into its start, so the restart doesn't show"
    }

    var body: some View {
        PageScaffold(page: .playback) {
            SectionLabel("All Wallpapers").padding(.top, -17)
            Card {
                Row(symbol: "arrow.up.left.and.arrow.down.right", title: "Scaling",
                    subtitle: "How a wallpaper that doesn't match the screen's shape fits") {
                    PillPicker(options: [(.fill, "Fill"), (.fit, "Fit"), (.stretch, "Stretch")],
                               selection: model.binding(\.scaling))
                }
            }

            SectionLabel("Videos")
            Card {
                Row(symbol: "speedometer", title: "Speed") {
                    PillPicker(options: [(0.5, "0.5×"), (1.0, "1×"), (1.5, "1.5×"), (2.0, "2×")],
                               selection: model.binding(\.speed))
                }
                RowDivider()
                Row(symbol: "infinity", title: "Hide Loop Jump",
                    subtitle: smoothSubtitle) {
                    Switch(isOn: Binding(get: { model.settings.smoothLoops }, set: { model.setSmoothLoops($0) }))
                }
            }

            SectionLabel("Dynamic")
            Card {
                Row(symbol: "location.fill", title: "Sun Position", subtitle: "Judged from your time zone, so no location access is needed") {
                    ValueText(TimeZone.current.localizedName(for: .generic, locale: .current) ?? TimeZone.current.identifier)
                }
            }
        }
    }
}

struct PowerPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PageScaffold(page: .power) {
            Card {
                Row(title: "Right Now") { ValueText(model.status.detail) }
            }

            SectionLabel("Pause Automatically")
            Card {
                Row(symbol: "macwindow.on.rectangle", title: "When Windows Cover the Desktop") {
                    Switch(isOn: model.binding(\.pauseWhenCovered))
                }
                RowDivider()
                Row(symbol: "battery.50percent", title: "On Battery Power") {
                    Switch(isOn: model.binding(\.pauseOnBattery))
                }
                RowDivider()
                Row(symbol: "leaf.fill", title: "In Low Power Mode") {
                    Switch(isOn: model.binding(\.pauseInLowPower))
                }
                RowDivider()
                Row(symbol: "thermometer.medium", title: "When the Mac Is Running Hot") {
                    Switch(isOn: model.binding(\.pauseWhenHot))
                }
                RowDivider()
                Row(symbol: "lock.fill", title: "While Locked or Asleep", value: "Always")
            }

            Text("Pictures and dynamic wallpapers are drawn once and use no power while shown, so they're never paused.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
                .padding(.top, 8)
        }
    }
}

struct GeneralPage: View {
    @ObservedObject var model: AppModel

    var body: some View {
        PageScaffold(page: .general) {
            Card {
                Row(symbol: "power", title: "Start Wallpaper at Login") {
                    Switch(isOn: Binding(
                        get: { model.opensAtLogin },
                        set: { model.setOpensAtLogin($0) }
                    ))
                }
                RowDivider()
                Row(symbol: "menubar.rectangle", title: "Show in Menu Bar") {
                    Switch(isOn: model.binding(\.showMenuBarIcon))
                }
            }

            SectionLabel("Library")
            Card {
                Row(symbol: Page.videos.symbol, colors: Page.videos.colors, title: "Your Videos",
                    value: "\(model.userVideos.count)")
                RowDivider()
                Row(symbol: Page.pictures.symbol, colors: Page.pictures.colors, title: "Your Pictures",
                    value: "\(model.userPictures.count)")
                RowDivider()
                Row(symbol: Page.dynamic.symbol, colors: Page.dynamic.colors, title: "Your Dynamic Wallpapers",
                    value: "\(model.state.library.filter { $0.kind == .dynamic }.count)")
                RowDivider()
                Row(symbol: "internaldrive.fill", title: "Size on Disk", value: Format.storage(model.libraryBytes))
                RowDivider()
                Row(symbol: "icloud.and.arrow.down.fill", title: "Downloaded Built-ins",
                    subtitle: "Downloaded the first time you pick them") {
                    HStack(spacing: 8) {
                        ValueText(Format.storage(model.includedBytes))
                        QuietButton(title: "Remove Unused") { model.removeUnusedDownloads() }
                            .help("Removes downloaded built-ins that aren't on screen. They download again when picked.")
                    }
                }
                RowDivider()
                Row(symbol: "folder.fill", title: "Library Folder") {
                    QuietButton(title: "Show") { NSWorkspace.shared.open(Paths.root) }
                }
            }

            SectionLabel("Online")
            Card {
                Row(symbol: "key.fill", colors: Theme.teal, title: "Pexels API Key",
                    subtitle: model.pexelsKey.isEmpty ? "Needed for online videos" : "Saved on this Mac") {
                    if model.pexelsKey.isEmpty {
                        QuietButton(title: "Add") {
                            model.online.kind = .videos
                            model.page = .online
                        }
                    } else {
                        QuietButton(title: "Remove") {
                            model.pexelsKey = ""
                            model.online.reload()
                        }
                    }
                }
            }

            SectionLabel("Engine")
            Card {
                Row(symbol: "cpu", title: "Background Engine", subtitle: "Keeps your wallpaper up after this window closes") {
                    QuietButton(title: model.status.state == .off && !model.isEngineRunning ? "Start" : "Stop") {
                        if model.isEngineRunning { model.stopEngine() } else { model.ensureEngineRunning() }
                    }
                }
            }

            SectionLabel("Updates")
            UpdatesCard(updater: model.updater)

            SectionLabel("About")
            AboutCard()
        }
        .onAppear { model.refreshMeasurements() }
    }
}

struct StatsPage: View {
    @ObservedObject var model: AppModel

    private var favourites: [(wallpaper: Wallpaper, seconds: Double)] {
        model.stats.playSeconds
            .compactMap { id, seconds in model.state.wallpaper(id: id).map { (wallpaper: $0, seconds: seconds) } }
            .sorted { $0.seconds > $1.seconds }
            .prefix(5)
            .map { $0 }
    }

    private static let palette = [Theme.coral, Theme.rose, Theme.magenta, Theme.indigo, Theme.teal]

    var body: some View {
        PageScaffold(page: .stats) {
            SectionLabel("Memory").padding(.top, -17)
            Card {
                Row(symbol: "memorychip.fill", title: "Wallpaper Engine",
                    subtitle: "What stays running", trailing: { ValueText(Format.bytes(model.engineFootprint)) })
                RowDivider()
                Row(symbol: "film", title: "Video Decoder",
                    subtitle: "macOS helper, used by videos only", trailing: { ValueText(Format.bytes(model.decoderFootprint)) })
                RowDivider()
                Row(symbol: "macwindow", title: "This Window",
                    subtitle: "Freed when you close it", trailing: { ValueText(Format.bytes(model.windowFootprint)) })
            }

            SectionLabel("Total Usage")
            Card {
                Row(symbol: "play.fill", title: "Time Animated", value: Format.duration(model.stats.totalPlayed))
                RowDivider()
                Row(symbol: "pause.fill", title: "Time Auto-Paused", value: Format.duration(model.stats.pausedSeconds))
            }

            SectionLabel("Favourite Wallpapers")
            Card {
                if favourites.isEmpty {
                    Row(title: "Nothing played yet", value: "—")
                } else {
                    let top = max(favourites[0].seconds, 1)
                    VStack(spacing: 2) {
                        ForEach(Array(favourites.enumerated()), id: \.element.wallpaper.id) { index, item in
                            FavouriteRow(item: item, share: item.seconds / top,
                                         colors: Self.palette[index % Self.palette.count])
                        }
                    }
                    .padding(6)
                }
            }
        }
        .task {
            while !Task.isCancelled {
                model.refreshMeasurements()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// A row whose background doubles as a bar showing its share of the total.
private struct FavouriteRow: View {
    let item: (wallpaper: Wallpaper, seconds: Double)
    let share: Double
    let colors: [Color]

    var body: some View {
        HStack(spacing: 9) {
            GlyphTile(symbol: item.wallpaper.symbol, colors: colors, size: 20)
            Text(item.wallpaper.name).font(Theme.body).foregroundStyle(Theme.primary).lineLimit(1)
            Spacer(minLength: 8)
            ValueText(Format.duration(item.seconds))
        }
        .padding(.horizontal, 6)
        .frame(height: 32)
        .background(alignment: .leading) {
            GeometryReader { proxy in
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill((colors.first ?? .white).opacity(0.28))
                    .frame(width: max(proxy.size.width * share, 20))
            }
        }
    }
}

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
            Row(symbol: "arrow.down.app.fill", title: "Install Updates Automatically",
                subtitle: "Downloads in the background and installs when you close the window") {
                Switch(isOn: $updater.installsAutomatically)
            }
            RowDivider()
            Row(symbol: "link", title: "Release Notes") {
                QuietButton(title: "Open") { NSWorkspace.shared.open(Updater.releasesPage) }
            }
        }
    }
}

struct AboutCard: View {
    private var version: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.0"
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("MacPaperEngine").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.primary)
                        Text("Version \(version)").font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    }
                    Text("Wallpapers that stay out of your memory. MacPaperEngine draws above your system wallpaper, which returns when it stops. Only Play on Lock Screen changes it, and turning that off restores it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        }
    }
}
