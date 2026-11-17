import SwiftUI
import Combine
import RiskellKit

/// Rectangles measured while editing, in the bar's own coordinate space ("bar").
struct FrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) { value.merge(nextValue()) { $1 } }
}

extension View {
    /// Reports this view's rectangle under `key`, only while editing (no layout readers at rest).
    @ViewBuilder func reportFrame(_ key: String, _ on: Bool) -> some View {
        if on {
            background(GeometryReader { g in Color.clear.preference(key: FrameKey.self, value: [key: g.frame(in: .named("bar"))]) })
        } else { self }
    }
}

/// One atom on a bar. At rest it is just the atom; in edit mode it is dashed, can be dragged, and has an x that takes it off the bars.
struct EditableAtom: View {
    @ObservedObject private var cfg = Config.shared
    let bar: BarKey, id: String
    @State private var drag = CGSize.zero
    var body: some View {
        let on = cfg.editing && id != "compat", mine = cfg.dragging == id
        AtomView(id: id, vertical: bar.vertical)
            .allowsHitTesting(!on)
            .overlay { if on { chip } }
            .reportFrame("atom:" + id, cfg.editing)
            .opacity(mine ? 0.5 : 1)
            .offset(mine ? drag : .zero)
            .zIndex(mine ? 1 : 0)
    }

    /// The dashed outline hugs the atom with an even gap on every side. A horizontal atom fills its pill's height, so its outline sits just
    /// outside it, with a corner (G.radius + gap) concentric with the pill's. A strip's atom sits in a column, so its outline is drawn just inside
    /// it, with a smaller corner.
    private var chip: some View {
        let r = bar.vertical ? 8 : G.radius + Self.gap
        // a strip's atom is 52 wide but its pill is 42 (a floating island), so its outline is inset to the pill, not to the atom's frame
        let pillW = cfg.isHug(bar) ? G.strip : G.strip - 10, hInset = (G.strip - pillW) / 2 + Self.gap
        return RoundedRectangle(cornerRadius: r).strokeBorder(Pal.accent.opacity(0.75), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            // a strip's atom can fill the strip's width, so its outline goes inside the atom instead (never past the screen edge)
            .padding(.vertical, bar.vertical ? Self.gap : -Self.gap).padding(.horizontal, bar.vertical ? hInset : -Self.gap).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .global)
                .onChanged { v in
                    if cfg.dragging != id { cfg.dragging = id }
                    drag = v.translation
                    let h = cfg.plan(id, mouse: NSEvent.mouseLocation)?.1
                    if h != cfg.hint { cfg.hint = h }
                }
                .onEnded { _ in
                    if let (d, _) = cfg.plan(id, mouse: NSEvent.mouseLocation) { cfg.apply(id, d) }
                    cfg.dragging = nil; cfg.hint = nil; drag = .zero
                })
            .overlay(alignment: bar.vertical ? .top : .topTrailing) { RemoveBadge(vertical: bar.vertical) { cfg.remove(id); cfg.save() } }
    }
    static let gap: CGFloat = 3
}

/// The x on a placed widget: a small crit disc inside the outline's top-right corner, brighter and a little larger under the pointer.
private struct RemoveBadge: View {
    let vertical: Bool                                 // a strip's atom: the badge sits above its top edge; a bar's: past its right edge
    let action: () -> Void
    @State private var hot = false
    var body: some View {
        Image(systemName: "xmark").font(.system(size: 5.5, weight: .heavy)).foregroundStyle(Pal.cardSolid)
            .frame(width: 11, height: 11).background(Circle().fill(Pal.crit.opacity(hot ? 1 : 0.85)))
            .scaleEffect(hot ? 1.12 : 1)
            .animation(.easeOut(duration: 0.12), value: hot)
            // out past the outline, never over the content: a horizontal atom's x sits just past its right edge (y: its top edge stays
            // inside the band); a strip's sits above its top edge, centred. Both stay inside the bar.
            .offset(x: vertical ? 0 : 8, y: vertical ? -8 : -3)
            .contentShape(Circle()).onHover { hot = $0 }
            .onTapGesture(perform: action)
    }
}

