import SwiftUI
import RiskellKit

/// Which islands hold which atoms, per bar and zone. The layout is data: `Config` owns it, edit mode changes it, and it is saved to
/// ~/.config/riskell/layout.json (riskell's own file). The bell is cut; "compat" is the version pill, drawn only while something needs attention.
struct Island: Identifiable, Codable, Equatable { let id: String; var atoms: [String] }

enum Zone: String, Codable, CaseIterable { case start, center, end }

/// How a bar's cards spill out. `fill` is the flush style (the card hangs from the bar, which fills in under it); `chat` is a rounded card
/// joined to the widget's pill by a short neck, the bar staying as it is. The raw value is what layout.json stores.
enum Spill: String, Codable { case fill, chat }

struct BarSpec: Codable, Equatable {
    var start: [Island] = []
    var center: [Island] = []
    var end: [Island] = []
    subscript(z: Zone) -> [Island] {
        get { switch z { case .start: return start; case .center: return center; case .end: return end } }
        set { switch z { case .start: start = newValue; case .center: center = newValue; case .end: end = newValue } }
    }
}

enum BarKey: String, CaseIterable, Identifiable {
    case top, bottom, left, right
    var id: String { rawValue }
    var vertical: Bool { self == .left || self == .right }
    /// The side a card opens on: a strip's card opens away from it (the left strip's card to its right, the right strip's to its left).
    var edge: PopEdge { switch self { case .top: return .below; case .bottom: return .above; case .left: return .right; case .right: return .left } }
    /// The top bar's middle is the notch and the strip has no middle, so only the bottom bar has a centre zone.
    var zones: [Zone] { self == .bottom ? [.start, .center, .end] : [.start, .end] }
    /// The bar a card that opens on this side hangs from.
    static func bar(for edge: PopEdge) -> BarKey { switch edge { case .below: return .top; case .above: return .bottom; case .right: return .left; case .left: return .right } }
    var title: String { switch self { case .top: return "Top"; case .bottom: return "Bottom"; case .left: return "Left"; case .right: return "Right" } }
}

/// What can be placed where: every atom has a horizontal and a vertical form, so any atom fits any bar (the version pill stays where it is).
/// The cards that open from them follow the bar's edge (see `popout`).
enum AtomCatalog {
    static var all: [String] { Registry.atoms.map(\.id) }
    static func fits(_ id: String, _ bar: BarKey) -> Bool { Registry.byID[id] != nil }
    /// The popout card an atom opens (nil: it has none).
    static func card(_ id: String) -> String? { Registry.byID[id]?.card?.id }
    static func name(_ id: String) -> String { Registry.byID[id]?.name ?? id }
}

enum Drop { case into(BarKey, String, Int), new(BarKey, Zone, Int) }      // merge at an index of an island / a new island at an index of a zone

/// Where a drop would land, in the target bar's own coordinates: an outline round the island it joins, and a line at the slot.
struct Hint: Equatable { var bar: BarKey; var box: CGRect?; var line: CGRect }

/// The bar thicknesses the window gaps are measured from, design units. The bottom (44) and top (50) are today's gaps less the default window
/// gap of 6, so the defaults reproduce the numbers riskell always wrote; the strip is `G.strip`.
enum WindowGap {
    static let strip: CGFloat = G.strip
    static let bottomBar: CGFloat = 44
    static let topBar: CGFloat = 50
}

final class Config: ObservableObject {
    static let shared = Config()

    @Published private(set) var specs: [BarKey: BarSpec] = Config.defaults { didSet { if ready { Needs.apply() } } }
    @Published private(set) var hug: [BarKey: Bool] = Config.defaultHug
    @Published private(set) var spillStyle: [BarKey: Spill] = [:]
    @Published private(set) var gap: CGFloat = 8
    @Published private(set) var enabled: [BarKey: Bool] = Config.defaultOn { didSet { if ready { Needs.apply() } } }
    @Published var editing = false
    @Published var dragging: String? = nil
    @Published var hint: Hint? = nil

