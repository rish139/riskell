import AppKit
import SwiftUI
import RiskellKit

/// Every size in this file is in the screen's real points, and every literal is a design number: multiplied by the one scale factor, so the
/// overview keeps its proportions to the screen at any resolution (Scale.swift). At scale 1 it is the same number.
private var u: CGFloat { Real.k }

/// The overview, drawn at the screen's own size: a blurred, darkened desktop, one tile per workspace in a row (each a true miniature of
/// the screen: wallpaper, its windows where they sit, riskell's bars), the slot for a new workspace, the numbers and the find field.
struct OverviewView: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var o = Overview.shared

    var body: some View {
        let L = OverviewLayout(count: s.spaces.count, screen: o.screen)
        let p = o.progress
        let full = CGRect(origin: .zero, size: o.screen)
        let fade = Double(min(1, max(0, (p - 0.15) / 0.6)))
        ZStack(alignment: .topLeading) {
            OverviewBackdrop()
                .opacity(Double(p))
            ForEach(Array(s.spaces.enumerated()), id: \.element.id) { i, sp in
                let slot = i < L.tiles.count ? L.tiles[i] : .zero
                let isOrigin = sp.id == o.origin
                let rect = isOrigin ? lerp(full, slot, p) : slot
                OverviewTile(space: sp.id, rect: rect, progress: p, isOrigin: isOrigin, selected: o.selected == sp.id)
                    // the morphing tile dissolves over its last third: what it grows into is a capture (small, so soft), and the real
                    // window is already there underneath, so it fades into the sharp one instead of popping to it
                    .opacity(isOrigin ? Double(min(1, p / 0.35)) : fade)
                    .offset(y: isOrigin ? 0 : (1 - p) * 40 * u)
                    .zIndex(isOrigin ? 2 : 1)
                Text("\(sp.id)")
                    .font(Pal.font(15 * u, .semibold))
                    .foregroundStyle(sp.focused ? Pal.accent : Pal.text4)
                    .frame(width: slot.width)
                    .offset(x: slot.minX, y: slot.maxY + 12 * u)
                    .opacity(fade)
            }
            NewSlot().frame(width: L.slot.width, height: L.slot.height)
                .offset(x: L.slot.minX, y: L.slot.minY)
                .opacity(fade)
            FindField(query: o.query)
                .offset(x: Config.shared.leftW + (o.screen.width - Config.shared.leftW - Config.shared.rightW) / 2 - FindField.width / 2, y: (L.tiles.first?.maxY ?? 0) + 64 * u)
                .opacity(fade)
                .zIndex(10)
            ForEach(o.fullscreenTiles(), id: \.app.id) { t in
                FullscreenTile(app: t.app, rect: t.rect).opacity(fade)
            }
            // hover ring and title, the carried window and its target: above every tile (the morphing one included)
            PointerLayer(layout: L).zIndex(10)
            // the pointer: hover, click and drag for everything, mapped onto the tiles by Overview.hit (tiles take no events themselves)
            Color.clear.contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    if case .active(let pt) = phase { o.pointerMoved(pt) } else { o.pointerMoved(nil) }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { o.pointerDragged(start: $0.startLocation, at: $0.location) }
                    .onEnded { o.pointerUp(start: $0.startLocation, at: $0.location) })
                .zIndex(11)
        }
        .frame(width: o.screen.width, height: o.screen.height, alignment: .topLeading)
        .allowsHitTesting(p > 0.9)
    }
}

private func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
           width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
}

struct OverviewBackdrop: View {
    var body: some View {
        ZStack { BehindBlur(); Pal.canvas.opacity(0.62) }.ignoresSafeArea()
    }
}

/// Blur of what is behind the panel (the desktop), as the system draws it.
struct BehindBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .fullScreenUI; v.blendingMode = .behindWindow; v.state = .active
        v.appearance = NSAppearance(named: .darkAqua)
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) {}
}

/// One workspace: the miniature screen at the overview's one scale, clipped round, outlined when current or selected.
struct OverviewTile: View {
    @ObservedObject private var o = Overview.shared
    let space: Int
    let rect: CGRect
    let progress: CGFloat
    let isOrigin: Bool
    let selected: Bool