/// Where the dragged pill would land.
struct HintView: View {
    @ObservedObject private var cfg = Config.shared
    let bar: BarKey
    var body: some View {
        ZStack(alignment: .topLeading) {
            if let h = cfg.hint, h.bar == bar {
                if let b = h.box {
                    RoundedRectangle(cornerRadius: G.radius).strokeBorder(Pal.accent.opacity(0.9), lineWidth: 1.5)
                        .frame(width: b.width, height: b.height).offset(x: b.minX, y: b.minY)
                }
                Capsule().fill(Pal.accent).frame(width: h.line.width, height: h.line.height).offset(x: h.line.minX, y: h.line.minY)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.1), value: cfg.hint)
    }
}

// MARK: settings panel

/// The small panel that holds the style settings and the tray of removed pills. Opening it turns edit mode on; Done turns it off.
/// Whether the settings panel is showing its content: it scales in on open.
final class PanelAppear: ObservableObject { @Published var shown = false }

final class SettingsPanel {
    static let shared = SettingsPanel()
    static let appear = PanelAppear()
    private var panel: NSPanel?
    private var host: NSHostingView<AnyView>?
    private var follow: AnyCancellable?
    var isOpen: Bool { panel?.isVisible ?? false }
    var snapshotView: NSView? { host }      // --settings --snap DIR

    /// The visible frame of the main screen (real points): the panel stays inside it.
    static var visible: CGRect { NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }

    /// The panel's width in design units: two columns, or one when the screen cannot take the two.
    static let wideWidth: CGFloat = 640, narrowWidth: CGFloat = 340
    /// The one place that picks the column mode: two columns when the wide panel fits in 90% of the visible width at factor `k`. Pure.
    static func twoColumns(visible v: CGRect, k: CGFloat) -> Bool { wideWidth * k <= v.width * 0.9 }

    struct Placement { let frame: CGRect; let scrolls: Bool }
    /// Where the panel goes and how big it is, in real points: content of `content` design size at factor `k`, on a screen whose visible frame
    /// is `v`. The size is the content's real size, never more than 90% of `v` in either direction (past that the content scrolls). The top-left
    /// is `topLeft` (centred when nil), moved in so that all of the panel is on `v`. Pure: the check (`checkPanel`) runs it on fake screens.
    static func layout(content: CGSize, k: CGFloat, visible v: CGRect, topLeft: CGPoint?) -> Placement {
        let wantH = content.height * k, maxH = v.height * 0.9
        let w = min(content.width * k, v.width * 0.9), h = min(wantH, maxH)
        let x = min(max(topLeft?.x ?? v.midX - w / 2, v.minX), v.maxX - w)
        let top = min(max(topLeft?.y ?? v.midY + h / 2, v.minY + h), v.maxY)
        return Placement(frame: CGRect(x: x, y: top - h, width: w, height: h), scrolls: wantH > maxH)
    }

    /// `RISKELL_PANEL_DEBUG=1`: the panel's sizes in real points after each fit (the test for the cap).
    private static let debug = ProcessInfo.processInfo.environment["RISKELL_PANEL_DEBUG"] != nil
    private static func report(_ design: CGSize, _ p: Placement) {
        guard debug else { return }
        let v = visible
        print(String(format: "panel: k %.2f content %.0fx%.0f design -> real frame %.0fx%.0f at (%.0f,%.0f); visible %.0fx%.0f; 90%% cap %.0fx%.0f; scroll %@",
                     Real.k, design.width, design.height, p.frame.width, p.frame.height, p.frame.minX, p.frame.maxY,
                     v.width, v.height, v.width * 0.9, v.height * 0.9, p.scrolls ? "ACTIVE" : "off"))
        fflush(stdout)
    }

