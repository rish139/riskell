# Roadmap

What is built is in `docs/ARCHITECTURE.md` and `docs/EXTENSION-KIT.md` (which has a status table); this is what is next. Nothing here is
promised. riskell supports Apple silicon only.

## Before a public release
- Verification on other Apple-silicon Macs and window managers (`docs/UNVERIFIED.md`): yabai, AeroSpace, command actions, other displays,
  macOS 14 and 15, a clean-machine install.
- Packaging: a Homebrew tap exists (`rish139/homebrew-riskell`, `brew install --HEAD riskell`); it needs the repository to be public, or the
  user's GitHub credentials, to fetch.

## Done: every atom is a package
Each atom that ships with riskell (clock, weather, AI usage, battery, CPU, fans, volume, network, workspaces, application icon) is a package in
`Packages/` on the same kit extensions use, listed in `listings/` (`scripts/listings-check.sh` keeps the listings in step), and starts nothing
until it is on a showing bar. The kit grew for it: `PopState`, `env.config`, `env.cache`, `Demo`, `onRightClick`, `onScrollSteps`, `AppHooks`
and the window-manager API.

## Extensions
- Close the extensibility gaps: everything the application still owns that an extension cannot replace or extend is inventoried in
  [`EXTENSIBILITY-GAPS.md`](EXTENSIBILITY-GAPS.md) (window-manager backends, the notch, the overview, the gesture and behaviour route, and more).
- Done: riskell preferences. The panel is renamed, and an extension declares typed settings in its manifest (`settings`: number, bool, choice)
  that appear in its EXTENSIONS card and apply at once. Text settings (a field you type into) stay in the file for now.
- The registry and storefront (`docs/STOREFRONT.md`), with CI that renders every listing across displays, bars and themes. This needs a check
  that the snapshot harness runs headless on a CI runner.
- Preset bundles, `risk ext publish`, `risk ext search`.
- `behaviour` extensions from outside the app, with a review policy.

## Ideas
- The notch beyond its media wings (a shelf, quick actions, timers): parked until it has been designed.
- Draw the clock drain and the CPU deck with Core Animation layers (about 0.8 % of a core). Open cards are the biggest cost now (`docs/EFFICIENCY.md`).
