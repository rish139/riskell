import SwiftUI
import Combine
import RiskellKit
import RiskellTTY

/// The app's side of RiskellKit (docs/EXTENSION-KIT.md): the hooks the kit calls, the feeds it offers, and the atoms of installed packages
/// registered like any other. Nothing here runs when no package is installed.

/// Which bars are showing. A bar that is switched off, or hidden while a fullscreen Space is up, is only a window at alpha 0: its views are
/// still alive, so "on a bar" is not enough to know that an atom may run. Pills and extension atoms attach (start their work) only while their
/// bar is active, and detach when it is not. Going inactive waits for the fade-out (0.3 s) so nothing changes on screen; going active is at once.
final class BarActivity: ObservableObject {
    static let shared = BarActivity()
    @Published private(set) var inactive: Set<BarKey> = []
    private var pending: [BarKey: DispatchWorkItem] = [:]
    private var known: Set<BarKey> = []      // bars told about once: the first word is applied at once (at launch nothing is fading)
    func isActive(_ k: BarKey) -> Bool { !inactive.contains(k) }
    func update(_ k: BarKey, shown: Bool) {
        pending[k]?.cancel(); pending[k] = nil
        let first = known.insert(k).inserted
        if shown { if inactive.contains(k) { inactive.remove(k) }; return }
        if first { inactive.insert(k); return }
        let w = DispatchWorkItem { [weak self] in self?.inactive.insert(k) }
        pending[k] = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }
}

/// Attach/detach of an atom that follows two things: its view being on a bar, and that bar showing.
struct ActiveWhenShown: ViewModifier {
    let attach: () -> Void, detach: () -> Void
    @Environment(\.popEdge) private var edge
    @ObservedObject private var activity = BarActivity.shared
    @State private var appeared = false
    @State private var running = false
    private var barActive: Bool { activity.isActive(edge.map { BarKey.bar(for: $0) } ?? .top) }
    private func sync() {      // (a struct: the @State wrappers write through)
        let want = appeared && barActive
        guard want != running else { return }
        running = want
        if want { attach() } else { detach() }
    }
    func body(content: Content) -> some View {
        content
            .onAppear { appeared = true; sync() }
            .onDisappear { appeared = false; sync() }
            .onChange(of: barActive) { _, _ in sync() }
    }
}

/// The workspaces, windows and the rail's swipe, for the kit's `WindowsModel` and `RailState`, and the window manager's actions (`KitHost.windows`).
final class WindowBridge: WindowActions {
    static let shared = WindowBridge()
    private var bag: [AnyCancellable] = []
    func start() {
        let s = store
        Publishers.CombineLatest(s.$spaces, s.$windows).sink { spaces, windows in
            WindowsModel.shared.update(
                spaces: spaces.map { WorkspaceInfo(id: $0.id, focused: $0.focused, visible: $0.visible, windows: $0.windows, fullscreen: $0.fullscreen) },
                windows: windows.map { WindowInfo(id: $0.id, pid: $0.pid, app: $0.app, title: $0.title, space: $0.space, focused: $0.focused) })
        }.store(in: &bag)
        Publishers.CombineLatest(s.rail.$swipe, s.rail.$live).sink { RailState.shared.update(swipe: $0, live: $1) }.store(in: &bag)
    }
    func focus(space: Int) { WM.shared?.focus(space: space) }
    func focus(window id: Int) { WM.shared?.focus(window: id) }
    func close(window id: Int) { WM.shared?.close(window: id) }
    func move(window id: Int, toSpace space: Int) { WM.shared?.move(window: id, toSpace: space) }
    func moveToNewSpace(window id: Int, after count: Int) { WM.shared?.moveToNewSpace(window: id, after: count) }
}

/// What the kit's `KitHost.app` offers an extension.
final class AppBridge: AppHooks {
    static let shared = AppBridge()
    func restart() { shutdown(); exit(0) }      // launchd starts riskell again
}

