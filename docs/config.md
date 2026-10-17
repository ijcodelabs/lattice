# Configuring Lattice

> Also: **[themes.md](themes.md)** (colours, fonts, focus border) · **[bar.md](bar.md)** (the bar and its widgets).

Lattice reads **`~/.config/lattice/config.yaml`** (or `$XDG_CONFIG_HOME/lattice/config.yaml`).
With no file, the built-in defaults apply.

```bash
lattice config init      # write the documented default config to start from
lattice config check     # validate it (errors show file:line:column)
lattice bindings         # list the active key bindings, resolved for your keyboard layout
```

**Saving the file reloads it.** If the new version has an error, Lattice keeps the previous config and prints the error with its line and column.

---

## Quick start

**The app** (normal use):

1. `scripts/build-app.sh --install`, then open `~/Applications/Lattice.app`.
2. Grant **Accessibility** (and Input Monitoring) when the welcome window asks; tiling starts by itself.
3. The menu-bar icon (▦) has **Open Config**, **Reload Config**, **Start at Login**, **Show Log**
   (`~/Library/Logs/Lattice/lattice.log`) and **Quit** (quitting brings hidden windows back).

**From a terminal** (development): grant your terminal Accessibility, then `lattice config init` and
`lattice run`. Stop it with `Ctrl-C` or `mod+shift+e`. Only one Lattice runs at a time (app or terminal).

**Turn off macOS's own window tiling.** macOS 15+ snaps windows you drag to screen edges or with ⌥ held,
before Lattice can place them. System Settings → Desktop & Dock → Windows: turn off *Drag windows to
screen edges to tile*, *Drag windows to menu bar to fill screen* and *Hold ⌥ key while dragging windows
to tile*. The welcome window has a button for it, and `lattice doctor` tells you if it's still on.

Try it on a few apps first:

```bash
lattice run --apps TextEdit,Notes --restore-on-exit
```

`--apps` manages only the listed apps. `--restore-on-exit` also puts the tiled windows back where they were when Lattice started.

---

## All settings

```yaml
mod: ctrl+alt                 # main modifier; `mod` in bindings expands to it

gaps:
  inner: 8                    # points between windows (0–200)
  outer: 8                    # points between windows and the screen edge (0–200)

layout:
  default: dwindle            # tree | dwindle | master | monocle — for new workspaces
  ratio: 0.5                  # dwindle split / master column share (0.1–0.9)

workspaces: ["1", "2", "3"]   # names, in order; the first is active at start

focus-new-windows: true       # new windows become the focused one
focus-wrap: true              # at the last window in a direction (no display beyond), focus wraps around

theme: lattice                # see docs/themes.md
borders: { enabled: true }    # focus border (colour/width from the theme)
bar: { … }                    # see docs/bar.md

bindings:                     # chord: command  (see below)
  mod+h: focus left

modes:                        # leader / which-key keymaps (see below)
  leader:
    bindings:
      l: { command: mode layout, label: layout… }

rules:                        # see below
  - match: { app: "^System Settings$" }
    float: true
```

Unknown keys are errors, so a typo like `gap:` is reported instead of silently ignored.

### `mod`

`mod` is any combination of `cmd`, `ctrl`, `alt` (also `opt`/`option`), `shift`, or `hyper` (all four).
The default `ctrl+alt` is deliberate. On many keyboard layouts (Croatian, German, French, …) **Option alone types characters** like `@ { } [ ] |`, so binding plain `alt+…` would break typing.

---

## Layouts

| Layout | What it does |
|---|---|
| `dwindle` | Each new window takes half of the previous one, split along the longer side (spiral). |
| `tree` | i3-style tree. `split vertical/horizontal` decides where the *next* window goes. Pressing `mod+v`/`mod+b` on a dwindle or master workspace switches it to tree **without moving anything**, so you can keep arranging by hand; `mod+d` goes back to dwindle. |
| `master` | One master window on the left (`ratio` wide); the rest stacked on the right. |
| `monocle` | Every window fills the screen; focus left/right cycles through them. Choosing monocle again (`mod+f`) goes back to the previous layout, arrangement intact — like i3's fullscreen toggle. |

Each workspace remembers its own layout. Switching layouts never loses your arrangement, because the tree and the window order are kept in sync.

**Floating windows** (`toggle-floating`, or rules with `float: true`) keep their own frame and stay on their workspace.

---

## Workspaces

Workspaces are **virtual**. Lattice uses a single macOS Space and hides the windows of inactive workspaces by parking them in a bottom corner of the screen, leaving only a 1-point sliver visible. macOS doesn't allow a window fully off-screen.

