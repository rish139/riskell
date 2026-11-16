# Gestures: riskell's 3-finger swipe (optional extension)

riskell can read the trackpad itself: three fingers sideways switch the workspace (the rail follows the fingers), three fingers up open
the overview, and trackpad scrolls are dropped while three fingers are down so the window under the pointer does not move. This is an
**optional extension, off by default.** Section 4 of `docs/COMPATIBILITY.md` has the measurements behind it.

## The election

`config.json` (`~/.config/riskell/config.json`, or the file `RISKELL_CONFIG` points at), top level:

```json
{ "gestures": "riskell" }
```

| Value | What runs |
|---|---|
| `"system"` (default, or absent) | nothing from this extension. macOS and the window manager keep their own gestures. |
| `"riskell"` | riskell's trackpad reader and the scroll guard. |

Switching is live: edit the file and the extension starts or stops within a second, no restart. Each change logs `extensions: gestures on`
or `off`, and turning it on logs `trackpad attached` and `scroll guard: active`.

## What it needs

- **Accessibility permission** for the scroll guard (the event tap that drops scrolls). macOS asks once, when the extension is turned on.
  Until it is granted the scroll guard waits and retries every 3 s; the swipe itself does not need it.
- **macOS's own 3- and 4-finger gestures off**, or macOS swipes Spaces and Mission Control on the same touches. The pills below say
  which are still on.
- **OmniWM's own workspace swipe and scroll gestures off** (`gestures.workspaceSwipeEnabled` and `gestures.scrollEnabled` in its
  `settings.toml`), as the version tracker already requires.

## Conflict pills

While gestures are `"riskell"`, the top bar's left pill shows `FIX · gesture: <what>` for each thing that would fight it, the same
pill as the version tracker (`+N` for more). Checked at launch, when the config changes, and when OmniWM reconnects or its settings file
changes. There is no timer: a change made in System Settings is seen at the next launch or config change.

| Pill text | Setting it reads |
|---|---|
| `macOS 3-finger horizontal swipe` | `TrackpadThreeFingerHorizSwipeGesture` non-zero, in `com.apple.AppleMultitouchTrackpad` or `com.apple.driver.AppleBluetoothMultitouch.trackpad` |
| `macOS 3-finger vertical swipe` | `TrackpadThreeFingerVertSwipeGesture` non-zero (same two domains) |
| `macOS 4-finger horizontal swipe` | `TrackpadFourFingerHorizSwipeGesture` non-zero (same two domains) |
| `macOS 4-finger vertical swipe` | `TrackpadFourFingerVertSwipeGesture` non-zero (same two domains) |
| `macOS Mission Control gesture` | `showMissionControlGestureEnabled` true in `com.apple.dock` |
| `macOS App Expose gesture` | `showAppExposeGestureEnabled` true in `com.apple.dock` |
| `OmniWM 3-finger swipe` | `gestures.workspaceSwipeEnabled` is not false in OmniWM's settings |
| `OmniWM scroll gestures` | `gestures.scrollEnabled` is not false in OmniWM's settings |

The values are read with CFPreferences (any host, the user's domain). A key that is not set is not a conflict. Turning the
OmniWM settings off is done by hand in `~/.config/omniwm/settings.toml` (the fix below does not touch OmniWM).

## Fixing the macOS conflicts (consented)

```sh
riskell --gestures-fix              # prints what it WOULD set; writes nothing
riskell --gestures-fix --yes        # saves the originals, then sets the conflicting keys to off
riskell --gestures-fix --yes --restart-dock   # the same, and killall Dock (for the Dock keys)
riskell --gestures-restore          # prints what it WOULD put back
riskell --gestures-restore --yes    # puts the saved values back and deletes the backup
```

- `--gestures-fix --yes` writes `0` to the four trackpad keys in both trackpad domains and `false` to the two Dock keys, only where they
  conflict. The originals go first to `~/.config/riskell/gesture-backup.json` (an existing backup is never overwritten: the command
  refuses, so restore first).
- The Dock reads its gestures when it starts (`--restart-dock`, or `killall Dock`). The trackpad settings may need a logout.
- Nothing is changed in OmniWM or in the window managers. These commands never run by themselves: no `--yes`, no write.
- Test hooks: `RISKELL_PREFS_SUFFIX` (appended to every domain name, so a test uses throwaway domains) and `RISKELL_GESTURE_BACKUP`
  (the backup path).

## Event-socket words

Scripts and hotkey tools can drive riskell with `printf <word> | nc -U -w1 ~/.cache/riskell/ev.sock`:

| Word | Does |
|---|---|
| `workspace-1` ... `workspace-9` | switch to that workspace (OmniWM's number; the rail and the window manager follow) |
| `overview` | open or close the overview (the same as ctrl-alt-space) |

The other words (`compat`, `touch-state`, `scroll-guard`, `touch-reattach`, ...) are debugging aids; see `Sources/riskell/main.swift`.

## Efficiency: off means nothing runs

With `"system"` the extension is never created: no event tap, no MultitouchSupport device registration, no timer, no observer, no
Accessibility prompt. The log shows `extensions: gestures off` and nothing `[touch` or `scroll guard`. Measured on a debug build, a
second instance with `--no-reserve`, idle over 20 s: **0.9 % CPU with gestures off, 1.2 % with them on** (`top`, 2026-11-16).

## Which window managers conflict

| Window manager | Its own gestures | Conflict with riskell's gestures | How the swipe is switched |
|---|---|---|---|
| OmniWM | workspace swipe, scroll gestures | yes: both must be off (pills) | riskell owns the swipe (`ownsSwipe`): exact switch on lift |
| yabai | none that riskell knows | none known; **not tested** | riskell predicts the target and the WM confirms it |
| AeroSpace | none that riskell knows | none known; **not tested** | the same prediction path |
| command (`wm: "command"`) | whatever the user's scripts do | not checked | the same prediction path |
| none | none | macOS gestures only | the same prediction path |

What is still unverified with yabai, AeroSpace and the command backend is listed in `docs/UNVERIFIED.md`.
