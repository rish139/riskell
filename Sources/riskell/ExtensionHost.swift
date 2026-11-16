import SwiftUI
import Combine
import RiskellKit

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

/// The kit's `.popout` modifier talks to the one popout host through this.
final class PopoutBridge: PopoutHooks {
    static let shared = PopoutBridge()
    var openCard: String? { Popout.shared.card }
    var editing: Bool { Config.shared.editing }
    func hover(_ id: String, anchor: CGRect, edge: PopEdge, island: CGRect?) { Popout.shared.hover(id, anchor: anchor, edge: edge, island: island) }
    func reanchor(_ id: String, _ anchor: CGRect, island: CGRect?) { Popout.shared.reanchor(id, anchor, island: island) }
    func leave(_ id: String) { Popout.shared.leave(id) }
    func toggleStage(_ id: String) { Popout.shared.toggleStage(id) }
    func holdOpen() { Popout.shared.holdOpen = true }
}

/// Feeds: the values the app already computes (the Store's), handed to extensions by subscription. A subscription is a Combine sink on the
/// Store (nothing polls for it); `minute` is a timer that exists only while someone is subscribed.
final class FeedBridge: FeedHub {
    static let shared = FeedBridge()

    private final class Sub { var bag: [AnyCancellable] = []; var timer: DispatchSourceTimer? }

    func subscribe(_ key: String, _ yield: @escaping @Sendable (Any) -> Void) -> () -> Void {
        let sub = Sub()
        DispatchQueue.main.async {
            let s = store
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
        return { DispatchQueue.main.async { sub.bag = []; sub.timer?.cancel(); sub.timer = nil } }
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
        Group {
            if vertical { atom.vertical(env).frame(maxWidth: 40).clipped() }
            else { atom.horizontal(env).fixedSize(horizontal: true, vertical: false).frame(maxWidth: maxWidth, maxHeight: G.pill, alignment: .leading).clipped() }
        }
        .modifier(ActiveWhenShown(attach: { life.attach() }, detach: { life.detach() }))
    }
}

/// The atoms of the packages in `installedPackages` (Generated/InstalledPackages.swift), as `AtomDef`s with the id `ext:<id>`.
enum PackageAtoms {
    static let all: [AtomDef] = build()

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

    private static func prefs(_ id: String) -> Prefs {
        let url = AppConfig.directory.appendingPathComponent("ext").appendingPathComponent(id + ".json")
        let j = (try? Data(contentsOf: url)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        return Prefs(json: j)
    }

    private static func reading(_ t: any ReadingAtom.Type) -> AtomDef {
        let m = t.meta
        let run = ExtensionReading(t, env: Env(id: m.id, prefs: prefs(m.id)))
        return AtomDef(id: "ext:" + m.id, name: m.name,
                       card: CardDef(id: run.cardID, size: { _ in PillCard.size(run.model.reading, stale: run.model.stale) }, content: { AnyView(PillCard(source: run)) }),
                       blank: nil,
                       view: { v in
                           // a horizontal form keeps its natural width and is clipped at `maxWidth` (text never wraps into two lines)
                           AnyView(Group { if v { PillAtom(source: run, vertical: true) } else { PillAtom(source: run, vertical: false).fixedSize(horizontal: true, vertical: false).frame(maxWidth: m.maxWidth, alignment: .leading).clipped() } }.id(ObjectIdentifier(run))) },
                       priority: m.priority)
    }

    private static func custom<A: CustomAtom>(_ t: A.Type) -> AtomDef {
        let m = t.meta, atom = A(), env = Env(id: m.id, prefs: prefs(m.id))
        let life = AtomLifecycle { atom.activate(env) }
        return AtomDef(id: "ext:" + m.id, name: m.name,
                       card: atom.card.map { CardDef(id: $0.id, size: $0.size, content: $0.content) },
                       blank: { _ in atom.isBlank() },
                       view: { v in AnyView(CustomAtomView(atom: atom, env: env, life: life, vertical: v, maxWidth: m.maxWidth)) },
                       priority: m.priority)
    }
}
