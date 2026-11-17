# Unverified: what still needs a real test

Things riskell ships that nobody has run against the real thing yet. Each one needs a person with the setup to try it and report. When one is
verified, move it to the "Verified" list with the date, the macOS version and the version of the other tool.

## Needs testing

### Window-manager backends
| Item | What to try | Why it is unverified |
|---|---|---|
| **yabai backend** (`wm: "yabai"`, `Services/Yabai.swift`) | Run yabai, set `wm` to `yabai`, `risk restart`. The rail shows your spaces and windows; clicking a workspace switches; the outer padding follows the bars. Check the signal list and the `nc` socket action. | Written from yabai's CLI and the old backend; yabai was not installed where it was written. JSON keys, `space --create` on a second display and native full-screen spaces are guesses. |
| **AeroSpace backend** (`wm: "aerospace"`, `Services/AeroSpace.swift`) | Run AeroSpace, add the two callbacks from `docs/COMPATIBILITY.md` to `aerospace.toml`, set `wm` to `aerospace`. Check the rail, focus, move and close, and the printed gap values. | AeroSpace was not installed. The `list-workspaces --all --json` keys, `--visible` and `move-node-to-workspace --window-id` were written from memory. Shows workspaces of every monitor. |
| **gestures with yabai / AeroSpace / command** (`"gestures": "riskell"` with `wm` set to one of them, docs/GESTURES.md) | Turn gestures on with that manager, check the swipe switches workspaces and the rail lands where the manager lands, check that its own gestures (if any) do not fight riskell's, and that the overview opens from three fingers up. | Only OmniWM was run with the trackpad reader. These managers use riskell's prediction path (`ownsSwipe` false), which was tuned on macOS Spaces, not on them. |
| **command backend actions** (`wm: "command"`, `docs/WM-COMMAND.md`) | Point the action commands (`focusSpace`, `focusWindow`, `closeWindow`, `moveWindow`) at scripts that log their arguments; click, middle-click, drag. | The `state` side was tested with sample scripts; the action scripts and their `{space}` / `{window}` substitution were never run. |

