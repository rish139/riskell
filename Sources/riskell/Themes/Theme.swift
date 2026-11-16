import SwiftUI
import Combine
import RiskellKit

/// A Base16 colour scheme as published by tinted-theming/schemes (the 16 slots base00...base0F). riskell never uses the slots raw: `Theme.resolve`
/// derives its own tokens from them and enforces contrast, because Base16's dim greys are comment tones, not readable text.
struct SchemeData {
    let id: String
    let name: String
    let author: String
    let variant: String                  // "dark" or "light"
    let palette: [String: UInt32]        // "base00" ... "base0F" -> 0xRRGGBB
}

extension Theme {
    /// What a scheme must reach against the surface (and the tile, which sits on it): WCAG 2.x ratios.
    enum Floor { static let text1 = 7.0, text2 = 4.5, text3 = 4.5, text4 = 3.2, accent = 3.0 }

    /// Moves `c` toward `target` in small steps until it reaches `minimum` against every background (or the target is reached).
    static func ensure(_ c: RGB, against bgs: [RGB], _ minimum: Double, toward target: RGB) -> RGB {
        func ok(_ x: RGB) -> Bool { bgs.allSatisfy { RGB.contrast(x, $0) >= minimum } }
        if ok(c) { return c }
        var t = 0.0
        while t < 1 { t += 0.04; let x = c.mix(target, min(1, t)); if ok(x) { return x } }
        return target
    }

    /// riskell's tokens from a scheme. The default scheme keeps the exact values the bar was designed with (`overrides`), so it never changes.
    static func resolve(_ s: SchemeData) -> Theme {
        func slot(_ k: String) -> RGB { RGB(s.palette[k] ?? 0x808080) }
        let dark = s.variant != "light"
        let bg = slot("base00"), tile = slot("base01")
        let pole = dark ? RGB.white : RGB.black                // what text and accents are pushed toward when they are too faint
        let backs = [bg, tile]
        let ov = overrides[s.id] ?? [:]
        func o(_ k: String, _ d: RGB) -> RGB { ov[k].map(RGB.init) ?? d }

        let ladder = dark ? ["base06", "base05", "base04"] : ["base07", "base06", "base05"]
        let t1 = ensure(slot(ladder[0]), against: backs, Floor.text1, toward: pole)
        let t2 = ensure(slot(ladder[1]), against: backs, Floor.text2, toward: pole)
        let t3 = ensure(slot(ladder[2]), against: backs, Floor.text3, toward: pole)
        // the dimmest text: as faint as the floor allows, found by fading text3 toward the surface
        var t4 = t3
        for i in 1...25 { let x = t3.mix(bg, Double(i) * 0.04); if RGB.contrast(x, bg) >= Floor.text4 { t4 = x } else { break } }
        func accentTone(_ k: String) -> RGB { ensure(slot(k), against: [bg], Floor.accent, toward: pole) }
        let crit = accentTone("base08")
        let accent = accentTone("base0A")
        return Theme(id: s.id, name: s.name, dark: dark,
                     bg: bg, tile: tile, canvas: o("canvas", bg.mix(.black, dark ? 0.22 : 0.06)),
                     text1: t1, text2: t2, text3: t3, text4: o("text4", t4),
                     accent: accent, ok: accentTone("base0B"), warn: accentTone("base09"), crit: crit, info: accentTone("base0D"),
                     critInk: o("critInk", crit.mix(t1, 0.25)), prov: accentTone("base0E"), amberDim: o("amberDim", accent.mix(bg, 0.5)))
    }

    /// Exact values from the original design, applied on top of the derived ones (only for the default scheme).
    static let overrides: [String: [String: UInt32]] = [
        "gruvbox-dark-medium": ["text4": 0x928374, "critInk": 0xff6b55, "amberDim": 0x91722c, "canvas": 0x1d2021],
    ]
    static let defaultID = "gruvbox-dark-medium"

    // MARK: the schemes: bundled, plus any Base16 .yaml/.yml the user drops into ~/.config/riskell/themes/

    static var userDirectory: URL { AppConfig.directory.appendingPathComponent("themes") }

