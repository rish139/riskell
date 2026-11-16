# Roadmap

What is built is in `docs/ARCHITECTURE.md` and `docs/EXTENSION-KIT.md` (which has a status table); this is what is next. Nothing here is
promised. riskell supports Apple silicon only.

## Before a public release
- Verification on other Apple-silicon Macs and window managers (`docs/UNVERIFIED.md`): yabai, AeroSpace, command actions, other displays,
  macOS 14 and 15, a clean-machine install.
- Packaging: a Homebrew tap.

## The built-in atoms as packages
The current atoms (workspaces, application icon, clock, battery, CPU, fans, volume, network, weather, AI usage) are meant to be the
storefront's first listings, so they have to look like any other listing. In order:
1. Gate each built-in service by whether its atom is placed, so that nothing runs for an atom that is not used. Today the services start at
   launch. This is also what makes an atom removable.
2. Give every built-in atom a manifest and an entry in the registry, as a first-party listing that points at its source in this repository.
3. Move atoms out of the application into packages one at a time, where the kit's feeds and drawing parts are enough. Atoms that need the
   window manager or the notch (workspaces, application icon, media) stay in the application longest.

## Extensions
- Preferences: settings for extensions in the layout editor, which is then renamed riskell preferences. An extension declares typed
  settings and ships no settings interface of its own.
- The registry and storefront (`docs/STOREFRONT.md`), with CI that renders every listing across displays, bars and themes. This needs a check
  that the snapshot harness runs headless on a CI runner.
- Preset bundles, `risk ext publish`, `risk ext search`.
- `behaviour` extensions from outside the app, with a review policy.

## Ideas
- The notch beyond its media wings (a shelf, quick actions, timers): parked until it has been designed.
- Draw the clock drain and the CPU deck with Core Animation layers (about 0.8 % of a core).
