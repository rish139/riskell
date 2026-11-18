# Recording a window manager's payload

`Tests/RiskellWMTests` parses the three wire formats from the files in `Tests/RiskellWMTests/fixtures/`, so a backend can be checked on a
machine with no window manager running (CI has none). The fixtures are read by path, not copied into a bundle: replacing one needs no
manifest change, and the tests keep working from Xcode and from `swift test`.

**Every fixture in there is synthetic today.** It follows the shape the backends read, but no yabai, AeroSpace or OmniWM printed it,
because the machine riskell is written on has none of them installed. Synthetic fixtures prove the parsers; they cannot prove that the
real tools print that shape. Replacing them is the whole point of this page: record on a Mac that runs the window manager, commit the
file in place of the synthetic one, and remove that format's "synthetic" note from the top of its test file.

Record all the payloads of one manager **from the same moment**: they are one query round, and a fixture from a different state than its
neighbours makes a nonsense test.

## yabai

```
yabai -m query --displays > Tests/RiskellWMTests/fixtures/yabai-displays.json
yabai -m query --spaces    > Tests/RiskellWMTests/fixtures/yabai-spaces.json
yabai -m query --windows   > Tests/RiskellWMTests/fixtures/yabai-windows.json
```

- `yabai-displays.json` proves which display the bars live on: the one whose `frame` origin is the global origin, not the first entry in
  yabai's numbering (`YabaiQueryTests.testTheBarsLiveOnTheDisplayWhoseOriginIsTheGlobalOrigin`).
- `yabai-spaces.json` proves the kebab-case keys (`has-focus`, `is-visible`, `is-native-fullscreen`) and which spaces are on that display.
- `yabai-windows.json` proves the window fields (`app`, `title`, `space`, `display`, `is-minimized`, `is-floating`, `frame`) and the
  filters: another display, a minimized window and space `0` are not drawn.

Run `yabai -m query --windows` with at least one minimized window and one window on a second display, or the filters stay untested.

## AeroSpace

```
aerospace list-workspaces --all --json  > Tests/RiskellWMTests/fixtures/aerospace-workspaces.json
aerospace list-windows --all --json     > Tests/RiskellWMTests/fixtures/aerospace-windows.json
aerospace list-windows --focused --json > Tests/RiskellWMTests/fixtures/aerospace-focused-window.json
aerospace list-workspaces --focused     > Tests/RiskellWMTests/fixtures/aerospace-focused-workspaces.txt
aerospace list-workspaces --visible     > Tests/RiskellWMTests/fixtures/aerospace-visible-workspaces.txt
```

- `aerospace-workspaces.json` proves the `{"workspace": "..."}` shape and that a non-numeric name (`T`, `mail`, a named workspace) is not
  a rail entry.
- `aerospace-windows.json` proves `window-id`, `window-title`, `app-name`, `app-pid` and that `workspace` is a **string**: a window whose
  workspace is not a number is not drawn.
- `aerospace-focused-window.json` proves which window is focused. When no window has focus this call prints nothing, so the fixture for
  that case is `aerospace-focused-window-none.txt`, a zero-byte file: record it with the same command, focused on an empty workspace, and
  check it is empty (`wc -c`). `AeroSpaceQueryTests.testNoFocusedWindowLeavesEveryWindowUnfocused` is the test that reads it.
- the two `.txt` files are plain text, one workspace name per line, not JSON. Together they prove focused vs visible; if `--visible` lists
  the focused workspace too (it usually does), the test for a focused workspace missing from that list still covers the other case.

## OmniWM

OmniWM pushes its state over a unix socket, so a recording is a short subscription. Use its own name for the socket and the secret next
to it, and send the same request the app sends (`Sources/riskell/Services/Omni.swift`, protocol version 22):

```
sock="$HOME/Library/Application Support/com.barut.OmniWM/ipc.sock"
secret=$(cat "$sock.secret")
printf '{"id":"record","kind":"subscribe","payload":{"allChannels":false,"sendInitial":true,"channels":["layout-changed","windows-changed","focus","active-workspace"]},"version":22,"authorizationToken":"%s"}\n' "$secret" \
  | nc -U "$sock" | head -n 40 > /tmp/omni-lines.jsonl
```

The initial push holds one line per kind. Take one line for each fixture:

```
grep '"kind":"workspaces"'       /tmp/omni-lines.jsonl | head -n 1 > Tests/RiskellWMTests/fixtures/omni-workspaces.json
grep '"kind":"windows"'          /tmp/omni-lines.jsonl | head -n 1 > Tests/RiskellWMTests/fixtures/omni-windows.json
grep '"kind":"active-workspace"' /tmp/omni-lines.jsonl | head -n 1 > Tests/RiskellWMTests/fixtures/omni-active-workspace.json
grep '"kind":"focused-window"'   /tmp/omni-lines.jsonl | head -n 1 > Tests/RiskellWMTests/fixtures/omni-focused-window.json
```

- `omni-workspaces.json` proves the envelope (`kind: "event"`, `result.kind`, `result.payload.workspaces`) and that `display.isMain` marks
  the main display, with a workspace that names no display counting as main
  (`OmniRailTests.testAWorkspaceThatNamesNoDisplayCountsAsTheMainOne`).
- `omni-windows.json` proves the window fields (`id`, `windowId`, `pid`, `title`, `app.name`, `workspace.number`, `isScratchpad`,
  `display.isMain`, `frame`, `hiddenReason`, `mode`, `focusRank`) and the filters: a scratchpad window, a window on another display and one
  with no workspace are not drawn. Record it with a window on a workspace that is **not showing**: its parked `frame` is what the
  half-on-screen test is for.
- `omni-active-workspace.json` and `omni-focused-window.json` prove the two small payloads the focus rules are tested with.

The error and reply lines (`omni-failure.json`, `omni-command-reply.json`) come from a command with a bad name, sent on the command
connection the same way the app does it (`"kind":"command"`, `"payload":{"name":"no-such-command"}`).

## OmniWM's outer gaps

`Gaps.rewrite` rewrites the user's own settings file, so the fixture is a trimmed copy of one:

```
cp "$HOME/.config/omniwm/settings.toml" Tests/RiskellWMTests/fixtures/gaps-settings.toml
```

Trim it to the `[gaps.outer]` section, its comments, one neighbouring section and the surrounding order: that is what proves comments,
key order and section scoping. Keep a copy saved with CRLF line endings as `gaps-settings-crlf.toml` (an editor on Windows, or
`perl -pi -e 's/\n/\r\n/'`) – the rewrite must give each line its own ending back. A file with no `[gaps.outer]` section is the
`gaps-settings-no-outer.toml` case: riskell must leave it alone.

## Before committing a recording

- Run `scripts/scrub-check.sh`: it fails on home-folder paths, e-mail addresses and workspace ids in tracked files.
- Read the diff yourself: window titles, app names and workspace names are personal data too. Replace them with neutral ones where the
  test does not care (it asserts what it names), and keep the shape.
- Keep the file as the tool printed it, pretty-printing included: a reformatted payload stops proving what the tool actually prints.