    /// `riskell --check-panel`: the panel's real frame for each scale and screen below, on the screen's visible frame (a 24 pt menu bar at the
    /// top), in the column mode the screen picks (`twoColumns`: two columns when the wide panel fits, else one). Every cell must have the whole
    /// panel on screen, the Done button on screen, and at least 300 pt of scroll area when it scrolls.
    static func checkPanel() -> Bool {
        // the natural size of each column mode, every card open and no scroll cap (design units)
        func natural(_ two: Bool) -> CGSize { NSHostingView(rootView: SettingsView(allOpen: true, forceTwoColumns: two)).fittingSize }
        let wide = natural(true), narrow = natural(false)
        let c = Config.shared
        print(String(format: "window gaps (real points, scale %.2f): left %.1f right %.1f bottom %.1f top %.1f", Real.k, c.gapLeft, c.gapRight, c.gapBottom, Config.gapTop))
        print("two columns \(Int(wide.width))x\(Int(wide.height)) design units; one column \(Int(narrow.width))x\(Int(narrow.height)) (all cards open)")
        print("scale  screen      panel (real)   top-left      columns  on screen  done  scroll area  result")
        var ok = true
        for (w, h) in [(1470, 956), (1512, 982), (1728, 1117), (2268, 1473), (1920, 1080)] {
            for k: CGFloat in [0.5, 0.75, 1, 1.25, 1.5, 2, 3] {
                let v = CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h) - 24)
                let two = twoColumns(visible: v, k: k)
                let p = layout(content: two ? wide : narrow, k: k, visible: v, topLeft: nil), f = p.frame
                let inside = v.contains(f)
                let done = CGRect(x: f.maxX - 18 * k - 56 * k, y: f.maxY - 18 * k - 24 * k, width: 56 * k, height: 24 * k)      // the Done chip, top right
                let doneIn = v.contains(done)
                let scrollArea = f.height - 72 * k      // the panel's padding and header are 72 design units
                let scrollOK = !p.scrolls || scrollArea >= 300
                let pass = inside && doneIn && scrollOK
                ok = ok && pass
                print(String(format: "%-6.2f %4dx%-5d %5.0fx%-5.0f  (%5.0f,%5.0f)  %@  %@  %@  %@  %@  %@",
                             k, w, h, f.width, f.height, f.minX, f.maxY, two ? "two" : "one", inside ? "yes" : "NO", doneIn ? "yes" : "NO",
                             p.scrolls ? "on, \(Int(scrollArea)) pt" : "off", scrollOK ? "" : "(under 300)", pass ? "PASS" : "FAIL"))
            }
        }
        print(ok ? "PASS" : "FAIL")
        return ok
    }

    /// Resize to the content, keeping the top edge where it is (after `delay`, e.g. once a card has folded). Clamped to 90% of the screen.
    func fit(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, let p = self.panel, let h = self.host else { return }
            h.sizingOptions = [.intrinsicContentSize]      // these panels size themselves to their content (see `hosting`)
            let design = h.fittingSize
            let place = SettingsPanel.layout(content: design, k: Real.k, visible: SettingsPanel.visible, topLeft: CGPoint(x: p.frame.minX, y: p.frame.maxY))
            SettingsPanel.report(design, place)
            let frame = place.frame
            guard abs(frame.height - p.frame.height) > 0.5 || abs(frame.width - p.frame.width) > 0.5 || abs(frame.minY - p.frame.minY) > 0.5 else { return }
            p.setFrame(frame, display: true)
            h.frame = CGRect(origin: .zero, size: frame.size)
            h.useDesignUnits()
        }
    }
    func toggle() { isOpen ? close() : open() }

    func open() {
        guard let screen = NSScreen.main else { return }
        Popout.shared.close()      // a card that is out when editing starts goes away
        Config.shared.editing = true
        if panel == nil {
            let h = hosting(SettingsView())
            h.sizingOptions = [.intrinsicContentSize]      // these panels size themselves to their content (see `hosting`)
            let design = h.fittingSize
            let place = SettingsPanel.layout(content: design, k: Real.k, visible: SettingsPanel.visible, topLeft: nil)      // real points, centred, on screen
            SettingsPanel.report(design, place)
            let frame = place.frame, size = frame.size
            let p = BarPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true
            p.takesKeys = true
            p.level = NSWindow.Level(rawValue: barBaseLevel)
            p.collectionBehavior = [.ignoresCycle]
            p.isReleasedWhenClosed = false
            p.isMovableByWindowBackground = true
            p.contentView = h
            h.frame = CGRect(origin: .zero, size: size)
            p.setFrame(frame, display: true)
            h.useDesignUnits()
            p.orderFrontRegardless()
            Sky.pin([p])
            panel = p; host = h
            follow = Config.shared.objectWillChange.sink { [weak self] _ in self?.fit() }
        } else { panel?.orderFrontRegardless() }
        guard let p = panel else { return }
        p.makeKey()      // so Esc and q reach the panel (BarPanel.keyDown)
        // a short fade and scale-in (the content scales through `appear`, the window fades)
        p.alphaValue = 0
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
        SettingsPanel.appear.shown = false
        DispatchQueue.main.async { SettingsPanel.appear.shown = true }
    }

    /// Esc and a plain q close the editor. A q with shift or command does not, and no other key does.
    static func closesEditor(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        let plain = modifiers.intersection([.command, .shift, .option, .control]).isEmpty
        switch keyCode {
        case 53, 12: return plain      // Escape, q
        default: return false
        }
    }

    /// `riskell --key-test`: the close rule against its cases. Prints PASS or FAIL for each; true when all pass.
    static func keyTest() -> Bool {
        let cases: [(String, UInt16, NSEvent.ModifierFlags, Bool)] = [
            ("Escape", 53, [], true),
            ("q", 12, [], true),
            ("Q (shift)", 12, [.shift], false),
            ("q (command)", 12, [.command], false),
            ("q (option)", 12, [.option], false),
            ("Escape (command)", 53, [.command], false),
            ("a", 0, [], false),
            ("Return", 36, [], false),
            ("Space", 49, [], false),
        ]
        var ok = true
        for (name, code, mods, want) in cases {
            let got = closesEditor(keyCode: code, modifiers: mods)
            print(got == want ? "PASS" : "FAIL", name, got ? "closes" : "stays")
            ok = ok && got == want
        }
        fflush(stdout)
        return ok
    }
    func close() {
        Config.shared.editing = false; Config.shared.dragging = nil; Config.shared.hint = nil
        panel?.orderOut(nil)
    }
}

