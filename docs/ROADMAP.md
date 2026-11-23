# Roadmap

What is built is in `docs/ARCHITECTURE.md` and `docs/EXTENSION-KIT.md` (which has a status table); this is what is next, in the order it will be
taken. Nothing here is promised. riskell supports Apple silicon only.

## Next: bringing other setups here, Omarchy first

A setup written somewhere else should be bringable here, and what comes across should be checked rather than approximated. No second
runtime: no Qt, no QML, no web view. Ports are mechanical or algorithmic first; a coding agent handles the residual and is never a gate.

1. **Omarchy widgets and themes.** Its bar is Waybar, so this is the Waybar importer (`exec`, `interval`, streaming, `format`,
   `tooltip-format`, `on-click`, `format-icons`) and, harder, carrying the look across: the CSS styling of a module has to land on
   native pills and readings through the theme's tokens (`Pal`, `T`, `G`) and nothing else. That mapping is the design problem, so it is
   worked out on a few real widgets before any importer is written.
2. **BitBar/SwiftBar import** (`"format": "bitbar"` on a pill): line one on the bar, the rest in the card.
3. **One `risk port <repo>` command**, once a porting path works end to end. It says plainly what it could not carry over.
4. **Presets as a file**: layout, config, pills, theme and extension locks in one file that can be shared and applied.
5. **Themes**: `risk theme` (list, check, import) exists as a developer command; fetching and exporting schemes waits until themes are
   taken up again.

`derivedFrom` provenance is already enforced by `risk ext validate`: a port that does not say where it came from is refused.

## Before a wider release

- Verification on other Apple-silicon Macs and window managers ([`UNVERIFIED.md`](UNVERIFIED.md)): yabai, AeroSpace, command actions, other
  displays, macOS 14 and 15, a clean-machine install.
- `behaviour` extensions from outside the application: the kind is built and `risk ext add` installs one, but scaffolding (`risk ext
  new behaviour`) and listing wait for a review policy.
- A CI step that builds `riskell-ext` from a pinned commit, instead of the registry's current unpinned `main`.

## Later

- **The notch** beyond its media wings (a shelf, a quick-action dock, timers, an expanded media panel): parked until it has been designed.
- **CI that renders every listing** across displays, bars and themes, with the images attached to the pull request. It is not possible on a
  runner as the code stands, and this is measured rather than assumed: the pictures are rasterised from real panels that must be in ordered
  windows, which needs a logged-in Aqua session, and the overview's screen capture additionally needs the Screen Recording permission
  ([`ARCHITECTURE.md`](ARCHITECTURE.md), `main.swift` and `Services/Capture.swift`). Images are rendered by the maintainer, so no listing
  claims to be rendered on CI.
- An in-app browse card in riskell preferences.
- Draw the clock drain and the CPU deck with Core Animation layers (about 0.8 % of a core). Open cards are the biggest cost now
  ([`EFFICIENCY.md`](EFFICIENCY.md)).
- Catalogue additions, when someone asks for one: brightness, Bluetooth device battery, disk, input language, a system monitor, `homebrew
  outdated`, docker/k8s context, VPN, git status, GitHub notifications.

## Constraints

- **No second runtime.** No Qt, no QML, no web view, no second process for a widget.
- **No `.dmg` and no notarisation.** A Homebrew build from source, or a bottle, is the distribution.
- **No closed "Pro" fork.** A paid build of the whole application is possible under the licence and the CLA; a crippled free edition is not.
- **No bulk auto-port.** A few at a time, each checked and pictured.
- **No auto-import and no auto-update** of community code: show the commands, ask, then act.
- **No telemetry**, and therefore no install counts.

## Done

- `risk` is one command line in one terminal style: thirteen commands, a screen per command drawn from the theme in force, an error form
  that says what is wrong and what to try, `--json` on reads, documented exit codes, `--dry-run` where something writes, and no output
  that is not meant for a person when it is piped. The commands are in [`CLI.md`](CLI.md); `risk status` is one screen and `risk status
  --all` is every check. `snap`, `bench`, `theme`, `fit` and `self-test` run as developer commands and are not listed.
- A test target for the window-manager parsers with recorded payloads (`Tests/RiskellWMTests`), and a contract test for the command line.
- Every atom is a package: clock, weather, AI usage, battery, CPU, fans, volume, network, workspaces and the application icon all live in
  `Packages/` on the same kit extensions use, are listed in `listings/` ([`scripts/listings-check.sh`](../scripts/listings-check.sh) keeps the
  two in step), and start nothing until they are on a showing bar. The kit grew for it: `PopState`, `env.config`, `env.cache`, `Demo`,
  `onRightClick`, `onScrollSteps`, `AppHooks` and the window-manager API.
- riskell preferences: the panel is renamed, and an extension declares typed settings in its manifest (`settings`: number, bool, choice) that
  appear in its EXTENSIONS card and apply at once. Text settings stay in the file for now.
- The registry and storefront ([`STOREFRONT.md`](STOREFRONT.md)): `risk ext search`, `info`, `add <name>`, `update`, `publish`, the
  riskell-registry repository with its checks, and a static storefront page.
- The repositories are public (kit, riskell, registry, tap); 0.2.1 is the current release under FSL-1.1-MIT ([`LICENSING.md`](../LICENSING.md)).
- The extensibility gaps are inventoried in [`EXTENSIBILITY-GAPS.md`](EXTENSIBILITY-GAPS.md) — window-manager backends, the notch, the overview,
  the gesture and behaviour route, and more — and each row says what opening it would take.
