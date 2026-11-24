# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Added
- `risk ext add --ship` and `risk ext remove --ship` write the tracked `extensions.lock.json`: the way a maintainer adds a package that ships
  with riskell, or takes one out.
- A behaviour's hook can name a binding mode (kit 0.8.0 `ManagerHook.bindingMode`), and the AeroSpace backend puts the manager in it while the behaviour
  runs, again after the manager restarts, and back in `main` when the behaviour stops or riskell quits. dwindle-aerospace's keys (the move keys and the
  tidy key, bound to `true` for it to act on) are in a `riskell` mode, and `main` keeps the plain keys, so AeroSpace is usable whenever riskell is not
  running; `aerospace mode main` restores them by hand. Reloading the AeroSpace config keeps the mode and moves no window.
- AeroSpace backend is a native socket client. One connection receives focus, workspace and window events, another sends commands, and
  no process starts per event, so the `exec-on-workspace-change` and `on-focus-changed` callbacks are no longer needed. Gestures under
  AeroSpace work too: AeroSpace has no swipe, so riskell sends the workspace switch and holds it until AeroSpace confirms.
- AeroSpace frame layer: AeroSpace reports no window frames, so riskell remembers each window's frame while it is on screen and works out
  an equal split for the rest. `aerospace.gaps` in `config.json` chooses who
  writes the outer gaps: `"riskell"` (the default) rewrites them in `aerospace.toml` and reloads AeroSpace, `"manual"` only reports drift.
- `risk wm use <omniwm|aerospace|none>` switches the window manager without touching either manager's own settings. It prints the plan
  unless `--yes` is given.
- `behaviour` packages (kit 0.7.0): an installed package's behaviours run in the background while riskell runs the window manager they name,
  and one that conforms to `ManagerHook` adds the manager's own commands to the request riskell was about to send, so the manager lays the
  windows out once instead of once per command. A behaviour's settings are its package's, and a change in the extensions card restarts it.
  `risk ext add` installs one; `risk ext new behaviour` stays closed until there is a review policy.
- The AeroSpace backend tells hooks when a window has arrived on a workspace (`window-arrived`): a window that moved, or that stopped
  floating, as one of its own queries reports it. A window riskell moves itself is announced in the same request as the move.

### Changed
- `risk ext add` and `risk ext remove` no longer touch a tracked file. A compiled package installed for local use goes into
  `extensions.local.json` and the generated module `Local/Sources/RiskellLocal/`, both git-ignored; `Package.swift` reads the local record,
  so a build passes `--manifest-cache none` (`scripts/risk` does), and the app links that module only when it is there, so a clean clone
  builds exactly as before. `risk ext sync` regenerates the tracked files and `Local/`; with nothing local, the folder goes.
- The AeroSpace backend asks less. The window server is asked about riskell's own windows (`CGWindowListCreateDescriptionFromArray`) and no longer
  lists every window on the system for each focus event: a call costs 1.1 ms instead of 3.2 ms here, and 20 focus events took 30 ms of waiting
  instead of 91. A binding of `resize`, `balance-sizes` or `fullscreen` no longer makes riskell query AeroSpace afterwards (a held resize key
  sent 19 requests a second, each making AeroSpace lay out the windows, for rows that hold neither sizes nor the fullscreen flag).
- The AeroSpace workspace rail is contiguous, as OmniWM's was: it runs from 1 to the five that always show, the highest workspace with a window, or the
  focused one, whichever is furthest, with the empty ones in between as dim beads. It used to skip workspaces (`1 2 3 4 5 8` with the focus on
  eight), so the capsule jumped instead of stepping through the empty ones. The beads of a workspace that joins or leaves fade on the capsule's own spring, and the
  island around a vertical rail is given that spring for a change in the number of spaces. SwiftUI animates each view's size with the animation in
  force at that view, so the rail's own animation never reached the island: it jumped to its new size at once and, on the way back in, cut across
  the capsule that was still moving.