    /// Measured while editing: "atom:<id>" and "isl:<id>" rectangles in each bar's own (top-left origin) coordinates.
    var frames: [BarKey: [String: CGRect]] = [:]
    var windows: [BarKey: NSWindow] = [:]
    /// Set by main: the screen's left edge and the notch's edges (screen x), so a bar can place the wings whatever strips are on.
    var screenMinX: CGFloat = 0
    var notchAbs: (l: CGFloat, r: CGFloat)? = nil
    /// Called after a bar is switched on or off: main re-fits the panels and rewrites OmniWM's gaps.
    var onGeometry: (() -> Void)?
    private var saveWork: DispatchWorkItem?

    static let defaults: [BarKey: BarSpec] = [
        .top: BarSpec(start: [Island(id: "compat", atoms: ["compat"])], end: [Island(id: "status", atoms: ["ext:bat", "ext:clock"])]),
        .bottom: BarSpec(center: [Island(id: "cpu", atoms: ["ext:cpu"])], end: [Island(id: "link", atoms: ["ext:net", "ext:vol"]), Island(id: "sky", atoms: ["ext:weather"])]),
        .left: BarSpec(start: [Island(id: "workspaces", atoms: ["ext:workspaces", "ext:appicon"])], end: [Island(id: "system", atoms: ["ext:usage", "ext:fan"])]),
        .right: BarSpec(),
    ]
    static let defaultHug: [BarKey: Bool] = [.top: false, .bottom: false, .left: true, .right: true]
    static let defaultOn: [BarKey: Bool] = [.top: true, .bottom: true, .left: true, .right: false]

    /// False while the saved layout is being read in `init`: the services are not asked about a layout that is not complete (and `Config.shared` is not reachable yet).
    private var ready = false
    private init() { load(); ready = true }

    func spec(_ b: BarKey) -> BarSpec { specs[b] ?? BarSpec() }
    func isHug(_ b: BarKey) -> Bool { hug[b] ?? false }
    /// The chosen card style, and the one in effect: chat needs separate pills, so a hugged bar always uses the flush style.
    func spill(_ b: BarKey) -> Spill { spillStyle[b] ?? .fill }
    func isChat(_ b: BarKey) -> Bool { spill(b) == .chat && !isHug(b) }

    // MARK: settings

    func setHug(_ b: BarKey, _ on: Bool) { guard hug[b] != on else { return }; hug[b] = on; save() }
    func setSpill(_ b: BarKey, _ v: Spill) { guard spill(b) != v, v == .fill || !isHug(b) else { return }; spillStyle[b] = v; save() }
    func setGap(_ g: CGFloat) { let v = min(16, max(2, g)); guard v != gap else { return }; gap = v; save() }
    func reset() { specs = Config.defaults; hug = Config.defaultHug; spillStyle = [:]; enabled = Config.defaultOn; gap = 8; save(); onGeometry?() }

    // MARK: bars on and off

    func on(_ b: BarKey) -> Bool { enabled[b] ?? true }
    /// A bar with no pills can be switched off (the top bar never: it carries the notch's wings).
    func isEmpty(_ b: BarKey) -> Bool { b.zones.allSatisfy { spec(b)[$0].allSatisfy { $0.atoms.allSatisfy { $0 == "compat" } } } }
    func canSwitchOff(_ b: BarKey) -> Bool { b != .top && isEmpty(b) }
    func setOn(_ b: BarKey, _ v: Bool) {
        guard b != .top, on(b) != v, v || isEmpty(b) else { return }
        enabled[b] = v; save(); onGeometry?()
    }
    /// Real points (screen coordinates), like everything the window manager is handed.
    var leftW: CGFloat { on(.left) ? Real.strip : 0 }
    var rightW: CGFloat { on(.right) ? Real.strip : 0 }
    /// OmniWM's gaps.outer for the bars that are on: room for a strip or the bottom bar, else the plain screen margin.
    /// Each gap is the bar's thickness plus the window gap (`spacing.windowGap`, design units, 6 by default), times the scale. At the default
    /// they are today's numbers: left 52 + 6 = 58, bottom 44 + 6 = 50, top 50 + 6 = 56, bare margin 6 (real points at scale 1).
    static var margin: CGFloat { Spacing.current.window * Real.k }
    var gapLeft: CGFloat { on(.left) ? (WindowGap.strip + Spacing.current.window) * Real.k : Config.margin }
    var gapRight: CGFloat { on(.right) ? (WindowGap.strip + Spacing.current.window) * Real.k : Config.margin }
    var gapBottom: CGFloat { on(.bottom) ? (WindowGap.bottomBar + Spacing.current.window) * Real.k : Config.margin }
    static var gapTop: CGFloat { (WindowGap.topBar + Spacing.current.window) * Real.k }

