import Foundation

/// Layout presets: the layout.json riskell reads (docs/BARS.md). Classic is riskell's built-in default
/// (Sources/riskell/Layout.swift, `Config.defaults`). Atom ids come from Sources/riskell/Registry.swift.
enum Preset: Int, CaseIterable {
    case minimal, classic, full

    var label: String {
        switch self {
        case .minimal: return "Minimal"
        case .classic: return "Classic"
        case .full: return "Full"
        }
    }

    var id: String {
        switch self {
        case .minimal: return "minimal"
        case .classic: return "classic"
        case .full: return "full"
        }
    }
}

/// Floating bars are separate pills; hugging bars are one band the pills dissolve into. `preset` keeps riskell's own mix.
enum BarMode: Int, CaseIterable {
    case preset, floating, hug
}

enum CardStyle: Int, CaseIterable {
    case flush, chat

    var id: String { self == .flush ? "fill" : "chat" }
}

enum Presets {
    private static func island(_ id: String, _ atoms: [String]) -> [String: Any] {
        ["id": id, "atoms": atoms]
    }

    private static func bar(start: [[String: Any]] = [], center: [[String: Any]] = [], end: [[String: Any]] = []) -> [String: Any] {
        ["start": start, "center": center, "end": end]
    }

    private static var top: [String: Any] {
        bar(start: [island("compat", ["compat"])], end: [island("status", ["bat", "ext:clock"])])
    }

    private static var link: [String: Any] { island("link", ["net", "vol"]) }

    static func layout(_ preset: Preset, mode: BarMode, cards: CardStyle) -> [String: Any] {
        let top = self.top
        let bars: [String: Any]
        let on: [Bool]
        switch preset {
        case .classic:
            bars = [
                "top": top,
                "bottom": bar(center: [island("cpu", ["cpu"])], end: [link, island("sky", ["weather"])]),
                "left": bar(start: [island("workspaces", ["workspaces", "appicon"])], end: [island("system", ["usage", "fan"])]),
                "right": bar(),
            ]
            on = [true, true, true, false]
        case .minimal:
            bars = ["top": top, "bottom": bar(), "left": bar(), "right": bar()]
            on = [true, false, false, false]
        case .full:
            bars = [
                "top": top,
                "bottom": bar(center: [island("cpu", ["cpu"])], end: [island("sky", ["weather"])]),
                "left": bar(start: [island("workspaces", ["workspaces", "appicon"])], end: [island("system", ["usage", "fan"])]),
                "right": bar(end: [link]),
            ]
            on = [true, true, true, true]
        }
        // Riskell's own defaults: top and bottom float, left and right hug.
        let presetHug = [false, false, true, true]
        let hug: [Bool]
        switch mode {
        case .preset: hug = presetHug
        case .floating: hug = [false, false, false, false]
        case .hug: hug = [true, true, true, true]
        }
        var out: [String: Any] = [:]
        out["top"] = bars["top"]
        out["bottom"] = bars["bottom"]
        out["left"] = bars["left"]
        out["right"] = bars["right"]
        out["hugTop"] = hug[0]
        out["hugBottom"] = hug[1]
        out["hugLeft"] = hug[2]
        out["hugRight"] = hug[3]
        out["gap"] = 8
        out["on"] = ["top": on[0], "bottom": on[1], "left": on[2], "right": on[3]]
        let style = cards.id
        out["spill"] = ["top": style, "bottom": style, "left": style, "right": style]
        return out
    }

    /// Every atom id a layout places, in bar order.
    static func atoms(_ layout: [String: Any]) -> [String] {
        var out: [String] = []
        for b in ["top", "bottom", "left", "right"] {
            guard let spec = layout[b] as? [String: Any] else { continue }
            for z in ["start", "center", "end"] {
                for isl in (spec[z] as? [[String: Any]]) ?? [] {
                    out += (isl["atoms"] as? [String]) ?? []
                }
            }
        }
        return out
    }

    /// Serialises a layout for layout.json.
    static func json(_ layout: [String: Any]) throws -> String {
        try ConfigIO.pretty(layout)
    }
}