struct Chip: View {
    let text: String
    var on = false
    var dim = false                    // looks lit but cannot act right now
    let action: () -> Void
    @State private var hot = false
    var body: some View {
        Text(text).font(Pal.font(11, .semibold)).foregroundStyle(on ? Pal.cardSolid : hot ? Pal.accent : Pal.text2)
            .padding(.horizontal, 10).frame(height: 24)
            .background(RoundedRectangle(cornerRadius: 7).fill(on ? Pal.accent.opacity(dim ? 0.55 : 1) : hot ? Pal.hoverFill : Pal.groove))
            .contentShape(Rectangle()).onHover { hot = $0 }.onTapGesture(perform: action)
    }
}

struct SettingsView: View {
    @ObservedObject private var cfg = Config.shared
    @ObservedObject private var appear = SettingsPanel.appear
    @ObservedObject private var theme = ThemeState.shared      // the theme's name in the THEME card follows a change
    @State private var picked: String?
    // which cards are open, remembered between launches (a key that is not there yet is the default)
    @AppStorage("layout.card.bars") private var barsOpen = true
    @AppStorage("layout.card.theme") private var themeOpen = false
    @AppStorage("layout.card.spacing") private var spacingOpen = false
    @AppStorage("layout.card.widgets") private var widgetsOpen = true
    @AppStorage("layout.card.ext") private var extOpen = true
    /// The check (`--check-panel`): every card open and no scroll cap, so the natural height is measured.
    var allOpen: Bool
    /// The check forces a column mode to measure it; nil lets the screen decide (`SettingsPanel.twoColumns`).
    var forceTwoColumns: Bool?
    init(allOpen: Bool = false, forceTwoColumns: Bool? = nil) { self.allOpen = allOpen; self.forceTwoColumns = forceTwoColumns }
    private func bound(_ b: Binding<Bool>) -> Binding<Bool> { allOpen ? .constant(true) : b }