/// The kit's `.popout` modifier talks to the one popout host through this.
final class PopoutBridge: PopoutHooks {
    static let shared = PopoutBridge()
    var openCard: String? { Popout.shared.card }
    var editing: Bool { Config.shared.editing }
    func hover(_ id: String, anchor: CGRect, edge: PopEdge, island: CGRect?) { Popout.shared.hover(id, anchor: anchor, edge: edge, island: island) }
    func reanchor(_ id: String, _ anchor: CGRect, island: CGRect?) { Popout.shared.reanchor(id, anchor, island: island) }
    func leave(_ id: String) { Popout.shared.leave(id) }
    func toggleStage(_ id: String) { Popout.shared.toggleStage(id) }
    func setStage(_ stage: Int) { Popout.shared.setStage(stage) }
    func closeCard() { Popout.shared.close() }
    func setKeyable(_ on: Bool) { Popout.shared.setKeyable(on) }
    func setHoldOpen(_ on: Bool) { Popout.shared.holdOpen = on }
    func refit() { Popout.shared.refit() }
    func holdOpen() { Popout.shared.holdOpen = true }
}

/// Feeds: the values the app already computes (the Store's), handed to extensions by subscription. A subscription is a Combine sink on the
/// Store (nothing polls for it); `minute` is a timer that exists only while someone is subscribed.
final class FeedBridge: FeedHub {
    static let shared = FeedBridge()

    private final class Sub { var bag: [AnyCancellable] = []; var timer: DispatchSourceTimer?; var release: (() -> Void)? }

    func subscribe(_ key: String, _ yield: @escaping @Sendable (Any) -> Void) -> () -> Void {
        let sub = Sub()
        DispatchQueue.main.async {
            let s = store
            if key == "battery" || key == "volume" { sub.release = Needs.hold("sys") }      // the battery and the volume are read by the sys service
            switch key {
            case "battery":
                sub.bag = [Publishers.CombineLatest3(s.$batPct, s.$onAC, s.$charging).map { BatteryState(percent: $0, onAC: $1, charging: $2) }
                    .removeDuplicates().sink { yield($0) }]
            case "volume":
                sub.bag = [Publishers.CombineLatest(s.$volume, s.$muted).map { VolumeState(percent: $0, muted: $1) }.removeDuplicates().sink { yield($0) }]
            case "focusedApp":
                sub.bag = [s.$windows.map { FocusedApp(name: $0.first(where: { $0.focused })?.app) }.removeDuplicates().sink { yield($0) }]
            case "spaces":
                sub.bag = [s.$spaces.map { SpacesState(count: $0.count, focused: $0.firstIndex(where: { $0.focused }).map { $0 + 1 }) }
                    .removeDuplicates().sink { yield($0) }]
            case "minute":
                let t = DispatchSource.makeTimerSource(queue: .main)
                let now = Date().timeIntervalSince1970
                t.schedule(deadline: .now() + (60 - now.truncatingRemainder(dividingBy: 60)), repeating: 60, leeway: .milliseconds(500))
                t.setEventHandler { yield(Date()) }
                t.resume(); sub.timer = t
                yield(Date())
            default: break
            }
        }
        return { DispatchQueue.main.async { sub.bag = []; sub.timer?.cancel(); sub.timer = nil; sub.release?(); sub.release = nil } }
    }
}

/// A `ReadingAtom` of an installed package, fed to the same view a script pill uses. The stream runs between the first atom appearing on a
/// showing bar and the last one leaving.
final class ExtensionReading: ReadingSource {
    let type: any ReadingAtom.Type
    let env: Env
    let model = PillModel()
    private var refs = 0
    private var task: Task<Void, Never>?

    init(_ type: any ReadingAtom.Type, env: Env) { self.type = type; self.env = env }

    var title: String { type.meta.name }
    var cardID: String { "ext." + type.meta.id }
    var keepsHistory: Bool { false }
    func click() {}
    func attach() { refs += 1; if refs == 1 { start() } }
    func detach() { refs = max(0, refs - 1); if refs == 0 { task?.cancel(); task = nil } }

    private func start() {
        let stream = type.init().readings(env), model = self.model
        task = Task {
            for await r in stream {
                await MainActor.run { if let r { model.apply(r, history: nil) } else if !model.stale { model.stale = true } }
            }
        }
    }
}

/// Start/stop of a `CustomAtom`, counted over its horizontal and vertical instances.
final class AtomLifecycle {
    private var refs = 0
    private var stop: (() -> Void)?
    private let start: () -> (() -> Void)?
    init(start: @escaping () -> (() -> Void)?) { self.start = start }
    func attach() { refs += 1; if refs == 1 { stop = start() } }
    func detach() { refs = max(0, refs - 1); if refs == 0 { stop?(); stop = nil } }
}