    /// Atoms that are on no bar (removed with their x); the settings panel lists them so they can be put back.
    /// The atoms placed on a bar that is on: what the built-in services are gated by (Services/Needs.swift).
    var placedAtoms: Set<String> { Set(BarKey.allCases.filter { on($0) }.flatMap { b in b.zones.flatMap { spec(b)[$0].flatMap(\.atoms) } }) }
    var tray: [String] { let placed = Set(BarKey.allCases.flatMap { b in b.zones.flatMap { spec(b)[$0].flatMap(\.atoms) } }); return AtomCatalog.all.filter { !placed.contains($0) } }

    // MARK: editing

    /// Takes the atom off wherever it is; an island left empty goes away (the version pill's island stays).
    func remove(_ atom: String) {
        for b in BarKey.allCases {
            var s = spec(b)
            for z in Zone.allCases {
                s[z] = s[z].compactMap { isl in
                    guard isl.atoms.contains(atom) else { return isl }
                    var i = isl; i.atoms.removeAll { $0 == atom }
                    return i.atoms.isEmpty ? nil : i
                }
            }
            if s != spec(b) { specs[b] = s }
        }
    }
    func add(_ atom: String, to b: BarKey) {
        guard AtomCatalog.fits(atom, b) else { return }
        remove(atom)
        if !on(b) { enabled[b] = true; onGeometry?() }
        var s = spec(b); s.end.append(Island(id: Config.newID(), atoms: [atom])); specs[b] = s
        save()
    }
    func apply(_ atom: String, _ d: Drop) {
        remove(atom)
        switch d {
        case .into(let b, let id, let idx):
            var s = spec(b)
            for z in Zone.allCases { if let k = s[z].firstIndex(where: { $0.id == id }) { s[z][k].atoms.insert(atom, at: min(idx, s[z][k].atoms.count)) } }
            specs[b] = s
        case .new(let b, let z, let idx):
            var s = spec(b); s[z].insert(Island(id: Config.newID(), atoms: [atom]), at: min(idx, s[z].count)); specs[b] = s
        }
        save()
    }
    private static func newID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    // MARK: drop target

    /// The bar under the pointer (screen coordinates, real points), and the pointer in that bar's own top-left coordinates, in design units
    /// (the space the islands report their frames in, see Bars.swift).
    func barUnder(_ m: CGPoint) -> (BarKey, CGPoint)? {
        let k = Real.k
        for b in [BarKey.left, .right, .top, .bottom] where on(b) {
            guard let w = windows[b] else { continue }
            var fr = w.frame
            let hostX: CGFloat = b == .right ? Real.r : 0          // the right panel has its fillet room on the inside, the strip is its right part
            if b == .left { fr.size.width = Real.strip }
            if b == .right { fr.origin.x += Real.r; fr.size.width = Real.strip }
            if fr.insetBy(dx: -4, dy: -4).contains(m) { return (b, CGPoint(x: (m.x - w.frame.minX - hostX) / k, y: (w.frame.maxY - m.y) / k)) }
        }
        return nil
    }

