# The registry and storefront

How extensions are found and shared. The model is Homebrew taps and Obsidian's community plugins: **GitHub is the backend and there is no
server.** The registry is its own repository, [riskell-registry](https://github.com/rish139/riskell-registry); this page is the design and what is
built.

## The unit

No agreement, signature or approval is needed to publish an extension: it stays in its author's repository under the author's license and
copyright (the manifest's `license` is an SPDX identifier, commercial and proprietary licenses included). A registry listing is metadata that
points at that repository.

An extension is a git repository with a `riskell.json` (`schemas/riskell-extension.schema.json`) at its root, a `LICENSE`, and a tag
`v<version>` on the commit that is listed. Kinds: `atom` and `reading` (compiled, linked into riskell), `pill` and `theme` (files). A **preset**
(a bundle: layout, pills, a theme, a list of extensions) is designed but not built.

## The listing

One small JSON file per extension in the registry, `listings/<id>.json` (`schema/listing.schema.json`): `id`, `kind`, `name`, `summary`, `repo`, a
**pinned commit** (`rev`), `version`, `license`, and optionally `kit`, `atoms`, `keywords`, `authors`. A listing is one specific commit, so an
author cannot silently change what people install; an update is a new pull request. `risk ext publish` (run in the extension's repository) checks it
is ready (pushed, tagged, licensed, valid) and prints the listing.

CI on each pull request (`validate.yml`, a macOS runner) clones the pinned commit and checks: the fields; that `riskell.json` there agrees on id, kind,
version, license, kit and atoms; the tag; and `risk ext validate`. On every merge `pages.yml` builds `index.json` (the one file the client reads) and
the storefront page and serves both from GitHub Pages. Still to add to CI: a build against the current kit and the previous one, the render matrix
(`docs/EXTENSION-KIT.md` section 6) with its images attached to the pull request, and an idle-CPU measurement (`scripts/resource-check`).

## Pictures

A listing shows a picture of the widget: its `preview`, a PNG inside the repository at the pinned commit (the manifest's `preview`; at least 600 px wide,
up to 500 KB). The registry's check verifies it exists at that commit; the page build copies it in, so the site is self-contained. `risk ext publish`
asks for it. The ones for what ships with riskell are rendered by riskell itself from fake data: `scripts/make-previews first-party` writes
`docs/images/store/<id>.png` (the widget on a bar and the card it opens). An author can do the same with `riskell --snap` or take a screenshot.

## First residents

The seven packages that ship with riskell are the first listings (clock, weather, usage, system, volume, network, windows), covering ten atoms, marked `bundled`: they are in
the application's lock already, `risk ext add clock` says so, and it puts one back after `risk ext remove`. Each is also a package in `Packages/`
and a worked example. (`listings/` in this repository maps each atom to its source files and is checked by `scripts/listings-check.sh`; the
registry's listings are what gets distributed.)

## The client

```
risk ext search <words>      risk ext info <name>      risk ext add <name | dir | git-url> [rev]
risk ext update [name] [--yes]      risk ext publish [dir]      risk ext list | remove <id>
```

A name is looked up in the registry (`RISKELL_REGISTRY` points at another index: a URL, a file or a folder) and installed at the pinned commit. The
manifest must agree with the listing or nothing is installed. Compiled kinds go into `extensions.lock.json` and need a rebuild (`risk` does it:
`riskell-ext` exits with status 10 to ask for it). Pills and themes are files copied into `~/.config/riskell/pills/` and `themes/`, applied live, and
recorded in `~/.config/riskell/extensions.json`. `update` compares what the registry pins now with what is installed, shows the change between the two
commits, and applies it only with `--yes`; nothing ever updates by itself. The index is cached, so `search` still works offline.

## Trust

There is no permission system, but nothing is installed unsaid: `risk ext add` shows who wrote it, the license and the exact commit, says that the
code runs with your rights, shows a pill's shell commands, and asks before anything is built (`--yes` answers for scripts). The client checks
everything a listing says (an https repository, a full commit hash, plain names and paths, plain small files) and turns git's command-running
`ext::` transport off. The trust model is a package manager's: pinned commits, a lockfile, source you can read, and the validator's findings
shown at install time. `risk ext validate` checks the rules it can see in source — no raw colour, no fixed font size, no screen reads, no timers of
its own, no windows — and reports them as findings, never as a gate. Behaviour extensions that touch input stay first-party or hand-reviewed.

## What this page cannot tell you, and why

There is no telemetry, no install counter, no heart button and no download number, and there will not be one: the client never reports home, and
the storefront is a static page on GitHub Pages, which does not expose per-file request logs. So any figure on this page is one of:

- **GitHub's own numbers** for the three repositories (stars, issues, pull requests, and the maintainer-only clone and view counts of the code
  repository — which count `git clone`, not installs);
- **what people tell us**, in an issue;
- **nothing at all**.

Where a number is missing it stays missing rather than being estimated. The honest way to say "this is used" is a labelled issue, not a counter.

## Not built yet

Presets and `risk ext preset apply`; a capability report from `risk ext validate` (the shell commands, files and hosts an extension's source
touches, printed as information — the checks above are style and resource rules, not this); the render matrix and a build against two kit
versions in CI; an in-app browse card in riskell preferences (last); a signed or verified-author mark.
