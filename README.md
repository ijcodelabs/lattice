# Lattice

**A keyboard-first tiling window manager for macOS.**

Lattice brings the way i3, sway and Hyprland handle windows to the Mac — windows tile themselves,
you move between them and across workspaces with the keyboard, and the whole setup lives in one
readable config file — while staying a good Mac citizen: **no SIP changes, no code injected into
other apps, no private APIs it depends on.** It only uses the public Accessibility API, so it keeps
working across macOS updates.

> **Status:** early, but daily-driven by its author. Expect rough edges; issues and ideas welcome.

## What it does

- **Layouts per workspace:** dwindle (spiral), tree (i3-style splits), master/stack, monocle —
  switch any time without losing the arrangement.
- **Workspaces** (named or numbered) that switch instantly, with **multi-display** support: each
  display shows its own workspace; focus and move windows across displays; pin workspaces to displays.
- **Groups / tabs:** stack several windows in one tile, tabbed or stacked, with a clickable tab strip.
- **Keyboard everything:** direct shortcuts plus a **leader key** (`ctrl+alt+space`) whose pop-up
  shows what to press next, a **command palette** (`ctrl+alt+p`), and **hint mode** (`ctrl+alt+u`) —
  a letter on every window, type it to jump there.
- **The mouse cooperates:** drag a window onto another to swap them, drag an edge to resize the split.
- **A themable bar** (workspaces, focused window, CPU, memory, battery, clock, your own scripts) and a
  **focus border**; built-in themes (Nord, Gruvbox, Catppuccin…) or your own.
- **Your layout survives restarts:** Lattice saves it continuously and rebuilds it when it starts.
- **One YAML config**, validated strictly (errors with line and column) and reloaded on save.

## Requirements

macOS 15 or later. Building needs Xcode (Swift 6).

## Install

```bash
git clone https://github.com/ijcodelabs/lattice.git && cd lattice
scripts/build-app.sh --install        # build, sign and copy Lattice.app to ~/Applications
open ~/Applications/Lattice.app
```

On first launch Lattice asks for **Accessibility** permission (System Settings → Privacy & Security →
Accessibility) and starts tiling as soon as it's granted. Its menu-bar icon (▦) has Open Config,
Reload Config, Start at Login and Quit — quitting always brings every window back on screen.

Signing: set `LATTICE_SIGN_IDENTITY` (or put it in `scripts/signing.env`) to a code-signing identity
you own (`security find-identity -v -p codesigning`), so macOS keeps the Accessibility permission
across rebuilds. Without one the app is signed ad-hoc and the permission must be granted again after
every build.

Tip: turn off macOS's own window tiling (System Settings → Desktop & Dock → Windows, the three
"tile" options) — it snaps dragged windows before Lattice can place them — and use one macOS Space
per display; Lattice's workspaces replace them.

## Configure

`~/.config/lattice/config.yaml` — created from the documented defaults with
`~/Applications/Lattice.app/Contents/MacOS/Lattice config init` (or ▦ → Open Config).

- [docs/config.md](docs/config.md) — keys, layouts, workspaces, displays, groups, hints, mouse, session, rules
- [docs/themes.md](docs/themes.md) — colours, fonts, the focus border
- [docs/bar.md](docs/bar.md) — the bar and its widgets, script widgets
- [docs/idea.md](docs/idea.md) — the design, and why it works the way it does

## How it works, briefly

A pure Swift core (layouts, workspaces, key routing — fully unit-tested) decides where every window
should be; a thin macOS layer applies that through the Accessibility API, one worker thread per app so
a frozen app can never freeze the window manager. Windows of hidden workspaces are parked in a screen
corner rather than moved between macOS Spaces. The bar, pop-ups and palette run in a separate helper
process, so a UI crash never affects your windows.

```bash
swift build && swift test             # core + config tests
swift run lattice doctor              # permissions, displays, macOS tiling check
```

## Contributing

Bug reports, ideas and pull requests are welcome. Before pushing, enable the repo's hooks once —
`git config core.hooksPath .githooks` — they run a secret/leak scan (`scripts/check-public.sh`,
using [gitleaks](https://github.com/gitleaks/gitleaks)).

## License

Copyright © 2026 ijcodelabs.

Lattice is free software: you can redistribute it and/or modify it under the terms of the
**GNU General Public License, version 3 or (at your option) any later version** — see [LICENSE](LICENSE).
In short: you may use, study, change and share it; if you distribute a modified version, you must
make its source available under the same license.

Third-party components and their licences: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