    /// Plain rules: on an island = join it, at the boundary nearest the pointer; anywhere else on the bar = a new island of its own,
    /// in the zone (start / centre / end) the pointer is in, between the islands there.
    func plan(_ atom: String, mouse: CGPoint) -> (Drop, Hint)? {
        guard let (bar, p) = barUnder(mouse), AtomCatalog.fits(atom, bar), let win = windows[bar] else { return nil }
        let v = bar.vertical, fr = frames[bar] ?? [:], s = spec(bar)
        let size = CGSize(width: (win.frame.width - (bar == .right ? Real.r : 0)) / Real.k, height: win.frame.height / Real.k)      // design units
        let along = v ? p.y : p.x
        func mid(_ r: CGRect) -> CGFloat { v ? r.midY : r.midX }
        func lo(_ r: CGRect) -> CGFloat { v ? r.minY : r.minX }
        func hi(_ r: CGRect) -> CGFloat { v ? r.maxY : r.maxX }
        func line(_ at: CGFloat, across: CGRect, thick: CGFloat, inset: CGFloat) -> CGRect {
            v ? CGRect(x: across.minX + inset, y: at - thick / 2, width: across.width - 2 * inset, height: thick)
              : CGRect(x: at - thick / 2, y: across.minY + inset, width: thick, height: across.height - 2 * inset)
        }
        for z in bar.zones {
            for isl in s[z] where isl.id != "compat" {
                guard let r = fr["isl:" + isl.id], r.insetBy(dx: -3, dy: -3).contains(p) else { continue }
                let others = isl.atoms.filter { $0 != atom }
                if others.isEmpty { return nil }                      // its own island: nothing to do
                var idx = 0
                for a in others { if let ar = fr["atom:" + a], mid(ar) < along { idx += 1 } else { break } }
                let rects: [CGRect?] = others.map { fr["atom:" + $0] }
                let at: CGFloat
                if idx == 0 { at = rects[0].map { lo($0) - 4 } ?? lo(r) }
                else if idx == others.count { at = rects[idx - 1].map { hi($0) + 4 } ?? hi(r) }
                else { at = ((rects[idx - 1].map(hi) ?? 0) + (rects[idx].map(lo) ?? 0)) / 2 }
                return (.into(bar, isl.id, idx), Hint(bar: bar, box: r.insetBy(dx: -2, dy: -2), line: line(at, across: r, thick: 2.5, inset: 5)))
            }
        }
        let len = v ? size.height : size.width
        let z: Zone = bar.zones.count == 3 ? (along < len / 3 ? .start : along > 2 * len / 3 ? .end : .center) : (along < len / 2 ? .start : .end)
        let list = s[z].filter { $0.atoms != [atom] }
        var idx = 0
        for isl in list { if let r = fr["isl:" + isl.id] { if mid(r) < along { idx += 1 } else { break } } else { idx += 1 } }
        let ref = list.compactMap { fr["isl:" + $0.id] }.first ?? CGRect(x: 0, y: 0, width: v ? G.pill : 0, height: v ? 0 : G.pill)     // design units throughout
        let across = v ? CGRect(x: (G.strip - G.pill) / 2, y: 0, width: G.pill, height: 0)
                       : CGRect(x: 0, y: ref.height > 0 ? ref.minY : (bar == .top ? G.topShift : 0) + (G.band - G.pill) / 2, width: 0, height: G.pill)
        let at: CGFloat
        if idx < list.count, let r = fr["isl:" + list[idx].id] { at = lo(r) - gap / 2 }
        else if idx > 0, let r = fr["isl:" + list[idx - 1].id] { at = hi(r) + gap / 2 }
        else { at = z == .start ? G.sideMargin : z == .end ? len - G.sideMargin : len / 2 }
        return (.new(bar, z, idx), Hint(bar: bar, box: nil, line: line(at, across: across, thick: 4, inset: 0)))
    }

    // MARK: persistence

