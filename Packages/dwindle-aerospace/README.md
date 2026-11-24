# Dwindle (AeroSpace)

A riskell extension that makes [AeroSpace](https://github.com/nikitabobko/AeroSpace) tile the way a dwindle layout does, and gives it keys to
edit that layout and to carry a window or the focus from one workspace to the next. It is a *behaviour*: it runs in the background and has no
place on a bar.

It does three things:

| | What | Needs keys? |
|---|---|---|
| **Placement** | A new window splits the window you were just in, and the splits alternate across and down. A window that arrives some other way (moved in, made tiling again) is placed the same way. | No |
| **Layout keys** | Four arrows that merge a window into what is beside it, take it out of a group, or send it on to the next workspace; and a tidy key that rebuilds a workspace as one dwindle chain. | Yes |
| **Traversal** | Focus that goes on to the next workspace when you press past the edge of this one, through empty workspaces too. | Yes (the focus keys you already have) |

It needs riskell with `wm` set to `aerospace`, AeroSpace 0.21.3-Beta or later (that is the version it was tried on), and AeroSpace's two
normalizations on, which they are by default:

    enable-normalization-flatten-containers = true
    enable-normalization-opposite-orientation-for-nested-containers = true

## Quick start

1. `risk wm use aerospace`, if riskell is not on AeroSpace yet.
2. `risk ext add Packages/dwindle-aerospace` (from your riskell checkout). Nothing tracked changes: the install is two git-ignored files.
3. Put the two binding modes of [`examples/aerospace-modes.toml`](examples/aerospace-modes.toml) in your `aerospace.toml`, with your own
   modifiers and the rest of your keys in both blocks (see [Binding modes](#binding-modes)).
4. Copy [`examples/dwindle-aerospace.json`](examples/dwindle-aerospace.json) to `~/.config/riskell/ext/dwindle-aerospace.json`. Its keys must
   be the bindings of step 3, written exactly as `aerospace.toml` writes them.
5. `aerospace reload-config`, then `risk restart`. `aerospace list-modes --current` now says `riskell`.

## Placement

AeroSpace puts a new window right after the one you used last. This extension then joins the two, so the window you were in gives half of
its space to the new one. Because AeroSpace turns every nested container the other way, each split runs across where the last one ran down.

- It acts only when the workspace already has two or more other tiling windows. With fewer, AeroSpace's own pair is already right, and
  joining would turn two windows side by side into two stacked.
- A window that comes in some other way is placed the same: moved from another workspace, or made tiling again after floating.
- A window this extension sent to another workspace itself (see below) is left where it lands.
- Closing a window needs nothing: AeroSpace's flatten puts the window that is left in the pair's place.

## The keys

The examples use `ctrl-alt` as the modifier; use your own. In this guide `←` `→` `↑` `↓` stand for the four move keys.

### Moving a window

A move is two steps in one direction, one after the other. A window that sits in a group running across the direction first leaves the
group and becomes a row or column of its own; once it is its own row or column, the next press merges it with what is beside it.

| Beside the window, that way | What happens |
|---|---|
| one window | the two become one group: `A │ B` with `B` pressing ← becomes `A` over `B` (the window goes under the one it moves into) |
| a group of several windows | the window enters it, next to the member that is level with where it was; if that member is itself a group, it becomes the first in it |
| nothing, but it sits in a group across the direction | it leaves the group as a row or column of its own |
| nothing, and it is already a row or column of its own at the edge | it goes on to the next workspace (below) |

A stack that fills the whole workspace is left the same way: with two windows one above the other, ← turns the workspace into columns with the
moved window on the left. So with `A │ B`, pressing ← on `B` stacks them, and pressing ← again pulls `B` out to the left of `A`.

A worked example, a column of three beside two single windows. `X │ Y │ [P / Q / R]` (`[ ]` is a stack, `/` separates its rows), `←` on `Q`:

    X │ Y │ [P / Q / R]      start
    X │ Y │ Q │ [P / R]      1st press: Q leaves the stack as a column of its own
    X │ [Y / Q] │ [P / R]    2nd press: Q merges with the single window beside it, Y; it goes under Y

`↑` and `↓` work the same way with rows: a window in a stack that moves ↑ merges with the one above it, side by side.

This differs from AeroSpace's own `move` in two places: `move` swaps with a single window beside it, where this merges, and at the edge
of the workspace `move` wraps the whole layout in a new container, where this goes on to the next workspace or does nothing. AeroSpace's
`swap` is the way to trade two windows' places, and needs nothing from this extension.

### Going on to the next workspace

A window that is a row or column of its own at the left or right edge of the workspace, or the only window on it, goes to the next
workspace in that direction when you move it further, and the focus goes with it. Only ← and → do this; ↑ and ↓ at the edge do nothing.
Moving right makes it the first column there, moving left the last. Workspaces go in AeroSpace's order for `next` and `prev`: by name, on the window's own monitor, empty ones included. Nothing
happens at the first or the last.

### Focusing past the edge

With the two focus keys set, `focus left` at the left-most window of a workspace goes to the previous workspace and to its last window;
`focus right` at the right-most goes to the next one's first. An empty workspace is switched to, and on an empty workspace every press goes
on. Nothing happens at the first and the last. Where something is still beside the focused window the key is AeroSpace's own `focus`, so
leave those bindings as `focus left` and `focus right`.

### Tidy

The tidy key rebuilds the focused workspace as one dwindle chain, its windows in the order they were made: the first takes half, the second
half of what is left, and so on, each split running across the one before. It ends by evening out the sizes.

## Binding modes

The keys that do nothing without this extension (the four move arrows and the tidy key, bound to `true` for it to act on) must not be what
AeroSpace has when riskell is not running. They live in a binding mode of their own, `riskell`, and `main` keeps the plain keys: AeroSpace's
own `move` and `balance-sizes`, and a way to walk the workspaces. While the extension runs, riskell puts AeroSpace in the `riskell` mode
when it connects (again after AeroSpace restarts) and back in `main` when the extension stops or riskell quits.

    [mode.main.binding]                          [mode.riskell.binding]
    ctrl-alt-shift-left = 'move left'            ctrl-alt-shift-left = 'true'
    ctrl-alt-r = 'balance-sizes'                 ctrl-alt-r = 'true'
    ctrl-left = 'workspace prev'                 (the same keys otherwise)

AeroSpace cannot share bindings between modes, so a key added to one block has to be added to the other. [`examples/scripts/`](examples/scripts)
has three one-file launcher scripts:

- `aerospace-check-modes.sh` compares the two modes as AeroSpace loaded them and says which keys are in only one (exit 1 when they differ).
- `aerospace-plain-keys.sh` reloads the config and puts AeroSpace in `main`: for when riskell has died and the `riskell` keys do nothing.
- `aerospace-riskell-keys.sh` puts it back in `riskell` without restarting riskell.

Reloading the AeroSpace config keeps the current mode and moves no window. A mode that is not in `aerospace.toml` is reported once in the log
and AeroSpace stays in `main`.

## Settings

The settings are in `~/.config/riskell/ext/dwindle-aerospace.json`, which riskell reads when it starts the extension (`risk restart`). They are
text settings, so the settings card does not show them. A key left out is off.

| Setting | Default | The binding it names |
|---|---|---|
| `moveLeftKey` `moveRightKey` `moveUpKey` `moveDownKey` | none | the four move arrows, bound to `true` in the `riskell` mode |
| `focusLeftKey` `focusRightKey` | none | the keys bound to `focus left` and `focus right`, which the extension adds the edge of the workspace to |
| `tidyKey` | `alt-shift-t` | the tidy key, bound to `true` in the `riskell` mode |

Each value is the binding exactly as `aerospace.toml` writes it (`ctrl-alt-shift-left`), and the binding has to exist there. The extension
matches the key, not the mode it is pressed in.

## What it does not do

- The layout keys read the layout from where the windows are on screen, so they act on the workspace you are looking at. A layout that
  cannot be read (a window of the workspace is off screen, two windows overlap because an app will not shrink, the top container is an
  accordion) is left alone: the key does nothing.
- Floating, minimised and full-screen windows are ignored by the keys.
- There is no switch for the placement: remove the extension to turn it off (`risk ext remove dwindle-aerospace`).
- A new window that an `[[on-window-detected]]` rule moves to another workspace is counted on the workspace it was detected on, because the
  state the rule is seen from is the query from before it ran; the join may then see fewer windows than it wants.
- A window moved in from another workspace lands at the end of that workspace's top row, so it is placed beside the group before it rather
  than beside a window.
- Several monitors are written for (the next workspace is on the same monitor) but not tried on a live setup.

## What it costs

Nothing runs between key presses and nothing is polled. A key press is one request to AeroSpace, with the commands and the two queries that
read back what they did in the same request; a key that is not one of this extension's costs nothing for it. The window rectangles it reads
come from the window server for riskell's own windows only (about a millisecond for eight windows), and only when one of these keys is
pressed. [docs/EFFICIENCY.md](../../docs/EFFICIENCY.md) has the measurements.

## Troubleshooting

- **The keys do nothing.** `aerospace list-modes --current` should say `riskell`. If it says `main`, riskell is not running or never entered
  the mode: `risk log` shows `could not enter the binding mode riskell (is it in aerospace.toml?)` when the mode is missing. If it says
  `riskell` and riskell is not running, run `aerospace mode main`.
- **One key does nothing.** The name in `dwindle-aerospace.json` has to match the binding in `aerospace.toml` letter for letter, and be bound
  to `true` (the move and tidy keys) or to `focus left|right` (the focus keys). `aerospace-check-modes.sh` shows keys that are in one mode only.
- **A move does nothing on a workspace that has a window with a minimum size.** Two windows overlapping, or one off screen, make the layout
  unreadable; see "What it does not do".

## Uninstall

`risk ext remove dwindle-aerospace`, then `risk restart`. riskell puts AeroSpace back in `main`; delete the `riskell` block from
`aerospace.toml` and `~/.config/riskell/ext/dwindle-aerospace.json` if you want them gone.

## How it works

A key press reaches riskell as AeroSpace's `binding-triggered` event, before AeroSpace runs the binding's commands (which are `true`). The
extension is asked first whether it wants that binding (`wants`) and whether it needs the windows' rectangles (`needsFrames`), so keys that are
not its own cost nothing. It reads the rectangles of the focused workspace's tiling windows and rebuilds the tree from them
(`FrameTree`: find the line no window crosses, split on it, and recurse along the alternating axes), decides one step (`DwindleMove`), and
returns AeroSpace commands, which riskell sends in the one request it is making anyway. Nothing about the layout is remembered, so nothing
can go stale.

It depends only on `RiskellKit`, the public extension API; the backend features it uses (window frames, the monitor, the key filter and the
binding mode on `ManagerHook`) are generic kit API that any behaviour can use. It is meant to be movable to a repository of its own.

### Tests

`swift test` in this folder. About 130 tests, in a few seconds, with no AeroSpace running: `AeroSpaceModel` is a model of AeroSpace's tiling tree
translated from its source (join, swap, move, layout, focus, workspaces, normalization, the argument rules of the commands the scripts use), and
the exhaustive tests run the extension's commands through it over every layout of up to six windows and compare the result with a separate
statement of the rules. A model is not AeroSpace: [docs/UNVERIFIED.md](../../docs/UNVERIFIED.md) says what has been tried on a live bar.