    /// The panel is at most 90% of the screen's visible height (real points); past that the cards scroll. The chrome around the scroll area
    /// (the panel's padding, the header row and the gap under it) is in design units, like everything the panel lays out in.
    static var scrollCap: CGFloat { (NSScreen.main?.visibleFrame.height ?? 900) * 0.9 / Real.k - 72 }

    var body: some View {
        let two = forceTwoColumns ?? SettingsPanel.twoColumns(visible: SettingsPanel.visible, k: Real.k)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("riskell preferences").font(Pal.font(14, .semibold)).foregroundStyle(Pal.text1)
                Spacer()
                Text("esc to close").font(T.sub).foregroundStyle(Pal.text4)
                Chip(text: "Done") { SettingsPanel.shared.close() }
            }
            .padding(.horizontal, 2).frame(height: 24)
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        if two {
                            // two columns: the bars and the spacing on the left, the theme and the widgets on the right
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 12) { barsCard; spacingCard; extensionsCard }.frame(maxWidth: .infinity)
                                VStack(alignment: .leading, spacing: 12) { themeCard(); widgetsCard(columns: 3) }.frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) { barsCard; themeCard(); spacingCard; widgetsCard(columns: 3); extensionsCard }
                        }
                    }
                    .id("panel.content")
                }
                .frame(maxHeight: allOpen ? nil : Self.scrollCap)
                // `RISKELL_PANEL_SCROLL=top|bottom` (a test): scroll to the start or the end once the panel has appeared
                .onAppear {
                    if let end = ProcessInfo.processInfo.environment["RISKELL_PANEL_SCROLL"] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { proxy.scrollTo("panel.content", anchor: end == "top" ? .top : .bottom) }
                    }
                }
            }
        }
        .onChange(of: picked) { _, _ in SettingsPanel.shared.fit() }
        // a card that opens grows the panel at once; one that folds shrinks it after its animation
        .onChange(of: barsOpen) { _, o in SettingsPanel.shared.fit(after: o ? 0 : 0.22) }
        .onChange(of: themeOpen) { _, o in SettingsPanel.shared.fit(after: o ? 0 : 0.22) }
        .onChange(of: spacingOpen) { _, o in SettingsPanel.shared.fit(after: o ? 0 : 0.22) }
        .onChange(of: widgetsOpen) { _, o in SettingsPanel.shared.fit(after: o ? 0 : 0.22) }
        .onChange(of: extOpen) { _, o in SettingsPanel.shared.fit(after: o ? 0 : 0.22) }
        .scaleEffect(appear.shown ? 1 : 0.97).opacity(appear.shown ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: appear.shown)
        .padding(18).frame(width: two ? SettingsPanel.wideWidth : SettingsPanel.narrowWidth)
        .background(RoundedRectangle(cornerRadius: G.cardRadius).fill(Pal.cardSolid))
        .overlay(RoundedRectangle(cornerRadius: G.cardRadius).stroke(Pal.hairline, lineWidth: 1))
    }

    /// Only when an installed extension declares settings; nothing is drawn (and no space taken) otherwise.
    @ViewBuilder private var extensionsCard: some View {
        if !installedSettings.isEmpty {
            CollapsibleCard(title: "EXTENSIONS", open: bound($extOpen), summary: { Text(ExtensionsCard.summary()).font(T.sub) }) { ExtensionsCard() }
        }
    }

    private var barsCard: some View {
        CollapsibleCard(title: "BARS", open: bound($barsOpen), summary: { Text("\(BarKey.allCases.filter { cfg.on($0) }.count) of 4 bars on").font(T.sub) }) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(BarKey.allCases) { b in
                    VStack(spacing: 5) {
                        HStack(spacing: 6) {
                            Text(b.title).font(Pal.font(12, .semibold)).foregroundStyle(cfg.on(b) ? Pal.text1 : Pal.text4)
                            Spacer()
                            if b != .top {
                                // an empty bar can be switched off; one with pills must be emptied first (the chip stays lit, nothing happens)
                                Chip(text: cfg.on(b) ? "On" : "Off", on: cfg.on(b), dim: cfg.on(b) && !cfg.canSwitchOff(b)) { cfg.setOn(b, !cfg.on(b)) }
                            }
                            Chip(text: "Floating", on: !cfg.isHug(b)) { cfg.setHug(b, false) }
                            Chip(text: "Hug", on: cfg.isHug(b)) { cfg.setHug(b, true) }
                        }
                        // how this bar's cards spill out; chat needs a floating bar (on a hugged one the chip stays dim and does nothing)
                        HStack(spacing: 6) {
                            Text("Cards").font(T.sub).foregroundStyle(Pal.text4)
                            Spacer()
                            Chip(text: "Flush", on: cfg.spill(b) == .fill) { cfg.setSpill(b, .fill) }
                            Chip(text: "Chat", on: cfg.spill(b) == .chat, dim: cfg.isHug(b)) { cfg.setSpill(b, .chat) }
                        }
                    }
                }
            }
        }
    }

    private func themeCard() -> some View {
        CollapsibleCard(title: "THEME", open: bound($themeOpen), summary: { ThemeSummary() }) { ThemePicker() }
    }

    private var spacingCard: some View {
        CollapsibleCard(title: "SPACING & SIZE", open: bound($spacingOpen), summary: { Text(SpacingCard.summary()).font(T.sub) }) { SpacingCard() }
    }

    private func widgetsCard(columns: Int) -> some View {
        CollapsibleCard(title: "WIDGETS", open: bound($widgetsOpen), summary: { Text(cfg.tray.isEmpty ? "all placed" : "\(cfg.tray.count) in the tray").font(T.sub) }) {
            VStack(alignment: .leading, spacing: 12) {
                if cfg.tray.isEmpty {
                    Text("Everything is placed. Take a widget off a bar with its x and it comes back here.").font(T.sub).foregroundStyle(Pal.text4)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    let rows = stride(from: 0, to: cfg.tray.count, by: columns).map { Array(cfg.tray[$0..<min($0 + columns, cfg.tray.count)]) }
                    VStack(spacing: 6) {
                        ForEach(rows, id: \.self) { row in
                            HStack(spacing: 6) {
                                ForEach(row, id: \.self) { TrayTile(id: $0, picked: $picked) }
                                ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity) }
                            }
                            if let p = picked, row.contains(p) {
                                HStack(spacing: 4) {
                                    Text("Place on").font(T.sub).foregroundStyle(Pal.text4)
                                    Spacer()
                                    ForEach(BarKey.allCases.filter { AtomCatalog.fits(p, $0) }) { b in Chip(text: b.title) { cfg.add(p, to: b); picked = nil } }
                                }
                                .transition(.opacity)
                            }
                        }
                    }
                }
                Text("Drag a widget on the bars. Drop it on an island to join it, on empty bar to give it an island of its own. A bar with no widgets can be switched off; its space goes back to your windows.")
                    .font(T.sub).foregroundStyle(Pal.text4).fixedSize(horizontal: false, vertical: true)
                HStack { Chip(text: "Reset layout") { cfg.reset() }; Spacer() }
            }
        }
    }

    /// The folded THEME card's summary: the scheme's name and its four signal tones.
    private struct ThemeSummary: View {
        var body: some View {
            let t = Theme.current
            HStack(spacing: 6) {
                Text(t.name)
                HStack(spacing: 4) { ForEach([t.accent, t.ok, t.warn, t.crit], id: \.r) { Circle().fill($0.color()).frame(width: 6, height: 6) } }
            }
            .font(T.sub)
        }
    }
}

