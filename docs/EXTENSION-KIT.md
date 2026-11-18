# RiskellKit: the extension design

How riskell is extended, and why it is shaped this way. The how-to is `docs/WRITING-EXTENSIONS.md`; the API is the [reference in the kit repository](https://github.com/rish139/riskell-kit/blob/main/docs/KIT-API.md)
(generated from the public symbols). This page is the reasoning and the status.

The four requirements, in the order they win a conflict: **robust, efficient, beautiful, easy**. Beauty and ease come from making the good
result the only easy one (the API has no way to say "wrong"), not from reviewing what people submit.

**Contents:** [Status](#status) · [Kinds](#1-kinds) · [How it loads](#2-how-an-extension-gets-into-the-app) ·
 [The API](#3-the-api) · [Robustness](#4-robustness) · [Efficiency](#5-efficiency-contract) ·
 [Beauty](#6-beauty-and-consistency) · [Open questions](#7-open-questions) · [Non-goals](#8-non-goals) ·
 [Measurements](#measurements)

## Status

| piece | state |
|---|---|
| RiskellKit, in [its own repository](https://github.com/rish139/riskell-kit) (tokens, primitives, reading renderer, popout hook, extension API, feeds) | built; the app depends on it by URL |
| the app draws pills and extension readings with the same kit code | built; snapshots identical to before the split |
| `reading` and `atom` extensions, linked through `extensions.lock.json` | built, tested end to end (`Examples/load-ext`) |
| built-in atoms moved out: every atom that ships with riskell is a package in `Packages/` (kit 0.2.0 `PopState`, 0.3.0 `env.config` and `env.cache`, 0.4.0 `Demo` and `onRightClick`, 0.5.0 `onScrollSteps` and `AppHooks`, 0.6.0 `WindowsModel`, `RailState` and `WindowActions`) | built; placed as `ext:clock`, an older layout.json's `clock` is read as it |
| `risk ext` (`validate`, `new`, `add`, `remove`, `list`, `search`, `info`, `update`, `publish`, `sync`) | built |
| `schemas/riskell-extension.schema.json`, `AGENTS.md`, `docs/WRITING-EXTENSIONS.md` | written |
| settings card in riskell preferences (EXTENSIONS) | built: `settings` in the manifest, written to `~/.config/riskell/ext/<id>.json`, applies at once; `riskell --ext-selftest` |
| disabling an installed extension from `config.json` (`disabledExtensions`) | built |
| the registry, the storefront and `risk ext publish` | built (`docs/STOREFRONT.md`); the CI render matrix is not |
| `behaviour` extensions from outside the app (the closed list in `Extensions/Extension.swift` is unchanged) | not built |

## 1. Kinds

An extension is a git repo with a `riskell.json` manifest (`schemas/riskell-extension.schema.json`: JSON Schema 2020-12, SemVer versions,
SPDX licenses). Its `kind` says what it adds. The kinds are open: a new kind is a new registration entry point in the app, not a rewrite.

| kind | adds | build | state |
|---|---|---|---|
| `pill` | a figure from a shell command or stream | no | yes (`docs/PILLS.md`) |
| `theme` | a Base16 palette | no | yes (`docs/THEMES.md`) |
| `preset` | layout + pills + theme + config fragment | no | the files exist; no bundle yet |
| `reading` | an atom fed by Swift; the kit draws both forms and the card | yes | yes |
| `atom` | an atom with its own SwiftUI | yes | yes |
| `behaviour` | a background capability with start/stop | yes | gestures only (closed list) |

`reading` is the one to prefer. Most useful atoms are "a number, a word, a gauge, a card of detail". If an author hands those over and the
kit draws them, the result matches the built-ins on every bar, theme and scale, with no layout code to get wrong. It is the compiled twin of
a pill, and it is literally the same renderer: a pill's JSON parses into the kit's `Reading`.

## 2. How an extension gets into the app

Compiled extensions are Swift packages linked into the one `riskell` binary (the xmonad model). Not `dlopen` (no stable Swift ABI, library
validation, notarization) and not separate processes (a process and IPC per extension against the efficiency rule).

- The kit is **its own repository** so the app can depend on extensions and extensions on the kit with no cycle. Both the app and every
  extension depend on it by URL and version (`.upToNextMinor(from: "0.6.0")`); they must use the same URL, or SwiftPM would see two `RiskellKit` modules.
- `extensions.lock.json` records what is installed (module, entry type, path or URL + commit). `risk ext sync` turns it into
  `Sources/riskell/Generated/InstalledPackages.swift` (the `import`s and the list of entry types) and into a literal block inside
  `Package.swift`. The literal is needed because SwiftPM caches a manifest by its own text: a manifest that reads the lock file at evaluation
  time works (verified), but is not re-evaluated when only the lock changes (verified, and it failed silently).
- A clean build with an extension takes about 35 s.

## 3. The API

One module, `RiskellKit`. If it is not in the kit's API reference, an extension cannot reach it: `Scale`, `Real`, `Display`, `Store`, `AppConfig`,
`NSScreen` and window frames stay inside the app. An extension never sees a pixel or a screen; lengths are design units and the app
multiplies by one scale factor where a number becomes a window frame.

- **Drawing:** `Pal` (colour tokens, `heat`, `calm`, `font`), `T` (type scale), `G` (`pill`, `strip`, `cardGap`, corner radii),
  `Num Cap Sep Bar VGauge Sparkline Rule Dot Sheen`, `.popout(...)`, `Tone`, `Reading`, `Metric`. There is **no colour parameter anywhere**:
  a tone is a role and the theme decides what it looks like.
- **Atoms:** `ReadingAtom` (yields `Reading?` values) and `CustomAtom` (both `horizontal` and `vertical` are required, so an atom without a
  vertical form does not compile), `Card`, `AtomMeta` (`id`, `name`, `priority`, `maxWidth`), `RiskellPackage`.
- **Boxes:** the app clips each form: a horizontal form is at most 36 tall and `maxWidth` wide, a vertical form at most 40 wide, and
  neither wraps text into two lines or pushes another atom off the bar (`WingRule` already hides by `priority`, shrinking to 0.8 first).
- **Waking up:** `env.every`, `env.watch`, `env.on(feed)` for readings; `env.repeating` for custom atoms (started in `activate`). An extension
  never makes its own timer, and the app cancels all of them while the atom is not on a showing bar. "Showing" is `BarActivity`
  (`ExtensionHost.swift`): a bar that is switched off, or hidden in a fullscreen Space, is only a window at alpha 0 with live views, so
  being on a bar was not enough. Found by a probe extension that counted its own productions: on a disabled bar it still ran (9 readings
  in 9 s); now it does not (0). Script pills use the same gate, which also makes the claim in `docs/PILLS.md` true for them.
- **Feeds:** `.battery .volume .focusedApp .spaces .minute`. A feed is a Combine sink on the app's own `Store`, so subscribing adds no
  polling. `.minute` is a timer that exists only while someone is subscribed. The built-in services (CPU/battery/volume,
  thermals, weather, Wi-Fi, AI usage) run only while an atom that needs them is placed on a bar that is on (`ExtensionHost.swift`'s `BarActivity`, which every package's atoms
  go through). The window manager and the notch wings' media feed are not gated by an atom.
- **Prefs:** `env.prefs.number/bool/string` from `~/.config/riskell/ext/<id>.json`.

## 4. Robustness

riskell is one process, so a crash in an extension is a crash of the bar. Measures:

1. A total API: `readings` cannot throw and views cannot fail; `nil` draws dimmed, as a failed pill does.
2. **A switch in the config file.** If an extension misbehaves, its id goes into `disabledExtensions` in `config.json` and riskell is
   restarted: its atoms are no longer registered and none of its code runs. No tooling is needed to recover from a bad extension.
3. A kit version gate (planned): an extension built against an incompatible major is skipped with a pill, never half-loaded.

A hung main thread cannot be rescued from inside the process; the way to keep one out is the efficiency contract below, checked before an
extension is listed.

## 5. Efficiency contract

Nothing runs unless it is on a bar that is showing. Proposed budgets, to be calibrated on real extensions before they become limits:

| measure | budget |
|---|---|
| an atom that is not on a bar | 0 wake-ups, 0 CPU |
| an atom on a bar, nothing changing | at most 0.1 % of a core over 30 s |
| wake-up rate | at most 1 per second unless a feed or a file event caused it |
| redraws | only the atom's own views (its own observable), never the whole bar |
| memory | at most 10 MB above the app without it |

Measured so far: see "Measurements" below.

## 6. Beauty and consistency

Three layers, the first two before any human looks:

1. **By construction** (section 3).
2. **A static check** in `risk ext validate`, with a rule id and a fix on every line: `no-raw-color`, `no-fixed-font`, `no-screen-api`,
   `no-own-timers`, `no-window-api`, plus manifest rules.
3. **A render matrix** (planned for the registry's CI), with the harness that exists (`--snap`, `--pop`, `RISKELL_FAKE_DISPLAY`,
   `RISKELL_SCALE`, `--check-fit`, `--check-panel`): displays (notch laptop, stock-mode notch, no-notch monitor, scale 0.75 and 1.5) × bars
   (top, bottom, left, right) × themes (the 11, or one light and two dark) × states (normal, blank, failed, longest text, widest digits, card
   open). Pass: both forms inside their boxes, nothing clipped that the box did not clip on purpose, contrast met (it is, by `Pal`), the card
   inside the safe area.

Stated plainly: the scale system has run on one machine so far (`docs/UNVERIFIED.md`). Opening riskell to other people's atoms will test
it harder; expect to find fit bugs in the app as well as in extensions.

## 7. Open questions

1. Does the render matrix run headless on a CI runner? `--snap` makes real windows; test before the registry's gate depends on it.
2. Feeds are not yet reference counted down to the services: a service runs if any of its atoms is placed, not per subscriber.
3. Text settings in the card (today the card offers number, bool and choice; text stays in the file).
4. Card size for `reading` is content-derived within a fixed width; do `atom` cards get a maximum?
5. `behaviour` extensions: a review policy for community code that touches input.
6. Publishing the kit as its own repository, and the package-identity rule that comes with it (section 2).

## 8. Non-goals

A permission system (nothing here is enforceable for compiled code, and the author does not want one); loading binaries at runtime;
out-of-process extensions; paid distribution.

## Measurements

Recorded in `docs/EFFICIENCY.md` under "Extension kit".
