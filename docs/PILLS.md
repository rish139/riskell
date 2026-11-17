# Script pills

A pill is an atom you define in `~/.config/riskell/config.json` with a shell command. No Swift, no rebuild: the config is applied live, open
riskell preferences (ctrl-alt,) and the pill is under **Not on a bar**, ready to place like any other atom.

```json
"pills": [
  { "id": "vpn",  "name": "VPN",  "run": "~/bin/vpn-status", "every": 10, "click": "open -a Tunnelblick" },
  { "id": "mail", "name": "Mail", "run": "~/bin/unread",     "watch": "~/Library/Mail/.unread" },
  { "id": "temp", "name": "Temp", "stream": "~/bin/temp-stream" }
]
```

A pill can also live in its own file: put `*.json` files in `~/.config/riskell/pills/`, each with one pill object or an array of them
(files are read in name order). They are picked up live, like the `pills` list in `config.json`.

| key | meaning |
|---|---|
| `id` | letters, digits, `-` `_`; unique. The atom is `pill:<id>`. |
| `name` | label in the editor and on the card (default: the id) |
| `run` | a command run on a schedule (run with `/bin/sh -c`; `~/` is expanded; PATH includes `/opt/homebrew/bin` and `/usr/local/bin`) |
| `stream` | a long-running command; every line it prints is a reading (see below). A pill has `run` **or** `stream`, not both; a pill with neither, or both, is ignored and logged |
| `every` | `run` only: seconds between runs (minimum 2, default 30 unless `watch` is set) |
| `watch` | `run` only: a file; the command re-runs when it changes (event-driven, no polling) |
| `click` | a command run when the pill is clicked; a `run` pill refreshes afterwards |
| `history` | how many of the pill's own `value`s riskell remembers for a sparkline, 8 to 120 (clamped) |

## What the command prints

Either **plain text**: the first line is the pill's text, any further lines become the hover card:

```
up 3d
load 1.2 0.9 0.8
```

or **one line of JSON**:

```json
{"text":"3%","icon":"internaldrive","tone":"ok","value":0.03,"lines":["Used 13G of 1.4T","Free 497G"]}
```

Every key is optional.

| key | what it does |
|---|---|
| `text` | the figure, at most 24 characters shown |
| `icon` | an SF Symbol name |
| `tone` | `ok` `warn` `crit` `accent` `dim` (any other value is the plain text colour) |
| `value` | 0 to 1: draws a gauge, and is the sample `history` remembers |
| `lines` | the hover card, at most 16 lines. A card opens only when there is something to show |
| `values` | up to 3 more figures drawn inline (below) |
| `spark` | a series of numbers drawn as a sparkline, the last 120 (below) |
| `grid` | two-column rows in the hover card (below) |

### `values`: more figures inline

```json
{"text":"62%","value":0.62,"values":[
  {"label":"CPU","text":"62","unit":"%","tone":"warn","value":0.62},
  {"label":"RAM","text":"48","unit":"%","tone":"ok","value":0.48},
  {"label":"TMP","text":"71","unit":"°C","tone":"crit"}]}
```

Each entry: `label` (a caption, 12 characters), `text` and `unit` (the figure, 10 characters, and its unit), `tone`, and `value` (0 to 1, a short
bar under the figure). On a horizontal bar the figures form a row after `text`; on a strip they stack in the 40 pt column, each caption over
its figure over its bar. A figure too wide for the column is cut off. More than 3 entries: the first 3 are drawn.

### `spark` and `history`: sparklines

Two ways to draw a line of numbers, both scaled to their own range, with the newest point marked:

- `"spark": [3, 5, 4, 8, 7]` in the reading: the command supplies the series (the last 120 numbers).
- `"history": 24` in the spec: riskell keeps the pill's last 24 `value`s itself, one sample a second at most (a stream's lines between
  samples are not kept). Nothing is saved to disk; a restart starts the history again.

When a reading has `spark`, that is drawn; otherwise the history, if the spec has one. Fewer than 2 points draw nothing.

### `grid`: rows in the hover card

```json
{"text":"3%","lines":["Used 13G of 1.4T"],"grid":[["Total","1.4T"],["Used","13G"],["Free","497G"],["Mount","/"]]}
```