    var body: some View {
        let k = rect.width / o.screen.width
        // 12, not more: the windows sit 6 px (one point here) inside the screen's edges, and a larger corner would clip theirs
        // only the morphing tile changes its corner: an animated mask on a screen-sized layer is redrawn every frame, so the others keep theirs
        let corner = isOrigin ? 12 * u * min(1, progress * 1.4) : 12 * u
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        // The miniature keeps its screen-sized layout, clipped there (the corner in screen units) and then only scaled and moved: the
        // morph is a transform, not a new layout of the whole tile every frame. Outline and shadow sit on the final rectangle.
        MiniScreen(space: space)
            .frame(width: o.screen.width, height: o.screen.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: corner / max(k, 0.01), style: .continuous))
            .scaleEffect(k, anchor: .topLeading)
            .frame(width: rect.width, height: rect.height, alignment: .topLeading)
            // the outline sits just outside the screen, so it never covers the windows' one-point margin at the edges
            .overlay(TileRing(space: space, corner: corner, selected: selected).opacity(Double(progress)))
            .background { shape.fill(Color.black).shadow(color: .black.opacity(0.45 * Double(progress)), radius: 22 * u, y: 12 * u) }      // the shadow of a plain shape, not of the whole miniature
            .offset(x: rect.minX, y: rect.minY)
            .allowsHitTesting(false)
    }
}

/// A native full-screen app's window as a tile of its own: its picture (or the app icon until there is one), its name under it.
private struct FullscreenTile: View {
    @ObservedObject private var o = Overview.shared
    @ObservedObject private var pointer = Overview.shared.pointer
    let app: Overview.FullApp
    let rect: CGRect

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12 * u, style: .continuous)
        let info = Apps.info(pid: app.pid, fallback: app.name)
        let hot = pointer.hoverFull == app.pid
        ZStack {
            Pal.tile
            if let img = o.thumbs[Int(app.wid)] {
                Image(nsImage: img).resizable().interpolation(.high)
            } else if let icon = info.icon {
                Image(nsImage: icon).resizable().scaledToFit().frame(width: rect.height * 0.4, height: rect.height * 0.4)
            }
            if hot { Pal.text1.opacity(0.08) }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(hot ? Pal.text1.opacity(0.9) : Pal.line, lineWidth: hot ? 2 * u : 1))
        .background { shape.fill(Color.black).shadow(color: .black.opacity(0.45), radius: 22 * u, y: 12 * u) }
        .offset(x: rect.minX, y: rect.minY)
        HStack(spacing: 6 * u) {
            if let icon = info.icon { Image(nsImage: icon).resizable().frame(width: 14 * u, height: 14 * u) }
            Text(app.name).font(Pal.font(11.5 * u, .medium)).foregroundStyle(Pal.text1).lineLimit(1)
        }
        .padding(.leading, 6 * u).padding(.trailing, 9 * u).padding(.vertical, 4 * u)
        .background(Capsule().fill(Pal.cardSolid))
        .overlay(Capsule().strokeBorder(Pal.line, lineWidth: 1))
        .fixedSize()
        .frame(width: rect.width)
        .offset(x: rect.minX, y: rect.maxY + 9 * u)
    }
}

/// A workspace at full screen size (scaled by its tile): wallpaper, windows where they sit, riskell's bars on top.
struct MiniScreen: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var o = Overview.shared
    let space: Int

    var body: some View {
        let items = o.placed(space: space, windows: s.windows)
        ZStack(alignment: .topLeading) {
            if let wp = o.wallpaper {
                Image(nsImage: wp).resizable().frame(width: o.screen.width, height: o.screen.height)
            } else {
                LinearGradient(colors: [Pal.tile, Pal.canvas], startPoint: .topTrailing, endPoint: .bottomLeading)
            }
            if items.isEmpty {      // empty: the wallpaper under a wash, and its number (readable on light and dark pictures alike)
                Pal.canvas.opacity(0.45)
                Text("\(space)").font(Pal.font(420 * u, .semibold)).foregroundStyle(Pal.text1.opacity(0.55))
                    .frame(width: o.screen.width, height: o.screen.height)
            }
            ForEach(items, id: \.win.id) { item in
                if item.settled {
                    MiniWindow(item: item, image: o.thumbs[item.win.id], feed: o.feed(item.win.id), hit: o.matches(item.win))
                } else {
                    PendingWindow(item: item, still: o.still(item.win.id), hit: o.matches(item.win))
                }
            }
            ForEach(o.bars) { b in
                Image(nsImage: b.image).resizable()
                    .frame(width: b.rect.width, height: b.rect.height)
                    .offset(x: b.rect.minX, y: b.rect.minY)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: o.screen.width, height: o.screen.height, alignment: .topLeading)
    }
}

