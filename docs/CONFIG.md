# config.json

riskell's settings file is `~/.config/riskell/config.json` (`RISKELL_CONFIG` points a second instance at another one). It is watched and applied live, except `wm`, which needs `risk restart`. A missing file means the defaults; a file that is not valid JSON is ignored until it is valid again. The layout (which atom is on which bar) lives in `layout.json`, not here.

## The keys

| Key | Meaning |
|---|---|
| `wm` | Window manager: `"auto"` (default), `"omniwm"`, `"yabai"`, `"none"` or `"command"`. |
| `theme` | Colour scheme id (bundled or a file in `themes/`). The editor's theme picker writes it. |
| `scale` | Layout scale. Absent = automatic from the bar's height. Applies on restart. `RISKELL_SCALE` overrides it. |
| `spacing` | Edge gap, window gap and corner roundness (below). Absent = the defaults. Applies live. |
| `disabledExtensions` | A list of ids of installed extensions (as `risk ext list` prints them) that must not load, for example `["gpu-load"]`. Read at launch: restart after changing it. The way back from an extension that misbehaves. |
| `location`, `pills`, `wmCommand` | Weather, script pills, the command backend (see the other docs). |
| `usage` | `"claude": true` turns on the usage atom, which reads Claude Code's local session logs (token counts only; no credentials, no network). Two optional numbers set the gauge limits: `"fiveHourTokens"` and `"sevenDayTokens"`. Absent, each gauge is measured against your own 30-day peak. Any other key here, such as an old `opencode` block, is ignored. Applies live. |

## `spacing`

All values are design units (the layout's own units; the scale multiplies them for the windows). Each is optional; a value outside its range is clamped.

| Key | Default | Range | What it is |
|---|---|---|---|
| `edgeGap` | 8 | 4 to 24 | Gap from a bar to the screen edge. |
| `windowGap` | 6 | 0 to 24 | Room between a bar and the tiled windows (the window manager's outer gaps, see BARS.md). |
| `radius` | 11 | 6 to 18 | Corner roundness of islands and bars; cards use radius + 2. |

```json
{ "spacing": { "edgeGap": 12, "windowGap": 8, "radius": 14 } }
```

The island gap is not in this file: it is the layout's `gap` in `layout.json` (2 to 16, default 8), changed with the editor's SPACING & SIZE card.

## `scale`

A number from 0.5 to 2.0 in steps of 0.05, or absent for automatic. The editor's SPACING & SIZE card writes it; it applies on the next launch.

```json
{ "scale": 1.25 }
```

## Editing by hand

Save the file and the change applies within about a third of a second. A file that is not valid JSON is ignored until it is fixed.
