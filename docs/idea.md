# Lattice — a keyboard-first tiling window manager for macOS

> The original design plan (October 2026). Kept as the record of *why* Lattice is built the way it is.
> Not a Hyprland/i3 clone and not a Linux daemon port: a new tiling WM designed around how macOS actually works.

## 1. What we want

1. **Tiled windows with layouts.** Ideas from i3, awesome, sway and Hyprland: trees, dwindle, master-stack, monocle, scrolling columns.
2. **Easy workspace switching.** Instant, named and numbered, per display.
3. **Everything by keyboard.** You never need the mouse.
4. **YAML config**, documented: how to set up, modify and customise.
5. **Themes.**
6. **A bar**, documented: how to add, move, modify and customise widgets.

## 2. Hard truths about macOS (these shape everything)

- **No compositor and no WM protocol.** Every macOS tiler (yabai, Amethyst, AeroSpace, Rectangle) moves windows by asking each app through the **Accessibility API (AXUIElement)**. That API is cross-process and asynchronous, and it is *adversarial*: elements go stale, calls fail with `kAXErrorCannotComplete`, and apps clamp, ignore or hang.
  → The core problem is **correctness**, not speed. The language barely matters.
- **Native Spaces have no public API.** yabai controls them by injecting into Dock.app, which needs SIP partially disabled and breaks on every macOS release.
  → **Never disable SIP.** We use **virtual workspaces** instead: the user keeps one native Space per display, and windows on inactive workspaces are *parked* off-screen (as AeroSpace does).
- **No SIP means no:** window animations, opacity, native Space control, or reading other apps' notifications.
- **Private APIs** (SkyLight/CGS, MediaRemote, which is gated since macOS 15.4) are **optional extras only**. Correctness relies on public AX + `CGWindowList`.
- **Scrolling (niri-style) is "logical scrolling".** Only columns near the viewport get real frames; the rest are parked like hidden workspaces. It is not continuous scrolling like a compositor's.

### Parking: decided 2026-10-14, by measurement
The week-1 question was fully off-screen vs a 1px sliver. Measured with `lattice park-test --corners all` on Zen, System Settings and Ghostty (three toolkits, identical results), so **it's a macOS window-server rule:**
- A window entirely off-screen horizontally is pulled back so 40pt shows; ≥1pt on screen is accepted.
- Vertically, the title bar must stay between the menu bar and the Dock, so off-screen in y is impossible.

→ **1pt sliver in a bottom corner** (as AeroSpace does). Only a 1×(title bar + Dock height) strip stays, inside the Dock area. Neighbouring-display checks use the clamped footprint, not the requested frame.

## 3. Product shape (Mac-native)

**One signed, notarized `.app`** (Developer ID + Homebrew cask). The App Store is impossible because AX control doesn't work in the sandbox.

- LSUIElement agent app with a **menu-bar extra**; launches at login and stays alive through **SMAppService**. launchd is an implementation detail; we write no plists by hand.
- **First-run onboarding** with live status for Accessibility and Input Monitoring permissions, plus a **health pane**. Permission problems are the #1 support issue for these tools.
- Diagnostics via `os_log` / `OSSignposter` (Console and Instruments); updates via Sparkle.

### Components

| Component | Role | Privileges |
|---|---|---|
| **Controller** (main app) | Pure reducer core, layout engine, AX workers, reconciliation, persistence, recovery, hotkeys | The **only** binary with AX + Input Monitoring |
| **Bar/HUD helper** (bundled, XPC) | SwiftUI bar per display, which-key HUD, command palette, hint labels, theme rendering | None. Never imports AX |
| **Widget helper** (bundled, XPC) | Runs script widgets, throttled, caches last good output | None (deliberately unprivileged) |
| **`lattice` CLI** (signed, in the bundle) | Scripting, `config check`, `rescue` | Talks XPC to a Mach service; the connection is checked by audit token / code signature |
| **App Intents** | Shortcuts and Spotlight actions ("switch to workspace Mail") | Secondary; never the hotkey path |

- **Crash isolation:** a bar or widget crash never affects window management. If the controller crashes, it is restarted and **restores every parked window**.
- **TCC is per binary.** Test the permission split in the real signed bundle; a helper doesn't inherit grants.
- **URL scheme** only for harmless actions (open palette, import config). Never for focus/move, otherwise any app could control the desktop.

### Controller internals
- **Pure core** (no AppKit): an immutable model plus a reducer, then the layout solver, which produces desired frames. Each window keeps **desired / last-sent / last-observed** frames separately. Changes are applied as transactions with generation IDs, which stops the WM reacting to its own moves.
- **AX effect workers:** a dedicated thread and run loop per app, `AXUIElementSetMessagingTimeout`, and a watchdog. A hung app can never stall the WM.
- AX notifications are **hints**. Reconcile them against the model, with a periodic refresh.
- **Trace recorder and replayer:** record real AX event and frame sequences from difficult apps, then replay them into the core as regression tests. Combine with property tests: no window lost, no window owned twice, every window recoverable.

## 4. Keyboard UX (where a new WM can win)