- If you Cmd-Tab or click into an app whose window is on another workspace, Lattice **switches to that workspace**.
- **Use one macOS Space per display** and switch with Lattice's workspaces (`mod+1…9`), not macOS Spaces
  (⌃←/⌃→, three-finger swipes, Mission Control). Lattice manages the Space it runs on. On another macOS
  Space its windows aren't visible to it; Lattice keeps them and picks up where it left off when you come
  back, but the bar won't follow you there. To remove extra Spaces: Mission Control → hover the Spaces
  strip → click ✕. Also consider turning off *Automatically rearrange Spaces* (Desktop & Dock).
- If Lattice quits or crashes, hidden windows come back: on quit immediately, after a crash via `lattice rescue` or the next `lattice run`.

---

## Groups (tabbed / stacked windows)

A **group** is several windows sharing one tile, only one of them shown at a time, like browser tabs. It works in every layout: in dwindle, master, monocle or tree, a group takes one slot like a single window. For example, Safari, Slack and Mail grouped on the left with Ghostty on the right.

```
┌──────────────────────────┬──────────────────────┐
│ Safari │ Slack │ ▌Mail▐   │                      │   ← tab strip (click a tab, or mod+[ / mod+])
├──────────────────────────┤                      │
│                          │       Ghostty        │
│          Mail            │                      │
│                          │                      │
└──────────────────────────┴──────────────────────┘
```

| Keys | Does |
|---|---|
| `mod+g` → `h`/`j`/`k`/`l` | Join the window in that direction (makes a group, or adds to its group) |
| `mod+g` → `g` | Group / ungroup: a group of one, or split the group back into tiles |
| `mod+g` → `u` | Take the focused window out of its group |
| `mod+g` → `s` | Tabbed ↔ stacked |
| `mod+]` / `mod+[` | Next / previous tab |
| `mod+shift+]` / `mod+shift+[` | Move the shown tab right / left in the strip (repeat to keep moving) |
| `mod+g` → `shift+h` / `shift+l` | Move the shown tab left / right |
| `mod+g` → `1`–`9` | Show tab N |

How it behaves:

- **A window opened from a grouped window joins its group**, as in i3 and Hyprland. Use `mod+g g` on a single window to start a group of one that new windows will join.
- **To open a window next to the group instead of inside it**, press `mod+v` (below) or `mod+b` (beside)
  on the group first, then open the window. It becomes its own tile there, sharing the group's space.
  This is one-shot: it applies to the next window only, and focusing another tile cancels it.
- **Hidden tabs are parked** (a 1-pixel sliver in a corner), just like windows on hidden workspaces, not stacked behind. Other apps can't pop them in front, and if Lattice quits they come back.
- **Cmd-Tab or the palette to a hidden tab switches the group to it.**
- When a group drops to **one window**, it turns back into a normal tile.
- Moving, floating or sending a grouped window to another workspace or display takes **just that window** out of the group.

```yaml
groups:
  tab-bar: true      # false: no strip (the bar's focused widget still names the window)
  style: tabbed      # tabbed | stacked — for new groups
  tab-height: 26     # one row; stacked groups use one row per window (16–48)
```

Tab colours come from the theme: the active tab of the focused group uses `accent`, other tabs use `surface`.

---

### macOS native tabs

Apps with macOS's own tab bar (Ghostty, Terminal, Finder, TextEdit…) get **one tile per tab bar**, however many tabs it has: a new tab (`cmd+t`), switching tabs or closing one (`cmd+w`, when others remain) keeps the same slot instead of splitting the screen or moving the window. Lattice tiles the tab that's showing; to tile tabs side by side, move one to its own window (Window → *Move Tab to New Window*) or use Lattice's own groups.

## Hints: jump to any window by letter

Press **`mod+u`** and a big letter appears on every visible window, on every display. Type it and that
window is focused. **`mod+shift+u`** does the same but *swaps* the focused window with the one you pick.

- Labels use the home row (`a s d f j k l g h`). With more than 9 windows they become two letters.
  Typing the first letter narrows the choice.
- **Esc**, or any key that matches no label, cancels; nothing is typed into your apps.
- Also in the leader menu: `mod+space` → `u`.

## The mouse

Lattice is keyboard-first, but the mouse cooperates:

