# Bars, layout and edit mode

How the bars are put together, how the layout is stored and changed, and the rules every atom follows so it can sit on any bar.
(Compatibility with OmniWM / macOS is in `COMPATIBILITY.md`; this file is about riskell's own bars.)

## The four bars

| Bar | Shape | Zones | Notes |
|---|---|---|---|
| **top** | island bar, 48 px band | start, end | Always on. Carries the notch's wings (media). The version pill (`compat`) lives in its start zone. No centre zone: the middle is the notch. |
| **bottom** | island bar, 48 px band | start, centre, end | Can be switched off while empty. |
| **left** | strip, 52 px wide | start (top), end (bottom) | Can be switched off while empty. |
| **right** | strip, 52 px wide, mirror of the left | start, end | **Off by default.** Cards open to its left. |

Each bar is **hug** (a solid band / strip with concave fillets where it meets the next bar; the pills dissolve into it) or **floating**
(separate pills on the screen). Defaults: top and bottom floating, left and right hug. A floating strip fills in (0.18 s fade) while any
card is out, so the card is welded to it.

## Atoms

Ten atoms: `workspaces`, `appicon`, `usage`, `fan`, `bat`, `clock`, `vol`, `net`, `cpu`, `weather` (plus the `compat` pill, which is not
editable). **Every atom has a horizontal and a vertical form and fits any bar** (`AtomView` passes `vertical`, true on a strip).
An island is a pill (or, on a hug bar, a stretch of band) holding one or more atoms separated by a hairline.

Atoms are registered in one list, `Sources/riskell/Registry.swift`: id, editor name, how to draw it, and the popout card it opens (id, size per
stage, content). The bars, edit mode, the popout host and the layout validation all read that list; a new atom is its own file plus one line there.

House rules for the two forms (match them for any new atom):

- **Horizontal:** a row, `.frame(height: G.pill)` (36), spacing `T.gap` (7), `Sep(height: 18).padding(.horizontal, 5)` between modules.
- **Vertical:** a centred column, content at most 40 pt wide (strip 52; a floating island's content is 42 wide), stacked, no rotated text.
  A level is drawn as caption or glyph **above**, a vertical gauge in the middle (`VGauge` in RiskellKit, the vertical twin of `Bar`),
  the number **under** it. Modules in one atom are separated by a 24 pt hairline (`Rule` in `Packages/system/Sources/SystemExt/CpuFace.swift`).
- Colours only through `Pal`, type only through `T`. The horizontal form of an atom that already had one must stay pixel-identical
  when a vertical form is added (compare snapshots, see "Snapshot harness").
- The popout card an atom opens is chosen by the **bar**, not the atom: `HBar` / `VBar` put `\.popEdge` in the environment and the
  `popout` modifier uses it (`.below` top, `.above` bottom, `.right` left strip, `.left` right strip).
- Notes per atom: battery's vertical form has no glyph (cell + figure, runtime fades in below on hover); clock stacks HH / MM, drain, meridiem
  chip, date; network stacks its four signal cells (lit from the bottom); CPU stacks CPU, core deck, RAM, PW; weather's column drops the tenth
  of a degree from 10° up (a 14 pt "-12.4°" is 49 pt wide); workspaces' horizontal form keeps its beads in place while the card is out (the
  float-onto-rows choreography belongs to the strip); the app icon's horizontal form is the icon plus the **full app name** (never truncated,
  never a window title; any width limit is a later decision) and its island disappears while no window is focused; fan and usage rebuilt
  horizontally from what their files really show.

## The layout model (`Layout.swift`)

`Config.shared` (an `ObservableObject`) owns everything the bars show: `specs` (per bar: `start` / `center` / `end` lists of `Island { id, atoms }`),
`hug` per bar, `gap` (island gap, 2-16, default 8), `enabled` per bar, plus `editing`, `dragging`, `hint` for edit mode.
`HBar` / `VBar` read it, so every change redraws the bars.

