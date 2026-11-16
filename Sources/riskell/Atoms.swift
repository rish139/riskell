import SwiftUI
import RiskellKit

/// Atoms are drawn by id, from the list in Registry.swift. `vertical` is true on a strip. "compat" is the version pill, drawn only while
/// something needs attention; it is not an editable atom, so it is not in the registry.
struct AtomView: View {
    let id: String
    let vertical: Bool
    var body: some View {
        if let def = Registry.byID[id] { def.view(vertical) }
        else if id == "compat" { CompatAtom() }
    }
}

struct StubAtom: View {
    let text: String
    var vertical = false
    var body: some View {
        Text(text).foregroundStyle(Pal.text3)
            .rotationEffect(.degrees(vertical ? -90 : 0)).fixedSize()
            .frame(width: vertical ? 14 : nil, height: vertical ? 40 : nil)
    }
}