| You do | Lattice does |
|---|---|
| Drag a window by its title bar **onto another window** | Swaps the two |
| Drag a window onto **another display** | Moves it there (next to the window under the pointer, or into the empty workspace) |
| Drag a window's **edge or corner** | Resizes the split; the neighbour on that side gives or takes the space |
| Hold **mod** while dragging | Floats the window where you drop it |
| Drop it anywhere else | It snaps back into its tile |
| Drag a **floating** window | It just stays where you put it |

---

## Session: your layout survives restarts

Lattice **saves its layout continuously** (about 1.5 s after each change, and on quit) and **rebuilds it the next time it starts**: workspaces, layouts, splits, groups and their tabs, floating windows, and which display shows what.

- **Restarting Lattice** while your apps keep running brings the same layout back instantly.
- **After a reboot**, apps reopen their windows (macOS *Reopen windows when logging back in*, plus each app's own restoration). As the windows appear, Lattice slots them back in over the next `grace` seconds, and you see the layout rebuild as apps start.
- Windows are recognised by **app + window title**, then by their order and position among the app's windows. Similar titles still match ("Inbox – Mail" ↔ "Inbox (2) – Mail").
- A saved window that never comes back leaves **no hole**: its place closes up. A window Lattice hasn't seen before goes to the workspace where its app mostly was.
- **Pressing a layout key while a restore is running ends the restore**, so it never undoes what you're doing.
- A missing display (laptop alone instead of docked) works like unplugging it: its workspaces show up on the main display.

```yaml
session:
  restore: true        # rebuild the last layout on start
  grace: 60            # seconds to keep matching windows as apps reopen (0–600)
  save-titles: true    # false: match by app + order only; window titles never hit the disk
```

- `lattice session show` lists what's saved; `lattice session forget` deletes it.
- `lattice run --no-restore` starts with a clean layout once (the next save overwrites the old session).
- `lattice run --session FILE` uses a different session file, e.g. one per setup.

The session lives in `~/Library/Application Support/Lattice/session.json`, readable only by you. It contains window titles unless `save-titles: false`.

Lattice doesn't start apps itself, and it can't reopen specific documents or tabs; that's each app's own job. Starting Lattice at login comes with the Lattice app.

---

## Several displays

Each display shows **one workspace at a time**, like i3 and sway. The workspace with the focused window is the *focused* one.

- **`workspace N`:** if N has windows and is already showing on another display, focus just moves there. Otherwise N appears on its pinned display (see below), else — if it has windows — on the display it was last shown on, else on the focused display, replacing what that display showed.
- **Empty workspaces belong to no display**, like i3 and sway: an empty N always opens where you are, even if it's sitting empty on another display (that display then shows another free workspace). A workspace you **leave empty is deleted** — its display, layout and splits are forgotten — so it starts fresh next time. Pinned workspaces keep their display.
- **`focus` and `move` cross displays.** `focus right` from the rightmost window jumps to the display beyond the right edge, and `move right` carries the window over to it, even when that display's workspace is empty.
- **Directions follow the real arrangement** (System Settings → Displays): a laptop placed *below* a monitor is reached with `down`, never with left/right. With no display that way, focus wraps around the workspace instead.
- **Plugging in** a display shows the next free workspace on it. **Unplugging** one moves its workspaces to the main display; nothing is lost, and the hidden ones are parked there.
- **Plugging the same displays back in** (or waking from sleep, when macOS briefly drops the external monitor) restores the arrangement you had with them: each display shows the workspace it showed before.
- **Sleep and screen lock:** while the Mac sleeps or is locked, macOS reports windows unreliably, so Lattice stops checking for closed windows. After you unlock, it puts the layout back as it was before sleep (like [session restore](#session-your-layout-survives-restarts)).
- Every display gets **its own bar**, listing that display's workspaces. The focused workspace is filled in; one that's showing but not focused is outlined.

Pin workspaces to displays:

```yaml
workspace-displays:
  "1": main          # the display with the menu bar
  "9": secondary     # the first other display
  "8": "DELL"        # any display whose name contains DELL (case-insensitive)
  "7": "2"           # second display, counting left → right
```

When a pinned display is unplugged, its workspaces move to the main display. When you plug it back in, they return to it.

Default keys: **`mod+o`** focuses the next display, **`mod+shift+o`** moves the focused window to the next display, and **`mod+space d`** opens the display menu.

---

## Bindings

```yaml
bindings:
  mod+h: focus left
  mod+shift+2: move-to-workspace 2
  cmd+ctrl+return: exec open -a Ghostty
```

**A new terminal window per keypress:** `open -na App` starts a whole new *instance* each time (one more Dock icon per press). For Ghostty, ask the running instance for a window instead:

```yaml
  mod+return: exec osascript -e 'if application "Ghostty" is running then' -e 'tell application "Ghostty" to new window' -e 'end if' -e 'tell application "Ghostty" to activate'
```

macOS asks once whether Lattice may control Ghostty.

**Chords** are modifiers plus one key, joined with `+`:

- **Modifiers:** `cmd`, `ctrl`, `alt`, `shift`, `hyper`, `mod`.
- **Keys:** any single character (`h`, `1`, `[`, `/`), or one of `return` (`enter`), `tab`, `space`, `escape`, `backspace`, `delete`, `left`, `right`, `up`, `down`, `home`, `end`, `pageup`, `pagedown`, `f1`–`f20`, `minus`, `equal`, `comma`, `period`, `slash`, `backslash`, `semicolon`, `quote`, `grave`, `leftbracket`, `rightbracket`.
- **Characters follow your keyboard layout.** On QWERTZ, `mod+z` is the key labelled Z. `lattice bindings` marks any key your layout can't type unshifted; those fall back to the US key position.
- Two chords that end up the same (e.g. `ctrl+h` and `control+h`) are an error.

### Commands

| Command | Effect |
|---|---|
| `focus left\|right\|up\|down` | Focus the neighbouring window on this workspace (in monocle: previous/next). Past the last one: the display in that direction if there is one, else wrap to the far side (`focus-wrap`). |
| `move left\|right\|up\|down` | Swap with the neighbouring window (floating windows nudge by 40pt). |
| `workspace NAME` | Switch to a workspace (created on demand if not listed). |
| `workspace back-and-forth` | Switch to the previous workspace. |
| `workspace next\|prev` | Cycle through workspaces. |
| `move-to-workspace NAME [follow]` | Send the focused window there; with `follow`, go along. |
| `layout tree\|dwindle\|master\|monocle\|next` | Set or cycle this workspace's layout. `layout monocle` on a monocle workspace returns to the layout before it. |
| `split horizontal\|vertical` (`h`/`v`) | Put the next window beside/below the focused one (or group). On a dwindle/master workspace this first turns it into a tree with the same arrangement. |
| `toggle-floating` | Float or re-tile the focused window. |
| `resize grow\|shrink [width\|height] [amount]` | Change the focused window's share (`amount` 0–1, default 0.05). |
| `balance` | Reset all splits and the ratio. |
| `exec SHELL COMMAND` | Run a shell command (`/bin/sh -c`), e.g. `exec open -a Ghostty`. |
| `focus-display left\|right\|up\|down\|next\|prev` | Focus the workspace shown on that display. |
| `move-to-display …` (same targets) | Move the focused window onto that display's workspace, and follow it. |
| `move-workspace-to-display …` | Move the whole focused workspace to that display. |
| `group` | Toggle grouping: wrap the focused window in a group of one, or dissolve its group. |
| `group left\|right\|up\|down` | Put the focused window into the neighbouring tile's group (making one if needed). |
| `ungroup` | Take the focused window out of its group into its own tile. |
| `group-next` / `group-prev` | Show the next/previous window of the focused group. |
| `group-style tabbed\|stacked\|toggle` | Tab strip style of the focused group. |
| `group-move left\|right\|up\|down` | Move the shown tab one place in its strip (left/up = earlier). Stops at the ends. |
| `group-tab N` | Show tab N (1-based) of the focused group. |
| `mode NAME` | Enter a key mode; its pop-up lists the next keys (see *Modes*). |
| `mode-exit` | Leave the current mode (useful inside sticky modes). |
| `palette` | Open the command palette. |
| `focus-window ID` | Jump to a window, switching workspace if needed (the palette uses this). |
| `hints` / `hints swap` | Letters on every visible window; type one to focus it / swap the focused window with it. |
| `swap-window ID` | Swap the focused window with another (any workspace or display). |
| `session save\|restore\|forget` | Save the layout now / rebuild it from the saved session / delete the saved session. |
| `retile` | Re-send every window's frame (if an app drifted). |
| `reload` | Reload the config file. |
| `quit` | Stop Lattice, bringing hidden windows back. |

A binding value is either the command text, or a mapping with a label for the pop-up:

```yaml
bindings:
  mod+space: mode leader
  mod+p: { command: palette, label: palette }
```

---

## Modes (leader key + which-key pop-up)

Press **`mod+space`** and a pop-up at the bottom of the screen lists what each next key does. Keys inside a mode need no modifiers: `mod+space`, then `l`, then `t` sets the tree layout. You don't need to memorise anything; the pop-up shows the way.

```yaml
modes:
  leader:
    label: Lattice                 # pop-up title
    timeout: 4                     # seconds idle before it closes (0 = never), default 4
    bindings:
      l: { command: mode layout, label: layout… }   # leads to another mode (shown as "+ layout…")
      f: { command: toggle-floating, label: float / tile }
  resize:
    label: Resize
    sticky: true                   # stay in the mode after each command
    timeout: 0
    bindings:
      h: resize shrink width
      l: resize grow width
      return: mode-exit
```

How keys behave inside a mode:

- **Esc** always leaves the mode.
- A **non-sticky** mode closes after one command. A **sticky** mode (like `resize`) stays open until you press Esc or run `mode-exit`.
- A **global** binding (e.g. `mod+3`) still works inside a mode, and closes it.
- **Any other key** closes the mode and is swallowed, so a half-remembered sequence never types into your app.
- `mode X` must name a mode defined under `modes:`. A typo is a config error, reported at its line.

The default config ships four modes:

| Mode | Opened by | Keys |
|---|---|---|
| `leader` | `mod+space` | `l` layout… · `r` resize… · `w` workspace… · `d` display… · `p` palette · `f` float/tile · `b` balance · `t` retile · `c` reload · `return` terminal |
| `layout` | leader → `l` | `t` tree · `d` dwindle · `m` master · `f` monocle · `v`/`h` split · `space` next |
| `resize` (sticky) | leader → `r` | `h`/`l` narrower/wider · `k`/`j` shorter/taller · arrows · `=` balance · `return` done |
| `workspace` | leader → `w` | `1`–`9` · `n`/`p` next/previous · `tab` back and forth |
| `group` | `mod+g` or leader → `g` | `h`/`j`/`k`/`l` join · `g` group/ungroup all · `u` take out · `s` style · `n`/`p` tabs · `⇧h`/`⇧l` move tab · `1`–`9` tab N |
| `display` | leader → `d` | `h`/`l` focus left/right · `n` next · `⇧h`/`⇧l` move window · `w` move workspace |

## Command palette

**`mod+p`** opens a Spotlight-style palette. Type to fuzzy-search windows (on any workspace), workspaces, layouts and commands. Use ↑/↓ to move, Return to run, and Esc or a click elsewhere to cancel. Picking a window on another workspace takes you there.

The pop-up and the palette run in a separate helper process, `lattice-ui`. If it crashes it's restarted, and window management carries on unaffected.

---

## Rules

```yaml
rules:
  - match: { app: "^System Settings$" }      # regex on the app name (case-insensitive)
    float: true
  - match: { bundle-id: "com.tinyspeck.slackmacgap" }   # exact bundle id
    workspace: "3"
  - match: { app: "Safari", title: "Picture in Picture" }   # all given matchers must match
    float: true
```

- `match` takes `app` (regex), `bundle-id` (exact) and `title` (regex). Give at least one.
- Actions are `float: true|false` and `workspace: NAME`. Give at least one.
- When several rules match, later rules override earlier ones.

---

## Strict YAML (why some things are errors)

YAML has traps. Lattice refuses them instead of guessing:

| Not allowed | Why | Write instead |
|---|---|---|
| `workspaces: [no, yes]` | YAML 1.1 reads `no`/`yes`/`on`/`off`/`~` as booleans or null (the "Norway problem") | `["no", "yes"]` |
| `&anchor` / `*alias` / `<<:` | Hidden indirection makes configs hard to read and diff | Repeat the value |
| `!!str`, `!!map`, other tags | Explicit types aren't needed | Plain values or quotes |
| Duplicate keys | The second one would silently win | One key |
| Unknown keys | Typos would be ignored | Check the spelling |

Booleans are exactly `true`/`false`. Quote workspace names that are numbers (`"1"`).

---

## Troubleshooting

- **Hotkeys do nothing:** run `lattice doctor`. `LATTICE_DEBUG_KEYS=1 lattice run` logs every key the tap sees and whether it was swallowed. Accessibility must be granted to the app you run Lattice from. If *Secure Input* is ON, a password field or a terminal with "Secure Keyboard Entry" is swallowing all keys.
- **A window is lost off-screen:** `lattice rescue` restores everything Lattice parked and pulls any stranded window back on screen.
- **An app doesn't tile:** dialogs, sheets and panels are never tiled; only standard windows are. `lattice list --all` shows what Lattice sees.
