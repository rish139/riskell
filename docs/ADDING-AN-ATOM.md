# Adding an atom

An atom is one module on a bar: a figure, a gauge, a glass cell, a list of readings. Each atom has a horizontal form (for the top and
bottom bars) and a vertical form (for the left and right strips), and it must fit any bar. The house rules are in [`BARS.md`](BARS.md).

**Every atom is a package** on [RiskellKit](https://github.com/rish139/riskell-kit), the same kit an extension uses: the application has no
atoms built in. So adding one is writing an extension, and the walkthrough is [`WRITING-EXTENSIONS.md`](WRITING-EXTENSIONS.md); the rules
the validator enforces are in [`AGENTS.md`](../AGENTS.md). Start with `risk ext new reading <name>` (the kit draws it) or
`risk ext new atom <name>` (you draw it), check with `risk ext validate`, then `risk ext add`.

The atoms that ship with riskell are the worked examples, in `Packages/`. Pick the one closest to what you want:

| You want | Look at |
|---|---|
| a time-driven atom with a two-stage card (a glance, then expanded) | `clock` (`ClockPackage.swift`, `DateCard.swift`) |
| an atom that fetches over the network, reads `config.json` and keeps a cache | `weather`, `usage` (`env.config`, `env.cache`, `env.repeating`) |
| several atoms sharing one reader, with their cards | `system` (battery, CPU and fans: `SystemEngine`) |
| hardware and OS access: audio, the mixer, Wi-Fi, Bluetooth | `volume`, `network` |
| the window manager: workspaces, windows, the swipe, focus and move | `windows` (`WindowsModel`, `RailState`, `WindowActions`) |
| a card with a text field | `system` (`VitalsCard`: `PopState.setKeyable`) |

Things every atom does:

- Draw only with `Pal` (colours), `T` and `Pal.font` (type) and design units (`G`); both forms; hover opens the card with `.popout("<card id>", ...)`.
- Do its work only while it is on a showing bar: start in `activate(_ env:)` and return the stop closure, with the kit's `env.every`, `env.watch`,
  `env.on(feed)` or `env.repeating` for anything that repeats. An atom that is not placed costs nothing.
- Be listed: a `listings/<id>.json` for a first-party atom (`scripts/listings-check.sh` keeps them in step with the app).

## The no-Swift alternative

If you only need a command's output or a file's content on a bar, a script pill needs no Swift at all: [`PILLS.md`](PILLS.md).