    static func parseBase16(_ text: String, id: String) -> SchemeData? {
        var name = id, author = "", variant = "dark", pal: [String: UInt32] = [:]
        func value(_ line: String) -> String {
            guard let c = line.firstIndex(of: ":") else { return "" }
            return line[line.index(after: c)...].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
        }
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("name:") { name = value(line) }
            else if line.hasPrefix("author:") { author = value(line) }
            else if line.hasPrefix("variant:") { variant = value(line).lowercased() }
            else if line.hasPrefix("base"), let c = line.firstIndex(of: ":") {
                let key = String(line[..<c]), hex = value(line).split(separator: " ").first.map(String.init)?.replacingOccurrences(of: "#", with: "") ?? ""
                if key.count == 6, let v = UInt32(hex, radix: 16), hex.count == 6 { pal["base" + key.dropFirst(4).uppercased()] = v }
            }
        }
        let need = (0..<16).map { "base0" + String($0, radix: 16, uppercase: true) }
        guard need.allSatisfy({ pal[$0] != nil }) else { return nil }
        return SchemeData(id: id, name: name, author: author, variant: variant == "light" ? "light" : "dark", palette: pal)
    }

    /// Bundled schemes, then the user's (a user file with a bundled id replaces it).
    static func catalog() -> [SchemeData] {
        var out = BundledSchemes.all
        let fm = FileManager.default
        for f in ((try? fm.contentsOfDirectory(atPath: userDirectory.path)) ?? []).sorted() where f.hasSuffix(".yaml") || f.hasSuffix(".yml") {
            let id = (f as NSString).deletingPathExtension
            guard let t = try? String(contentsOf: userDirectory.appendingPathComponent(f), encoding: .utf8), let s = parseBase16(t, id: id) else {
                print("theme: \(f) is not a Base16 scheme (needs base00 ... base0F)"); fflush(stdout); continue
            }
            if let i = out.firstIndex(where: { $0.id == id }) { out[i] = s } else { out.append(s) }
        }
        return out
    }

    /// The theme the config asks for; called once at launch (main.swift), which sets `Theme.current`.
    static func loadInitial() -> Theme {
        let all = BundledSchemes.all
        let want = AppConfig.shared.theme ?? defaultID
        let s = catalog().first { $0.id == want } ?? all.first { $0.id == defaultID } ?? all[0]
        return resolve(s)
    }

    /// Switch to the scheme `id` (an unknown id means the default). Returns false when nothing would look different. Everything that draws is
    /// rebuilt: the roots of the hosting views are keyed by `ThemeState.epoch`, and AppKit-drawn views listen for `didChange`.
    @discardableResult static func apply(_ id: String?) -> Bool {
        let all = catalog(), want = id ?? defaultID
        guard let s = all.first(where: { $0.id == want }) ?? all.first(where: { $0.id == defaultID }) else { return false }
        let t = resolve(s)
        guard t.id != current.id || t.signature != current.signature else { return false }
        current = t
        ThemeState.shared.epoch += 1
        NotificationCenter.default.post(name: ThemeState.didChange, object: nil)
        return true
    }

    // MARK: validator (riskell --check-themes)

    /// `riskell --list-themes`: every scheme (bundled and the user's) as JSON with the tokens riskell resolves from it, for the installer's previews.
    static func listJSON() -> String {
        func hex(_ c: RGB) -> String { String(format: "#%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        let rows: [[String: Any]] = catalog().map { s in
            let t = resolve(s)
            return ["id": s.id, "name": s.name, "variant": s.variant, "author": s.author, "default": s.id == defaultID,
                    "bg": hex(t.bg), "tile": hex(t.tile), "text1": hex(t.text1), "text2": hex(t.text2), "text3": hex(t.text3), "text4": hex(t.text4),
                    "accent": hex(t.accent), "ok": hex(t.ok), "warn": hex(t.warn), "crit": hex(t.crit), "info": hex(t.info)]
        }
        let d = (try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: d, as: UTF8.self)
    }

    /// `riskell --check-themes tokens`: the default theme's tokens as hex, for comparing against a known palette.
    static func dumpTokens(_ id: String = defaultID) {
        guard let s = catalog().first(where: { $0.id == id }) else { return }
        let t = resolve(s)
        func hex(_ c: RGB) -> String { String(format: "%02x%02x%02x", Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded())) }
        for (k, v) in [("bg", t.bg), ("tile", t.tile), ("canvas", t.canvas), ("text1", t.text1), ("text2", t.text2), ("text3", t.text3), ("text4", t.text4),
                       ("accent", t.accent), ("ok", t.ok), ("warn", t.warn), ("crit", t.crit), ("info", t.info), ("critInk", t.critInk), ("prov", t.prov), ("amberDim", t.amberDim)] {
            print("\(k) \(hex(v))")
        }
    }

    static func check() {
        print("scheme                      var   t1    t2    t3    t4    acc   ok    warn  crit   (WCAG ratio vs surface; * = below its floor)")
        for s in catalog() {
            let t = resolve(s)
            func r(_ c: RGB, _ f: Double) -> String { let v = RGB.contrast(c, t.bg); return String(format: "%5.2f", v) + (v + 0.005 < f ? "*" : " ") }
            print(s.id.padding(toLength: 27, withPad: " ", startingAt: 0), (t.dark ? "dark " : "light"),
                  r(t.text1, Floor.text1), r(t.text2, Floor.text2), r(t.text3, Floor.text3), r(t.text4, Floor.text4),
                  r(t.accent, Floor.accent), r(t.ok, Floor.accent), r(t.warn, Floor.accent), r(t.crit, Floor.accent))
        }
    }
}

/// Bumped when the theme changes; the root of every hosting view is keyed by it, so the whole tree is rebuilt with the new colours.
final class ThemeState: ObservableObject {
    static let shared = ThemeState()
    @Published var epoch = 0
    static let didChange = Notification.Name("riskell.themeDidChange")
}

/// Wraps a root view so a theme change rebuilds it.
struct ThemeRoot<C: View>: View {
    @ObservedObject private var state = ThemeState.shared
    let content: C
    var body: some View { content.id(state.epoch) }
}
