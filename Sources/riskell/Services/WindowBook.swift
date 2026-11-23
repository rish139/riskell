import AppKit
import CoreGraphics

/// Where each window was last seen on screen. AeroSpace reports no frames and parks the windows of a hidden workspace at the screen's
/// bottom-right corner (keeping their size), so the overview needs the place a window had while it was showing.
/// Main thread only: nothing here is locked.
final class WindowBook {
    static let shared = WindowBook()

    struct Entry { let id: Int; let workspace: Int; let floating: Bool; let rank: Int }

    private struct Seen { var rect: CGRect; var workspace: Int? }   // workspace is nil until `frames` learns which one it was
    private var seen: [Int: Seen] = [:]

    /// Stores the frame of each of `ids` that is mostly on screen now, with its size: one window-server call.
    func remember(ids: Set<Int>) {
        let screen = Self.screenSize
        for (id, r) in Self.read(.optionOnScreenOnly) where ids.contains(id) && Self.mostlyOnScreen(r, screen) {
            if seen[id]?.rect != r { seen[id] = Seen(rect: r, workspace: seen[id]?.workspace) }
        }
    }
    /// The ids in `ids` the window server no longer lists. A window can close without AeroSpace reporting anything (Cmd-W, an app
    /// closing its own window), so this is the only word on whether the rows still name live windows. One call for all the ids, and none
    /// when there is nothing to ask. Called from the AeroSpace queue too: it reads no state of its own.
    static func gone(_ ids: Set<Int>) -> Set<Int> {
        guard !ids.isEmpty else { return [] }
        // no answer at all: ask the window manager rather than keep showing a window that may be gone
        guard let list = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return ids }
        var live = Set<Int>()
        for w in list {
            if let id = w[kCGWindowNumber as String] as? Int { live.insert(id) }
        }
        return ids.subtracting(live)
    }

    /// True when the window server no longer lists one of `ids`.
    static func anyGone(_ ids: Set<Int>) -> Bool { !gone(ids).isEmpty }

    /// A frame for each entry whose window still exists (top-left origin, screen points): the live one while it is on screen, else
    /// the remembered one while the window is on the same workspace at the same size, else a computed place (`placed == false`).
    func frames(for entries: [Entry]) -> [Int: WinFrame] {
        let screen = Self.screenSize
        let now = Self.read(.optionAll)
        var out: [Int: WinFrame] = [:]
        var unplaced: [Int: [Entry]] = [:]                    // tiled windows with no known place, by workspace
        for e in entries {
            guard let cur = now[e.id] else { unplaced[e.workspace, default: []].append(e); continue }      // not listed by the window server: still shown, in its share of the area
            if Self.mostlyOnScreen(cur, screen) {
                seen[e.id] = Seen(rect: cur, workspace: e.workspace)
                out[e.id] = WinFrame(rect: cur, placed: true, floating: e.floating, rank: e.rank)
            } else if let s = seen[e.id], abs(s.rect.width - cur.width) <= 2, abs(s.rect.height - cur.height) <= 2,
                      s.workspace == nil || s.workspace == e.workspace || e.floating {
                seen[e.id]?.workspace = e.workspace
                out[e.id] = WinFrame(rect: s.rect, placed: true, floating: e.floating, rank: e.rank)
            } else if e.floating {
                let a = OverviewLayout.workArea(screen)
                let size = CGSize(width: min(cur.width, a.width), height: min(cur.height, a.height))
                let r = CGRect(x: a.midX - size.width / 2, y: a.midY - size.height / 2, width: size.width, height: size.height)
                out[e.id] = WinFrame(rect: r, placed: false, floating: true, rank: e.rank)
            } else {
                unplaced[e.workspace, default: []].append(e)
            }
        }
        // a hidden workspace nobody has looked at yet: the windows share the work area equally, with the tiling gap between them. The place is
        // worked out here, so it is returned as known: the overview would otherwise place them again by their sizes and could overlap them
        let gap: CGFloat = 7
        for (_, group) in unplaced {
            let a = OverviewLayout.workArea(screen), list = group.sorted { $0.rank < $1.rank }, n = CGFloat(list.count)
            let wide = a.width >= a.height
            let each = ((wide ? a.width : a.height) - gap * (n - 1)) / n
            for (i, e) in list.enumerated() {
                let off = CGFloat(i) * (each + gap)
                let r = wide ? CGRect(x: a.minX + off, y: a.minY, width: each, height: a.height)
                             : CGRect(x: a.minX, y: a.minY + off, width: a.width, height: each)
                out[e.id] = WinFrame(rect: r, placed: true, floating: false, rank: e.rank)
            }
        }
        seen = seen.filter { now[$0.key] != nil }
        return out
    }

    private static var screenSize: CGSize { NSScreen.screens.first?.frame.size ?? .zero }

    private static func mostlyOnScreen(_ r: CGRect, _ screen: CGSize) -> Bool {
        let i = CGRect(origin: .zero, size: screen).intersection(r)
        return !i.isNull && i.width * i.height >= 0.5 * r.width * r.height
    }

    /// Normal-layer windows by id with their bounds (top-left origin points).
    private static func read(_ opts: CGWindowListOption) -> [Int: CGRect] {
        guard let list = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [:] }
        var out: [Int: CGRect] = [:]
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0, let id = w[kCGWindowNumber as String] as? Int,
                  let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            out[id] = r
        }
        return out
    }
}