// MARK: the tray

    /// A widget that is on no bar, drawn live. Drag it onto a bar (a ghost follows the pointer, the bar shows where it would land) or click it
    /// to pick a bar from the buttons that open under it. The drop rules are the ones for a widget already on a bar (`Config.plan` / `apply`).
    private struct TrayTile: View {
        @ObservedObject private var cfg = Config.shared
        let id: String
        @Binding var picked: String?
        @State private var hot = false
        var body: some View {
            let open = picked == id, mine = cfg.dragging == id
            VStack(spacing: 5) {
                FitPreview(box: CGSize(width: 76, height: 26)) { AtomView(id: id, vertical: false).allowsHitTesting(false) }
                Text(AtomCatalog.name(id)).font(Pal.font(9.5, .semibold)).foregroundStyle(open || hot ? Pal.text1 : Pal.text3).lineLimit(1)
            }
            .padding(.vertical, 7).padding(.horizontal, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(open ? Pal.pressFill : hot ? Pal.hoverFill : Pal.groove))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(open ? Pal.accent.opacity(0.7) : Color.clear, style: StrokeStyle(lineWidth: 1, dash: [3, 2])))
            .opacity(mine ? 0.35 : 1)
            .contentShape(Rectangle())
            .onHover { hot = $0 }
            .onTapGesture { withAnimation(.easeOut(duration: 0.12)) { picked = open ? nil : id } }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { _ in
                    let m = NSEvent.mouseLocation
                    if cfg.dragging != id { cfg.dragging = id; picked = nil; DragGhost.shared.show(id) }
                    DragGhost.shared.move(to: m)
                    let h = cfg.plan(id, mouse: m)?.1
                    if h != cfg.hint { cfg.hint = h }
            }
            .onEnded { _ in
                if let (d, _) = cfg.plan(id, mouse: NSEvent.mouseLocation) { cfg.apply(id, d) }
                cfg.dragging = nil; cfg.hint = nil; DragGhost.shared.hide()
            })
    }
}

