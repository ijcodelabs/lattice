# The bar

A status bar at the top or bottom of the screen showing workspaces, the focused window, the layout, the current key mode, system stats, a clock, and anything a shell command can print.

```yaml
# ~/.config/lattice/config.yaml
bar:
  enabled: true
  position: top      # top | bottom
  mode: reserve      # reserve: windows tile around it · overlay: floats above windows
  height: 30         # 16–80
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
```

Colours, font and corner radius come from the [theme](themes.md).

## Where it sits

- **`top`**: just below the macOS menu bar. If you auto-hide the menu bar (System Settings → Control Center → *Automatically hide and show the menu bar*), the bar sits at the very top of the screen.
- **`bottom`**: just above the Dock.
- **`reserve`** (default): tiled windows leave room for the bar. **`overlay`**: windows use the full height and the bar floats on top.

## Add, move and remove widgets

The bar has three sections, `left`, `center` and `right`, and each is a list of widgets drawn in order:

- **Move a widget:** cut its line and paste it into another list or position.
- **Remove a widget:** delete its line.
- **Add a widget:** add its name (`- cpu`), or `- { type: NAME, option: value }` to configure it.

Save, and the bar updates immediately.

## Widgets

| Widget | Shows | Options |
|---|---|---|
| `workspaces` | One pill per workspace. Active = accent, has windows = surface; **click to switch**. | `show-empty: true` also lists empty workspaces (default: only occupied + active) |
| `focused` | `App — window title` of the focused window | `max-length: 70` (5–300) |
| `layout` | Icon + name of this workspace's layout | — |
| `mode` | The current key mode (`LEADER`, `RESIZE`…); hidden when none | — |
| `clock` | Date/time, updated every second | `format: "HH:mm"` ([Unicode date patterns](https://www.unicode.org/reports/tr35/tr35-dates.html#Date_Field_Symbol_Table): `EEE` weekday, `d` day, `MMM` month, `HH:mm:ss`) |
| `battery` | Percent + charging icon; urgent colour at ≤ 20% unplugged. Hidden on desktops. | — |
| `cpu` | CPU use across all cores, every 2 s; urgent colour above 85% | — |
| `memory` | Memory used (as in Activity Monitor), every 2 s; urgent colour above 90% | — |
| `script` | First line printed by a shell command | `command:` (required), `interval:` seconds (1–86400, default 10) |
| `text` | Fixed text | `text:` (required) |

## Script widgets: anything a command can print

```yaml
right:
  - { type: script, command: "~/.config/lattice/scripts/wifi.sh", interval: 30 }
  - { type: script, command: "date +%V | sed 's/^/W/'", interval: 3600 }
```

- The command runs with `/bin/sh -c`, every `interval` seconds, off the main thread.
- It has **5 seconds** to finish, or it's stopped and shows `⚠︎ timeout`. A slow run never overlaps the next one.
- The widget shows the **first line** of standard output. Standard error is ignored.

To control colour and icon, print **JSON** instead:

```bash
#!/bin/sh
# ~/.config/lattice/scripts/wifi.sh
ssid=$(ipconfig getsummary en0 | awk -F' SSID : ' '/ SSID : / {print $2}')
if [ -n "$ssid" ]; then
  echo "{\"text\": \"$ssid\", \"icon\": \"wifi\"}"
else
  echo '{"text": "offline", "icon": "wifi.slash", "color": "#ff5f57"}'
fi
```

- `text` is the text to show.
- `icon` (optional) is any [SF Symbol](https://developer.apple.com/sf-symbols/) name.
- `color` (optional) is a `#rrggbb` colour; it defaults to the theme's foreground.

Remember `chmod +x` on script files.

### Recipes

```yaml
# Now playing (Music app)
- { type: script, interval: 5, command: "osascript -e 'tell application \"Music\" to if it is running then (artist of current track) & \" – \" & (name of current track)'" }

# Disk free on /
- { type: script, interval: 300, command: "df -h / | awk 'NR==2 {print $4 \" free\"}'" }

# Uptime
- { type: script, interval: 60, command: "uptime | sed 's/.*up \\([^,]*\\),.*/up \\1/'" }

# A label
- { type: text, text: "λ" }
```

## How it works (for the curious)

The bar is drawn by the `lattice-ui` helper process, the same one that draws the which-key pop-up, the palette and the focus border. That process never touches the Accessibility API. If it crashes it's restarted, and tiling never notices.

The bar's position and reserved height are computed by Lattice's core from this config, so the bar and the tiled windows can never disagree about where the bar is.
