import AppKit
import SwiftUI

/// One version's section of `CHANGELOG.md`.
struct ChangelogEntry: Identifiable {
    let version: String
    let date: String?
    /// The paragraph under the heading, if any.
    let summary: String?
    let items: [String]
    var id: String { version }
}

/// `CHANGELOG.md`, bundled with the app. It's What's New on the About page, the sidebar's line
/// after an update, and each GitHub release's notes, so the three always agree.
enum Changelog {
    static let entries: [ChangelogEntry] = {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(text)
    }()

    static func entry(for version: String) -> ChangelogEntry? {
        entries.first { $0.version == version }
    }

    /// Sections look like `## 1.2.0 — 3 December 2026`, then an optional paragraph, then
    /// `- ` items. Anything before the first section is for people reading the file.
    static func parse(_ text: String) -> [ChangelogEntry] {
        var entries: [ChangelogEntry] = []
        var version: String?
        var date: String?
        var summary: [String] = []
        var items: [String] = []

        func finish() {
            guard let version else { return }
            entries.append(ChangelogEntry(version: version, date: date,
                                          summary: summary.isEmpty ? nil : summary.joined(separator: " "),
                                          items: items))
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("## ") {
                finish()
                let heading = line.dropFirst(3).components(separatedBy: " — ")
                let name = heading[0].trimmingCharacters(in: .whitespaces)
                version = name.hasPrefix("v") ? String(name.dropFirst()) : name
                date = heading.count > 1 ? heading[1].trimmingCharacters(in: .whitespaces) : nil
                summary = []
                items = []
            } else if version == nil || line.isEmpty || line.hasPrefix("#") {
                continue
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                items.append(String(line.dropFirst(2)))
            } else if raw.hasPrefix(" "), !items.isEmpty {
                items[items.count - 1] += " " + line
            } else if items.isEmpty {
                summary.append(line)
            }
        }
        finish()
        return entries
    }

    /// Bold and links inside a line, as written in the file.
    static func styled(_ markdown: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: markdown, options: options)) ?? AttributedString(markdown)
    }
}

struct AboutPage: View {
    @ObservedObject var model: AppModel

    private var version: String { Updater.currentVersion }

    /// This version's notes. A development build may be older than the newest section.
    private var current: ChangelogEntry? { Changelog.entry(for: version) }

    private var earlier: [ChangelogEntry] {
        Changelog.entries.filter { $0.version != version && !Updater.isNewer($0.version, than: version) }
    }

    var body: some View {
        PageScaffold(page: .about) {
            AboutHeader(updater: model.updater)

            if let current {
                SectionLabel("What's New in \(current.version)", detail: current.date)
                ChangelogCard(entry: current)
            }

            ForEach(earlier) { entry in
                SectionLabel(entry.version, detail: entry.date)
                ChangelogCard(entry: entry)
            }

            SectionLabel("Credits")
            Card {
                Row(symbol: "photo.fill", colors: Theme.sky, title: "Online Pictures",
                    subtitle: "From Wallhaven, uploaded by its community") {
                    QuietButton(title: "Visit") { NSWorkspace.shared.open(URL(string: "https://wallhaven.cc")!) }
                }
                RowDivider()
                Row(symbol: "play.rectangle.fill", colors: Theme.rose, title: "Online Videos",
                    subtitle: "From Pexels, free to use") {
                    QuietButton(title: "Visit") { NSWorkspace.shared.open(URL(string: "https://www.pexels.com")!) }
                }
                RowDivider()
                Row(symbol: "shippingbox.fill", colors: Theme.coral, title: "Built-in Wallpapers",
                    subtitle: "Each belongs to its original creator") {
                    QuietButton(title: "Visit") {
                        NSWorkspace.shared.open(URL(string: "https://github.com/edisadk-pm/macpaper-media")!)
                    }
                }
            }
        }
        // Seen here, so the sidebar's "Updated to" card has done its job.
        .onAppear { model.updater.dismissWhatsNew() }
    }
}

private struct AboutHeader: View {
    @ObservedObject var updater: Updater

    private var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""
    }

    var body: some View {
        Card {
            HStack(alignment: .top, spacing: 16) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacPaperEngine")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Theme.primary)
                    Text(build.isEmpty ? "Version \(updater.version)" : "Version \(updater.version) (\(build))")
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(Theme.secondary)
                    Text("Wallpapers that stay out of your memory. MacPaperEngine draws above your system wallpaper, which returns when it stops. Only Play on Lock Screen changes it, and turning that off restores it.")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 4)
                    HStack(spacing: 8) {
                        QuietButton(title: "Check for Updates") { updater.check(userInitiated: true) }
                            .disabled(!updater.isAvailable)
                        QuietButton(title: "Source Code", symbol: "chevron.left.forwardslash.chevron.right") {
                            NSWorkspace.shared.open(URL(string: "https://github.com/\(Updater.repository)")!)
                        }
                        QuietButton(title: "All Releases", symbol: "arrow.up.forward") {
                            NSWorkspace.shared.open(Updater.releasesPage)
                        }
                    }
                    .padding(.top, 8)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }
}

private struct ChangelogCard: View {
    let entry: ChangelogEntry

    var body: some View {
        Card {
            if let summary = entry.summary {
                Text(Changelog.styled(summary))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                if !entry.items.isEmpty { RowDivider(inset: 14) }
            }
            ForEach(Array(entry.items.enumerated()), id: \.offset) { index, item in
                if index > 0 { RowDivider(inset: 36) }
                HStack(alignment: .firstTextBaseline, spacing: 9) {
                    Image(systemName: "sparkle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.sky[0])
                        .frame(width: 13)
                    Text(Changelog.styled(item))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.primary.opacity(0.88))
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
            }
        }
    }
}
