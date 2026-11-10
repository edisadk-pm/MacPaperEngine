import MacPaperCore
import SwiftUI

enum Theme {
    /// The window's width, which is fixed. Its height can grow to show more rows.
    static let windowWidth: CGFloat = 780
    static let windowHeight: CGFloat = 640
    static let sidebarWidth: CGFloat = 230

    static let tint = Color(white: 0.32).opacity(0.70)
    static let primary = Color.white.opacity(0.93)
    static let secondary = Color.white.opacity(0.62)
    static let sectionLabel = Color.white.opacity(0.70)
    static let hairline = Color.white.opacity(0.10)
    static let cardFill = Color.white.opacity(0.075)
    static let cardStroke = Color.white.opacity(0.13)
    static let selection = Color.white.opacity(0.11)
    static let accent = Color(red: 0.05, green: 0.47, blue: 1.0)

    static let cardRadius: CGFloat = 14
    static let body = Font.system(size: 13, weight: .medium)
    static let value = Font.system(size: 13, weight: .regular).monospacedDigit()

    static let graphite = [Color(white: 0.60), Color(white: 0.42)]
    static let teal = [Color(red: 0.26, green: 0.86, blue: 0.70), Color(red: 0.09, green: 0.66, blue: 0.62)]
    static let magenta = [Color(red: 0.98, green: 0.35, blue: 0.80), Color(red: 0.66, green: 0.25, blue: 0.95)]
    static let indigo = [Color(red: 0.46, green: 0.48, blue: 1.0), Color(red: 0.32, green: 0.26, blue: 0.92)]
    static let coral = [Color(red: 1.0, green: 0.65, blue: 0.40), Color(red: 0.98, green: 0.44, blue: 0.34)]
    static let rose = [Color(red: 1.0, green: 0.40, blue: 0.46), Color(red: 0.95, green: 0.20, blue: 0.40)]
    static let sky = [Color(red: 0.32, green: 0.72, blue: 1.0), Color(red: 0.12, green: 0.46, blue: 0.96)]
    static let green = [Color(red: 0.40, green: 0.88, blue: 0.47), Color(red: 0.18, green: 0.70, blue: 0.33)]
    static let violet = [Color(red: 0.72, green: 0.52, blue: 1.0), Color(red: 0.50, green: 0.30, blue: 0.94)]
}

extension Page {
    var title: String {
        switch self {
        case .videos: "Videos"
        case .dynamic: "Dynamic"
        case .pictures: "Pictures"
        case .online: "Online"
        case .displays: "Displays"
        case .playback: "Playback"
        case .power: "Power"
        case .general: "General"
        case .stats: "Stats"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .videos: "play.rectangle.fill"
        case .dynamic: "sun.horizon.fill"
        case .pictures: "photo.fill"
        case .online: "globe"
        case .displays: "display"
        case .playback: "slider.horizontal.3"
        case .power: "bolt.fill"
        case .general: "gearshape.fill"
        case .stats: "chart.bar.fill"
        case .about: "info"
        }
    }

    var colors: [Color] {
        switch self {
        case .videos: Theme.rose
        case .dynamic: Theme.coral
        case .pictures: Theme.sky
        case .online: Theme.teal
        case .displays: Theme.indigo
        case .playback: Theme.magenta
        case .power: Theme.green
        case .general: Theme.graphite
        case .stats: Theme.violet
        case .about: Theme.sky
        }
    }
}

extension Wallpaper {
    /// A small glyph for lists, matching the tab the wallpaper lives in.
    var symbol: String {
        switch kind {
        case .video: animated == true ? "photo.stack" : "film"
        case .image: "photo"
        case .dynamic: "sun.horizon"
        }
    }
}

// MARK: - Building blocks

struct GlyphTile: View {
    let symbol: String
    var colors: [Color] = Theme.graphite
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay {
                RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5)
            }
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.52, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Theme.cardFill, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
    }
}

struct SectionLabel: View {
    let title: String
    var detail: String?
    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.sectionLabel)
            if let detail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.secondary.opacity(0.8))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.top, 17)
        .padding(.bottom, 8)
    }
}