- The top bar waits for a menu of the menu bar. With the menu bar set to hide itself, a menu opened from it (File, the Apple menu) or the panel
  of one of its extras (the Control Center) keeps the menu bar out however far down the pointer goes, and the top bar used to come back on top of
  it as soon as the pointer left the notch-height stripe. The top bar and the strips' top widgets now stay down while such a menu is open, and until
  the menu bar has slid away after it closed. The window server says when: the menu bar's own window is on screen, and a pop-up window is open on
  this display. It is asked every 0.1 s only while a menu is open, so nothing runs otherwise. A panel that opens at another window level than a
  menu's is not seen, and the top bar comes back as it did before.
- `risk status` follows the window manager that `wm` selects, not only OmniWM.
- AeroSpace backend asks it less. A refresh is one request instead of two, a command and the queries that read back what it did are one
  request too, and an event that already names what changed (a focus change, a workspace switch, a navigation keybinding, a volume or
  echo binding) is applied to the last answer instead of being asked about. Every request makes AeroSpace lay out the visible windows and refresh what every app
  holds, so a focus change no longer costs it anything. A workspace switch riskell sends itself asks for the rows once: the check a second
  later now runs only while AeroSpace has not confirmed the switch. The workspace query also reads the layout of each workspace's top
  container, and the backend reads the screens on the main thread to say whether a workspace's display is landscape; both are what a hook
  decides from.

## [0.3.1] - 2026-11-23

Fixes from a week of daily use, and full-screen apps in the overview.

### Added
- The overview lists apps in native full-screen Spaces (a game, a full-screen browser) as small window tiles in a row below the find
  field, with the window's picture when it can be captured and the app's icon when not. A click goes to that app's Space.
- A four-finger swipe up opens Mission Control, and a four-finger swipe down closes the one the gesture opened. A fourth finger landing in
  a three-finger swipe now cancels that swipe instead of committing it.

### Fixed
- Live window streams could keep running after the overview closed (a close that arrived while the streams were still starting left the
  late ones capturing the screen, with the recording indicator on and about 8 % CPU). A stop now stops every stream of its start.
- The overview takes the first click again after a workspace change, and keeps keyboard focus; each press is logged with what it hit.
- The Claude usage figure keeps the last real percentages, dimmed, when the limits request fails, instead of falling back to tokens. A
  null five-hour or seven-day window no longer rejects the whole response.
- A floating strip no longer takes the pointer over the gaps between its islands, so the Dock and the apps below are reachable there.
- When the auto-hidden menu bar is out, the top bar sits under it and comes back only after the pointer leaves the menu bar's stripe;
  the widgets at the top of the side strips step down clear of it.

## [0.3.0] - 2026-11-23

`risk` is now a command line you can use and script: thirteen commands, one terminal style, JSON where a program reads it.

### Added
- `risk status` is a health report: the binary and signature, the launch agent, the font, the socket, the window manager and its protocol,
  gap drift, gesture conflicts, versions against the verified record and permissions. The rows only the running app knows come from the
  app. `--json` is for programs, `--check` is the installer's checklist, and `--bundle` writes one redacted report to attach to an issue.
- `risk log` and `risk ctl` print the log and send a word to the running bar, so scripting does not start with `tail` or `nc -U`.
  `risk config` reads and changes settings without hand-edited JSON (`path`, `show`, `get`, `set`, `edit`).
- `risk help`, the shell completions and `docs/CLI.md` are all generated from one command table. The JSON the commands print has schemas
  under `schemas/`, with documented exit codes (`10` rebuild needed, `2` usage, `1` failure).
- `risk ext validate` checks `derivedFrom`, the manifest block that says where a ported extension came from (repository, revision, licence
  and authors), and refuses one that is incomplete. The rule runs in CI.
- A test target for the window-manager parsers, with payloads recorded from real installs, and a contract test for the command line whose
  screens are recorded, so a change to one is a diff.
- Developer commands that are not listed in `risk help`: `risk snap` (renders the picture set), `risk bench` (measures the efficiency
  table), `risk theme`, `risk fit` and `risk self-test`. `risk gallery` draws every screen from fixed data.

### Changed
- The user CLI is thirteen commands: `install`, `uninstall`, `dev`, `status`, `log`, `ctl`, `setup`, `config`, `gestures fix`, `gestures
  restore`, `ext`, `completions` and `help`. `theme`, `snap`, `bench`, `fit`, `self-test`, `version`, the `wm` commands and `gestures
  status` still run but are no longer listed, and `risk status` shows the gestures and window-manager state.
