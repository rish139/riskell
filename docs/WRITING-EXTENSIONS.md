# Writing an extension

An extension is a git repository with a `riskell.json` manifest. This page is task-first: pick what you want to build, follow its recipe,
check it with `risk ext validate`, share it. (The design behind it is `docs/EXTENSION-KIT.md`; the API is the [reference in the kit repository](https://github.com/rish139/riskell-kit/blob/main/docs/KIT-API.md).)

```
risk ext new <kind> <name>     scaffold             risk ext add <dir|git-url> [rev]   install it into this riskell
risk ext validate <dir>        check it             risk ext remove <id> | list        manage what is installed
```

`risk` is the control script of riskell; the installer puts it on the PATH (from a checkout that has not been installed, run it as
`scripts/risk`). `risk ext` runs a small tool that is built with the app on first use. `add` and `remove` change `extensions.lock.json`,
regenerate the import list, rebuild and restart riskell. A clean build takes about 35 seconds.

**Contents:** [Which kind](#which-kind) · [A reading](#a-reading) ·
 [An atom that draws itself](#an-atom-that-draws-itself) ·
 [The rules](#the-rules-the-validator-checks-the-ones-a-machine-can) · [Settings](#settings) ·
 [Check, try, share](#check-try-share) · [Trust](#trust)

## Which kind?

| You want | Kind | Build |
|---|---|---|
| a figure from a shell command or a file | **pill** (`docs/PILLS.md`) | none, live |
| colours | **theme** (`docs/THEMES.md`) | none, live |
| a figure, gauge and hover card from Swift | **reading** | yes |
| your own drawing | **atom** | yes |
| a background capability | **behaviour** | yes, but `risk ext new` does not scaffold one: community behaviours wait for a review policy |

Choose the first one that fits. A `reading` looks exactly like a built-in atom with no layout code to get wrong; an `atom` is for the
cases that need their own drawing.

## A reading

```swift
import RiskellKit

public enum GpuPackage: RiskellPackage {
    public static var readings: [any ReadingAtom.Type] { [Gpu.self] }
}

public struct Gpu: ReadingAtom {
    public static let meta = AtomMeta(id: "gpu", name: "GPU", priority: 4)
    public init() {}
    public func readings(_ env: Env) -> AsyncStream<Reading?> {
        env.every(.seconds(5)) {
            let load = probe()                                   // your own code; return nil when there is nothing usable
            return Reading(text: "\(Int(load * 100))", icon: "cpu", tone: .heat(load), value: load,
                           lines: ["Load \(Int(load * 100)) %"])  // the hover card
        }
    }
}
```

`Reading` has `text`, `icon` (an SF Symbol name), `tone` (`.ok .warn .crit .accent .dim .plain .heat(x) .calm(x)`), `value` (0 to 1, draws
the gauge), up to three `values` (`Metric`: label, text, unit, tone, value), a `spark` series, `lines` and a two-column `grid` for the card.
Return `nil` and the atom draws dimmed. The kit draws the row on the top and bottom bars, the column on the strips and the card, and sizes the
card from its content.

Ways to wake up (all of them stop while the atom is off a showing bar):

| | |
|---|---|
| `env.every(.seconds(n))` | now, then every n seconds (at least 1), off the main thread |
| `env.watch("~/path")` | now, then whenever the file changes (a kernel event, no polling) |
| `env.on(.battery)` | when a shared value changes: `.battery .volume .focusedApp .spaces .minute` |

## An atom that draws itself

```swift
public struct Meter: CustomAtom {
    public static let meta = AtomMeta(id: "meter", name: "Meter", maxWidth: 140)
    public init() {}
    private let model = MeterModel()
    public func activate(_ env: Env) -> (() -> Void)? { env.repeating(.seconds(3)) { [model] in model.tick() } }   // runs only while on a bar
    public func horizontal(_ env: Env) -> some View { HStack(spacing: T.gap) { Cap(text: "METER"); Bar(value: model.v, tone: Pal.heat(model.v), hot: false) }.frame(height: G.pill) }
    public func vertical(_ env: Env) -> some View { VStack(spacing: 3) { Cap(text: "METER"); VGauge(value: model.v, tone: Pal.heat(model.v), hot: false) }.fixedSize().frame(width: 40) }
    public var card: Card? { Card(id: "meter", size: { _ in CGSize(width: 220, height: 96) }) { MeterCard(model: model) } }
}
```

Use the kit's pieces: `Num` (a figure with its unit), `Cap` (a caption), `Sep`, `Bar`, `VGauge`, `Sparkline`, `Rule`, `Dot`, and `.popout(id,
edge:hot:)` to open a card. The app puts each form in its box (36 tall; 40 wide on a strip; `maxWidth` wide) and clips to it.

## The rules (the validator checks the ones a machine can)

1. **Colours from the theme.** `Pal.text1` ... `Pal.accent`, `Pal.heat(x)`, or a `Tone`. Never `Color(...)`, `NSColor`, `Color.red`.
2. **Type from the scale.** `T.value`, `T.unit`, `T.cap`, `T.sub`, `Pal.font(size, weight)`. Never `.font(.system(size:))`.
3. **Design units, never pixels.** `G.pill`, `G.strip`, plain numbers. Never `NSScreen`. riskell scales everything from one factor.
4. **No timers or threads of your own.** See the table above and `env.repeating`.
5. **Both forms.** The compiler enforces it. A vertical form has no rotated text and is at most 40 wide.
6. **No windows.** The app owns every window.

Why: colours and type come from the theme and the scale, so every extension matches every theme and every display; nothing wakes up on its
own, so an extension costs nothing at rest.

## Settings

Values the user may change live in `~/.config/riskell/ext/<id>.json` (numbers, booleans, strings). Read them with `env.prefs.number("key",
default: 85)`, `.bool`, `.string`.

Declare a setting in `riskell.json` and riskell preferences shows it in the EXTENSIONS card, so you write no settings interface:

```json
"settings": [
  { "key": "hotAt", "label": "Gauge full at %", "type": "number", "min": 50, "max": 200, "step": 25, "default": 100 },
  { "key": "icon", "label": "Show icon", "type": "bool", "default": true },
  { "key": "unit", "label": "Unit", "type": "choice", "options": ["C", "F"], "default": "C" }
]
```

`number` (with `min`, `max`, `step`), `bool` and `choice` (2 to 4 `options`) are offered; the label is at most 24 characters. A change is written to
the file and the atoms are rebuilt at once, so read the values when the atom starts (in `readings` or `activate`), as `Examples/load-ext` does.
A text setting is not offered in the card; it stays a file you edit.

## Check, try, share

1. `risk ext validate <dir>`: every finding is `file:line: rule <id>: <what>. Fix: <how>.`
2. `swift build` in the package.
3. `risk ext add <dir>` then `scripts/risk dev`; open riskell preferences (ctrl-alt-,) and place `ext:<id>` from the tray. Look at it on the
   top bar, a strip, and with a different theme (`docs/THEMES.md`).
4. Publish: push the repo with a `LICENSE` and a tag `vX.Y.Z` on the commit, then `risk ext publish` prints the registry listing (and tells you what is
   missing). Save it as `listings/<id>.json` in [riskell-registry](https://github.com/rish139/riskell-registry) and open a pull request; people then
   `risk ext add <id>`, and `risk ext update` offers them each new commit you list. Add the GitHub topic `riskell-extension` and a screenshot. In a compiled extension's
   `Package.swift` depend on the kit by URL: `.package(url: "https://github.com/rish139/riskell-kit", .upToNextMinor(from: "0.7.0"))` (the kit is 0.x: a new minor can change the API, so an extension pins the minor it was built for).

## Trust

`risk ext add` shows the author, license and commit, shows a pill's commands, and asks before it builds or installs anything of someone else's (`--yes` to
answer for a script).

Compiled extensions run inside riskell with the user's rights. There is no permission system and no sandbox: installing one is like
installing a Homebrew formula or a shell plugin, and the source is the thing to read. `risk ext add` shows the validator's findings
and pins a commit; nothing updates by itself.