/// A window in a miniature: its capture (or its app icon until the capture lands). Click goes there; middle-click closes (Overview);
/// while finding, a match is ringed in the accent and the rest fade.
struct MiniWindow: View {
    @ObservedObject private var o = Overview.shared
    let item: Placed
    let image: NSImage?
    @ObservedObject var feed: LiveFeed      // live video while open; the snapshot until its first frame
    let hit: Bool?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
        ZStack {
            if let live = feed.image {
                Image(decorative: live, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: item.rect.width, height: item.rect.height, alignment: .top).clipped()
            } else if let image {
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                    .frame(width: item.rect.width, height: item.rect.height, alignment: .top).clipped()
            } else {
                Pal.tile
                if let icon = Apps.info(pid: item.win.pid, fallback: item.win.app).icon {
                    Image(nsImage: icon).resizable().frame(width: 200 * u, height: 200 * u)
                }
            }
        }
        .frame(width: item.rect.width, height: item.rect.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(hit == true ? Pal.accent : .clear, lineWidth: 14 * u))
        .opacity(hit == false ? 0.2 : 1)      // faded while finding elsewhere
        .offset(x: item.rect.minX, y: item.rect.minY)
    }
}

/// A window whose place is predicted or guessed (dropped onto a hidden workspace, or one riskell has not seen laid out yet): its live
/// picture would be the wrong shape there, so it is drawn as what it is, a window on its way. Its last picture blurred and dimmed, a soft
/// sheen, its icon and name, and a dashed edge; it becomes live video again once the workspace is shown and the WM lays it out.
struct PendingWindow: View {
    let item: Placed
    let still: NSImage?
    let hit: Bool?

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 16 * u, style: .continuous)
        let side = min(item.rect.width, item.rect.height)
        ZStack {
            Pal.canvas
            if let still {
                Image(nsImage: still).resizable().aspectRatio(contentMode: .fill)
                    .frame(width: item.rect.width, height: item.rect.height).clipped()
                    .saturation(0.55).opacity(0.5)
            }
            LinearGradient(colors: [Pal.text1.opacity(0.10), .clear, Pal.accent.opacity(0.07)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: side * 0.04) {
                if let icon = Apps.info(pid: item.win.pid, fallback: item.win.app).icon {
                    Image(nsImage: icon).resizable()
                        .frame(width: min(300 * u, side * 0.30), height: min(300 * u, side * 0.30))
                        .shadow(color: .black.opacity(0.45), radius: 30 * u, y: 14 * u)
                }
                Text(item.win.app).font(Pal.font(min(72 * u, side * 0.06), .medium)).foregroundStyle(Pal.text1.opacity(0.75)).lineLimit(1)
            }
        }
        .frame(width: item.rect.width, height: item.rect.height)
        .clipShape(shape)
        .overlay(shape.strokeBorder(hit == true ? Pal.accent : Pal.text1.opacity(0.32), style: StrokeStyle(lineWidth: (hit == true ? 14 : 6) * u, dash: [28 * u, 18 * u])))
        .opacity(hit == false ? 0.2 : 1)
        .offset(x: item.rect.minX, y: item.rect.minY)
    }
}

