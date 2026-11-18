# riskell: what it depends on, what was tuned, and how to re-verify after an update

riskell sits on things it does not own: private macOS frameworks, OmniWM's IPC and settings, and a handful of macOS system settings.
Any of them can change under an update and break riskell quietly. This file is the record of **what the dependencies are, every custom
setting and why, the decisions and measurements behind them, and the checklist to run after macOS or OmniWM updates.**

Last verified: **macOS 27.2 (26B123), OmniWM 0.8.0 (IPC protocol 22)**, 2026-11-15. The macOS and OmniWM versions are the constants in
`Sources/riskell/Services/Compat.swift` (`Compat.Verified`); the protocol number is `Omni.protocolVersion`.

**Contents:** [Version tracker](#1-the-version-tracker-built-in) ·
 [Dependencies](#2-dependencies-that-can-break-on-an-update) ·
 [Custom settings](#3-custom-settings-what-differs-from-stock-and-why) ·
 [The swipe](#4-the-3-finger-workspace-swipe-what-was-measured-and-what-was-decided) ·
 [Worth knowing](#5-other-things-worth-knowing) ·
 [Update checklist](#6-checklist-after-a-macos-or-omniwm-update-when-the-pill-says-update-due)

## 1. The version tracker (built in)

`Services/Compat.swift` compares what is running with what riskell was last verified against and shows a pill in the **top bar's left
zone** (between the hug strip and the notch) while anything differs. Nothing is drawn when all is as verified.

| Pill text | Meaning | What to do |
|---|---|---|
| `UPDATE DUE · macOS 27.3` | macOS version or build differs from `Verified.macOS` | walk section 6, then bump the constant |
| `UPDATE DUE · OmniWM 0.9.0` | installed OmniWM.app version differs from `Verified.omniwm` | walk section 6, then bump the constant |
| `FIX · OmniWM workspaceSwipeEnabled = true` | an OmniWM setting riskell needs has the wrong value (section 3) | put the value back in `~/.config/omniwm/settings.toml` (an OmniWM update or a settings reset can undo it) |
| `+N` after the text | more than one thing needs attention | `printf compat \| nc -U ~/.cache/riskell/ev.sock` lists all of them in the log |

When it checks: at launch, every time OmniWM (re)connects (an OmniWM update restarts it), and whenever `settings.toml` changes (a file
watch, re-armed after each change because editors replace the file). No timer. The settings it enforces are the table `Verified.omniwmSettings`.
Debug: `printf compat | nc -U -w1 ~/.cache/riskell/ev.sock` prints running vs verified; `--fake-compat` shows the pill with no real mismatch
(use it with `--snap` to look at the pill without touching the live bar).

The tracker only knows the *installed* versions, not whether a newer one exists. "Update due" means "riskell has not been checked against this
version", not "install an update".

## 2. Dependencies that can break on an update

| Dependency | Used for | Where | Symptom when it breaks |
|---|---|---|---|
| SkyLight (private): `SLSSpaceCreate`, `SLSSpaceSetAbsoluteLevel`, `SLSShowSpaces`, `SLSSpaceAddWindowsAndRemoveFromSpaces`, `SLSGetActiveSpace`, `SLSSpaceGetType` | bars pinned in a private always-shown space; hidden on native full-screen Spaces (type 4) | `Sky.swift`, `SpaceWatch.swift` | bars slide with desktop changes, or stay over full-screen apps, or vanish |
| MultitouchSupport (private): `MTDeviceCreateList`, `MTRegisterContactFrameCallback`, `MTDeviceStart/Stop` | the 3-finger gesture (workspace swipe, overview swipe up, scroll guard's finger count). `MTTouch` layout assumed: 96 bytes, state Int32 at +20, x,y Float at +32/+36 | `Extensions/Gestures/Touch.swift` | swipe dead. `printf touch-state \| nc -U ...`: `lastFrame` keeps growing. Devices also die after sleep/lock; `Touch.attach()` is repeatable and re-runs after wake/unlock |
| MediaRemote (via an Apple-signed `/usr/bin/perl` loading `libnowplaying.dylib`, a technique published by ungive/mediaremote-adapter; macOS 15.4+ blocks direct third-party callers) | now playing, notch wings | `NowPlaying.swift` | no media in the wings |
| CGEvent tap (needs Accessibility permission) | `ScrollGuard` drops trackpad scroll events while 3 fingers are down so the window under the pointer does not scroll | `Extensions/Gestures/ScrollGuard.swift` | windows scroll during a swipe |
| OmniWM IPC (`~/Library/Application Support/com.barut.OmniWM/ipc.sock` + `.secret`, newline-delimited JSON, protocol **22**) | workspaces, windows, focus in; `switch-workspace` and window commands out | `Omni.swift`, `Omni.protocolVersion` | rail empty / commands ignored; the log shows `omniwm: ... error` lines. `omniwmctl version` prints the protocol |
| OmniWM settings file `~/.config/omniwm/settings.toml` | read-only by riskell (the tracker); see section 3 | `Compat.swift` | see the `FIX` pill |
| CoreAudio, IOKit/SMC, CoreWLAN, host statistics | volume, battery/fans/temps, Wi-Fi, CPU | `Services/*` | the matching atom goes blank or stale |
| Location permission, login keychain item "Always Allow", local `riskell-dev` signing certificate | Wi-Fi names; stable code identity so permissions survive rebuilds | `scripts/risk`, README | a permission prompt reappears after a rebuild |

## 3. Custom settings (what differs from stock, and why)

### OmniWM, `~/.config/omniwm/settings.toml`

Stock file for comparison: `settings.toml.default` (OmniWM writes it). Backups made along the way: `settings.toml.bak-riskell` (the very
first, before riskell touched anything), `settings.toml.bak-sens8` (sensitivity 8, swipe still on OmniWM's side).
`~/.config` is the user's: ask before editing it.

| Setting | Value | Why |
|---|---|---|
| `gestures.workspaceSwipeEnabled` | **false** | riskell's `Touch` owns the 3-finger workspace swipe (section 4). **Enforced by the tracker.** |
| `gestures.scrollEnabled` | false | OmniWM's scroll gestures would act on the same touches. **Enforced.** |
| `gestures.scrollSensitivity` | 8.0 | no effect while the swipe is off; 8.0 was what the user preferred when OmniWM owned the swipe |
| `gestures.overviewGestureEnabled` | false | riskell has its own overview (3-finger swipe up, ctrl-alt-space) |
| `gestures.overviewGestureFingerCount` | 3 | (unused while disabled) |
| `gestures.workspaceSwipeAxis` | "horizontal" | (unused while the swipe is off) |
| `general.ipcEnabled` | **true** | riskell's whole connection to OmniWM. **Enforced.** |
| `general.updateChecksEnabled` | false | the user updates deliberately; the tracker is the reminder |
| `general.defaultLayoutType` | "dwindle" | the Hyprland-style layout (stock is "niri") |
| `gaps.outer` top / left / bottom / right | **56 / 58 / 50 / 6** with the left strip, bottom bar on and the right bar off | room for the bars that are on. **riskell writes these itself** (`Services/Gaps.swift`, when a bar is switched on or off in riskell preferences; first change backs the file up as `settings.toml.bak-riskell-gaps`; OmniWM applies it live, measured within 1 s). A bar that is on takes strip 52 + 6 (left / right) or 50 (bottom), a bar that is off leaves the plain 6 px margin; top is always 56. The version pill shows FIX if the file disagrees. If `Frame.swift`'s geometry `G` changes, change `Config.gap*` |
| `gaps.size` | 7.0 | inner gap |
| `gaps.fullscreenUsesOuterGaps` | true | OmniWM "fullscreen" keeps the bars visible |
| `focus.followsMouse` | true | |
| several stock features `enabled = false` | (hidden bar, status bar, island, etc.) | riskell draws the bars; OmniWM's own are off |
| appRules: System Settings, one more app | `layout = "float"` | these must not be tiled |

### macOS

| Setting | Value | Why |
|---|---|---|
| System trackpad gestures (`com.apple.AppleMultitouchTrackpad`): `TrackpadThreeFingerHorizSwipeGesture`, `...VertSwipeGesture`, `TrackpadThreeFingerDrag`, `TrackpadThreeFingerTapGesture`, four-finger horiz | **0 (off)** | three fingers must reach riskell alone: macOS would otherwise swipe its own Spaces / Mission Control. With them off macOS treats 3 fingers as a scroll, hence `ScrollGuard` |
| Exactly **one** macOS Space on the built-in display (`defaults read com.apple.spaces`) | 1 | OmniWM's workspaces are virtual. With several Spaces and `workspaces-auto-swoosh` on, opening an app with windows on another Space jumped there. The extra desktops were deleted in Mission Control. Native full-screen apps get their own Space by design (riskell hides its bars on a native full-screen Space) |
| Dock `mru-spaces` = 0, `workspaces-auto-swoosh` = 1 | as is | stock-ish; relevant to the one-Space rule above |
| Accessibility permission for riskell | granted | `ScrollGuard`'s event tap |
| Location permission for riskell | granted | Wi-Fi network names |
| Other bars / tiling WMs | not installed or not running | the backend is chosen by `wm` in `~/.config/riskell/config.json` (`WM.make`): `auto` (default) is OmniWM when it is installed, otherwise `none`; `omniwm` always talks to OmniWM (it reconnects while the socket is down); `none` runs on plain macOS (no rail, app icon follows the frontmost app, no gap reservation). Other names fall back to `none` until their backend exists. `risk wm omniwm|export|import` are OmniWM-only helpers |
| yabai backend (`Services/Yabai.swift`, selected by `wm: "yabai"`) | **experimental and unverified**: yabai running; the scripting addition is NOT needed for what riskell uses (queries, focus, move, close, padding) | not tested by the maintainer; written against yabai's CLI and never run against a live yabai. Not the default |
| aerospace backend (`Services/AeroSpace.swift`, selected by `wm: "aerospace"`) | **experimental and unverified**: needs the two callbacks in `aerospace.toml` (`exec-on-workspace-change` and `on-focus-changed`, both writing `aerospace` to `~/.cache/riskell/ev.sock`; riskell never edits that file) and the matching `[gaps] outer.*` values, which riskell logs at start | not tested by the maintainer; written against AeroSpace's CLI and never run against a live AeroSpace. Not the default |
| command backend (`Services/CommandWM.swift`, selected by `wm: "command"`, `wmCommand` in config.json) | **user-defined**: riskell runs the user's `state` command (one line of JSON) and action commands; nothing manager-specific in riskell | the riskell side is tested with scratch scripts (`docs/WM-COMMAND.md`); what the scripts do is the user's. Not the default |

## 4. The 3-finger workspace swipe: what was measured and what was decided

**The swipe is an optional extension, off by default** (`"gestures": "system"` in config.json). Turned on with `"gestures": "riskell"`, the
code in `Sources/riskell/Extensions/Gestures/` (`Touch.swift`, `ScrollGuard.swift`) runs, with Accessibility and the conflict pills; off, nothing
starts. Setup, the fix and restore commands, the socket words and the window-manager table are in `docs/GESTURES.md`. What follows is the
record of the OmniWM era and the decision behind it; it applies while gestures are riskell's.

**Before (macOS Spaces):** macOS flipped the Space ~960 ms after lift and reported nothing earlier, so riskell predicted the target
on lift (a queue of unconfirmed swipes, a 1.6 s spring-back if macOS never confirmed).

**OmniWM era, measured 2026-11-15 with timestamps in the log (`[touch ..]` lines are always on):**
- OmniWM confirms a committed swipe **~0.3 s after lift**, on every IPC channel at the same instant (`active-workspace`, `workspace-bar`,
  `windows`, `workspaces`, `focused-window`). There is no gesture channel and nothing earlier to subscribe to.
- Riskell's prediction matched OmniWM on 14 of 14 normal swipes, but **OmniWM silently ignores short flicks**: swipes with a travel of about
  0.04–0.08 pad widths were not committed (it armed, and sometimes committed nothing), while riskell's rule (commit if quick and >= 0.03, or >= 0.2)
  moved the rail. The rail and the desktop then disagreed. Everything OmniWM caught travelled >= 0.086 at `scrollSensitivity` 8.0.
- Raising `scrollSensitivity` to 12.0 moved the cutoff only slightly (it caught 0.073 and 0.082) and 14 of 16 swipes between 0.04 and 0.08 were
  still missed: OmniWM's decision is not a plain travel threshold.
- OmniWM's own trace (`omniwmctl capture start trace` ... `capture stop`; the file is under `~/.local/state/omniwm/diagnostics/`, it contains window
  state, do not share it) logs `gesture: armed 3 fingers`, `committed workspaceSwitch`, `3 -> 2 fingers, ending`. In a 53-swipe run it armed 53 and
  committed 52, so a **fast** burst (~3 swipes/s, faster than its 0.3 s switch) is not "missed", just too quick for the slide to show every step.
- `ScrollGuard` (riskell's event tap) was suspected of starving OmniWM and ruled out by that trace.

**Decision: riskell owns the swipe.** OmniWM's `workspaceSwipeEnabled` is false; `Touch` follows the fingers, decides on lift, and calls
`WM.focus(space:)`, which sends `switch-workspace N` (absolute number, so rapid swipes cannot drift) and sets the Store's focus at once.
- `WindowManager.ownsSwipe` (true for `Omni`) selects this path; the older prediction path stays in `Touch.swift` for a WM that does not own the swipe.
- `Omni.intent`: a switch riskell sent is the truth for up to 1 s or until OmniWM reports it. Without this, OmniWM's lagging reports of
  *earlier* swipes (each 0.3 s late) flick the rail backwards during a burst. If OmniWM never goes there, the rail returns to the real workspace.
- The commit rule (`Touch.swift`: quick `< 0.6 s` and travel `>= 0.03`, or travel `>= 0.2`; axis lock 0.025; `span` 0.30 pad widths per slot) is now
  riskell's own, so short flicks work. Direction follows macOS's natural-scrolling default.
- Cost: OmniWM's live preview that followed the fingers is gone (rail follows the fingers; the windows switch on lift with OmniWM's normal animation).
  The rail clamps at the first and last workspace (OmniWM's own swipe had `workspaceSwipeEdgeBehavior = "cycle"`).

If a swipe ever misbehaves, read `~/.cache/riskell/riskell.log`: `[touch ..] 3 fingers down` (none = frames not arriving), `sideways`/`vertical`
(axis), `fingers up after N ms, travel T, predicted ..`, then `omniwm: workspace N confirmed`. `printf touch-state | nc -U ~/.cache/riskell/ev.sock`.

## 5. Other things worth knowing

- Floating windows stay on top: OmniWM raises whatever it focuses over floating windows and has no always-on-top setting, so riskell sends
  `raise-all-floating-windows` 0.2 s after each focus / workspace event while a floating window is visible (`Omni.keepFloatingOnTop`, `Omni.floatingOnTop`).
- A known latent bug: `Event<Focused>` fails to decode `focused-window` events in `Omni.received`; the rail falls back to each window's `isFocused`.
- `risk dev` rebuilds, signs and restarts the agent that is the live bar; each restart briefly re-tiles windows. `risk log` follows the log.
- Debug commands go through `printf <name> | nc -U ~/.cache/riskell/ev.sock` (`compat`, `touch-state`, `scroll-guard`, `touch-reattach`,
  `overview-state`, `gesture-up`, `window-order`, ...; see `main.swift`).

## 6. Checklist after a macOS or OmniWM update (when the pill says UPDATE DUE)

1. `printf compat | nc -U -w1 ~/.cache/riskell/ev.sock`, read the log line: confirms what changed.
2. `omniwmctl version`: if the **protocol** number differs from 22, update `Omni.protocolVersion` and re-check the wire types in `Omni.swift`.
3. Diff OmniWM's settings: `diff ~/.config/omniwm/settings.toml.default ~/.config/omniwm/settings.toml`. OmniWM rewrites `.default` for the new
   version, so new keys or changed stock values show up here. Re-check every row of section 3; the `FIX` pill covers the enforced ones.
4. macOS system settings: the three-finger gesture keys are still 0 (`defaults read com.apple.AppleMultitouchTrackpad | grep ThreeFinger`),
   still one Space (`defaults read com.apple.spaces`), permissions still granted (System Settings > Privacy: Accessibility, Location).
5. Bars: pinned correctly (do not slide on a desktop change), hidden on a native full-screen app, visible again after.
6. Swipe: a few quick flicks, a slow drag, a very short flick, a fast burst, one at each end. Read the `[touch ..]` lines.
   `touch-state` shows frames arriving. Swipe up opens the overview.
7. Atoms that use private or system data: now playing (wings), volume, battery, Wi-Fi, fans/temps.
8. Floating window stays above a tiled one (System Settings).
9. Everything fine: set the new versions in `Compat.Verified` (and the "Last verified" line above), `scripts/risk dev`, confirm the pill is gone, commit.
   Something broke: fix it, record what changed and why in this file, then bump.
