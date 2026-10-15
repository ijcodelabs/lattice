# Themes

A theme is a small set of **design tokens**: seven colours, a font, corner radii, border width and opacity. Lattice applies them everywhere at once: the bar, the which-key pop-up, the command palette and the focus border.

```yaml
# ~/.config/lattice/config.yaml
theme: nord
```

Save, and everything re-colours immediately.

## Built-in themes

| Name | Light/dark | Notes |
|---|---|---|
| `lattice` (default) | both | neutral greys, blue accent |
| `nord` | dark only | Nord palette |
| `gruvbox` | both | warm retro |
| `catppuccin` | both | Mocha (dark) / Latte (light) |

A theme with a `light:` palette **follows macOS appearance automatically**: switch light/dark (or let *Auto* do it) and Lattice switches too. A theme without one uses its dark palette in both modes.

## Make your own

Create `~/.config/lattice/themes/NAME.yaml` and set `theme: NAME`. A user file with the same name as a built-in **wins**, so `themes/nord.yaml` replaces the built-in Nord. Edits to theme files reload live, just like the config.

```yaml
# ~/.config/lattice/themes/midnight.yaml
font: "JetBrains Mono"   # optional; omit for the system font
font-size: 13            # 8–32
radius: 10               # corners of bar / pop-up / palette (0–30)
border-width: 3          # focus border thickness (0 = no border) (0–20)
border-radius: 12        # focus border corners — match your windows (0–40)
opacity: 0.94            # background opacity of bar / pop-up / palette (0.3–1)

dark:                    # required
  background: "#0f111a"  # bar, pop-up and palette background
  surface: "#1f2233"     # key caps, occupied workspaces, outlines
  foreground: "#e6e6f0"  # main text
  muted: "#8b8fa8"       # secondary text, layout indicator
  accent: "#7aa2f7"      # active workspace, modes, palette selection
  urgent: "#f7768e"      # low battery, high CPU/memory
  border: "#7aa2f7"      # the focus border

light:                   # optional — used when macOS is in light mode
  background: "#f4f5fa"
  surface: "#dfe1ec"
  foreground: "#1f2233"
  muted: "#5c607a"
  accent: "#3d59a1"
  urgent: "#c0304d"
  border: "#3d59a1"
```

Rules:

- **All seven colours are required** in each palette. A missing one is reported by name.
- Colours are `"#rgb"`, `"#rrggbb"` or `"#rrggbbaa"` (the last two digits are alpha, e.g. `"#7aa2f780"` for a 50% border).
- **Quote colours.** In YAML an unquoted `#` starts a comment, so `background: #0f111a` would be empty. Lattice catches this and tells you to quote it.
- Errors point into the theme file with a line and column. The previous theme stays active until the file is valid.

The built-in themes are written in exactly this format: see [`BuiltinThemes.swift`](../Sources/LatticeConfig/BuiltinThemes.swift) for complete examples to copy.

## Focus border

```yaml
borders:
  enabled: true     # false to turn it off
```

The border is drawn just outside the focused window, in the theme's `border` colour, `border-width` thick, with `border-radius` corners. It's an ordinary click-through window, so it never intercepts the mouse and needs no special permissions. It hides on empty workspaces.
