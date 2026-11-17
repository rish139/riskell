# Efficiency

riskell runs all day, so what it costs at rest is a feature. The rules, what was measured, and how to measure again.

## Rules
- **Event-driven.** Kernel file events (config, themes, pills), sockets, notifications. A repeating timer needs a reason that is true right now.
- **Off means nothing runs.** A pill that is on no bar runs no command. Gestures off start no event tap and no trackpad reader. A card that is
  closed is not built. A stream pill is one long-lived process, never polled. A built-in service (CPU and battery, thermals, weather, Wi-Fi, AI usage)
  runs only while an atom that needs it is placed on a bar that is on (`Services/Needs.swift`). Measured with `scripts/idle-cpu`, two runs each, the same
  binary: the author's full layout used 0.26 and 0.28 s of CPU over 30 s; the same layout with only the clock placed used 0.13 and 0.12 s.
- **Setters ignore unchanged values**, so a reading that did not change redraws nothing.
- **Measure, then change.** Every efficiency change is an A/B on the same binary with `scripts/idle-cpu` (three runs per variant) and a profile.

## What runs at rest (the author's layout, 14" notch display)
| Source | Cadence | Cost |
|---|---|---|
| Clock drain (seconds bar) | 1 s | about 0.4 % of one core: a SwiftUI update of the top bar's host each second |
| CPU widget (cores, RAM, power) | 2 s | about 0.4 %: one update of a larger view with its bar animations |
| Fan history (SMC read of every sensor, to average the groups) | 10 s | about 0.1 %: ~60 keys at ~0.2 ms each |
| System sampler (CPU, power) | 2 s | about 0.1 % |
| Window-server scan for Picture-in-Picture windows | on a click, an app change or a Space change, then 0.3 s for 2 s; 5 s safety net | about 0.03 % (was 3.3 scans a second, about 0.4 %) |
| Everything else (battery, volume, network, weather, usage) | event-driven or minutes | under 0.1 % together |
| Floor with no widgets at all | | 0.17 % (0.05 s per 30 s) |

Total on the author's layout: about 0.3 s of CPU per 30 s, 1.0 % of one core, 105 MB resident, 8 threads, no idle wake-ups counted by `top`.

## Findings (2026-11-16)
- A **polling window-server scan** was the single biggest waste: a full window list every 0.3 s forever. It is now event-driven (`pipKick`, `pipSchedule`
  in `main.swift`). A window named "Picture in Picture" opened with no user action is caught within the 5 s safety interval, usually sooner; once one
  exists the scan follows it every 0.3 s, and the bar drops back 0.3 s after it closes (`RISKELL_TEST_PIP=1` opens a fake one to test this).
- **A SwiftUI update costs about 4 ms** whatever it draws (the layout pass of the hosting view plus the Core Animation commit). The remaining idle cost
  is therefore the number of updates per second, not the drawing. An experiment replacing the clock drain's Canvas with plain shapes made no
  measurable difference (0.19 / 0.23 s against 0.19 / 0.14 s per 30 s, noise of about 0.04), so it was not kept.
- **The forecast parser was quadratic.** `WeatherService.parse` converted each of 14 hourly and 17 daily columns from Foundation to a Swift array
  again for every row (bridging copies the whole array), so one fetch cost about 5,500 array copies. Hoisting the columns out of the loop makes it
  28x faster on a realistic forecast (2.6 ms against 73.9 ms) with identical results; `riskell --weather-selftest` proves that on every build.
- **Script pills:** idle and silent streams cost nothing (same as no pills); a rich stream line costs about 4 ms (three rich 1 Hz pills add about 1.3 % of a core).
- **Not changed, on purpose:** the fan history read (thinning the sensors would change the numbers on screen) and the clock's once-a-second drain
  (its visible stepping is the feature).

## Ideas that would cut the rest, and their price
- Draw the clock drain with Core Animation layers instead of SwiftUI (one discrete keyframe animation per minute): removes the 1 Hz update, saves up to
  0.4 %, but is a redraw of a visible element that has to be pixel-matched, including its hover spring.
- The same for the CPU widget's core deck and power trace: up to 0.4 %.

## Measuring
```
scripts/idle-cpu "label" layout.json config.json     # CPU seconds over 30 s, for a scratch instance
/usr/bin/sample <pid> 25 -file out.txt                 # a profile (the `sample` on PATH may be a different tool)
```
Compare variants of the same layout (for example without the clock) to find what an element costs; the floor is the empty layout.

## Extension kit (2026-11-16)

Splitting the design tokens, primitives and reading renderer into RiskellKit, and moving pills onto the kit's `Reading`:
- **Pixels:** every bar, the pill cards, the battery and vitals cards and the settings panel match a build of `main` except for live data
  (power draw, battery level, clock), which also differs between two runs of `main` itself.
- **Idle CPU** (`scripts/idle-cpu` method, same scratch fixtures, CPU seconds over 30 s, three runs each): `main` 0.27, 0.31, 0.62 (the last
  was disturbed by other work on the machine); kit 0.37, 0.31, 0.34. No change at this method's noise (about 0.04 s).
- **Two installed extension atoms** (a reading on a 5 s `env.every` and a custom atom on a 3 s `env.repeating`, both on a bar): 0.38, 0.40,
  0.45 s, about 0.06 s over 30 s more than the kit alone (0.2 % of a core).
- **Atoms off a showing bar:** a probe extension (a reading every second) and a probe pill (a command every 2 s) were each placed on the top
  bar and on a switched-off right bar, 9 s runs. On the top bar: 9 readings, 5 runs. On the switched-off bar before the fix: 9 and 5 (a
  bar that is off is a window at alpha 0 with live views, so `onAppear` fired anyway). After the fix (`BarActivity`: an atom attaches only
  while its bar shows; a fade-out is waited out, 0.3 s): 0 and 0. Fullscreen Spaces hide the bars the same way and now stop them too.
