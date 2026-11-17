// SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
// Copyright 2026 Rishabh Tiwari

import SwiftUI
import RiskellKit

/// The focused window's app icon, under the workspace rail (`vertical`). On a horizontal bar it is one 36 pt row: the 24 pt icon, then the
/// focused app's full name (never the window title, never truncated or capped). It draws nothing when no window is focused.
struct AppIconFace: View {
    @ObservedObject private var s = WindowsModel.shared
    @ObservedObject private var pop = PopState.shared
    let vertical: Bool
    private static var cache: [Int: NSImage] = [:]
    private static func icon(_ pid: Int) -> NSImage? {
        if let i = cache[pid] { return i }
        guard let i = NSRunningApplication(processIdentifier: pid_t(pid))?.icon else { return nil }
        cache[pid] = i
        return i
    }

    var body: some View {
        if let w = s.windows.first(where: { $0.focused }), let img = Self.icon(w.pid) {
            if vertical {
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    .frame(width: 24, height: 24)
                    .frame(width: G.strip)
                    .opacity(pop.open && pop.card == "workspaces" && !pop.chat ? 0 : 1)      // the rail unfolds into its card: the icon steps aside (a chat card keeps the pill)
                    .animation(.easeOut(duration: 0.15), value: pop.open && pop.card == "workspaces" && !pop.chat)
                    .help(w.app)
            } else {
                HStack(spacing: T.gap) {
                    Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .frame(width: 24, height: 24)
                    Text(w.app).font(T.value).foregroundStyle(Pal.text1).fixedSize()      // the full name: no truncation, no width cap
                }
                .frame(height: G.pill)
            }
        }
    }
}
