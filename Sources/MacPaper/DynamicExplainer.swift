import ImageIO
import MacPaperCore
import SwiftUI

/// Explains dynamic wallpapers at the top of their tab, using a real one to show how a day plays
/// out: each picture, and the time it takes over today.
struct DynamicExplainer: View {
    @ObservedObject var model: AppModel
    @AppStorage("dynamicExplainerCollapsed") private var collapsed = false
    @State private var example: Example?

    struct Example: Equatable {
        let wallpaper: Wallpaper
        let steps: [Step]
        let currentStep: Int
        /// The wallpaper on screen, rather than a stand-in because something else is up.
        let isSelected: Bool
        let followsAppearance: Bool
    }

    struct Step: Equatable {
        let label: String
        let index: Int
        let help: String
    }

    private static let moreURL = URL(string: "https://dynamicwallpaper.club")!

    var body: some View {
        Card {
            Button {
                withAnimation(.snappy(duration: 0.25)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 10) {
                    GlyphTile(symbol: "questionmark", colors: Theme.coral, size: 22)
                    Text("What are dynamic wallpapers?")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.secondary)
                        .rotationEffect(.degrees(collapsed ? 0 : 180))
                }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(collapsed ? "Shows the explanation" : "Hides the explanation")

            if !collapsed {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Pictures that change on their own as your day goes by, the way macOS's own wallpapers do. One file holds several photos of the same place, from dawn to night, and MacPaperEngine shows the one that matches the moment.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(alignment: .top, spacing: 10) {
                        Feature(symbol: "sun.max.fill", colors: Theme.coral, title: "Follow the sun",
                                text: "Brightens at sunrise and darkens after sunset, timed for where you are.")
                        Feature(symbol: "circle.lefthalf.filled", colors: Theme.indigo, title: "Light and Dark",
                                text: "Or switch with your Mac's appearance, like Sonoma does.")
                        Feature(symbol: "leaf.fill", colors: Theme.green, title: "Nothing to play",
                                text: "Each picture is drawn once and fades in when it's due, using no power.")
                    }
                    // Each card takes the tallest one's height, so the row lines up.
                    .fixedSize(horizontal: false, vertical: true)

                    if let example {
                        DayStrip(example: example).id(example.wallpaper.id)
                    }

                    HStack(spacing: 8) {
                        QuietButton(title: "Add a .heic File…", symbol: "plus") { model.presentImportPanel(for: .dynamic) }
                        QuietButton(title: "Find More Online", symbol: "arrow.up.right") {
                            NSWorkspace.shared.open(Self.moreURL)
                        }
                        .help("Dynamic Wallpaper Club, a free collection made by its community")
                        Spacer()
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
        .task(id: exampleKey) {
            example = await Self.makeExample(from: model.allDynamic, preferring: model.currentWallpaper,
                                             dark: NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua)
        }
    }

    /// Rebuilds the example when the wallpaper in use changes, and on the hour.
    private var exampleKey: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return "\(model.currentWallpaper?.id ?? "-")|\(model.allDynamic.count)|\(hour)"
    }

    /// Shows the dynamic wallpaper on screen. When something else is up, the first one that
    /// changes through the day stands in.
    private static func makeExample(from list: [Wallpaper], preferring current: Wallpaper?, dark: Bool) async -> Example? {
        let selected = current.flatMap { $0.kind == .dynamic ? $0 : nil }
        return await Task.detached(priority: .utility) {
            for wallpaper in [selected].compactMap({ $0 }) + list {
                guard let url = wallpaper.dynamicSourceURL, let schedule = DynamicSchedule.read(from: url) else { continue }
                let isSelected = wallpaper.id == selected?.id
                if case .appearance(let light, let darkIndex) = schedule.mode {
                    // Only worth showing when it's the one chosen; as a stand-in it explains less.
                    guard isSelected else { continue }
                    return Example(wallpaper: wallpaper,
                                   steps: [Step(label: "Light", index: light, help: "In Light mode"),
                                           Step(label: "Dark", index: darkIndex, help: "In Dark mode")],
                                   currentStep: dark ? 1 : 0, isSelected: true, followsAppearance: true)
                }
                guard let timeline = schedule.timeline(), timeline.count > 1 else { continue }
                let steps = timeline.enumerated().map { position, entry in
                    let time = entry.start.formatted(date: .omitted, time: .shortened)
                    return Step(label: position == 0 ? "Midnight" : time, index: entry.index,
                                help: position == 0 ? "Showing from midnight" : "From \(time)")
                }
                let now = Date()
                let current = timeline.lastIndex { $0.start <= now } ?? 0
                return Example(wallpaper: wallpaper, steps: steps, currentStep: current,
                               isSelected: isSelected, followsAppearance: false)
            }
            return nil
        }.value
    }
}

private struct Feature: View {
    let symbol: String
    let colors: [Color]
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            GlyphTile(symbol: symbol, colors: colors, size: 22)
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(10)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A day of one dynamic wallpaper: every picture it shows, with the time each one takes over.
private struct DayStrip: View {
    let example: DynamicExplainer.Example