- **Direct chords** for frequent actions: focus, switch workspace, move, palette.
- **Leader key → modes** (move / resize / layout / launch / workspace), with a **which-key HUD** that lists the available keys, so you can learn it without docs. `Esc` always exits, modes auto-expire, and the bar shows the current mode.
- **Hyper isn't a physical key on Mac.** The default is a non-conflicting chord. There is an **optional built-in Caps Lock → F18 remap** through `hidutil` (public, no Karabiner) to act as the leader.
- **Command palette** (Spotlight-like): fuzzy search over commands, windows, workspaces, apps, layouts and themes.
- **Hint mode** (like the Vimium browser extension): letter labels over windows, with separate *focus* and *swap/move* actions.
- **Workspace-local switcher** alongside Cmd-Tab. Don't replace Cmd-Tab.
- **Resize mode** with step sizes, presets (50/50, 66/33) and *balance*.
- Hotkeys: a **CGEventTap** (full chords, submaps, key swallowing) whose callback only enqueues events. It swallows only keys that match a binding, re-enables itself after a timeout, and shows Secure Input clearly. **Carbon hotkeys** are a degraded fallback when Input Monitoring is missing.

## 5. Layouts & workspaces

- Layouts: **tree** (i3: split h/v, tabbed, stacked), **dwindle**, **master-stack**, **monocle**, **floating**, **logical scroll**. Set per workspace.
- Workspaces: virtual (parked), named and numbered, per-display or global assignment, back-and-forth, app → workspace rules, move-and-follow.
- Per-app **compatibility profiles**: apps that misbehave fall back to floating.

## 6. Config, themes, docs

- **YAML** (Yams) pinned to **1.2 core**, in strict mode. It **rejects** duplicate keys, anchors/aliases/merge keys, custom tags, unknown keys, ambiguous unquoted booleans and dates (the "Norway problem"), and cyclic includes. <!-- gitleaks:allow -->
- Layout of the config directory: `~/.config/lattice/config.yaml` with `include:` for `bindings.yaml`, `rules.yaml` and `bar.yaml`; themes in `themes/*.yaml`.
- **Hot reload** via FSEvents. On an invalid config, keep the last good one and show the error in the HUD with line and column.
- A published **JSON Schema** gives autocomplete and validation in VS Code (yaml-language-server). The **key reference is generated from the schema**. Concepts, recipes, recovery and widget tutorials are written by hand. CLI: `lattice config check` and `lattice config explain <key>`.
- **Themes** are design tokens: colours, fonts, radii, gaps, border widths, bar height, HUD style. They follow macOS light/dark automatically and apply to the bar, HUD, palette, hints and borders.
- **Focus borders** are our own click-through, non-activating overlay windows. No SkyLight needed.

## 7. Bar

- SwiftUI, one panel per display, notch-aware.
- Publishes a **versioned reserved-region contract** ("struts") to the controller, which derives usable area from it rather than guessing from `visibleFrame`. Modes: `overlay` | `reserve-space`.
- `bar.yaml`: `left` / `center` / `right` lists of widget instances, each with props and theme overrides.
- **Built-in widgets:** workspaces, focused app/title, layout, mode, clock/calendar, battery, CPU/mem, network, volume, keyboard layout, media (best-effort).
- **Custom widgets:** `type: script`, i.e. a command with an interval or event trigger. Output is plain text or JSON `{text, icon, color, tooltip}`. Runs in the widget helper. **No in-process plugins in v1.**
- Docs: a cookbook titled "Add a bar widget in 5 minutes".

## 8. Milestones (each with an exit criterion)

1. **Week 1: compatibility test against difficult apps.** AX worker with timeouts and watchdog, trace recorder, frame get/set, `rescue`, parking experiments across browsers, Electron apps, Xcode, Finder, sheets, fullscreen, display hotplug, sleep/wake and Mission Control.
   **Exit:** killing or restarting the controller never strands a window; failures can be diagnosed; parking strategy chosen.
2. **Keyboard-first MVP.** Chords + leader HUD, tree/dwindle/monocle/floating, named virtual workspaces, palette, YAML validation + hot reload, rescue CLI.
   **Exit:** a full workday keyboard-only on one display.
3. **Daily driver.** Multiple displays, transactional reconciliation, app rules, compatibility profiles, trace replay + property tests in CI, sleep/hotplug/fullscreen.
   **Exit:** one week of normal work with no manual rescue.
4. **Mac surface.** Themed bar, hints, switcher, widget helper, schema docs + cookbooks, App Intents, signed `.app` + onboarding.
   **Exit:** a bar or widget crash never affects the controller.
5. **Advanced.** Master-stack, tabbed/stacked, logical scroll, optional private-API extras.
   **Exit:** every optional feature degrades safely.

## 9. Non-goals

Disabling SIP, code injection, Dock modification · native Space control · compositor-grade animation or opacity · truly continuous infinite scrolling · in-process plugins · reading system notifications.

## 10. Top risks

1. **Apps are inconsistent through AX.** Mitigation: per-app capability profiles, bounded workers, reconciliation, floating fallback, trace corpus.
2. **Parking or scrolling strands windows.** Mitigation: test matrix, conservative parking, crash restore, a `rescue` that always works.
3. **Fragile TCC permissions and input lifecycle.** Mitigation: onboarding health checks, clear degraded modes, testing in the signed bundle, event-tap recovery.

## 11. Tech

Swift 6 (strict concurrency) · SwiftPM · an AppKit-free core (could be extracted to Rust later) · Yams · swift-testing · Developer ID signing + notarization.
