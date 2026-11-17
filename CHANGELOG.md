# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Fixed
- The three-finger swipe could end up reversed until riskell restarted: its direction was guessed from the first Space change after a swipe, and a
  Space change from another cause close to a swipe taught it the wrong way. The direction now follows System Settings > Trackpad > Natural scrolling,
  read each time, and a Space that moves against a swipe is only noted in the log.

## [0.1.0] - 2026-11-17

### Security
- The AI usage atom reads no credential and makes no network request: it computes the Claude meters from Claude Code's own local session logs (token
  counts; an active 5-hour session and the last 7 days, measured against limits you set in `config.json` or your own 30-day peak). The first version
  read the Claude Code OAuth token from the keychain and called an unofficial Anthropic endpoint, which Anthropic's terms do not allow for third-party
  tools, and a provider that copied a browser's cookie database; both were removed before release, along with the OpenCode provider.
- `risk ext add` and `update` are strict about what they install: https repositories only (git's `ext::` transport, prompts and hooks are off), every
  field of a listing is checked, a pill or theme file must be a plain small regular file inside the repository, the registry index is fetched over
  https only, and installing someone else's code or a pill's shell commands needs your confirmation after you are shown the author, license, commit
  and commands (`--yes` for scripts).
- GitHub Actions are pinned to commits and run with a read-only token; Dependabot, CODEOWNERS and `scripts/harden-github` (secret scanning, push
  protection, private vulnerability reporting, fork-PR approval) are set up; `SECURITY.md` says what is built in and how to report.
- `scripts/release` makes a release only from a clean, checked main; `riskell --version` and `scripts/version-check.sh` keep one version number.

### Licensing
- The app is source-available under the PolyForm Noncommercial License 1.0.0; RiskellKit, `risk ext`, the schema and the examples are
  Apache-2.0. Contributions need a CLA. Added a Code of Conduct and a security policy.

### Added
- [`RiskellKit`](https://github.com/rish139/riskell-kit), a separate repository: the design tokens, the drawing primitives, the reading renderer, the popout
  hook and the extension API (`ReadingAtom`, `CustomAtom`, `Env`, feeds). Extensions depend on it alone.
- Extensions: compiled packages linked into the one binary through `extensions.lock.json`; atoms are placed as `ext:<id>`.
- `risk ext`: `validate`, `new`, `add`, `remove`, `list`, `sync`.
- `schemas/riskell-extension.schema.json`, `AGENTS.md`, `docs/WRITING-EXTENSIONS.md`, `Examples/load-ext`.

- riskell preferences: the layout editor is renamed, and an extension declares typed settings (`settings` in `riskell.json`: number, bool,
  choice) that appear in its EXTENSIONS card and apply at once. `risk ext validate` checks them; `riskell --ext-selftest` tests the write and rebuild.
- `listings/`: one registry listing for each built-in atom, `schemas/riskell-listing.schema.json`, `riskell --list-atoms` and
  `scripts/listings-check.sh`, which keeps the listings in step with the app.

### Added (the storefront)
- `risk ext search`, `info`, `add <name>`, `update [--yes]` and `publish`: extensions are found in a registry (`riskell-registry`, listings pinned to a
  commit, an `index.json` the client reads, `RISKELL_REGISTRY` to point elsewhere) and installed at the pinned commit; the manifest must agree with the
  listing. Pills and themes are files copied into the config folder and applied live (`~/.config/riskell/extensions.json` records them). `update`
  shows the change between the two commits and applies only with `--yes`. `risk` rebuilds only when `riskell-ext` exits 10.
- The registry repository: listing schema, `scripts/check-listing.py`, the index and storefront page builders, and CI (pull-request checks and GitHub Pages).

- Storefront pictures: listings carry a `preview` PNG (the manifest's `preview`, checked by `risk ext validate` and `publish`); `scripts/make-previews` renders them with riskell, for what ships with it
  (`docs/images/store/`).

### Fixed
- `risk ext new` scaffolded extensions that depended on RiskellKit 1.0, which does not exist, so they could not build; they now depend on the kit's
  current minor (`.upToNextMinor(from: "0.6.0")`, `"kit": "^0.6"`), as does `Examples/load-ext`.

### Changed
- Workspaces and the application icon are a package too (`Packages/windows`; `ext:workspaces` and `ext:appicon`; older layouts are read as them), so
  every atom that ships with riskell is a package on the kit and the application has no built-in atoms left. RiskellKit 0.6.0 adds `WindowsModel`
  (`WorkspaceInfo`, `WindowInfo`), `RailState` and `WindowActions` for the window manager, `PopState.chat` and `setHoldOpen`, and
  `KitHost.screenHeight`. The overview and the window-manager backends stay in the application.
- Volume and network are packages too (`Packages/volume`, `Packages/network`; `ext:vol` and `ext:net`; older layouts are read as them). The volume
  package owns the CoreAudio readers, the mixer taps and the microphone; the network package owns the Wi-Fi service (a Location grant restarts riskell
  through the kit's new `AppHooks`) and the live network card. RiskellKit 0.5.0 adds `View.onScrollSteps` and `AppHooks.restart`. The application's
  `Sys` keeps only the battery and volume that the `.battery` and `.volume` feeds read, started by their first subscriber, and the `Needs` table has
  no atom rows left. The network card reads its tab from `--pop net:<n>` itself.
- Battery, CPU and fans are one package, `Packages/system` (`ext:bat`, `ext:cpu`, `ext:fan`; older layouts are read as them). The package owns its
  samplers (CPU and memory, the smart battery, the SMC, the process list) behind one engine that runs only while one of the three is on a showing bar.
  RiskellKit 0.4.0 adds `PopState.setKeyable` and `refit`, `View.onRightClick` and `Demo` (the screenshot placeholders). The application's own `Sys`
  now reads only the battery and the volume, with no timer.
- An atom that draws nothing until its data arrives is now started: the host gives every custom atom a zero-size anchor, because an empty view never
  "appears". An extension subscribed to a feed keeps the service behind it running.
- Weather and AI usage are packages too (`Packages/weather`, `Packages/usage`, placed as `ext:weather` and `ext:usage`; older layouts are read as
  them). They read the location and the usage providers from `config.json` through the kit's new `env.config`, keep their caches in `env.cache`, and
  start only while on a showing bar. RiskellKit 0.3.0 adds `HostConfig`, `Env.config`, `Env.cache`, `PopState.open` and `.close()`, and
  `CustomAtom.isBlank(_ env:)`. The weather forecast parser keeps `riskell --weather-selftest`.
- The clock is the first built-in atom to move out of the application: a package, `Packages/clock`, installed by `extensions.lock.json` and placed as
  `ext:clock` (an older layout.json that says `clock` is read as it). The look is unchanged. RiskellKit 0.2.0 adds `PopState` for its
  two-stage date card. The clock now ticks only while it is on a showing bar, and the app's own minute timer wakes once a minute, not once a second.
- A custom atom's horizontal form hugs its content (at most `maxWidth`) instead of growing to the room the bar offers.
- Built-in services (CPU, battery, volume and microphone, thermals, weather, Wi-Fi, AI usage) start only while an atom that needs them is
  placed on a bar that is on, and stop when it is removed (`Services/Needs.swift`). A layout with no weather or network atom makes no request,
  and asks for no Location access.
- Script pills and extension readings are drawn by the same code (the kit's `ReadingBody` and `ReadingCardContent`). No pixel changed.

### Documentation
- A README with a full feature list, screenshots of everything, and a roadmap. The pictures come from `scripts/make-screenshots`, which
  renders them from fake data (a made-up wallpaper, fake workspaces, placeholder device and process names) so they can be made again.

### Fixed
- The overview is resolution-independent: every size in it follows the one scale factor, and it follows display changes.
- The weather card footer showed a hardcoded city; it now shows the place from `config.json`.
- Script pills (and extension atoms) no longer run while their bar is switched off or hidden by a fullscreen Space.
