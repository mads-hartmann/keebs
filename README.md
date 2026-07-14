# keebs

A small, personal macOS keyboard remapper with Emacs-style mark selection and
latched key sequences. It runs as a Swift daemon using a
[`CGEventTap`](https://developer.apple.com/documentation/coregraphics/cgevent/tapcreate%28tap%3Aplace%3Aoptions%3Aeventsofinterest%3Acallback%3Auserinfo%3A%29).

## Key mappings

Mappings are hardcoded as `KeyMapping` values in `Sources/keebs/main.swift` and
are applied before mark mode:

| Input | Output |
| --- | --- |
| `Caps Lock` | `Control` |
| `Command-Control-H/J/K/L` | Left/Down/Up/Right |
| `Command-Control-S/W/D` | Down/Up/Right |
| `Control-P/B/F/N` | Up/Left/Right/Down |
| `Control-A/E` | `Command-Left/Right` |
| `Control-G` | `Escape` |
| `Control-V` / `Option-V` | `Page Down` / `Page Up` |
| `Option-B/F` | `Option-Left/Right` |
| `Option-D` | `Option-Delete Forward` |

`Caps Lock` is mapped through macOS's
[HID key-mapping facility](https://developer.apple.com/library/archive/technotes/tn2450/)
while keebs is running. The mapping is removed on normal shutdown and by a
watchdog after a crash. Keebs will not install it when another HID mapping
already exists.

## Mark mode

Press `Control-Space` to toggle mark mode. A HUD remains visible while it is
active.

Mark mode adds `Shift` to navigation events, including:

- Arrow keys, Home, End, Page Up, and Page Down
- Navigation with existing modifiers, such as `Option-Right`
- Mapped movement keys such as `Control-N`
- `Control-A/E`, producing `Shift-Command-Left/Right`

This extends the current selection using the normal macOS navigation behavior.
Mark mode is deactivated by:

- `Escape`, Delete, or Backspace
- `Control-G`, which emits `Escape`
- `Command-X` or `Command-V`
- Regular typing
- A mouse click or application switch
- Starting a hyper sequence

## Hyper sequences

Tap `Right Command` to latch hyper mode and show its HUD. The real Command
modifier is suppressed. Press `Right Command` again, click the mouse, or switch
applications to cancel.

- `Right Command`, `r`, `w`: switch windows in [Raycast](https://www.raycast.com/)
- `Right Command`, `r`, `c`: Raycast clipboard history
- `Right Command`, `r`, `k`: Raycast confetti
- `Right Command`, `r`, `s`: Raycast snippet search
- `Right Command`, `r`, `i`: Raycast screenshot search
- `Right Command`, `r`, `n`: Raycast notes
- `Right Command`, `a`, `t`: open Ghostty
- `Right Command`, `a`, `e`: open Visual Studio Code

A completed sequence launches its target with `/usr/bin/open` and exits hyper
mode. An unknown key is consumed and cancels the sequence.

## Alternatives

### [Karabiner-Elements](https://karabiner-elements.pqrs.org/)

Karabiner-Elements can implement the key mappings and approximate mark mode,
but adding `Shift` while mark mode is active requires separate rules for every
movement binding. Keebs keeps the movement mappings independent and applies
mark mode as a generic step after them.

## Build and run

Requires macOS 14 or later and Swift 5.9 or later.

```sh
swift build
swift run keebs --debug
```

Grant keebs Accessibility and Input Monitoring access in **System Settings →
Privacy & Security**, then restart it.

Use `--trace` to log individual key events:

```sh
swift run keebs --trace
```

The default [event-tap location](https://developer.apple.com/documentation/coregraphics/cgeventtaplocation)
is `annotated`. If another tool intercepts a shortcut before keebs sees it, try
the earlier session tap:

```sh
swift run keebs --trace --tap session
```