    private struct Saved: Codable {
        var top: BarSpec, bottom: BarSpec, left: BarSpec
        var hugTop: Bool, hugBottom: Bool, hugLeft: Bool
        var gap: Double
        var right: BarSpec?, hugRight: Bool?, on: [String: Bool]?      // added later: an older file lacks them
        var spill: [String: String]?                                    // per bar, "fill" or "chat"; absent or unknown = fill
    }
    /// Atoms that became packages keep working from an older layout.json (the clock became ext:clock).
    static let legacyIDs = ["workspaces": "ext:workspaces", "appicon": "ext:appicon", "net": "ext:net", "vol": "ext:vol", "bat": "ext:bat", "cpu": "ext:cpu", "fan": "ext:fan", "usage": "ext:usage", "weather": "ext:weather", "clock": "ext:clock"]
    private static var url: URL { URL(fileURLWithPath: ProcessInfo.processInfo.environment["RISKELL_LAYOUT"] ?? NSHomeDirectory() + "/.config/riskell/layout.json") }

    private func load() {
        guard let d = try? Data(contentsOf: Config.url), let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        var seen = Set<String>(), ids = Set<String>()
        func clean(_ b: BarKey, _ spec: BarSpec) -> BarSpec {
            var out = BarSpec()
            for z in b.zones {
                for isl in spec[z] {
                    let atoms = isl.atoms.map { Config.legacyIDs[$0] ?? $0 }.filter { a in
                        if a == "compat" { return b == .top && z == .start }
                        guard AtomCatalog.fits(a, b), !seen.contains(a) else { return false }
                        seen.insert(a); return true
                    }
                    if !atoms.isEmpty, ids.insert(isl.id).inserted { out[z].append(Island(id: isl.id, atoms: atoms)) }
                }
            }
            return out
        }
        var top = clean(.top, s.top)
        if !top.start.contains(where: { $0.id == "compat" }) { top.start.insert(Island(id: "compat", atoms: ["compat"]), at: 0) }
        specs = [.top: top, .bottom: clean(.bottom, s.bottom), .left: clean(.left, s.left), .right: clean(.right, s.right ?? BarSpec())]
        hug = [.top: s.hugTop, .bottom: s.hugBottom, .left: s.hugLeft, .right: s.hugRight ?? true]
        var on = Config.defaultOn
        for (k, v) in s.on ?? [:] { if let b = BarKey(rawValue: k), b != .top { on[b] = v } }
        enabled = on
        var styles: [BarKey: Spill] = [:]
        for (k, v) in s.spill ?? [:] { if let b = BarKey(rawValue: k), let st = Spill(rawValue: v) { styles[b] = st } }
        spillStyle = styles
        gap = min(16, max(2, CGFloat(s.gap)))
    }

    /// A pill left the config while it was on a bar: take it off the layout (an island left empty goes away).
    func pruneUnknown() {
        var changed = false
        for b in BarKey.allCases {
            var s = spec(b)
            for z in Zone.allCases {
                s[z] = s[z].compactMap { isl in
                    let atoms = isl.atoms.filter { $0 == "compat" || Registry.byID[$0] != nil }
                    if atoms.count != isl.atoms.count { changed = true }
                    return atoms.isEmpty ? nil : Island(id: isl.id, atoms: atoms)
                }
            }
            if s != spec(b) { specs[b] = s }
        }
        if changed { save() }
    }

    /// Debounced: a drag can change the layout many times a second.
    func save() {
        saveWork?.cancel()
        let s = Saved(top: spec(.top), bottom: spec(.bottom), left: spec(.left), hugTop: isHug(.top), hugBottom: isHug(.bottom), hugLeft: isHug(.left), gap: Double(gap),
                      right: spec(.right), hugRight: isHug(.right), on: Dictionary(uniqueKeysWithValues: BarKey.allCases.map { ($0.rawValue, on($0)) }),
                      spill: Dictionary(uniqueKeysWithValues: BarKey.allCases.map { ($0.rawValue, spill($0).rawValue) }))
        let w = DispatchWorkItem {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? FileManager.default.createDirectory(at: Config.url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let d = try? enc.encode(s) { try? d.write(to: Config.url, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}