Saved to **`~/.config/riskell/layout.json`** (riskell's own file), debounced 0.3 s. The env var `RISKELL_LAYOUT` points a second instance at another
file. On load the file is validated: unknown atoms and atoms already placed (first wins, in the order top, bottom, left, right) are dropped, empty islands
removed, the `compat` island forced to the top bar's start. A file from before the right bar existed loads fine. Delete the file to get the defaults.

## Edit mode and the settings panel (`EditMode.swift`)

Open with **ctrl-alt-,** or `printf settings | nc -U ~/.cache/riskell/ev.sock`. Opening turns edit mode on; **Done**, **Esc** or a plain **q** turns it off
(the panel takes keys while it is open; `SettingsPanel.closesEditor` is the rule, `riskell --key-test` checks it).
- The panel: a header (Layout, esc hint, Done), then cards BARS, THEME, WIDGETS (`Card` in EditMode.swift; `Pal.hoverFill`). It scales and fades in on open (0.15 s).

- **Drag a pill** (dashed outline). Drop **on an island** = join it at the boundary nearest the pointer (this also reorders). Drop **anywhere else on a
  bar** = a new island of its own, in the zone the pointer is in (thirds on the bottom bar, halves elsewhere), between the islands already there.
  An accent line shows the slot; an outline marks the island you would join. Dragging works across bars (screen coordinates).
  The rules are `Config.plan` / `Config.apply`: plain, no heuristics; an island left empty disappears.
- **x** on a pill removes it; it appears under **Not on a bar** in the panel, with one button per bar to put it back (added as an island at the
  bar's end, switching that bar on if it was off).
- Per bar: **On / Off** (a bar can be switched off only while it has no pills; the chip stays lit and nothing happens otherwise; the top bar has no
  switch), **Floating / Hug**. **Island gap** and **Reset layout**. An empty bar shows a dashed slot while editing.
- Popouts are suppressed while editing; a pill's own taps are off (the drag layer sits on top).
- While editing, a translucent veil (`EditBackdrop.swift`, the theme's `text1` at low opacity) covers the main screen. It sits just under the bars'
  level: above windows, below the bars and the settings panel; it takes no clicks. It fades in and out in 0.15 s and is ordered out when editing ends.
- A placed widget's dashed outline hugs it with a 3 pt gap. Horizontal atoms: outside, corner G.radius + 3 (concentric with the pill). Strip atoms: inside
  the atom's frame. The x is an 11 pt crit disc centred on the outline's top-right corner (brighter and larger under the pointer); it stays inside the bar.

## Switching bars on and off, and OmniWM's gaps

`Config.setOn` calls `onGeometry` (set in `main.swift`): `applyGeometry()` re-fits the panels (the top and bottom bars run between the strips that are on;
a bar that is off is faded to alpha 0 and takes no mouse), and `Gaps.apply()` (`Services/Gaps.swift`) rewrites OmniWM's `gaps.outer`:

| | on | off |
|---|---|---|
| left, right | 58 (strip 52 + 6) | 6 |
| bottom | 50 | 6 |
| top | 56 | (always on) |

OmniWM reads `settings.toml` live (measured: within 1 s). Only these four values under `[gaps.outer]` are touched, only when they differ; the first
change keeps `~/.config/omniwm/settings.toml.bak-riskell-gaps`. The version pill expects exactly these values (`Compat.Verified.gaps`) and shows FIX if
something else changed them. `OverviewLayout.workArea` and the overview's row use the same numbers (`Config.gapLeft/Right/Bottom`, `leftW`, `rightW`).
**A second instance for snapshots must run with `--no-reserve`** or it would rewrite the live gaps.

The right panel is the left one mirrored: `G.strip + G.r` wide, the strip is its right part (`HugStrip(right: true)`, fillets `corner: 1 / 3`), its host
view is offset by `G.r`. `LitBand` has `joinL` / `joinR`: a bar only grows a fillet toward a strip that is on. The top bar's notch edges are kept as screen
x (`Config.notchAbs`) and converted per render, because the bar's left edge moves with the left strip.

## Cards that stay between the bars (`Popout.place`)

- Cards of the top / bottom bars are kept `leftW + 8 + r` from the left edge and `rightW + 8 + r` from the right edge (the strips that are on).
- Cards of a strip are kept **inside the safe area**: card plus coves between `G.safeTop` (61 px from the top: band 48 + fillet 11 + 2) and
  `G.safeBottom` (55 from the bottom; 10 when the bottom bar is off). If it does not fit, the top limit wins.
- **The island floats with its card.** `Popout.floatY` is the part of the push that the margins add (what the old fit-the-screen clamp did already is not
  counted: a tall card was always moved off its atom); `VBar` offsets the island whose card is out by it (spring 0.30), so the pill sits beside its card
  and clear of the other bar. The workspaces beads need nothing extra: they float relative to the rail, which moves with the island. `reanchor` subtracts the
  float, so the atom's natural place is not lost. Known: the floated island moves away from where the pointer was; the card stays up while the pointer is on
  the original spot, on the island or on the card, but the pill's own hover highlight can drop for a moment.
- Pills of the horizontal bars do not float: their cards are only clamped sideways.

## Card style: flush or chat (`ChatCard.swift`)

Each bar has a style for the cards that open from it (`Config.spill`, saved as `spill` in layout.json: `"fill"` or `"chat"`, per bar; absent or
unknown = `fill`; set in the settings panel under each bar's Floating / Hug chips). **Flush** is everything above. **Chat** needs a floating bar (a
hugged bar always uses flush, whatever is stored): the bar does not fill in, the card is a fully rounded card, and the island it belongs to goes solid and
is joined to it by a short neck (`ChatCard.neck`) with a concave fillet (`ChatCard.flare`) at each end, so pill, neck and card are one silhouette.

- One shape, `ChatShape`, drawn in "below" orientation and flipped or transposed for the other three edges. The popout panel reaches `ChatCard.overlap`
  into the pill (above the bars' own panels, `ChatCard.level`) so the pill's hairline does not cross the join.
- The island's rectangle is read on demand when a card opens (`IslandAnchor`, an anchor view on each island, like the atom's own); nothing is measured at rest.
- **Top and bottom bars:** `ChatCard.fit` centres the card on the **hovered atom** (its own rectangle, not the whole pill: the battery in a battery + clock
  island), keeps it on the screen and the bar's limits, and moves it toward the island when the edge needs it. The neck uses the stretch of the island's
  edge the card can reach (at least 14 pt), so it always joins the island. A single-atom island has the same centre either way.
- **Strips:** `ChatCard.stripFit`. The island floats inward by the least that puts it inside the margins (between the top and bottom bars, the same bounds the card keeps to), and never travels to centre on its card; the card is positioned relative to it. The card hangs
  from the island top-aligned or bottom-aligned, whichever needs the smaller push, then is kept between `G.safeTop` and `G.safeBottom`. The island moves
  (`floatY`, spring 0.30) only when card and island overlap by less than the neck and its two fillets (18 + 2 x 13 pt), and then only by the least that makes
  the overlap enough, still inside the margins. The neck joins the island at the middle of the overlap. For example fan (the bottom zone) and workspaces
  (the top zone) do not move; the card's window is placed against the island.
- A chat card's island is re-read when it resizes (`Popout.reanchor`, e.g. the battery runtime sliding out), so the card follows the pill's final centre.
- The workspaces rail keeps its dots and app icon in chat style (it does not unfold into rows as in flush). The neck is `ChatCard.neck` (18 pt) for every card.
- Snapshots: `--pop-anchor x,y,w,h` and `--pop-island x,y,w,h` (screen points, origin bottom-left) open a card from those rectangles, so a chat card can be
  put under a real pill (measure the pill from a plain snapshot first). `RISKELL_FORCE_HOT=<card id>` (a test hook, off by default) hovers that atom 0.5 s
  after launch through the real hover path, so the runtime slides out with the card open and the reanchor path runs; the snapshot then shows the settled state.

## Snapshot harness (`scripts/orient-snap`)

`scripts/orient-snap ATOM BAR OUTDIR [flags]` runs a second instance (`--no-usage --no-reserve --no-claude --fake-usage --snap`) with a temporary layout holding
that one atom on that bar, and writes `OUTDIR/ATOM-BAR.png` (cropped to the island, on a blue backdrop so spill is visible). Use `bottom` for horizontal checks (the
top bar has the notch wings) and `left` for vertical ones. Workflow used for the orientation work: baseline PNGs of every atom in its existing orientation first,
then build the new form and compare the old orientation with PIL's `ImageChops.difference(...).getbbox()` (must be `None`, or only live values differ); force worst-case
values (100 %, "-12.4°", muted, low battery) temporarily in source, snapshot, restore, rebuild.

Other debug aids: `--edit` (edit mode on in snapshots), `--edit-test` (drives `plan` / `apply` and prints the result), `--pop ID [--pop-edge below|above|right|left]`
(open a card from a bar on that side; prints `pop-frame` with the panel's rectangle and `floatY`), `printf bar-left|right|bottom-on|off | nc -U ~/.cache/riskell/ev.sock`,
`printf settings | nc -U ...`.

## Known gaps

- The vertical 24 h clock form is not visually confirmed (the harness could not force 24 h); the fan's MAX chip needs a live SMC maxRPM.
- The top bar cannot be switched off (notch wings).
- Overview tile geometry is driven by `leftW` / `rightW`; with both strips off the row simply uses the full width.
- Memory: 41 MB fresh, ~64 MB after opening the overview (flat across repeats); one long session showed 227 MB (peak 588 MB), cause not found.

## Scale

Every size is written in design units (`G`, `T`, `Pal.font`, plain numbers in views). `Scale.factor` (Sources/riskell/Scale.swift) is the bar height over 48, clamped to 0.75...1.5; `"scale"` in config.json or `RISKELL_SCALE` overrides it. On the author's display it is exactly 1.
Windows take real points: `Real.*` is `G.* x factor`, used for every frame, screen position, window-manager gap and hit rectangle. Hosting views are sized in real points and then `useDesignUnits()` sets their bounds to frame / factor, so SwiftUI lays out in design units.
`Display` (Display.swift) is the one place bar geometry reads the screen: frame, notch height and edges, menu bar thickness, and the automatic scale (`Scale.auto(for:)`). Config `display` picks the screen ("auto", "main", "primary"). Test hook: `RISKELL_FAKE_DISPLAY="WIDTHxHEIGHT:notch=H,W"` or `"WIDTHxHEIGHT:menubar=H"` lays everything out against a fake screen at the real screen's origin.
Screen changes: `didChangeScreenParametersNotification` (no polling) triggers one debounced (0.3 s) `relayout()` in main.swift, which rebuilds `Display`, re-fits the panels and hosts and bumps `ThemeState.epoch`.

Wings (WingFit.swift): on a notched screen the top bar's start wing must end a gap before the notch and the end wing start one after it. A wing shrinks uniformly to 0.80 first, then hides its lowest-priority islands (`Registry` priorities: clock and battery 9, workspaces 8, app icon 6, usage and cpu and script pills 5, net and volume 4, fan 3, weather 2; the compat pill is never dropped). Dropped islands are hidden, not removed. Widths are the islands' measured widths, reported as they draw. `riskell --check-fit` (with `RISKELL_LAYOUT` pointing at a copy of layout.json) runs a snapshot instance per fake display and prints the table; it exits 1 on FAIL.

Without a notch the top bar keeps a centred stand-in gap of 278 design units and sits below the menu bar (`Display.topInset`; the top gap grows by the same amount).

The overview is scaled throughout: its row gaps, margins, lift and minimum tile size (`OverviewLayout`), and every size in `OverviewView.swift` (the find field, numbers, the new-workspace slot, rings, the hover label, the drag decorations, and the contents of the miniatures) are design numbers multiplied by `Real.k` (`u` in that file). At scale 1 nothing changes; on a 1512-wide screen at scale 0.67 it is the same picture as on a 2268-wide screen at scale 1 (`scripts/overview-check`: mean difference 0.4 of 255 after resizing). It learns a new screen size when the display changes (`Overview.displayChanged`). The EditBackdrop veil has no sizes; it covers `Display.current.frame`.

## Spacing and window gaps

`spacing` in config.json (Sources/riskell/Spacing.swift; see `CONFIG.md`) sets three design-unit values read by the `G` constants: `edgeGap` (8, the bar to the screen edge), `radius` (11, the corner roundness; `G.r` is the same value, `G.cardRadius` is radius + 2) and `windowGap` (6, the room between a bar and the tiled windows).
The gaps riskell writes into the window manager (Layout.swift, `Config.gapLeft/gapRight/gapBottom`, `Config.gapTop`) are each bar's thickness plus `windowGap`, times the scale: strip 52, bottom 44, top 50, and a bare margin of `windowGap`. At the defaults that is left 58, bottom 50, top 56, margin 6, the numbers riskell always wrote. The bottom and top thicknesses are today's gaps less 6, so they are fixed by the defaults rather than measured from the bars.
A spacing change re-fits the panels and re-sends the gaps (`onGeometry`) and bumps the views' epoch. Limit: the strips' panels are sized once at launch with `Real.r` of fillet room, so a larger corner radius on a hugged strip is clipped until restart.

## The layout panel's size

The panel (`SettingsPanel` in EditMode.swift) is sized by `SettingsPanel.layout`: content in design units times the scale, never more than 90% of the visible frame in either direction, placed with its top-left on the visible frame. Past that the content scrolls inside (`SettingsView.scrollCap`, the same limit in design units). `riskell --check-panel` runs that function for scales 0.5 to 3 on five screen sizes (24 pt menu bar taken off the top) and prints PASS or FAIL per cell.