struct NewSlot: View {
    @ObservedObject private var pointer = Overview.shared.pointer
    var body: some View {
        let hot = pointer.drag?.toNew == true       // a carried window is over it
        let shape = RoundedRectangle(cornerRadius: 12 * u, style: .continuous)
        ZStack {
            shape.fill(hot ? Pal.selected : .clear)
            shape.strokeBorder(hot ? Pal.accent : Pal.line, style: StrokeStyle(lineWidth: (hot ? 3 : 2) * u, dash: [7 * u, 6 * u]))
            Text("+").font(Pal.font(26 * u, .medium)).foregroundStyle(hot ? Pal.accent : Pal.text4)
        }
        .scaleEffect(hot ? 1.04 : 1)
        .animation(.spring(duration: 0.22, bounce: 0.2), value: hot)
        .allowsHitTesting(false)
    }
}

/// Everything that follows the pointer, drawn over the tiles. Hover: a ring round the window and its app and title centred under its
/// workspace (one place for every window, floating or not). Drag: the window's own spot dimmed, the window following the pointer, and
/// the workspace under it lit with a dashed box where dwindle will put it.
struct PointerLayer: View {
    @EnvironmentObject var s: Store
    @ObservedObject private var pointer = Overview.shared.pointer
    private var o: Overview { Overview.shared }
    let layout: OverviewLayout

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let d = pointer.drag { carried(d) } else if o.progress > 0.95, let id = pointer.hoverWin { hovered(id) }
        }
        .frame(width: o.screen.width, height: o.screen.height, alignment: .topLeading)
        .allowsHitTesting(false)
    }

    @ViewBuilder private func hovered(_ id: Int) -> some View {
        if let w = s.windows.first(where: { $0.id == id }), let full = o.screenRect(of: id),
           let i = s.spaces.firstIndex(where: { $0.id == w.space }), i < layout.tiles.count {
            let tile = layout.tiles[i]
            let r = full.intersection(tile)      // a window wider than the screen (an app's minimum size) must not draw its ring outside its tile
            RoundedRectangle(cornerRadius: 4 * u, style: .continuous).fill(Pal.text1.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 4 * u, style: .continuous).strokeBorder(Pal.text1.opacity(0.9), lineWidth: 2 * u))
                .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY)
            let name = w.title.isEmpty ? w.app : w.title
            HStack(spacing: 6 * u) {
                if let icon = Apps.info(pid: w.pid, fallback: w.app).icon { Image(nsImage: icon).resizable().frame(width: 14 * u, height: 14 * u) }
                Text(name.count > 34 ? String(name.prefix(33)) + "…" : name)
                    .font(Pal.font(11.5 * u, .medium)).foregroundStyle(Pal.text1).lineLimit(1)
            }
            .padding(.leading, 6 * u).padding(.trailing, 9 * u).padding(.vertical, 4 * u)
            .background(Capsule().fill(Pal.cardSolid))
            .overlay(Capsule().strokeBorder(Pal.line, lineWidth: 1))
            .fixedSize()
            .frame(width: tile.width)
            .offset(x: tile.minX, y: tile.maxY + 9 * u)       // where that workspace's number is (it sits on top of it)
        }
    }

    @ViewBuilder private func carried(_ d: Overview.Drag) -> some View {
        if let src = o.screenRect(of: d.win.id) {
            RoundedRectangle(cornerRadius: 4 * u, style: .continuous).fill(Pal.canvas.opacity(0.7))
                .overlay(RoundedRectangle(cornerRadius: 4 * u, style: .continuous).strokeBorder(Pal.text4, style: StrokeStyle(lineWidth: 1.5 * u, dash: [4 * u, 3 * u])))
                .frame(width: src.width, height: src.height).offset(x: src.minX, y: src.minY)
        }
        if let t = d.target, t != d.win.space, let i = s.spaces.firstIndex(where: { $0.id == t }), i < layout.tiles.count {
            let tile = layout.tiles[i], r = o.dropRect(into: t), k = layout.scale
            // the glow is a wide soft stroke, not a blurred shadow: this redraws at the pointer's rate; both outside the tile's edge
            RoundedRectangle(cornerRadius: 22 * u, style: .continuous).strokeBorder(Pal.accent.opacity(0.22), lineWidth: 8 * u)
                .frame(width: tile.width + 22 * u, height: tile.height + 22 * u).offset(x: tile.minX - 11 * u, y: tile.minY - 11 * u)
            RoundedRectangle(cornerRadius: 12 * u, style: .continuous).fill(Pal.accent.opacity(0.10))
                .frame(width: tile.width, height: tile.height).offset(x: tile.minX, y: tile.minY)
            RoundedRectangle(cornerRadius: 15 * u, style: .continuous).strokeBorder(Pal.accent, lineWidth: 3 * u)
                .frame(width: tile.width + 6 * u, height: tile.height + 6 * u).offset(x: tile.minX - 3 * u, y: tile.minY - 3 * u)
            RoundedRectangle(cornerRadius: 4 * u, style: .continuous).fill(Pal.accent.opacity(0.28))
                .overlay(RoundedRectangle(cornerRadius: 4 * u, style: .continuous).strokeBorder(Pal.accent, style: StrokeStyle(lineWidth: 2 * u, dash: [6 * u, 4 * u])))
                .frame(width: r.width * k, height: r.height * k)
                .offset(x: tile.minX + r.minX * k, y: tile.minY + r.minY * k)
        }
        if let src = o.screenRect(of: d.win.id) {
            let shape = RoundedRectangle(cornerRadius: 6 * u, style: .continuous)
            ZStack {
                if let img = o.thumbs[d.win.id] { Image(nsImage: img).resizable().interpolation(.high) } else { Pal.tile }
            }
            .frame(width: src.width, height: src.height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Pal.accent, lineWidth: 2.5 * u))
            .background(shape.fill(.black.opacity(0.45)).offset(x: 6 * u, y: 12 * u))     // a plain offset plate for depth (no blur)
            .scaleEffect(1.08)
            .rotationEffect(.degrees(-2))
            .offset(x: d.at.x - d.grab.width, y: d.at.y - d.grab.height)
        }
    }
}

