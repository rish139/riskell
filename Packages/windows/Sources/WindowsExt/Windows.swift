// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import AppKit
import SwiftUI
import RiskellKit

/// What the system knows about a window's app, read in-process (no `ps`): its icon and when its process started.
enum Apps {
    struct Info { let icon: NSImage?; let launched: Date?; let name: String }
    private static var cache: [Int: Info] = [:]
    static func info(pid: Int, fallback: String) -> Info {
        if let c = cache[pid] { return c }
        let app = NSRunningApplication(processIdentifier: pid_t(pid))
        let i = Info(icon: app?.icon, launched: app?.launchDate, name: app?.localizedName ?? fallback)
        cache[pid] = i
        return i
    }
    /// "now", "42m", "3h 12m", "2d 4h": the unit that matters, never seconds
    static func age(_ since: Date?, now: Date = Date()) -> String {
        guard let since else { return "" }
        let m = Int(now.timeIntervalSince(since) / 60)
        if m < 1 { return "now" }
        if m < 60 { return "\(m)m" }
        let h = m / 60
        if h < 24 { return "\(h)h \(String(format: "%02d", m % 60))m" }
        return "\(h / 24)d \(h % 24)h"
    }
}

/// What the card is doing right now, shared with the rail on the bar (the beads float to the card's rows and light up under a drag).
final class WsState: ObservableObject {
    static let shared = WsState()
    @Published var hoverWin: Int? = nil
    @Published var dragId: Int? = nil
    @Published var dragPos = CGPoint.zero          // in the card's own coordinate space
    @Published var dropSpace: Int? = nil           // the space a released tile would land in; spaces.count + 1 = a new one
    var dragging: Bool { dragId != nil }
}

/// Geometry of the workspaces card, pure arithmetic from the model so the rail on the bar can float its beads onto the card's rows
/// and the host can size the panel before anything is drawn.
struct WsTile: Identifiable { let id: Int; let win: WindowInfo?; let more: Int }
struct WsGroup { let space: WorkspaceInfo; let tiles: [WsTile]; let rows: Int; let top: CGFloat; let height: CGFloat }

struct WsLayout {
    static let pad: CGFloat = 14, tile: CGFloat = 52, cell: CGFloat = 68, gap: CGFloat = 7, label: CGFloat = 22
    static let gapY: CGFloat = 16, masthead: CGFloat = 30, footer: CGFloat = 40

    let groups: [WsGroup]
    let perRow: Int
    let width: CGFloat, height: CGFloat
    let slotTop: CGFloat?                  // the new-space slot, only while a tile is carried

    var rowCenters: [CGFloat] { groups.map { $0.top + Self.tile / 2 } }
    var gapCenters: [CGFloat] { groups.dropLast().map { $0.top + $0.height + Self.gapY / 2 } }

    init(spaces: [WorkspaceInfo], windows: [WindowInfo], dragging: Bool, screenH: CGFloat) {
        var counts: [Int: Int] = [:]
        for w in windows { counts[w.space, default: 0] += 1 }
        let perRow = max(3, min(5, counts.values.max() ?? 0))
        self.perRow = perRow
        var rows: [Int] = spaces.map { max(1, min(3, Int((Double(counts[$0.id] ?? 0) / Double(perRow)).rounded(.up)))) }
        // a short screen: shrink the biggest spaces until the rows fit
        let budget = max(spaces.count, Int((screenH * 0.8 - 90) / (Self.cell + Self.gap)))
        var used = rows.reduce(0, +)
        while used > budget, let big = rows.indices.filter({ rows[$0] > 1 }).max(by: { rows[$0] < rows[$1] }) { rows[big] -= 1; used -= 1 }
        var y = Self.pad + Self.masthead
        var gs: [WsGroup] = []
        for (i, sp) in spaces.enumerated() {
            let list = windows.filter { $0.space == sp.id }.sorted {
                // youngest process first, so what you just opened leads; unknown ages last; the id keeps the order stable
                let a = Apps.info(pid: $0.pid, fallback: $0.app).launched ?? .distantPast, b = Apps.info(pid: $1.pid, fallback: $1.app).launched ?? .distantPast
                return a != b ? a > b : $0.id < $1.id
            }
            let cap = rows[i] * perRow, over = list.count > cap, shown = over ? cap - 1 : list.count
            var tiles = list.prefix(shown).map { WsTile(id: $0.id, win: $0, more: 0) }
            if over { tiles.append(WsTile(id: -1, win: nil, more: list.count - shown)) }
            let h = CGFloat(rows[i]) * Self.cell + CGFloat(rows[i] - 1) * Self.gap
            gs.append(WsGroup(space: sp, tiles: tiles, rows: rows[i], top: y, height: h))
            y += h + Self.gapY
        }
        y -= Self.gapY
        if dragging { slotTop = y + Self.gapY; y += Self.gapY + Self.cell } else { slotTop = nil }
        groups = gs
        width = 2 * Self.pad + Self.label + Self.gap + CGFloat(perRow) * Self.tile + CGFloat(perRow - 1) * Self.gap
        height = y + 6 + Self.footer
    }

    static func current() -> WsLayout {
        WsLayout(spaces: WindowsModel.shared.spaces, windows: WindowsModel.shared.windows, dragging: WsState.shared.dragging, screenH: KitHost.screenHeight())
    }
}