- Every command is drawn in one terminal style, in the theme in force: a masthead with the riskell mark and the agent's state, section
  rules, one row shape for a check, a hint under anything that needs a command, a health bar, a `next` line, and one form for errors that
  says what is wrong, the command's synopsis and what to try. It has an ASCII form for terminals without UTF-8 (`RISKELL_ASCII=1`), wraps
  instead of cutting, and prints no colour, spinner or carriage return when the output is not a terminal. The guided installer, the app's
  own flag reports and the self-tests use it too.
- `risk status` is one screen: a line per section with each check's name coloured by its state, detail and a fix only for what needs
  attention, then the summary. `risk status --all` lists every check.
- `risk help` groups commands as run, look, change and extend. A bare `risk config`, `risk ext` or `risk ctl` opens its help page, and a
  mistyped command or flag prints the error form instead of a bare `usage:` line.
- `risk install`, `dev` and `uninstall` show their steps, with a spinner on a terminal and, when one fails, its last lines in an error
  block. `uninstall` asks first on a terminal and refuses without `--yes` when it cannot ask. It no longer lists `--all` and
  `--keep-config`, which it never honoured.
- `risk ctl --list` is a line per group of words (`--list --all` has what each word does), `risk ext list` and `search` show each
  description in full, `risk config path` marks which files exist, and `risk log` leaves out the time column for lines the log wrote
  without one.
- Output meant for a person starts one blank line below the prompt. Nothing is added when stdout is not a terminal or the command was
  given `--json`.
- `risk version --json` and `risk gestures status --json` print JSON; before, they printed text.
- `risk ext validate` keeps its `file:line: rule <id>: <what>. Fix: <how>.` lines unchanged; a clean folder now prints `valid`.

### Fixed
- The documented commands `config`, `setup`, `gestures`, `version`, `theme`, `snap`, `bench`, `fit` and `self-test` fell through `risk` to
  its header text and did nothing. Every command now reaches its implementation, and an unknown command is an error with exit 2.
- `risk install --dry-run` and `risk uninstall --dry-run` changed things: the wrapper ignored the flag. Both, and `dev`, now print what they
  would do and change nothing.
- `risk` commands read and wrote under the account's home even when `HOME` named another folder, so a test with a scratch `HOME` could
  change the real `~/.config/riskell`. They now use `HOME` when the shell names one; in a normal shell nothing moves.
- `risk` rebuilt `riskell-ext` and `riskell-setup` only when they were missing, so after an update it could run a tool older than the
  checkout. In a git checkout it now rebuilds them when their sources are newer; an installed copy never rebuilds itself.
- A `[gaps.outer]` line in OmniWM's `settings.toml` that carries a trailing `# comment` is no longer rewritten on every apply: the old
  comparison included the comment, so it never matched, and rewriting removed the comment and a CRLF line ending. The file is now left alone
  when the gaps already match, and its backup is not recreated for a write that does not happen.

### Documentation
- The roadmap says the command line is done and that bringing other setups here starts with Omarchy widgets and themes, then BitBar and
  SwiftBar, one simple port command and presets as a file. The constraints it works under are written down with it: no second runtime, no
  `.dmg`, no closed edition, no bulk ports, no auto-import, no telemetry.

## [0.2.1] - 2026-11-18

### Documentation
- The README's title block says what riskell is in its own terms — a desktop shell framework for macOS — instead of a slogan, and the
  section headings say what the section contains. No product change.

## [0.2.0] - 2026-11-18

### Licensing
- The application moves from PolyForm Noncommercial 1.0.0 to the Functional Source License 1.1, MIT Future License (`FSL-1.1-MIT`). Work use
  and company use are now allowed; a paid product built on riskell is not, for two years, after which each release is MIT. `LICENSING.md`
  answers the common questions in a table, and the trademark and `riskell.` registry-namespace limits are stated there. Releases `0.1.0` to
  `0.1.2` stay under PolyForm Noncommercial. `risk ext` accepts both FSL identifiers as known SPDX licenses.
- The bundled atom packages carry `FSL-1.1-MIT` in their headers and manifests, so `risk ext validate` finds no unknown license in them.

