import SwiftUI
import RiskellKit

/// The workspaces inspector: every space as a row (its number on the left), its windows as icon tiles on the right, each with how long
/// that app's process has been running. A tile is the app and nothing more; the full "App - title" of the tile under the pointer is
/// printed on the footer line, so nothing floats over the card. The rail's beads on the bar float down onto the rows (WorkspacesAtom).
/// Click a tile to focus its window, right-click to close it, drag it onto another space's row to move it (or below the last row for a
/// new space), click a space's number to go there.
struct WorkspacesCard: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var ws = WsState.shared
    @ObservedObject private var pop = Popout.shared

    var body: some View {
        let L = WsLayout.current()
        let focusedSpace = s.spaces.first { $0.focused }?.id
        let now = Clock.shared.minute
        ZStack(alignment: .topLeading) {
            // drop highlight (underlay)
            if let d = ws.dropSpace, ws.dragging {
                let r = d <= L.groups.count ? L.groups[d - 1].top - 5 : (L.slotTop ?? 0) - 5
                let h = d <= L.groups.count ? L.groups[d - 1].height + 10 : WsLayout.cell + 10
                RoundedRectangle(cornerRadius: 10).fill(Pal.selected).overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.selectedLine, lineWidth: 1))
                    .frame(width: L.width - 2 * (WsLayout.pad - 6), height: h).offset(x: WsLayout.pad - 6, y: r)
            }
            // masthead
            HStack(spacing: 8) {
                label("WORKSPACES", 10, Pal.amberDim, 2.2)
                Rectangle().fill(Pal.amberGhost).frame(height: 1)
                label("\(s.windows.count) WINDOWS", 9, Pal.text4, 1.4)
            }.frame(width: L.width - 2 * WsLayout.pad, height: 14).offset(x: WsLayout.pad, y: WsLayout.pad)

            ForEach(L.groups, id: \.space.id) { g in
                HStack(alignment: .top, spacing: WsLayout.gap) {
                    Text(String(g.space.id)).font(Pal.font(13, .bold))
                        .foregroundStyle(g.space.id == focusedSpace ? Pal.accent : Pal.text3)
                        .frame(width: WsLayout.label, height: WsLayout.tile)
                        .contentShape(Rectangle())
                        .onTapGesture { WM.shared?.focus(space: g.space.id); Popout.shared.close() }
                    if g.tiles.isEmpty {
                        VStack(spacing: 3) {
                            RoundedRectangle(cornerRadius: 9).stroke(Pal.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                                .frame(width: WsLayout.tile, height: WsLayout.tile)
                            label("EMPTY", 8, Pal.text4.opacity(0.7), 1.2)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: WsLayout.gap) {
                            ForEach(0..<g.rows, id: \.self) { r in
                                HStack(spacing: WsLayout.gap) {
                                    ForEach(g.tiles.dropFirst(r * L.perRow).prefix(L.perRow)) { t in tile(t, now: now, L: L) }
                                }
                            }
                        }
                    }
                }.offset(x: WsLayout.pad, y: g.top)
            }
            if let top = L.slotTop {
                HStack(alignment: .top, spacing: WsLayout.gap) {
                    Text("+").font(Pal.font(15, .bold)).foregroundStyle(Pal.text4).frame(width: WsLayout.label, height: WsLayout.tile)
                    VStack(spacing: 3) {
                        RoundedRectangle(cornerRadius: 9).stroke(Pal.text4.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .frame(width: WsLayout.tile, height: WsLayout.tile)
                        label("NEW SPACE", 8, Pal.text4, 1.2)
                    }
                }.offset(x: WsLayout.pad, y: top)
            }
            // footer
            VStack(alignment: .leading, spacing: 0) {
                Rectangle().fill(Pal.amberGhost).frame(height: 1)
                Text(caption(L)).font(Pal.font(12)).foregroundStyle(Pal.text1).lineLimit(1).truncationMode(.tail)
                    .frame(width: L.width - 2 * WsLayout.pad, height: WsLayout.footer - 1, alignment: .leading)
            }.frame(width: L.width - 2 * WsLayout.pad).offset(x: WsLayout.pad, y: L.height - WsLayout.footer)

            // the carried tile
            if let id = ws.dragId, let w = s.windows.first(where: { $0.id == id }) {
                face(w, focused: false).opacity(0.95).scaleEffect(1.08).shadow(color: .black.opacity(0.4), radius: 6, y: 2)
                    .position(ws.dragPos).allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "wscard")
        .frame(width: L.width, height: L.height, alignment: .topLeading)
        .onDisappear { ws.hoverWin = nil; ws.dragId = nil; ws.dropSpace = nil; Popout.shared.holdOpen = false }
    }

    private func label(_ t: String, _ size: CGFloat, _ color: Color, _ tracking: CGFloat) -> some View {
        Text(t).font(Pal.font(size, .bold)).tracking(tracking).foregroundStyle(color).fixedSize()
    }

    private func caption(_ L: WsLayout) -> String {
        if let id = ws.dragId, let w = s.windows.first(where: { $0.id == id }) {
            let name = Apps.info(pid: w.pid, fallback: w.app).name
            guard let d = ws.dropSpace else { return title(w) }
            return d > L.groups.count ? "Move \(name) to a new space" : "Move \(name) to space \(d)"
        }
        if let id = ws.hoverWin, id == -1 { return "more windows in this space" }
        if let id = ws.hoverWin, let w = s.windows.first(where: { $0.id == id }) { return title(w) }
        return s.windows.first(where: { $0.focused }).map(title) ?? ""
    }
    private func title(_ w: WinInfo) -> String {
        let name = Apps.info(pid: w.pid, fallback: w.app).name, t = w.title.trimmingCharacters(in: .whitespaces)
        return t.isEmpty || t.lowercased() == name.lowercased() ? name : "\(name) — \(t)"
    }

    private func face(_ w: WinInfo, focused: Bool, hover: Bool = false) -> some View {
        let info = Apps.info(pid: w.pid, fallback: w.app)
        let shape = RoundedRectangle(cornerRadius: 10)
        return ZStack {
            shape.fill(focused ? Pal.selected : hover ? Pal.hoverFill : Pal.pressFill)
            shape.stroke(focused ? Pal.selectedLine : Pal.hairline, lineWidth: 1)
            if let icon = info.icon { Image(nsImage: icon).resizable().interpolation(.high).frame(width: 29, height: 29) }
            else { Text(String(info.name.prefix(1)).uppercased()).font(Pal.font(17, .bold)).foregroundStyle(Pal.text3) }
        }.frame(width: WsLayout.tile, height: WsLayout.tile)
    }

    @ViewBuilder private func tile(_ t: WsTile, now: Date, L: WsLayout) -> some View {
        if let w = t.win {
            let info = Apps.info(pid: w.pid, fallback: w.app)
            let hov = ws.hoverWin == w.id, carried = ws.dragId == w.id
            VStack(spacing: 3) {
                face(w, focused: w.focused, hover: hov)
                Text(Apps.age(info.launched, now: now)).font(Pal.font(9)).foregroundStyle(Pal.text4).frame(height: 12)
            }
            .opacity(carried ? 0.3 : 1)
            .contentShape(Rectangle())
            .onHover { h in if h { ws.hoverWin = w.id } else if ws.hoverWin == w.id { ws.hoverWin = nil } }
            .onTapGesture { WM.shared?.focus(window: w.id); Popout.shared.close() }
            .overlay(RightClick { WM.shared?.close(window: w.id) })
            .gesture(DragGesture(minimumDistance: 6, coordinateSpace: .named("wscard"))
                .onChanged { v in
                    if ws.dragId == nil { ws.dragId = w.id; Popout.shared.holdOpen = true; Popout.shared.refit() }
                    ws.dragPos = v.location
                    let l = WsLayout.current()
                    ws.dropSpace = dropTarget(v.location.y, l)
                }
                .onEnded { _ in
                    let target = ws.dropSpace, spaces = s.spaces.count
                    ws.dragId = nil; ws.dropSpace = nil
                    if let target, target != w.space {
                        if target > spaces { WM.shared?.moveToNewSpace(window: w.id, after: spaces) } else { WM.shared?.move(window: w.id, toSpace: target) }
                    }
                    Popout.shared.holdOpen = false; Popout.shared.refit()
                })
        } else {
            VStack(spacing: 3) {
                RoundedRectangle(cornerRadius: 10).fill(Pal.pressFill).overlay(RoundedRectangle(cornerRadius: 10).stroke(Pal.hairline, lineWidth: 1))
                    .overlay(Text("+\(t.more)").font(Pal.font(13, .bold)).foregroundStyle(Pal.text3))
                    .frame(width: WsLayout.tile, height: WsLayout.tile)
                Color.clear.frame(height: 12)
            }
            .onHover { h in ws.hoverWin = h ? -1 : (ws.hoverWin == -1 ? nil : ws.hoverWin) }
        }
    }

    /// Which space's row (or the new-space slot) a point at card-y `y` is over: the row, plus half the gap above and below it.
    private func dropTarget(_ y: CGFloat, _ L: WsLayout) -> Int? {
        for g in L.groups where y >= g.top - WsLayout.gapY / 2 && y <= g.top + g.height + WsLayout.gapY / 2 { return g.space.id }
        if let top = L.slotTop, y >= top - WsLayout.gapY / 2, y <= top + WsLayout.cell + WsLayout.gapY / 2 { return L.groups.count + 1 }
        return nil
    }
}
