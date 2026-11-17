# Adding an atom

An atom is one module on a bar: a figure, a gauge, a glass cell, a list of readings. Each atom has a horizontal form (for the top and
bottom bars) and a vertical form (for the left and right strips), and it must fit any bar. The house rules are in `docs/BARS.md`; this
page is the procedure.

## 1. Draw it: `Sources/riskell/<Name>Atom.swift`

Take the figure from the store, branch on `vertical`, and build both forms from the shared pieces in RiskellKit (`import RiskellKit`):
`Num(value:unit:tone:hot:)`, `Cap(text:)`, `Sep(height:)`, `Bar(value:tone:hot:width:)`, `VGauge(value:tone:hot:length:)`.

```swift
import SwiftUI

struct FooAtom: View {
    @EnvironmentObject var s: Store
    @State private var hot = false
    let vertical: Bool

    var body: some View {
        Group {
            if vertical {
                // strip: a centred column, at most 40 pt wide; caption above, gauge in the middle, figure under it
                VStack(spacing: 0) {
                    Cap(text: "FOO")
                    VGauge(value: 0.5, tone: Pal.ok, hot: hot)
                    Num(value: "50", unit: "%")
                }
                .fixedSize()
                .frame(width: 40)
            } else {
                // bar: a row, G.pill tall, T.gap between modules
                HStack(spacing: T.gap) {
                    Cap(text: "FOO")
                    Num(value: "50", unit: "%")
                }
                .frame(height: G.pill)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hot)
        .popout("foo", edge: .below, hot: $hot)   // the id must match the card's id (step 4)
    }
}
```

- Colours only from `Pal` (`Pal.ok`, `Pal.warn`, `Pal.crit`, `Pal.text1`, `Pal.text4`, `Pal.accent`), type only from `T`
  (`T.value`, `T.unit`, `T.cap`, `T.sub`) and the spacing constants `T.gap` and `G.pill`.
- The vertical form has no rotated text and no content wider than 40 pt (52 on a strip).
- `Rule` (the 24 pt hairline between modules in a column) is private to `CpuAtom.swift`. Copy it into your file, or make it
  internal first in its own change.
- The bar, not the atom, decides which side the card opens to. Pass `edge:` as the other atoms do.

## 2. Register it: one line in `Sources/riskell/Registry.swift`

Add the atom to `Registry.atoms`, before the `] + Pills.all` line. The position is the order it appears in the editor's tray.

```swift
atom("foo", "Foo", card: card("foo", size: { _ in FooCard.size }) { FooCard() }, blank: { $0.foo == nil }) { FooAtom(vertical: $0) },
```

- The first argument is the id, which is saved in the user's layout file. Keep it stable.
- `card:` is optional. Leave it out for an atom with no popout card.
- `blank:` is optional. Return `true` while the atom has nothing to draw; an island whose atoms are all blank is then not drawn.
- Ids must be unique: the registry is built with `uniqueKeysWithValues`, so a duplicate id or card id stops the app at launch.

## 3. Feed it data (only if it needs any): `Sources/riskell/Services/<Name>.swift`

Atoms read `Store`, and services write it. Follow `Services/Sys.swift`: a class with `init(store: Store)`, a `start()` that
arms a timer, and writes through `Store` setters.

- Add the published field and its setter to `Sources/riskell/Store.swift` (the setters ignore an unchanged value, so a redundant
  reading never redraws). Services write on the main queue.
- A number that changes on a timer (CPU, memory, power, temperature) belongs in `Gauges`, so a tick redraws only the views that show it.
- Create the service in `Sources/riskell/main.swift` next to the others and call its `start()`.
- A card that needs data that is costly to read should start the work when it appears and stop it when it goes, as `Vitals.shared`
  does. Closed means no timer and no work.

## 4. Declare its card (only if it opens one): `CardDef`

A card is a plain SwiftUI view with a static size. In `Registry.swift`, `card(_:size:_:)` builds a `CardDef`:

- `id`: the popout id the atom passes to `.popout(...)`.
- `size`: a closure from the stage (1 is the glance, 2 is expanded) to a `CGSize`. Use `{ _ in FooCard.size }` for one size, or
  a closure on the stage when the size depends on it (the clock's date card, in `Packages/clock`, is 252 tall at a glance and grows when expanded).
- `content`: a closure that returns the view, `{ FooCard() }`.

```swift
struct FooCard: View {
    @EnvironmentObject var s: Store
    static let size = CGSize(width: 182, height: 120)
    var body: some View { Text("Foo").font(T.sub).foregroundStyle(Pal.text2) }
}
```

## 5. Check it

```sh
scripts/risk dev                           # rebuild and restart the agent, to look at it live
scripts/orient-snap foo bottom /tmp/snaps  # horizontal form; use `left` for the vertical one (see docs/BARS.md)
```

Compare the horizontal form with its previous snapshot. The default look must not change, so the difference should be empty.
Force the worst-case values (full, empty, the longest text) in the source, snapshot them, then put the source back.

## The no-Swift alternative

If the atom only shows the output of a command, you do not need any of the above. Add a script pill to `config.json`. It appears
under **Not on a bar** in riskell preferences. See [`docs/PILLS.md`](PILLS.md).
