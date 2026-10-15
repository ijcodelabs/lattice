/// The built-in configuration. `lattice config init` writes it to ~/.config/lattice/config.yaml.
/// It is also what Lattice uses when no config file exists — one source of truth for defaults and docs.
public enum DefaultConfig {
    public static let yaml = """
        # Lattice configuration
        # Docs: docs/config.md  ·  Check: `lattice config check`  ·  Saved changes reload automatically.

        # Main modifier; `mod` in bindings expands to it.
        # ctrl+alt is the default because plain alt/option types characters on many layouts
        # (Croatian, German, … use it for @ { } [ ] |). Combine with shift for "move" variants.
        mod: ctrl+alt

        gaps:
          inner: 8        # between windows
          outer: 8        # between windows and the screen edge

        layout:
          default: dwindle   # tree | dwindle | master | monocle
          ratio: 0.5         # dwindle split / master column share (0.1–0.9)

        # Workspace names, in order. Quote numbers so they stay names.
        workspaces: ["1", "2", "3", "4", "5", "6", "7", "8", "9"]

        focus-new-windows: true

        # At the last window in a direction (with no display beyond it), focus wraps to the other side.
        focus-wrap: true

        # Several displays: each shows one workspace. Pin workspaces to a display with
        # main | secondary | 1, 2, … (left → right) | part of the display's name, e.g. "DELL".
        # Unpinned workspaces appear on the focused display.
        workspace-displays: {}
        #   "9": secondary
        #   "8": "DELL"

        # Session: Lattice saves its layout continuously and rebuilds it on the next start, matching the
        # windows that come back (same app + title, then order/position). See docs/config.md#session.
        session:
          restore: true      # rebuild the last layout on start (`lattice run --no-restore` skips once)
          grace: 60          # seconds to keep matching windows as apps reopen
          save-titles: true  # false: match by app + order only; window titles never hit the disk

        # Groups: several windows share one tile, one shown at a time, with a tab strip on top.
        # mod+g opens the group menu; mod+[ / mod+] switch tabs. See docs/config.md#groups.
        groups:
          tab-bar: true      # false: no strip (the bar's focused widget still shows the window)
          style: tabbed      # tabbed | stacked — for new groups (switch per group with group-style)
          tab-height: 26

        # Theme: lattice | nord | gruvbox | catppuccin, or NAME for ~/.config/lattice/themes/NAME.yaml
        # (see docs/themes.md). Themes with a light palette follow macOS light/dark automatically.
        theme: lattice

        borders:
          enabled: true      # coloured border around the focused window (colour/width from the theme)

        # The bar (see docs/bar.md). Widgets: workspaces, focused, layout, mode, clock, battery, cpu,
        # memory, script, text. Reorder the lists to move widgets; `{ type: …, option: … }` to configure.
        bar:
          enabled: true
          position: top      # top | bottom (sits below the menu bar / above the Dock)
          mode: reserve      # reserve: windows tile around it · overlay: floats above windows
          height: 30
          left:
            - workspaces
            - mode
            - layout
          center:
            - { type: focused, max-length: 70 }
          right:
            - cpu
            - memory
            - battery
            - { type: clock, format: "EEE d MMM  HH:mm" }

        bindings:
          # focus (vim keys + arrows)
          mod+h: focus left
          mod+j: focus down
          mod+k: focus up
          mod+l: focus right
          mod+left: focus left
          mod+down: focus down
          mod+up: focus up
          mod+right: focus right

          # move (swap with the neighbour in that direction)
          mod+shift+h: move left
          mod+shift+j: move down
          mod+shift+k: move up
          mod+shift+l: move right
          mod+shift+left: move left
          mod+shift+down: move down
          mod+shift+up: move up
          mod+shift+right: move right

          # workspaces
          mod+1: workspace 1
          mod+2: workspace 2
          mod+3: workspace 3
          mod+4: workspace 4
          mod+5: workspace 5
          mod+6: workspace 6
          mod+7: workspace 7
          mod+8: workspace 8
          mod+9: workspace 9
          mod+shift+1: move-to-workspace 1
          mod+shift+2: move-to-workspace 2
          mod+shift+3: move-to-workspace 3
          mod+shift+4: move-to-workspace 4
          mod+shift+5: move-to-workspace 5
          mod+shift+6: move-to-workspace 6
          mod+shift+7: move-to-workspace 7
          mod+shift+8: move-to-workspace 8
          mod+shift+9: move-to-workspace 9
          mod+tab: workspace back-and-forth

          # displays
          mod+o: focus-display next
          mod+shift+o: move-to-display next
          mod+period: workspace next
          mod+comma: workspace prev

          # layouts
          mod+t: layout tree
          mod+d: layout dwindle
          mod+m: layout master
          mod+f: layout monocle
          mod+shift+space: toggle-floating
          mod+v: split vertical
          mod+b: split horizontal

          # size
          mod+equal: resize grow
          mod+minus: resize shrink
          mod+0: balance

          # groups
          mod+g: mode group
          mod+rightbracket: group-next
          mod+leftbracket: group-prev
          mod+shift+rightbracket: group-move right
          mod+shift+leftbracket: group-move left

          # hints: letters on every window — type one to jump there (shift: swap with it)
          mod+u: hints
          mod+shift+u: hints swap

          # leader & palette — press mod+space and a pop-up lists the next keys
          mod+space: mode leader
          mod+p: palette

          # apps & control
          mod+return: exec open -na Terminal
          mod+shift+t: retile
          mod+shift+r: reload
          mod+shift+e: quit

        # Key modes (which-key). A binding value can be `command` or `{ command: …, label: … }`;
        # the label is what the pop-up shows. Esc leaves any mode. Non-sticky modes leave after
        # one command; `timeout` (seconds, 0 = never) closes an idle mode.
        modes:
          leader:
            label: Lattice
            bindings:
              l: { command: mode layout, label: layout… }
              r: { command: mode resize, label: resize… }
              w: { command: mode workspace, label: workspace… }
              d: { command: mode display, label: display… }
              g: { command: mode group, label: group… }
              p: { command: palette, label: palette }
              u: { command: hints, label: hints (jump to window) }
              f: { command: toggle-floating, label: float / tile }
              b: { command: balance, label: balance }
              t: { command: retile, label: retile }
              c: { command: reload, label: reload config }
              return: { command: exec open -na Terminal, label: terminal }

          layout:
            label: Layout
            bindings:
              t: { command: layout tree, label: tree }
              d: { command: layout dwindle, label: dwindle }
              m: { command: layout master, label: master }
              f: { command: layout monocle, label: monocle }
              v: { command: split vertical, label: split ↓ (tree) }
              h: { command: split horizontal, label: split → (tree) }
              space: { command: layout next, label: next layout }

          resize:
            label: Resize
            sticky: true
            timeout: 0
            bindings:
              h: { command: resize shrink width, label: narrower }
              l: { command: resize grow width, label: wider }
              k: { command: resize shrink height, label: shorter }
              j: { command: resize grow height, label: taller }
              left: { command: resize shrink width, label: narrower }
              right: { command: resize grow width, label: wider }
              up: { command: resize shrink height, label: shorter }
              down: { command: resize grow height, label: taller }
              equal: { command: balance, label: balance }
              return: { command: mode-exit, label: done }

          group:
            label: Group
            bindings:
              h: { command: group left, label: join left }
              j: { command: group down, label: join below }
              k: { command: group up, label: join above }
              l: { command: group right, label: join right }
              g: { command: group, label: group / ungroup all }
              u: { command: ungroup, label: take out }
              s: { command: group-style toggle, label: tabbed ↔ stacked }
              n: { command: group-next, label: next tab }
              p: { command: group-prev, label: previous tab }
              shift+h: { command: group-move left, label: move tab left }
              shift+l: { command: group-move right, label: move tab right }
              "1": { command: group-tab 1, label: tab 1 }
              "2": { command: group-tab 2, label: tab 2 }
              "3": { command: group-tab 3, label: tab 3 }
              "4": { command: group-tab 4, label: tab 4 }
              "5": { command: group-tab 5, label: tab 5 }
              "6": { command: group-tab 6, label: tab 6 }
              "7": { command: group-tab 7, label: tab 7 }
              "8": { command: group-tab 8, label: tab 8 }
              "9": { command: group-tab 9, label: tab 9 }

          display:
            label: Display
            bindings:
              h: { command: focus-display left, label: focus left display }
              l: { command: focus-display right, label: focus right display }
              n: { command: focus-display next, label: focus next display }
              shift+h: { command: move-to-display left, label: window → left }
              shift+l: { command: move-to-display right, label: window → right }
              w: { command: move-workspace-to-display next, label: workspace → next }

          workspace:
            label: Workspace
            bindings:
              "1": workspace 1
              "2": workspace 2
              "3": workspace 3
              "4": workspace 4
              "5": workspace 5
              "6": workspace 6
              "7": workspace 7
              "8": workspace 8
              "9": workspace 9
              n: { command: workspace next, label: next }
              p: { command: workspace prev, label: previous }
              tab: { command: workspace back-and-forth, label: back and forth }

        rules:
          - match: { app: "^System Settings$" }
            float: true
          - match: { app: "^(Calculator|Archive Utility|Installer|Software Update)$" }
            float: true
        """
}