    private var detail: String {
        if example.followsAppearance { return "· switches with your Mac's appearance" }
        let zone = TimeZone.current.localizedName(for: .shortGeneric, locale: .current) ?? TimeZone.current.identifier
        return example.isSelected ? "· your time zone, \(zone)" : "· choose one below to see its day here"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Text(example.followsAppearance ? example.wallpaper.name : "Today with \(example.wallpaper.name)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.primary)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
            ScrollViewReader { reader in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Array(example.steps.enumerated()), id: \.offset) { position, step in
                        let isNow = position == example.currentStep
                        VStack(spacing: 4) {
                            FrameThumbnail(wallpaper: example.wallpaper, index: step.index)
                                .frame(width: 84, height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .strokeBorder(isNow ? Theme.accent : Color.white.opacity(0.12), lineWidth: isNow ? 2 : 1)
                                }
                            Text(isNow ? (example.followsAppearance ? "\(step.label) · Now" : "Now") : step.label)
                                .font(.system(size: 10, weight: isNow ? .semibold : .medium).monospacedDigit())
                                .foregroundStyle(isNow ? Theme.primary : Theme.secondary)
                        }
                        .help(step.help)
                        .id(position)
                    }
                }
                .padding(.vertical, 2)
            }
            .onAppear { reader.scrollTo(example.currentStep, anchor: .center) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(example.followsAppearance
            ? "\(example.wallpaper.name) has a Light and a Dark picture"
            : "\(example.wallpaper.name) changes \(example.steps.count - 1) times today")
    }
}

/// One picture from inside a dynamic wallpaper, cached on disk after the first time.
private struct FrameThumbnail: View {
    let wallpaper: Wallpaper
    let index: Int
    @State private var image: NSImage?

    var body: some View {
        Color.white.opacity(0.06)
            .overlay {
                if let image { Image(nsImage: image).resizable().scaledToFill() }
            }
            .clipped()
            .task(id: "\(wallpaper.id)#\(index)") {
                let cached = Paths.thumbnails.appendingPathComponent(
                    "\(wallpaper.id).frame\(index)\(wallpaper.isDownloaded ? "" : ".preview").jpg")
                if let existing = NSImage(contentsOf: cached) {
                    image = existing
                    return
                }
                guard let file = wallpaper.dynamicSourceURL else { return }
                let made: Bool = await Task.detached(priority: .utility) {
                    guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
                          let frame = CGImageSourceCreateThumbnailAtIndex(source, index, [
                              kCGImageSourceCreateThumbnailFromImageAlways: true,
                              kCGImageSourceCreateThumbnailWithTransform: true,
                              kCGImageSourceThumbnailMaxPixelSize: 240,
                          ] as CFDictionary) else { return false }
                    Paths.prepare()
                    Thumbnails.write(frame, to: cached)
                    return true
                }.value
                if made { image = NSImage(contentsOf: cached) }
            }
    }
}
