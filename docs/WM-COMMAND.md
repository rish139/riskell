# The `command` window manager backend

Any tiling manager, or a plain script, can drive riskell's workspace rail through your own commands. No Swift, no rebuild. Set
`"wm": "command"` in `~/.config/riskell/config.json` and describe the commands in `wmCommand`:

```json
"wm": "command",
"wmCommand": {
  "state": "~/bin/wm-state",
  "focusSpace": "~/bin/wm-focus {space}",
  "focusWindow": "~/bin/wm-focus-window {window}",
  "closeWindow": "~/bin/wm-close {window}",
  "moveWindow": "~/bin/wm-move {window} {space}",
  "every": 5
}
```

| key | meaning |
|---|---|
| `state` | **required.** Prints the manager's state as one line of JSON (below). |
| `focusSpace` | run with `{space}` = workspace number |
| `focusWindow` | run with `{window}` = window id |
| `closeWindow` | run with `{window}` |
| `moveWindow` | run with `{window}` and `{space}` |
| `every` | optional. Seconds between state reads, 2 at least. Leave it out for purely event-driven updates. |

An absent action is a no-op. `{space}` and `{window}` are replaced by integers only, so nothing else can be injected. Commands run with
`/bin/sh -c`, `~/` is expanded, PATH includes Homebrew, and each command is killed after 10 s. A failing or invalid `state` keeps the last
good state. A missing `state` at start runs the plain `none` backend and logs one line.

## The `state` JSON

```json
{"spaces":[{"id":1,"focused":true,"windows":2},{"id":2,"windows":0}],
 "windows":[{"id":123,"pid":456,"app":"Safari","title":"Docs","space":1,"focused":true}]}
```

- `spaces[]`: `id` (required), `focused`, `windows` (count; if absent, counted from `windows[]`). Every rail workspace is listed.
- `windows[]`: `id` (required), `pid`, `app`, `title`, `space` (the workspace number), `focused`.
- Unknown keys are ignored. Everything but `id` is optional. Print it on one line (the first line is read).

## Worked example

A hypothetical manager `zz` with `zz list --json` (workspaces and windows) and `zz focus N` / `zz send ID N` / `zz kill ID`:

```sh
#!/bin/sh
# ~/bin/wm-state: the state line riskell reads
zz list --json | jq -c '{
  spaces: [.workspaces[] | {id: .n, focused: .active, windows: .count}],
  windows: [.windows[] | {id: .id, pid: .pid, app: .app, title: .title, space: .ws, focused: .focused}]
}'
```

```sh
#!/bin/sh
# ~/bin/wm-focus: $1 is the workspace number
exec zz focus "$1"
```

Then `wmCommand.state` is `~/bin/wm-state`, `focusSpace` is `~/bin/wm-focus {space}`, and so on.

## Instant refresh from your manager's own events

riskell reads the state on start, on each macOS Space change, after each of its own actions, and when a script writes the word `wm` to
its event socket. Hook your manager's events to that word so changes show at once:

```sh
printf wm | nc -U -w1 ~/.cache/riskell/ev.sock
```

For example, in a manager's event hook or a `yabai`-style signal: `zz on-change 'printf wm | nc -U -w1 ~/.cache/riskell/ev.sock'`.
A burst of requests becomes one read 50 ms later, and one read runs at a time.

## Efficiency

- **Event-driven.** No polling unless `every` is set. With events and no `every`, riskell runs `state` only when something happened.
- **`every` is a floor of 2 s.** Use it only for managers with no events to hook.
- **Changes only.** A read publishes to the rail only when the result differs; an unchanged state costs one short process run.
- **Off the main thread.** Every command runs on one serial queue, so the bars never wait on your script.

## Live changes

Editing `wmCommand` in config.json applies at once (the timer and the commands change, nothing restarts). Changing `wm` itself needs
`risk restart`.

## What the backend does not do

It draws no window frames (the overview lays windows out itself), it does not own the 3-finger swipe (riskell's own swipe switches the
rail), and it does not reserve gaps (the manager owns its own outer gaps). `moveToNewSpace` passes the number after the last shown
workspace to `moveWindow`; your script decides whether that creates one.
