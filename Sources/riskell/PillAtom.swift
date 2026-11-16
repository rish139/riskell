import SwiftUI
import RiskellKit

/// An atom drawn from a reading (a script pill, or an extension's `ReadingAtom`): an optional SF Symbol, the text, an optional gauge.
/// Horizontal: one 36 pt row. Vertical: a column at most 40 pt wide (symbol above, text, gauge under). A failed run dims it. Hover opens
/// a card of the extra lines, if there are any; a click runs the source's click command. The drawing itself is the kit's `ReadingBody`.
struct PillAtom: View {
    let source: any ReadingSource
    let vertical: Bool
    @ObservedObject private var model: PillModel
    @State private var hot = false

    init(source: any ReadingSource, vertical: Bool) { self.source = source; self.vertical = vertical; model = source.model }

    var body: some View {
        let r = model.reading
        // a sparkline: the source's own series, else its remembered values when it keeps a history
        let spark = (r?.spark.isEmpty == false ? r?.spark : nil) ?? (source.keepsHistory ? model.history : [])
        let core = ReadingBody(reading: r, stale: model.stale, spark: spark, vertical: vertical, hot: hot)
            .onTapGesture { source.click() }
            .modifier(ActiveWhenShown(attach: { source.attach() }, detach: { source.detach() }))
        // the card opens for lines, grid rows, or a stale reading (its "last updated" line)
        if let r, !(r.lines.isEmpty && r.grid.isEmpty) || model.stale { core.popout(source.cardID, edge: .right, hot: $hot) }
        else { core.onHover { hot = $0 } }
    }
}

/// The hover card: the source's name, then the extra lines it printed. The content is the kit's `ReadingCardContent`.
struct PillCard: View {
    let source: any ReadingSource
    @ObservedObject private var model: PillModel
    @ObservedObject private var pop = Popout.shared
    static let width: CGFloat = ReadingCardContent.width
    static func size(_ reading: PillReading?, stale: Bool) -> CGSize { ReadingCardContent.size(reading, stale: stale) }

    init(source: any ReadingSource) { self.source = source; model = source.model }

    var body: some View {
        ReadingCardContent(title: source.title, reading: model.reading, stale: model.stale, updated: model.updated)
            .opacity(pop.open ? 1 : 0).offset(y: pop.open ? 0 : 6)
            .animation(.easeOut(duration: 0.22).delay(0.04), value: pop.open)
    }
}