/// Draws its content at its natural size, scaled down (never up) to fit `box`.
private struct FitPreview<C: View>: View {
    let box: CGSize
    @ViewBuilder let content: C
    @State private var natural = CGSize(width: 1, height: 1)
    var body: some View {
        content.fixedSize()
            .background(GeometryReader { g in Color.clear.onAppear { natural = g.size }.onChange(of: g.size) { _, n in natural = n } })
            .scaleEffect(min(1, box.width / max(1, natural.width), box.height / max(1, natural.height)))
            .frame(width: box.width, height: box.height)
    }
}

/// The small floating copy of a widget that follows the pointer while it is dragged out of the tray (the panel itself would clip it).
final class DragGhost {
    static let shared = DragGhost()
    private var panel: NSPanel?
    func show(_ id: String) {
        hide()
        let h = hosting(Ghost(id: id))
        h.sizingOptions = [.intrinsicContentSize]      // these panels size themselves to their content (see `hosting`)
        let size = h.fittingSize.times(Real.k)      // real points; the content lays out in design units
        let p = BarPanel(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.ignoresMouseEvents = true
        p.level = NSWindow.Level(rawValue: barBaseLevel + 6)
        p.collectionBehavior = [.ignoresCycle]; p.isReleasedWhenClosed = false
        p.contentView = h; h.frame = CGRect(origin: .zero, size: size)
        p.setFrame(CGRect(origin: .zero, size: size), display: false)
        h.useDesignUnits()
        p.orderFrontRegardless()
        Sky.pin([p])
        panel = p
        move(to: NSEvent.mouseLocation)
    }
    func move(to m: CGPoint) {
        guard let p = panel else { return }
        p.setFrameOrigin(CGPoint(x: m.x - p.frame.width / 2, y: m.y - p.frame.height / 2))
    }
    func hide() { panel?.orderOut(nil); panel = nil }

    private struct Ghost: View {
        let id: String
        var body: some View {
            AtomView(id: id, vertical: false)
                .padding(.horizontal, 12).frame(height: G.pill)
                .background(RoundedRectangle(cornerRadius: G.radius).fill(Pal.cardSolid))
                .overlay(RoundedRectangle(cornerRadius: G.radius).strokeBorder(Pal.accent.opacity(0.8), lineWidth: 1))
                .padding(8)
        }
    }
}
