# Architecture

How the code is laid out, the checks and test hooks, and the extension kit. (The design of the kit is `docs/EXTENSION-KIT.md`; what is
next is `docs/ROADMAP.md`; what has not been tested on real hardware is `docs/UNVERIFIED.md`.)

## Code map
- `Sources/riskell/`: the app. `main.swift` wires everything (panels, hosts, services). `Frame.swift` (host-only `G` geometry), `Layout.swift`
  (`Config`: bars, islands, hug/floating, card style, saved to `~/.config/riskell/layout.json`), `Registry.swift` (the ONE list of atoms and
  their cards), one `*Atom.swift` and `*Card.swift` per widget, `Popout.swift` and `ChatCard.swift` (the single popout host and the chat-card
  geometry), `Bars.swift` (HBar/VBar), `EditMode.swift` + `SettingsCards.swift` (riskell preferences: the layout editor and its panel), `Scale.swift` + `Display.swift` +
  `WingFit.swift` (one scale factor, the screen/notch model, top-bar fitting), `Spacing.swift`, `Overview.swift` (the workspace overview),
  `Wings.swift` (notch wings), `PillAtom.swift` (script pills and extension readings), `ExtensionHost.swift` (the app's side of the kit).
- `Services/`: data and system access. `AppConfig.swift` (`~/.config/riskell/config.json`), `ConfigWatcher.swift` (live reload of config, pill
  files, theme files), window-manager backends (`Omni`, `Yabai`, `AeroSpace`, `CommandWM`, `NoWM` behind `WindowManager`), `Pills.swift`,
  `Sys` (battery and volume), `Wifi`, `Audio`/`Mixer`, `NowPlaying`, `Compat.swift` (version pill and checks).
- `Packages/`: the atoms that have moved out of the app, each a package on the kit and installed by `extensions.lock.json`: `clock`, `weather`, `usage` and `system` (battery, CPU and fans, one package because their cards read each other's numbers).
- `Extensions/`: optional behaviours with a start/stop lifecycle. `Gestures/` (Touch, ScrollGuard) is off by default and starts nothing when off.
- `Themes/`: Base16 schemes (generated `Schemes.swift`), `Theme.swift` (derivation with enforced contrast), `ThemePicker.swift`.
- RiskellKit ([its own repository](https://github.com/rish139/riskell-kit), Apache-2.0): design tokens `Pal`/`T`/`G`, the drawing primitives, the `Reading` renderer, the
  popout hook, `ReadingAtom`/`CustomAtom`/`Env`/feeds. The app depends on it by URL (`Package.swift`); so does every extension. To change the
  kit and the app together, check the kit out next to this repository and run `swift package edit riskell-kit --path ../riskell-kit`
  (`swift package unedit riskell-kit` to go back).
- `Sources/riskell-ext/`: the extension CLI, run as `risk ext` (`validate`, `new`, `add`, `remove`, `list`, `sync`). `extensions.lock.json` and a generated block in
  `Package.swift` link installed extensions into the binary; `Sources/riskell/Generated/` holds the generated import list.
  `Examples/load-ext` is the working example; `schemas/` holds the manifest schema.
- `Sources/riskell-setup/`: the guided terminal installer, a second small executable (Foundation only).
- `scripts/`: `risk` (control script: install, dev, restart, log, status, wm, ext), `idle-cpu`, `scrub-check.sh`, `try-installer`, generators.

## Rules the code keeps
- **Efficiency:** event-driven; nothing runs while it is switched off. Pills and extension atoms run only while their bar is showing
  (`BarActivity`). Measure idle CPU before and after a change (`scripts/idle-cpu`, `/usr/bin/sample`); results are in `docs/EFFICIENCY.md`.
- **A refactor changes no pixel:** take snapshots from `main` first, compare after; only ticking widgets (clock, battery, cpu, network, fan)
  may differ.
- **Resolution independence:** views lay out in design units (`G`, `T`); only the window layer uses real points (`Real`, `Scale`).
- Colours only through `Pal`, type only through `T`.

## Checks and test hooks
`riskell --key-test`, `--check-fit` (needs `RISKELL_LAYOUT`), `--check-panel`, `--check-themes`, `--list-themes`, `--gestures-fix|restore`
(dry run without `--yes`), `riskell-setup --self-test`, `Tests/installer/pty_flow.py`, snapshot flags (`--snap`, `--pop <card>`,
`--settings`, `--edit`), environment: `RISKELL_FORCE_HOT=<card>[,<card>]` (hover through the real path), `RISKELL_FAKE_DISPLAY`
(`1512x982:notch=32,185`), `RISKELL_SCALE`, `RISKELL_TEST_PIP`, `RISKELL_PANEL_DEBUG`, `RISKELL_SNAP_DIR` (where the `overview-snap` socket command writes), `RISKELL_CACHE_DIR` (where the weather cache lives, so a
test instance never touches the real one), `RISKELL_WALLPAPER` (a picture to use as the overview's wallpaper), `RISKELL_DEMO` (placeholder names
for devices, volumes, processes and addresses, and a minute of sample history for the CPU, network and volume graphs; `--fake-heat` seeds the
fan history), `scripts/overview-check`
(the overview at three scales on a scratch instance).

A second instance for testing, which never touches the running bar or OmniWM's gaps:
`.build/release/riskell --no-usage --no-reserve --no-claude --fake-usage --fake-media --snap DIR --stay 6`, with `RISKELL_CONFIG` and
`RISKELL_LAYOUT` pointing at scratch copies. **Pass `--no-reserve` as a separate argument**: it is what stops the instance from rewriting
OmniWM's `gaps.outer`.
