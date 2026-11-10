import AppKit
import SwiftUI

/// Where the built-in wallpapers come from. They're credited on their sections, their tiles and
/// the About page.
enum MediaCredits {
    /// The six abstract loops.
    static let abstractAuthor = "Colin Jones"
    static let abstractURL = URL(string: "https://www.pexels.com/@larchmedia/")!
    /// The five dynamic wallpapers.
    static let dynamicSource = "Dynamic Wallpaper Club"
    static let dynamicURL = URL(string: "https://dynamicwallpaper.club")!
}

/// A small accent-coloured link to a web page, with the outward arrow.
struct CreditLink: View {
    let title: String
    let url: URL

    var body: some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            Text("\(title) \(Image(systemName: "arrow.up.forward"))")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.link)
                .lineLimit(1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(url.absoluteString)
    }
}

/// The last tile of the built-in dynamic wallpapers: where to find more.
struct MoreDynamicTile: View {
    @State private var hovering = false

    var body: some View {
        Button {
            NSWorkspace.shared.open(MediaCredits.dynamicURL)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                    .fill(LinearGradient(colors: [Theme.coral[0].opacity(hovering ? 0.42 : 0.30),
                                                  Theme.indigo[1].opacity(hovering ? 0.42 : 0.30)],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay {
                        RoundedRectangle(cornerRadius: TileMetrics.radius, style: .continuous)
                            .strokeBorder(Color.white.opacity(hovering ? 0.30 : 0.16), lineWidth: 1)
                    }
                    .overlay {
                        VStack(spacing: 5) {
                            Image(systemName: "sun.horizon.fill")
                                .font(.system(size: 22, weight: .medium))
                                .foregroundStyle(.white.opacity(0.9))
                            Text("Get more on")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.primary.opacity(0.75))
                            Text(MediaCredits.dynamicSource)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(Theme.primary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .minimumScaleFactor(0.85)
                        }
                        .padding(10)
                    }
                    .aspectRatio(TileMetrics.aspectRatio, contentMode: .fit)
                Text("dynamicwallpaper.club \(Image(systemName: "arrow.up.forward"))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help("Find more dynamic wallpapers on Dynamic Wallpaper Club. Download a .heic and drop it here.")
    }
}