Each row is `[label, value]`, shown as two columns under `lines`. At most 8 grid rows, and `lines` plus grid rows together at most 16. The
card's height follows its rows.

## Examples

**A streaming reading.** `stream` starts the command once, when the pill first shows on a bar, and keeps it running. This one prints the
time every second:

```sh
#!/bin/sh
# ~/bin/clock-stream
while true; do date +%H:%M:%S; sleep 1; done
```

```json
{ "id": "clock", "name": "Clock", "stream": "~/bin/clock-stream" }
```

A file watcher works the same way: `fswatch` prints a line per batch of changes, and each line is a reading:

```json
{ "id": "dl", "name": "Downloads", "stream": "fswatch -o ~/Downloads | while read n; do echo \"$(ls ~/Downloads | wc -l | tr -d ' ') files\"; done" }
```

**A multi-value reading.** Three figures on one pill, with a history of the headline value:

```sh
#!/bin/sh
# ~/bin/load-stream (one JSON line a second)
while true; do
  cpu=$(ps -A -o %cpu= | awk '{s+=$1} END {printf "%d", s}')      # whole percent, all processes
  frac=$(awk "BEGIN {printf \"%.2f\", $cpu / 100}")                 # 0.00 to 1.00 (a leading zero: valid JSON)
  printf '{"text":"%s%%","value":%s,"values":[{"label":"CPU","text":"%s","unit":"%%","value":%s}]}\n' "$cpu" "$frac" "$cpu" "$frac"
  sleep 1
done
```

```json
{ "id": "load", "name": "Load", "stream": "~/bin/load-stream", "history": 30 }
```

**A sparkline from the command.** A run pill whose series comes from the command itself, with a grid on the card:

```json
{ "id": "disk", "name": "Disk", "run": "~/bin/disk-info", "every": 60 }
```

where `~/bin/disk-info` prints `{"text":"3%","value":0.03,"spark":[12,15,11,9,10,8],"grid":[["Total","1.4T"],["Free","497G"]]}`.

## Rules it keeps

- A pill's command runs **only while the pill is on a bar that is showing**; take it off every bar and nothing runs. A `stream` pill's process
  starts with its first bar and is killed (with its direct child commands) when the last one goes; deeper grandchildren are not reached (see UNVERIFIED.md).
- A `stream` is **one long-running process**: no polling, no timer while it runs. Its lines are read as they come; the newest is shown at most
  10 times a second (4 a second for a rich one: with `values`, `spark` or `history`), so a fast stream costs at most that many redraws.
  Lines over 8 KB are dropped. A reading that draws the same as the one shown (values compared to 1/100) is not redrawn.
- riskell's exit kills every running stream with its children. A stream killed by a signal that riskell cannot catch (SIGKILL) is not
  reached; it then notices the closed pipe when it next writes.

**Measured** (riskell's own CPU time, `ps`, on a second instance; the numbers vary by about 0.3 s a minute between identical runs, so they
are rough): old pills only, 0.1 to 0.3 s a minute; three rich 1 Hz streams on three bars, about 1.4 s a minute. A `sample` of that instance
found only a few milliseconds a second in the pill code; the rest of the cost was not located. Three silent streams (no output at all)
cost about 0.65 s a minute, so the cost is not per line alone. This is above the target of 0.2 s per 20 s; see UNVERIFIED.md.
- A stream that exits is restarted after 1, 2, 4 ... seconds, at most 30 apart; a run that lasted 60 s or more starts the backoff again.
  While it is down the pill is dimmed.
- A `run` command runs off the main thread, one at a time, **killed after 10 s** (its child processes too), at most 8 KB read. Nothing with
  `every` is polled faster than every 2 s.
- A failed run, or a stream that is restarting, keeps the last reading and dims it. Its hover card then says **last updated Ns ago**, worked
  out when the card opens. A pill that never succeeded shows a dim "-".
- Both orientations are drawn for you: a row on a horizontal bar, a column at most 40 pt wide on a strip.
- The commands are yours, from your own config file. riskell never fetches or shares pills.
