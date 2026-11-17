import SwiftUI
import RiskellKit

/// The one list of atoms. An atom is registered here with its id, its name in the editor, how to draw it (`vertical` is true on a strip) and,
/// when it has one, the popout card it opens (id, size per stage, content). Everything that needs to know what atoms exist (the bars, edit mode,
/// the popout host, the saved layout's validation) reads this list, so a new atom is its own file plus one line below.
///
/// Views are type-erased once, here, at the boundary; inside an atom nothing is erased, so SwiftUI diffs the atom as before.
struct CardDef {
    let id: String
    let size: (_ stage: Int) -> CGSize
    let content: () -> AnyView
}

struct AtomDef {
    let id: String
    let name: String
    let card: CardDef?
    /// True while the atom has nothing to draw (no workspaces, no focused window); an island whose atoms are all blank is not drawn.
    let blank: ((Store) -> Bool)?
    let view: (_ vertical: Bool) -> AnyView
    /// When a wing is too narrow at its smallest scale, the lowest priority is hidden first (WingFit.swift). 5 by default.
    var priority: Int = 5
}

private func card<C: View>(_ id: String, size: @escaping (_ stage: Int) -> CGSize, _ content: @escaping () -> C) -> CardDef {
    CardDef(id: id, size: size, content: { AnyView(content()) })
}
private func atom<A: View>(_ id: String, _ name: String, priority: Int = 5, card: CardDef? = nil, blank: ((Store) -> Bool)? = nil, _ view: @escaping (_ vertical: Bool) -> A) -> AtomDef {
    AtomDef(id: id, name: name, card: card, blank: blank, view: { AnyView(view($0)) }, priority: priority)
}

enum Registry {
    /// In this order they are offered in the editor's tray, then the script pills, then the atoms of installed packages.
    private static let builtins: [AtomDef] = [
        atom("workspaces", "Workspaces", priority: 8, card: card("workspaces", size: { _ in let l = WsLayout.current(); return CGSize(width: l.width, height: l.height) }) { WorkspacesCard() }, blank: { $0.spaces.isEmpty }) { WorkspacesAtom(vertical: $0) },
        atom("appicon", "App icon", priority: 6, blank: { s in !s.windows.contains(where: { $0.focused }) }) { AppIconAtom(vertical: $0) },
        atom("usage", "AI usage", priority: 5, card: card("usage", size: { _ in UsageCard.size }) { UsageCard() }, blank: { _ in !AppConfig.shared.claudeEnabled && AppConfig.shared.opencodeWorkspace == nil }) { UsageAtom(vertical: $0) },
        atom("fan", "Fan", priority: 3, card: card("fan", size: { _ in FanCard.size }) { FanCard() }) { FanAtom(vertical: $0) },
        atom("bat", "Battery", priority: 9, card: card("bat", size: { _ in BatteryCard.size }) { BatteryCard() }) { BatAtom(vertical: $0) },
        atom("clock", "Clock", priority: 9, card: card("date", size: { DateCard.size(stage: $0) }) { DateCard() }) { ClockAtom(vertical: $0) },
        atom("vol", "Volume", priority: 4, card: card("vol", size: { _ in VolumeCard.size }) { VolumeCard() }) { VolAtom(vertical: $0) },
        atom("net", "Network", priority: 4, card: card("net", size: { _ in NetworkCard.size }) { NetworkCard() }) { NetAtom(vertical: $0) },
        atom("cpu", "CPU", priority: 5, card: card("vitals", size: { _ in VitalsCard.size }) { VitalsCard() }) { CpuAtom(vertical: $0) },
        atom("weather", "Weather", priority: 2, card: card("weather", size: { _ in WeatherCard.size }) { WeatherCard() }) { WeatherAtom(vertical: $0) },
    ]

    /// The built-in atoms' ids, for `riskell --list-atoms` and the listings check.
    static var builtinIDs: [String] { builtins.map(\.id) }

    /// Script pills from config.json: ids "pill:<id>". The view is keyed by its runner, so a changed pill is a fresh view that attaches itself.
    private static func pillAtoms() -> [AtomDef] {
        Pills.all.map { r in
            atom("pill:" + r.spec.id, r.spec.name ?? r.spec.id,
                 card: card(r.cardID, size: { _ in PillCard.size(r.model.reading, stale: r.model.stale) }) { PillCard(source: r) }) { PillAtom(source: r, vertical: $0).id(ObjectIdentifier(r)) }
        }
    }

    private(set) static var atoms: [AtomDef] = builtins + pillAtoms() + PackageAtoms.all
    private(set) static var byID: [String: AtomDef] = Dictionary(uniqueKeysWithValues: atoms.map { ($0.id, $0) })
    private(set) static var cards: [String: CardDef] = Dictionary(uniqueKeysWithValues: atoms.compactMap { a in a.card.map { ($0.id, $0) } })

    /// An atom is a view of its own, so none of this is read except when a body is drawn; call after the pills changed.
    static func rebuild() {
        atoms = builtins + pillAtoms() + PackageAtoms.all
        byID = Dictionary(uniqueKeysWithValues: atoms.map { ($0.id, $0) })
        cards = Dictionary(uniqueKeysWithValues: atoms.compactMap { a in a.card.map { ($0.id, $0) } })
    }

    /// The atoms of an island that have something to draw (all of them while editing): a blank atom leaves no separator behind.
    static func shown(_ atoms: [String], _ store: Store, editing: Bool) -> [String] {
        editing ? atoms : atoms.filter { byID[$0]?.blank?(store) != true }
    }

    /// An island none of whose atoms has anything to draw right now (the bars skip it unless the layout is being edited).
    static func blank(_ island: Island, _ store: Store) -> Bool { island.atoms.allSatisfy { byID[$0]?.blank?(store) == true } }
}
