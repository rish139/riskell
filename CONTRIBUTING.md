# Contributing to riskell

riskell is a native macOS app that draws the bars for a Mac window manager (OmniWM). Read `README.md` for what it does and
`docs/BARS.md` for how the bars and atoms fit together.

## Building

You need macOS 14 or later and the Command Line Tools (Xcode is not required). The project uses Swift Package Manager only.

```sh
swift build -c release
```

The binary is `.build/release/riskell`.

## Running it as an agent

`scripts/risk` runs the release build from your checkout as a launch agent (it starts at login and restarts if it dies):

```sh
scripts/risk install   # build, then start now and at login
scripts/risk dev       # rebuild and restart the running agent (use this while you work)
scripts/risk status    # is it running
scripts/risk log       # follow the log
scripts/risk uninstall # stop it and remove the agent
```

`risk` signs the app bundle with a local certificate named `riskell-dev` if you have one. Without it the app still runs, but macOS
asks for Location and keychain access again after each rebuild.

## Snapshots

To check how something looks without touching your live bar, run a second instance that writes PNGs and quits. Point it at scratch
files so it does not read or write your own config or layout:

```sh
scratch=$(mktemp -d)
mkdir -p "$scratch/out"
RISKELL_CONFIG="$scratch/config.json" RISKELL_LAYOUT="$scratch/layout.json" \
  .build/release/riskell --no-usage --no-reserve --no-claude --fake-usage --fake-media \
  --snap "$scratch/out" --stay 6
```

It writes `left.png`, `top.png` and `bottom.png` into the output folder. `--no-reserve` is required for a second instance: without
it the instance rewrites OmniWM's gaps for the live bars. `scripts/orient-snap` wraps this for one atom on one bar (see `docs/BARS.md`).

## Licences and the CLA

What a contribution needs depends on where it goes:

| Contribution | Agreement |
|---|---|
| An **extension** (a pill, a theme, a reading or an atom) | None. It lives in its own repository under its author's license and is never merged into this one. |
| The **Apache-2.0 parts**: `Sources/riskell-ext`, `schemas`, `Examples`, and the separate RiskellKit repository | None. Contributions are accepted under Apache-2.0, as section 5 of that license provides. No sign-off is required. |
| The **application** (everything else, PolyForm Noncommercial) | The [CLA](CLA.md), signed once with a comment on the first pull request. Copyright stays with the contributor. The agreement exists only so that the application can also be offered under commercial licenses. |

A pull request that touches only the Apache-2.0 parts is not checked for the CLA.

## Rules

- **No personal data in the repo.** That means names, e-mail addresses, account ids, home-folder paths and host names, in code,
  docs, comments, sample configs and commit messages. Use `~/` or a placeholder instead. `scripts/scrub-check.sh` checks the tracked
  files and CI runs it, but it is not a substitute for looking before you commit.
- **Colours go only through `Pal`**, **type only through `T`** (both live in [RiskellKit](https://github.com/rish139/riskell-kit), the extension kit).
  No hex values or ad hoc fonts in drawing code.
- **Every change keeps the default look pixel-identical and the idle CPU unchanged.** If a change is meant to alter the look, say so
  in the pull request and show before and after snapshots. Do not add timers or polling that run while nothing is shown.
- Keep changes small and in the style of the code around them. Add a comment only where the reason is not obvious.

## Share an extension

Most contributions should be an extension rather than a change to riskell. Write it ([docs/WRITING-EXTENSIONS.md](docs/WRITING-EXTENSIONS.md),
or hand `AGENTS.md` to your coding agent), run `risk ext validate`, and publish it as its own git repository with the GitHub topic
`riskell-extension` (`riskell-theme` and `riskell-preset` for those kinds). Use [Semantic Versioning](https://semver.org) for the
`version`, an [SPDX](https://spdx.org/licenses) identifier for the `license`, and tag releases `vMAJOR.MINOR.PATCH`.

`RiskellKit` follows Semantic Versioning: a breaking change to its public API is a major version. Everything else may change at any time.
Keep `CHANGELOG.md` up to date under "Unreleased" ([Keep a Changelog](https://keepachangelog.com) format).

## Adding an atom

An atom is one thing on a bar: a clock, a meter, a card, and every atom is a package on the kit. The guide is in
[`docs/ADDING-AN-ATOM.md`](docs/ADDING-AN-ATOM.md). If you only need a command's output on a bar, a script pill needs no Swift at all;
see [`docs/PILLS.md`](docs/PILLS.md).

## Before you open a pull request

1. `swift build -c release` passes. riskell depends on [RiskellKit](https://github.com/rish139/riskell-kit) by URL; to change the kit together
   with the application, check the kit out next to this repository and temporarily point `Package.swift` at `.package(path: "../riskell-kit")` (do not
   commit that; tag the kit once its CI is green, then point back at the tag).
2. `scripts/scrub-check.sh` passes, and `Tests/registry/e2e.sh` if you changed `risk ext`, and `scripts/listings-check.sh` if you changed an atom in `Packages/`.
3. Snapshots of the atoms you touched look the way they should, in both orientations.
   For an extension: `risk ext validate <dir>` passes.
4. The commit messages and the pull request description say what changed and why.

## Running a second instance safely
riskell takes a lock (`~/.cache/riskell/riskell.lock`) and refuses to start a second full instance: two of them would fight over the event
socket, the trackpad and the window manager's gaps. A scratch run is exempt when it uses `--snap`, `--dump`, `--no-reserve`, `--settings`, `--pop`
or `--edit`, or its own `RISKELL_CONFIG` / `RISKELL_LAYOUT` (or `RISKELL_NO_LOCK=1`). Always chain a build and a run with `&&`, so a failed build
never runs a stale binary, and always pass `--no-reserve` for a scratch run.