/// One form of a `CustomAtom`, held to its box: a horizontal form is at most 36 tall and `maxWidth` wide, a vertical one at most 40 wide.
struct CustomAtomView<A: CustomAtom>: View {
    let atom: A
    let env: Env
    let life: AtomLifecycle
    let vertical: Bool
    let maxWidth: CGFloat
    var body: some View {
        // The anchor is a view of its own: an atom that draws nothing until its data arrives (the battery, before its first reading) resolves to an
        // empty view, which never "appears", so it would never start the work that fetches the data. It has no size, so the layout is unchanged.
        ZStack {
            Color.clear.frame(width: 0, height: 0)
                .modifier(ActiveWhenShown(attach: { life.attach() }, detach: { life.detach() }))
            Group {
                if vertical { atom.vertical(env).frame(maxWidth: 40).clipped() }
                else { atom.horizontal(env).fixedSize(horizontal: true, vertical: false).frame(maxWidth: maxWidth, maxHeight: G.pill, alignment: .leading).clipped().fixedSize(horizontal: true, vertical: false) }      // hugs its content, at most `maxWidth` (a bare maxWidth frame would grow to the room the bar offers)
            }
        }
    }
}

/// One setting an extension declares in its manifest (`settings`), shown in the EXTENSIONS card of riskell preferences. The generated list is
/// Generated/InstalledSettings.swift; the values live in `~/.config/riskell/ext/<id>.json` and are read through `env.prefs`.
struct ExtSetting: Identifiable {
    enum Kind { case number(min: Double, max: Double, step: Double, def: Double), bool(def: Bool), choice([String], def: String) }
    let ext: String, key: String, label: String, kind: Kind
    var id: String { ext + "." + key }
}

enum ExtPrefs {
    static func file(_ ext: String) -> URL { AppConfig.directory.appendingPathComponent("ext").appendingPathComponent(ext + ".json") }
    static func json(_ ext: String) -> [String: Any] {
        (try? Data(contentsOf: file(ext))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
    }
    static func number(_ s: ExtSetting, def: Double) -> Double { (json(s.ext)[s.key] as? NSNumber)?.doubleValue ?? def }
    static func bool(_ s: ExtSetting, def: Bool) -> Bool { (json(s.ext)[s.key] as? NSNumber)?.boolValue ?? def }
    static func choice(_ s: ExtSetting, def: String) -> String { json(s.ext)[s.key] as? String ?? def }

    /// Writes one value (the others kept) and rebuilds the extension atoms, so the change shows at once.
    static func set(_ ext: String, _ key: String, _ value: Any) {
        var j = json(ext)
        j[key] = value
        let f = file(ext)
        try? FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) { try? d.write(to: f, options: .atomic) }
        PackageAtoms.reload(); Registry.rebuild(); ThemeState.shared.epoch += 1
    }
}

/// The atoms of the packages in `installedPackages` (Generated/InstalledPackages.swift), as `AtomDef`s with the id `ext:<id>`.
enum PackageAtoms {
    private(set) static var all: [AtomDef] = build()
    /// Fresh atoms, which read the preferences again (after a setting changed).
    static func reload() { all = build() }