struct FindField: View {
    static var width: CGFloat { 460 * u }
    let query: String
    var body: some View {
        HStack(spacing: 10 * u) {
            Image(systemName: "magnifyingglass").font(.system(size: 14 * u, weight: .semibold)).foregroundStyle(Pal.text4)
            Text(query.isEmpty ? "Type to find a window" : query)
                .font(Pal.font(15 * u, query.isEmpty ? .regular : .medium))
                .foregroundStyle(query.isEmpty ? Pal.text4 : Pal.text1)
                .lineLimit(1)
            Spacer(minLength: 0)
            Text("↵").font(Pal.font(12 * u, .medium)).foregroundStyle(Pal.text4)
                .padding(.horizontal, 7 * u).padding(.vertical, 2 * u)
                .overlay(RoundedRectangle(cornerRadius: 6 * u).strokeBorder(Pal.line, lineWidth: 1))
        }
        .padding(.horizontal, 16 * u)
        .frame(width: Self.width, height: 44 * u)
        .background(RoundedRectangle(cornerRadius: 14 * u, style: .continuous).fill(Pal.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: 14 * u, style: .continuous).strokeBorder(Pal.hairline, lineWidth: 1))
        .allowsHitTesting(false)
    }
}


/// The tile's outline: accent on the workspace the rail is on or swiping to (it follows the fingers), a pale ring on the keyboard selection.
/// Its own view so the touch frames redraw only the ring, not the tiles.
private struct TileRing: View {
    @EnvironmentObject var s: Store           // the focus changing redraws the ring too, not only the swipe travel
    @ObservedObject private var rail = store.rail
    let space: Int
    let corner: CGFloat
    let selected: Bool
    var body: some View {
        let current = s.focusedIndex.map { f in
            let i = min(max(Int((Double(f) + rail.swipe).rounded()), 0), max(s.spaces.count - 1, 0))
            return s.spaces.indices.contains(i) && s.spaces[i].id == space
        } ?? false
        let line: CGFloat = current ? 3 * u : selected ? 2.5 * u : 1
        RoundedRectangle(cornerRadius: corner + line, style: .continuous)
            .strokeBorder(current ? Pal.accent : selected ? Pal.text1.opacity(0.7) : Pal.line, lineWidth: line)
            .padding(-line)
            .animation(.easeOut(duration: 0.12), value: current)
    }
}

/// The overview's hosting view takes the first click even when its panel is not key, so a click after the window server moved focus
/// to another app still reaches the tiles.
final class OverviewHost: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
