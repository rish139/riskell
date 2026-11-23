# Dwindle

Binary tiling for AeroSpace. The workspace's tiling tree stays binary: a new window splits the focused window in half, and the split
directions alternate, the way Hyprland's dwindle layout does. It is a behaviour, so it has no place on a bar.

## What it does

- A window that opens, or arrives on a workspace, joins the workspace only when two or more other tiling windows are already there. In a
  row it joins the window on its left, in a column the one above, and AeroSpace halves the window it split.
- With one window or none it is left alone. A join wraps the window and its neighbour in a container that takes the neighbour's place, and
  with the first two windows of a workspace that container is the whole workspace: two windows side by side would turn into two stacked.
- Closing a window needs nothing from this package. AeroSpace's flatten normalization puts the window that is left into the pair's place.
- The tidy key rebuilds the focused workspace as one dwindle chain, its windows in the order they were made. It flattens the workspace
  into one container and lays it out the way the display is (a row on a wide display, a column on a tall one, and the layout it has now
  when riskell cannot tell), then brings the windows back one at a time, each joined in the direction that alternates with the last
  split, and evens out the sizes. Bringing them back is also what puts them in id order, since the flatten keeps the order the tree had, so
  even the second window of a two-window workspace goes through it (no join: a pair cannot alternate).

What it does not do:

- The split directions do not follow a window's aspect ratio; they alternate.
- There is no switch to make one pair split the other way by hand.
- It does not move, close or focus anything. It only sends AeroSpace the joins and the tidy.

Known limits, from how AeroSpace reports what changed:

- A new window that an `[[on-window-detected]]` rule moves to another workspace is counted on the workspace it was detected on: the state
  the rule is seen from is the query from before it ran. The join then applies to the window's real parent, so the workspace it landed on
  may be joined with fewer windows there than the rule of "two others" wants.
- A window moved in from another workspace, or made tiling again after floating, lands at the end of the workspace's root container, so its
  join pairs it with the container before it rather than with a window. The tree stays binary and alternating; the tidy is what puts it back
  into one chain in id order.
- There is no on/off row in riskell preferences: with no settings to show, the package does not appear there. Turn it off by adding
  `"dwindle"` to `disabledExtensions` in `~/.config/riskell/config.json`.

## Install

AeroSpace has to be riskell's window manager (`risk wm use aerospace`), and AeroSpace's two normalizations have to be on, which they are by
default:

    enable-normalization-flatten-containers = true
    enable-normalization-opposite-orientation-for-nested-containers = true

The first one is what puts the surviving window in a pair's place when the other closes.

    risk ext add Packages/dwindle

Then place nothing: a behaviour has no bar form.

## Bind the tidy key

The package acts on a key binding of AeroSpace's own, so one key press reaches both. `true` is a command of AeroSpace's: it does nothing and
exits. AeroSpace reports a binding before it runs the binding's commands, so the binding can do nothing while riskell does the tidying:

    [mode.main.binding]
    alt-shift-t = 'true'

A binding in another mode works too.

## Another key

The tidy key is a text setting, which the settings card cannot show, so it is not declared in `riskell.json`: set it in the package's own
settings file, then restart riskell so the behaviour reads it again.

    ~/.config/riskell/ext/dwindle.json

    {"tidyKey": "alt-ctrl-t"}

The value is the binding exactly as `aerospace.toml` writes it (`alt-shift-t`, `ctrl-alt-space`, ...), and the binding in `aerospace.toml`
has to use the same key. The default is `alt-shift-t`.

## Tests

The package's tests run from this folder with `swift test`; they are not part of riskell's CI yet.
