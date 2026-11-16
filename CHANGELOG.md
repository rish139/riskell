# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/). Versioning: [Semantic Versioning](https://semver.org).

## [Unreleased]

### Licensing
- The app is source-available under the PolyForm Noncommercial License 1.0.0; RiskellKit, `risk ext`, the schema and the examples are
  Apache-2.0. Contributions need a CLA. Added a Code of Conduct and a security policy.

### Added
- [`RiskellKit`](https://github.com/rish139/riskell-kit), a separate repository: the design tokens, the drawing primitives, the reading renderer, the popout
  hook and the extension API (`ReadingAtom`, `CustomAtom`, `Env`, feeds). Extensions depend on it alone.
- Extensions: compiled packages linked into the one binary through `extensions.lock.json`; atoms are placed as `ext:<id>`.
- `risk ext`: `validate`, `new`, `add`, `remove`, `list`, `sync`.
- `schemas/riskell-extension.schema.json`, `AGENTS.md`, `docs/WRITING-EXTENSIONS.md`, `Examples/load-ext`.

### Changed
- Script pills and extension readings are drawn by the same code (the kit's `ReadingBody` and `ReadingCardContent`). No pixel changed.

### Documentation
- A README with a full feature list, screenshots of everything, and a roadmap. The pictures come from `scripts/make-screenshots`, which
  renders them from fake data (a made-up wallpaper, fake workspaces, placeholder device and process names) so they can be made again.

### Fixed
- The overview is resolution-independent: every size in it follows the one scale factor, and it follows display changes.
- The weather card footer showed a hardcoded city; it now shows the place from `config.json`.
- Script pills (and extension atoms) no longer run while their bar is switched off or hidden by a fullscreen Space.