    private static func build() -> [AtomDef] {
        var out: [AtomDef] = [], seen = Set<String>()
        func ok(_ m: AtomMeta) -> Bool {
            guard !m.id.isEmpty, m.id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }), seen.insert(m.id).inserted else {
                print("extensions: ignoring atom \"\(m.id)\" (needs a unique plain id)"); fflush(stdout); return false
            }
            return true
        }
        let off = Set(AppConfig.shared.disabledExtensions ?? [])
        for p in installedPackages {
            if off.contains(p.id) { print("extensions: \"\(p.id)\" is disabled in config.json"); fflush(stdout); continue }
            for t in p.package.readings where ok(t.meta) { out.append(reading(t)) }
            for t in p.package.atoms where ok(t.meta) { out.append(custom(t)) }
        }
        if !out.isEmpty { print("extensions: \(out.count) atom(s) from installed packages"); fflush(stdout) }
        return out
    }

    private static func prefs(_ id: String) -> Prefs { Prefs(json: ExtPrefs.json(id)) }
    private static func env(_ id: String) -> Env { Env(id: id, prefs: prefs(id), cache: URL(fileURLWithPath: Demo.cacheDirectory)) }

    private static func reading(_ t: any ReadingAtom.Type) -> AtomDef {
        let m = t.meta
        let run = ExtensionReading(t, env: env(m.id))
        return AtomDef(id: "ext:" + m.id, name: m.name,
                       card: CardDef(id: run.cardID, size: { _ in PillCard.size(run.model.reading, stale: run.model.stale) }, content: { AnyView(PillCard(source: run)) }),
                       blank: nil,
                       view: { v in
                           // a horizontal form keeps its natural width and is clipped at `maxWidth` (text never wraps into two lines)
                           AnyView(Group { if v { PillAtom(source: run, vertical: true) } else { PillAtom(source: run, vertical: false).fixedSize(horizontal: true, vertical: false).frame(maxWidth: m.maxWidth, alignment: .leading).clipped() } }.id(ObjectIdentifier(run))) },
                       priority: m.priority)
    }

    private static func custom<A: CustomAtom>(_ t: A.Type) -> AtomDef {
        let m = t.meta, atom = A(), env = env(m.id)
        let life = AtomLifecycle { atom.activate(env) }
        return AtomDef(id: "ext:" + m.id, name: m.name,
                       card: atom.card.map { CardDef(id: $0.id, size: $0.size, content: $0.content) },
                       blank: { _ in atom.isBlank(env) },
                       view: { v in AnyView(CustomAtomView(atom: atom, env: env, life: life, vertical: v, maxWidth: m.maxWidth)) },
                       priority: m.priority)
    }
}

/// `riskell --ext-selftest` (with RISKELL_CONFIG pointing at a scratch config, never the real one): a change made in the EXTENSIONS card is
/// written, read back, and shows in the rebuilt atoms; the grid snapping stays inside the range. PASS / FAIL per case, exit 1 on a FAIL.
enum ExtSelfTest {
    static func run() -> Never {
        var bad = 0
        let tty = terminal()
        print(tty.header("self-test extensions", detail: "the preferences card's writes and the live rebuild"))
        print("")
        // The word stays first, as in the installer's self-test: these lines are read by eye and by a `^PASS` grep.
        func check(_ name: String, _ ok: Bool) {
            print(tty.tone(ok ? "PASS" : "FAIL", ok ? .ok : .crit) + " " + tty.tone(name, .text1))
            if !ok { bad += 1 }
        }
        guard let s = installedSettings.first(where: { if case .number = $0.kind { return true } else { return false } }), case let .number(lo, hi, step, def) = s.kind else {
            let lines = tty.errorBlock(title: "no extension with a number setting is installed", detail: nil,
                                       tries: [("risk ext add Examples/load-ext", "install the working example")])
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
            exit(2)
        }
        let before = Registry.byID.keys.filter { $0.hasPrefix("ext:") }.count
        check("snap: below the range", ExtensionsCard.snap(lo - 1000, lo, hi, step) == lo)
        check("snap: above the range", ExtensionsCard.snap(hi + 1000, lo, hi, step) == hi)
        check("snap: stays on the step grid", ExtensionsCard.snap(lo + step * 1.4, lo, hi, step) == lo + step)
        let target = ExtensionsCard.snap(def + step, lo, hi, step)
        ExtPrefs.set(s.ext, s.key, target)
        check("a number is written and read back", ExtPrefs.number(s, def: def) == target)
        check("the file is where the config is", FileManager.default.fileExists(atPath: ExtPrefs.file(s.ext).path) && ExtPrefs.file(s.ext).path.hasPrefix(AppConfig.directory.path))
        check("the extension atoms are rebuilt", Registry.byID.keys.filter { $0.hasPrefix("ext:") }.count == before && before > 0)
        ExtPrefs.set(s.ext, "other", "x")
        check("a second key keeps the first", ExtPrefs.number(s, def: def) == target && ExtPrefs.json(s.ext)["other"] as? String == "x")
        try? FileManager.default.removeItem(at: ExtPrefs.file(s.ext))
        print("")
        print(tty.check(bad == 0 ? .ok : .crit, "result", bad == 0 ? "all checks passed" : "\(bad) check(s) failed",
                        keyWidth: 7).joined(separator: "\n"))
        exit(bad == 0 ? 0 : 1)
    }
}
