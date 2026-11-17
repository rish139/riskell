# The registry and storefront (plan)

How extensions are found and shared. Nothing here is built yet; it is the design the CLI and the manifest already point at. The model is
Homebrew taps and Obsidian's community plugins: **GitHub is the backend and there is no server.**

## The unit

No agreement, signature or approval is needed to publish an extension: it stays in its author's repository under the author's license
and copyright (the manifest's `license` is an SPDX identifier, commercial and proprietary licenses included). A registry listing is
metadata that points at that repository.

A git repository with a `riskell.json` (`schemas/riskell-extension.schema.json`), a `LICENSE`, tagged releases (`vMAJOR.MINOR.PATCH`) and the
GitHub topic `riskell-extension` (`riskell-theme`, `riskell-preset`). A **preset** is a bundle: `layout.json`, pills, a theme, the config
fragments that are not personal, and a list of extensions to install.

## First residents

The first listings are the built-in atoms: workspaces, application icon, clock, battery, CPU, fans, volume, network, weather and AI usage.
Each has a manifest and an entry in the registry as a first-party listing, so the storefront is populated from the start and every
built-in atom is also a reference for how an atom is built. They are listed before they are moved out of the application (see
`docs/ROADMAP.md`): `listings/<id>.json` (`schemas/riskell-listing.schema.json`), kept in step with the app by `scripts/listings-check.sh`. A
built-in listing is marked `builtin` and says where it will live (`home`: `app` for workspaces and the application icon, which need the window
manager and Space internals, `kit` for the rest, once the kit's feeds carry what they read). Its service now runs only while the atom is placed
(`Services/Needs.swift`), so removing the atom from every bar stops it.

## The index

One curated repository, `riskell-registry`, with one small JSON file per listing: the repo, a **pinned commit**, the kind. Authors list by
pull request. A listing is a specific commit, so an author cannot silently change what people install; an update is a new PR or a bot bump.

CI on each PR clones the pinned commit and runs, on a macOS runner:

1. `risk ext validate` (manifest and source rules);
2. a build against the current kit, and against the previous major;
3. the render matrix (`docs/EXTENSION-KIT.md` section 6): images attached to the PR;
4. an idle-CPU measurement (`scripts/idle-cpu`) against the budget.

Repositories with the topic but not in the registry are discoverable, flagged "not reviewed".

## The storefront

A static site generated from the registry by CI and served from GitHub Pages: a card per listing with its preview images, search and
filters by kind, and a copy-able install command. No server, no accounts.

## The client

```
risk ext search <words>          risk ext add <name | git-url> [rev]       risk ext update
risk ext preset apply <name>     risk ext list | remove <id>
```

(`add`, `remove` and `list` exist today for a path or a git URL; `search`, `update`, `preset` and names resolved through the registry do
not.) Pills, themes and presets are files dropped into `~/.config/riskell/`, applied live; a preset backs up what it replaces first.
Compiled kinds go into `extensions.lock.json` and need a rebuild. Updates never happen by themselves: `update` shows the diff first.

## Trust

There is no permission system. The trust model is a package manager's: pinned commits, a lockfile, source you can read, and the validator's
findings shown at install time. `risk ext validate` can also print what the code touches (shell, network, files) as information, never
as a gate. Behaviour extensions that touch input stay first-party or hand-reviewed.

## Publishing

`risk ext publish` (planned): runs the checks, scrubs personal data from a preset (the location and usage keys of `config.json`, as
`scripts/scrub-check.sh` does for the repo), tags, and opens the registry PR through `gh`.

## Order

1. Pills, themes and presets first: no SDK needed, and they are most of what people share. 2. Compiled kinds (the kit exists now).
3. An in-app browse card in the settings panel, last.
