# Themes

riskell's colours come from a theme. The default is the original gruvbox dark. Pick another in riskell preferences (ctrl-alt-, then the
**THEME** card): it applies at once and is saved as `"theme"` in `~/.config/riskell/config.json`. Or set it by hand:

```json
{ "theme": "nord" }
```

Editing the file applies live too; no restart.

## Bundled schemes

Eleven [Base16](https://github.com/tinted-theming/schemes) schemes (MIT, see `THIRD-PARTY-NOTICES.md`): gruvbox dark, catppuccin mocha,
rosé pine, nord, tokyo night dark, kanagawa, everforest dark, dracula, github dark high contrast, gruvbox light, catppuccin latte.

## Your own scheme

Drop any Base16 scheme file (`.yaml` or `.yml`, the format used by the tinted-theming catalogue, 375 schemes there) into
`~/.config/riskell/themes/`. The file name (without extension) is its id. It shows up in the picker and applies as soon as it is saved.

```yaml
system: "base16"
name: "My scheme"
variant: "dark"        # or "light"
palette:
  base00: "#101820"    # ... through base0F
```

## How a scheme becomes riskell's colours

riskell does not use the 16 slots raw: Base16's greys are comment tones, not readable text. `Themes/Theme.swift` derives its tokens and enforces
contrast (WCAG 2.x ratios against the surface and the tile on it):

| token | from | must reach |
|---|---|---|
| text1 | base06 (dark) / base07 (light) | 7 |
| text2 | base05 / base06 | 4.5 |
| text3 | base04 / base05 | 4.5 |
| text4 (dimmest) | text3 faded toward the surface | 3.2 |
| accent, ok, warn, crit, info | base0A, 0B, 09, 08, 0D | 3 |

A colour below its floor is moved toward white (dark schemes) or black (light) in small steps until it passes, so every scheme is readable.
`riskell --check-themes` prints the ratios for every scheme, bundled and yours. The default scheme keeps four exact values of the original
design (dimmest text, critical ink, dim amber, canvas), so it never changes.

## Adding a bundled scheme

Put the YAML in a folder, add its id to the list in `scripts/gen-schemes.py`, run `python3 -I scripts/gen-schemes.py FOLDER`, and add its row
to `THIRD-PARTY-NOTICES.md`.
