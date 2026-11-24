# Instructions for coding agents

This file is for any coding agent (and any person in a hurry). It has two parts: how to write an extension for riskell, and the rules for
changing riskell itself. Read only the part you need.

## A. Writing an extension

An extension is a git repo with a `riskell.json` manifest. Pick the smallest kind that does the job:

| You want | Kind | Needs a build | Start with |
|---|---|---|---|
| a number or text from a command or a file | `pill` | no | `risk ext new pill <name>` |
| new colours | `theme` | no | `risk ext new theme <name>` |
| a figure, gauge and hover card from Swift code | `reading` | yes | `risk ext new reading <name>` |
| your own drawing (both bar forms) | `atom` | yes | `risk ext new atom <name>` |
| a background capability (input, automation) | `behaviour` | yes | built; not scaffolded, and waits for a review policy (`Packages/dwindle-aerospace` is the worked example) |

Publishing an extension needs no agreement: it lives in its own repository under its author's license.

The loop:

1. `risk ext new <kind> <name>` creates the canonical layout. Edit only what the template marks.
2. `risk ext validate <dir>` after every change. It prints `file:line: rule <id>: <what>. Fix: <how>.` and exits 1 on a problem. Fix every
   line it prints; do not work around a rule.
3. For a compiled kind, `swift build` inside the package must succeed.
4. To try it in a running bar: `risk ext add <dir>` (rebuilds with `scripts/risk dev`), place `ext:<id>` in riskell preferences.

Rules the validator enforces, and why (read these, they are the whole design):

- **Colours only through `Pal` or a `Tone`.** Never `Color(...)`, `NSColor` or `Color.red`. The theme owns every colour, so a theme change
  cannot leave unreadable text behind.
- **Type only through `T` or `Pal.font`.** Never `.font(.system(size:))`.
- **Lengths are design units.** Use `G.pill` (36, the row height) and `G.strip`; a vertical form is at most 40 wide. Never read the screen
  (`NSScreen`): riskell scales everything from one factor, so your atom looks the same on every display.
- **Never create your own timers or threads** (`Timer`, `DispatchSource`, `Thread`). Wake up only through `env.every`, `env.watch`,
  `env.on(feed)` (readings) or `env.repeating` (custom atoms, started in `activate`). riskell stops them whenever the atom is not on a
  showing bar; that is what keeps idle CPU at zero.
- **Both forms are required** (`horizontal` and `vertical`); the compiler enforces it. Do not open windows (`NSWindow`, `NSPanel`).
- **Settings are declared, never drawn.** Put a `settings` list in `riskell.json` (number, bool or choice) and riskell preferences shows it; read
  it with `env.prefs`. Do not build a settings view.
- Prefer `reading` over `atom`. The kit draws a `Reading` exactly like the built-in atoms, in both forms, with the hover card.

The API is the [reference in the kit repository](https://github.com/rish139/riskell-kit/blob/main/docs/KIT-API.md) (generated from the public symbols) and the walkthrough is `docs/WRITING-EXTENSIONS.md`. The working
example is `Examples/load-ext`. If something you need is not in the kit, it is deliberately not available to extensions: say so instead of
reaching around it.

## B. Changing riskell itself

- **Efficiency is a requirement.** Everything is event-driven; nothing runs while it is switched off. Measure idle CPU before and after
  (`scripts/idle-cpu`).
- **A refactor changes no pixel.** Take snapshots from `main` first (`--snap DIR`, flags in `docs/ARCHITECTURE.md`), compare after; only
  ticking widgets (clock, battery, cpu, network, fan) may differ.
- **Resolution independence.** Views lay out in design units (`G`, `T`); only the window layer uses real points (`Real`, `Scale`). Check
  with `riskell --check-fit` and `--check-panel`.
- Do not drive synthetic mouse input on a running bar. Test instances use `--no-reserve` and `RISKELL_CONFIG` / `RISKELL_LAYOUT` pointing
  at scratch copies, and never write the user's files.
- `scripts/scrub-check.sh` must pass: no personal data in tracked files.
- The kit is a separate repository ([riskell-kit](https://github.com/rish139/riskell-kit)). A change to its public API needs a new version tag there
  and an updated `from:` requirement here; use `swift package edit riskell-kit --path ../riskell-kit` to work on both at once.
- Comments, docs, commit messages and file names say what the code does and why. They never say who or what wrote it, which task or step it
  belonged to, or what a spec or brief asked for, and no file is named after a task. `scripts/scrub-check.sh` fails on it.
- Keep it plain: the author prefers a simple rule to a clever one.