/// A small label laid over a thumbnail, such as GIF or 4K.
struct Badge: View {
    let text: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 8, weight: .bold)) }
            Text(text).font(.system(size: 9, weight: .bold)).monospacedDigit()
        }
        .foregroundStyle(.white.opacity(0.95))
        .padding(.horizontal, 5)
        .frame(height: 16)
        .background(.black.opacity(0.5), in: Capsule())
    }
}

enum Badges {
    static func resolution(width: Int, height: Int) -> String? {
        let longest = max(width, height)
        switch longest {
        case 7680...: return "8K"
        case 6016...: return "6K"
        case 5120...: return "5K"
        case 3840...: return "4K"
        default: return nil
        }
    }

    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// A search box in the window's style.
struct SearchField: View {
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.secondary)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Theme.primary)
                .focused($focused)
                .onSubmit(onSubmit)
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 9)
        .frame(height: 30)
        .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(focused ? Theme.accent.opacity(0.8) : Theme.cardStroke, lineWidth: focused ? 1.5 : 1)
        }
    }
}

/// A rounded choice that reads as a filter, for quick searches.
struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(selected ? Color.white : Theme.primary.opacity(0.85))
                .padding(.horizontal, 10)
                .frame(height: 24)
                .background(selected ? Theme.accent : Color.white.opacity(hovering ? 0.14 : 0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A divider that starts at the row's label rather than its glyph.
struct RowDivider: View {
    var inset: CGFloat = 41

    var body: some View {
        Rectangle().fill(Theme.hairline).frame(height: 1).padding(.leading, inset).padding(.trailing, 12)
    }
}

struct Row<Trailing: View>: View {
    var symbol: String?
    var colors: [Color] = Theme.graphite
    let title: String
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 9) {
            if let symbol { GlyphTile(symbol: symbol, colors: colors, size: 20) }
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.body).foregroundStyle(Theme.primary)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 38)
        .padding(.vertical, subtitle == nil ? 0 : 4)
    }
}

extension Row where Trailing == ValueText {
    init(symbol: String? = nil, colors: [Color] = Theme.graphite, title: String, value: String) {
        self.init(symbol: symbol, colors: colors, title: title, subtitle: nil) { ValueText(value) }
    }
}

struct ValueText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(Theme.value).foregroundStyle(Theme.secondary)
    }
}

struct PillToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button {
            configuration.isOn.toggle()
        } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? Theme.accent : Color.white.opacity(0.18))
                Capsule()
                    .fill(Color.white.opacity(configuration.isOn ? 0.86 : 0.72))
                    .frame(width: 27, height: 16)
                    .padding(2)
            }
            .frame(width: 45, height: 20)
            .animation(.snappy(duration: 0.18), value: configuration.isOn)
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(isOn: configuration.$isOn) { configuration.label } }
    }
}

struct Switch: View {
    let isOn: Binding<Bool>
    var label = ""

    var body: some View {
        Toggle(label, isOn: isOn).toggleStyle(PillToggleStyle()).labelsHidden()
    }
}

struct PillPicker<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    let selection: Binding<Value>

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                let selected = option.value == selection.wrappedValue
                Button {
                    selection.wrappedValue = option.value
                } label: {
                    Text(option.label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(selected ? Theme.primary : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 22)
                        .background(selected ? Color.white.opacity(0.17) : .clear,
                                    in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct QuietButton: View {
    let title: String
    var symbol: String?
    var prominent = false
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(prominent ? Color.white : Theme.primary)
            .padding(.horizontal, 10)
            .frame(height: 24)
            .background(prominent ? Theme.accent.opacity(hovering ? 0.85 : 1)
                                  : Color.white.opacity(hovering ? 0.18 : 0.11),
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A page's scrolling body. Its title and actions are in the window's toolbar.
struct PageScaffold<Content: View>: View {
    let page: Page
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 17)
                .padding(.top, 14)
                .padding(.bottom, 22)
        }
    }
}

enum Format {
    static func bytes(_ value: UInt64?) -> String {
        guard let value else { return "—" }
        return String(format: "%.1f MB", Double(value) / 1_048_576)
    }

    static func storage(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    static func duration(_ seconds: Double) -> String {
        guard seconds >= 60 else { return seconds > 0 ? "< 1 min" : "—" }
        let minutes = Int(seconds / 60)
        return minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h \(minutes % 60) min"
    }
}