### Documentation
- `README.md` rebuilt: a centred title block with the tagline and status in one line, a "Why another bar" comparison before the install step, a
  2×2 picture grid for the tour, headings that can be scanned as a list of claims, and the deep material moved into collapsed sections.
- `docs/STOREFRONT.md` no longer claims a capability report that does not exist, and says plainly what the storefront cannot know (no install
  counter, no telemetry, and why GitHub Pages offers no logs). Previews are no longer listed as unbuilt.
- The documentation was checked against the code as a whole. Corrected: the top bar cannot be switched off, `risk ext` gained `search`, `info`,
  `update` and `publish` in three lists that predated them, `config.json` named neither `gestures` nor `display` and omitted `aerospace`,
  `Compat.Verified` does not hold the protocol number or a build hash, the memory figure disagreed with `docs/EFFICIENCY.md`, the live-reload
  claim ignored `wm`, `scale` and `disabledExtensions`, the atom count is ten in seven packages, and the paused-media window is 15 minutes.
  The panel is called riskell preferences everywhere, and the six longest documents have a contents line.

## [0.1.2] - 2026-11-17

### Fixed
- `risk install` ended silently, with no launch agent, on a Mac without a `riskell-dev` signing certificate (every new install). The certificate is
  optional: the bundle is now signed ad hoc when there is none, and `risk` says so. macOS asks again for keychain and Location access after a rebuild.
- `risk install` failed writing its launch agent on an account with no `~/Library/LaunchAgents` folder yet. The folder is created.
- `riskell-install` (the Homebrew link to `install.sh`) did not find the guided installer or `scripts/risk` when run through the symlink, and fell back
  to a quick install that pointed at a path that does not exist. It now resolves its own location through symlinks.

## [0.1.1] - 2026-11-17

### Added
- Two opt-in AI usage sources, both off by default and never enabled by `--yes` alone. `usage.claudeLimits` shows your plan's real Claude limits: it
  reads the Claude Code login token from the login keychain and asks Anthropic's usage endpoint. This is unofficial: Anthropic's terms do not allow
  using that token in other tools, so the account could be restricted. `usage.opencode` shows OpenCode Go usage: it reads the console session cookie
  from a Firefox-family browser profile inside your home folder (a private temporary copy, removed afterwards) and asks the OpenCode console, which
  is not a published API. Requests go over https to `api.anthropic.com` and `opencode.ai` only, with no cross-host redirects; secrets are never
  logged or cached. The installer has a step for each, with a panel that says what is read and sent and needs `y` to accept
  (`--claude-limits`, `--opencode-workspace`, `--opencode-profiles` for scripts). See `docs/CONFIG.md`.

### Fixed
- AI usage no longer shows a percentage it cannot know. Claude Code's local logs have token counts but not your plan's limits, so a percentage was
  only "of your own peak" and read 100 % whenever you were at it. Without `usage.fiveHourTokens` / `usage.sevenDayTokens` in `config.json` the atom
  and card now show the tokens used (the running 5-hour session and the last 7 days); with them, a real percentage, as before.
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

### Added: the storefront
- `risk ext search`, `info`, `add <name>`, `update [--yes]` and `publish`: extensions are found in a registry (`riskell-registry`, listings pinned to a
  commit, an `index.json` the client reads, `RISKELL_REGISTRY` to point elsewhere) and installed at the pinned commit; the manifest must agree with the
  listing. Pills and themes are files copied into the config folder and applied live (`~/.config/riskell/extensions.json` records them). `update`
  shows the change between the two commits and applies only with `--yes`. `risk` rebuilds only when `riskell-ext` exits 10.
- The registry repository: listing schema, `scripts/check-listing.py`, the index and storefront page builders, and CI (pull-request checks and GitHub Pages).

- Storefront pictures: listings carry a `preview` PNG (the manifest's `preview`, checked by `risk ext validate` and `publish`); `scripts/make-previews` renders them with riskell, for what ships with it
  (`docs/images/store/`).

### Fixed
- The overview is resolution-independent: every size in it follows the one scale factor, and it follows display changes.
- The weather card footer showed a hardcoded city; it now shows the place from `config.json`.
- Script pills (and extension atoms) no longer run while their bar is switched off or hidden by a fullscreen Space.
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