### Guided installer (`riskell-setup`, docs/INSTALL.md)
| Item | What to try | Why it is unverified |
|---|---|---|
| **First install on a clean Mac** | A Mac or user account with no `~/.config/riskell` and no agent: run `./install.sh`, go through all eight steps, press Install, confirm the agent runs (`risk status`), the bars appear, and `riskell-setup --check` is clean. | Tested only with a scratch HOME, `--no-build --no-launch` (pty flow and `--yes --dry-run`). The real `scripts/risk install` path (build inside it, launchd bootstrap, the health check's socket wait) was never run from the installer. |
| **Launch agent step with real launchd** | Install, then `riskell-setup --uninstall --yes` and check `launchctl print gui/$(id -u)/com.rish.riskell` is gone; install again and check it is back. | `launchctl` was never called by the installer in tests. |
| **Keychain and Accessibility prompts** | Turn on Claude usage and riskell's gestures in the installer; approve the keychain prompt and the Accessibility prompt; confirm both survive a rebuild. | The installer only states the prompts on the finish screen; it never triggers them. |
| **Trackpad gestures from the installer** | Choose riskell gestures with "Turn them off for me"; check the trackpad keys in `defaults read` change, then `riskell --gestures-restore --yes` restores them. | Same open items as the gesture writes above; the installer only calls `riskell --gestures-fix --yes`. |
| **Weather lookup over the network** | Type a real city and check the results list; then unplug the network and check the "could not reach" message and the coordinates prompt. | The lookup was tested with canned responses (`--self-test`) and an unreachable host only. |
| **Terminal look** | Run the flow in Terminal.app, iTerm2 and a 256-colour-only terminal (`COLORTERM` unset); check the accent, the theme previews and the progress cells render as in `docs/installer-snapshots/`. | Snapshots were read as text and ANSI, not in a real terminal emulator. |

### Placement and preferences
| Item | What to try | Why it is unverified |
|---|---|---|
| **Services follow placement, live** (`Services/Needs.swift`) | In riskell preferences remove the weather atom from every bar, then `risk log` and Activity Monitor: no weather request, no timer. Place it again: the forecast returns. Repeat with Network (the Location prompt appears only once it is placed) and AI usage (the keychain read). | Tested at launch with scratch layouts (`riskell --dump` lists the running services) and by build; a drag in the real editor was not driven, because synthetic mouse input is not used on a running bar. Stopping and restarting Wi-Fi monitoring and the Sys battery listener in one session was never run. |
| **EXTENSIONS card** | `risk ext add Examples/load-ext`, open riskell preferences, press the − / + and On chips; the Load atom changes at once and `~/.config/riskell/ext/load-ext.json` holds the values. | The card was drawn (`--settings`), and the write and rebuild are covered by `riskell --ext-selftest`; the click path was not driven. |

| **Weather and AI usage as packages** | Place weather and AI usage, change `location` in `config.json` while running, and toggle `usage.claude`; the atoms follow without a restart. Check the keychain prompt for Claude usage appears once, after the rebuild. | Weather was run live in a scratch instance (fetch, and a location change refetching); usage was checked only with `--fake-usage`, never against the real keychain or OpenCode. The weather glyphs now take `Pal.font` instead of the system font: layout matched, but day and night glyphs were compared on different data. |

| **Battery, CPU and fans as a package** | `risk dev`, then hover each of the three and open the CPU card (search, kill a process, right-click the CPU figure for Activity Monitor); unplug and plug the charger; check the fan card's live reading. Remove all three from every bar and confirm in Activity Monitor that riskell stops waking. | Compared with the built-in versions on identical layouts (bars and cards matched apart from live numbers) and run in scratch instances only. The weather-style real-data comparison, charger events and a process kill were not exercised. Idle CPU was noisy on a busy machine (0.25 to 0.35 s per 30 s for the full layout, as before). |

| **Volume and network as packages** | `risk dev`, then: scroll over the volume atom (steps 1 % per 6 px of trackpad), right-click mutes, open the mixer and watch the meters move; open the network card (every tab: Wi-Fi, Bluetooth, Ethernet, VPN), connect and disconnect a Bluetooth device, and on a build that has not been granted Location, grant it and check riskell restarts and shows the network name. | Compared with the built-in versions on scratch instances (bars and cards matched, apart from live audio streams and devices). The mixer meters now tick from a SwiftUI timeline at 0.125 s instead of a `Timer`, the Location restart goes through `KitHost.app`, and neither was exercised on real hardware. |

### Display and system
| Item | What to try | Why it is unverified |
|---|---|---|
| Other display modes / Mac models | Switch to another scaled mode (a stock 14" is about 1512 x 982) and restart; check bars, cards, the top bar beside the notch. Also a 13", a 16", an external monitor with no notch. | Only forced scale factors were tested, on one screen. |
| System preference writes on macOS 26 (`riskell --gestures-fix --yes`, `--gestures-restore --yes`, docs/GESTURES.md) | On a machine where the 3-finger gestures are on: `--gestures-fix` (dry run first), then `--yes`; confirm the gestures stop, then `--gestures-restore --yes` and confirm they come back. Check whether the trackpad keys need a logout and the Dock keys a `killall Dock`. | Only a throwaway suffix domain was written (test values read back). The real trackpad and Dock domains were never written. Unknown: whether System Settings keeps a second copy per host (ByHost) that `--gestures-fix` does not write, and whether the trackpad keys apply without a logout. |
| Live screen change (plug in or unplug a monitor, change resolution) | Plug in an external monitor and unplug it; the bars must re-fit within about a second, with no leftover panels. Check the top bar's notch gap again after a mode change. | The observer and `relayout()` (main.swift) were written but never fired on a real change: the test needs a physical or virtual display change. |
| No-notch top bar (stand-in gap, below the menu bar) | On an external monitor: the top bar sits under the menu bar's strip, the centre gap is empty and cards from the top bar open below it. | Snapshots only. Top-bar cards (Popout.swift `place`, the `f.maxY - Real.band` offset) do not yet subtract the menu bar inset, so they sit about 24 pt high there. The stand-in gap is drawn as a black cutout. |
| Wing fit on real content | Put long app names (the app icon atom shows the full name) and many islands on the top bar at 1512 and at 2268; check the start wing shrinks, then drops islands by priority, and the compat pill stays. | `--check-fit` measures the snapshot's state (the app icon's width depends on the focused window, so the natural width varies between runs). A 600 pt wide fake screen overflows (the compat pill cannot be dropped) and shows it. |
| Overview at scales other than 1, with real windows and a real pointer | Open the overview (ctrl-alt-space) at a real or fake scale of 0.67 and 1.5; hover and drag windows between workspaces, use the find field. | Everything is scaled and the layout was checked at scales 0.67, 1 and 1.5 on a scratch instance with fake workspaces (`scripts/overview-check`), but with no windows drawn in the miniatures and no real pointer. Dragging and hit-testing at other scales are unchecked. |
| Script pill streams: CPU cost of stream pills | On a second instance, three stream pills on three bars, `ps` cputime over 10 minutes, against the same layout with `run` pills. | Three rich 1 Hz streams about 1.4 s CPU a minute against 0.4 s for run pills; three silent streams about 0.65 s. The pill code itself is a few ms a second in `sample`, so the rest is unlocated. Target is about 0.2 s per 20 s. |
| Script pill streams: process cleanup for deeper trees | A `stream` that starts a pipeline of several commands, then removed from the layout; `pgrep` should find nothing. | Only the shell's direct children are killed (as `run` timeouts already do); deeper grandchildren may outlive it. |

### Interaction (needs a real pointer or keys)
| Item | Status |
|---|---|
| Drag a tray tile onto a bar, drag a placed widget between bars, at scales other than 1 | The drop rules pass as a rule test; no real drag at another scale. |
| Card open/close springs and the strip island float | Judged by eye on the author's display only. |
| Esc / q closing the editor, the edit backdrop | Confirmed by the author on one machine. |

## Verified
| Item | Date | Where |
|---|---|---|
| Script pills: text and JSON output, hover card, click, file watch | 2026-11-16 | macOS 27.2 (26B123), author's machine |
| Live config reload, theme switching, drop-in scheme files | 2026-11-16 | same |
| Chat-style cards on all four bars, strip island float, battery centring | 2026-11-16 | same |
| Layout editor: outlines, backdrop, Esc / q, tray, theme picker | 2026-11-16 | same |
| OmniWM backend (the daily driver) | ongoing | same |

### Added 2026-11-16 (after the geometry, gestures, pills and installer merges)
| Item | What to try | Why it is unverified |
|---|---|---|
| Picture-in-Picture detection (event-driven) | Open a real PiP window (Safari, Orion, Chrome) over the bottom bar and the right edge; drag it across the bars; close it. The bar should drop under it within a click or about 5 s, follow it, and come back. | Tested only with a fake window titled "Picture in Picture" on a second instance. |
| Top bar wing-fit on a real crowded bar | Drag many widgets onto the top bar; the lowest-priority islands should drop and the rest shrink to at most 20 %, never overlapping the notch. | `--check-fit` is numeric; never watched on the live bar. |
| Collapsible settings panel, SPACING & SIZE card (edge gap, window gap, corner roundness live; scale on restart) | Fold and unfold cards; change each value and watch the bars and OmniWM's gaps follow; set `"scale": 1.5` or `2` and open the editor: it must fit the screen. | Checked by `--check-panel` and snapshots; not by hand. Corner roundness on the strips needs a restart. |
| Live display change (plug a monitor, change the display mode) | With riskell running, change the scaled mode in System Settings; bars should re-fit within a second. | The observer has never been fired by a real change. |
| Rich and streaming pills on the live bar | A `stream` pill, a `values` pill and a `history` sparkline; remove the pill from the layout and confirm its process is gone (`pgrep`). | Verified on a second instance only; the layout file is not live-reloaded, so removing a pill from the layout only stops its process after a restart. |
| Gestures election live | Flip `"gestures"` between `system` and `riskell` in config.json with riskell running; swipe, overview; conflict pills. | Verified by log lines, not by real touches. |
| Idle CPU on the real bar | Activity Monitor or `scripts/idle-cpu`: about 1 % of one core is expected. | Measured on a second instance. |
| Minimum macOS version | Run on macOS 14 and 15. | `Package.swift` says macOS 14; only the author's macOS 27.2 build has ever run it. |
| Guided installer in a real terminal | `./install.sh` in a fresh user account; check the glyphs (check marks, battery cells) in the terminal's font, and the launchd step. | Only snapshots, a pseudo-terminal test and a scratch home were used. |
| `--uninstall` and `--check` modes | Run them after a real install. | Not run against a real launch agent. |
