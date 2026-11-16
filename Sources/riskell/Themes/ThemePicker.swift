import SwiftUI
import RiskellKit

extension AppConfig {
    /// Saves the chosen scheme as `theme` in config.json, keeping every other key. A file that cannot be read is never overwritten.
    static func setTheme(_ id: String) {
        shared.theme = id
        var obj: [String: Any] = [:]
        if let d = try? Data(contentsOf: url) {
            guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            obj = o
        }
        obj["theme"] = id
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: url, options: .atomic) }
    }
}

/// The THEME card's grid: every scheme as a tile painted in its own colours (surface, a one-line name, four signal tones), the current one
/// outlined. Two columns in either panel layout, so the tiles stay roomy. Click applies it at once and saves it.
struct ThemePicker: View {
    @ObservedObject private var state = ThemeState.shared
    @State private var themes: [Theme] = Theme.catalog().map(Theme.resolve)
    private let columns = 2

    var body: some View {
        let rows = stride(from: 0, to: themes.count, by: columns).map { Array(themes[$0..<min($0 + columns, themes.count)]) }
        VStack(alignment: .leading, spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 8) {
                    ForEach(rows[r], id: \.id) { ThemeTile(theme: $0, current: $0.id == Theme.current.id) }
                    ForEach(0..<(columns - rows[r].count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                }
            }
        }
        .onAppear { themes = Theme.catalog().map(Theme.resolve) }      // a scheme dropped into the themes folder shows the next time the panel opens
    }
}

private struct ThemeTile: View {
    let theme: Theme, current: Bool
    @State private var hot = false
    var body: some View {
        VStack(spacing: 6) {
            // one line, never wrapped: a name too long for the tile shrinks a little before it truncates
            Text(Theme.shortName(theme.name)).font(Pal.font(10.5, .semibold)).foregroundStyle(theme.text1.color()).lineLimit(1).minimumScaleFactor(0.85)
            HStack(spacing: 5) {
                ForEach([theme.accent, theme.ok, theme.warn, theme.crit], id: \.r) { Circle().fill($0.color()).frame(width: 7, height: 7) }
            }
        }
        .padding(.vertical, 10).padding(.horizontal, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(theme.bg.color()))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(current ? Pal.accent : hot ? Pal.text3 : Pal.line, lineWidth: current ? 1.5 : 1))
        .contentShape(Rectangle())
        .onHover { hot = $0 }
        .onTapGesture { AppConfig.setTheme(theme.id); Theme.apply(theme.id) }
    }
}

extension Theme {
    /// A tile-sized name: the variant word "medium" and the long "High Contrast" are shortened so no name is cut off in the picker.
    static func shortName(_ n: String) -> String {
        n.replacingOccurrences(of: ", medium", with: "").replacingOccurrences(of: " Medium", with: "")
            .replacingOccurrences(of: "High Contrast", with: "HC").replacingOccurrences(of: "Github", with: "GitHub")
    }
}
