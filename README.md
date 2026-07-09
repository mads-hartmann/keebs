# keebs

A tiny macOS keyboard remapper focused on one workflow: Emacs-style active
mark selection.

The narrow scope is: toggle a mark state, then add `Shift` to keypresses while
that state is active. Since most macOS apps already interpret shifted movement
keys as selection extension, this gives us an application-agnostic way to get
the Emacs-style active region workflow across different apps.

## Goal

Make `Ctrl-Space` behave like a lightweight Emacs active mark workflow in macOS
text fields and apps.

In Emacs terms, the relevant ideas are:

- `point`: the current cursor position
- `mark`: a saved position
- `region`: the text between point and mark
- `set-mark-command`: usually bound to `Ctrl-Space`
- `transient-mark-mode`: shows the active region as a visible selection

For this project, "mark mode" means our own keyboard-level state where movement
commands extend the current selection.

## MVP Behavior

- `Ctrl-Space` toggles mark mode.
- While mark mode is active, movement keypresses get `Shift` added.
- Existing movement bindings are left to the user, Karabiner, the app, or the
  operating system.
- Editing/action keys deactivate mark mode.
- Regular typing deactivates mark mode and sends the key as-is.
- A small HUD is shown while mark mode is active.

Example pipeline:

```text
Down Arrow
  -> mark mode is active
  -> add Shift
  -> emit Shift-Down Arrow
```

If another tool or app maps `Ctrl-n` to `Down Arrow`, this project should only
care about the final key event it sees and add `Shift` while mark mode is
active.

## Initial Keys

The first version should add `Shift` to navigation keys such as:

- arrow keys
- `Page Up` / `Page Down`
- `Home` / `End`
- navigation keys with existing modifiers, such as `Option-Right Arrow` or
  `Command-Left Arrow`

It should not define Emacs movement bindings like `Ctrl-n` or `Ctrl-f` in the
MVP. Those can be handled elsewhere for now.

## Deactivation

The first version should deactivate mark mode on:

- `Escape`
- `Ctrl-g`, emitting `Escape`
- `Delete` / `Backspace`
- `Command-x`
- `Command-v`
- mouse click
- app switch
- regular typing, with the typed key sent unchanged

Typing letters should not get `Shift` applied. Caps Lock already exists for
that. A typed character should leave mark mode and pass through unchanged.

## Non-Goals

- General Karabiner JSON compatibility
- Device-specific rules
- App-specific rules
- Input-source rules
- Mouse key emulation
- Emacs movement bindings
- Hyper key layers
- Shell/app launchers
- Multiple profiles

Those can come later if they become useful, but the project starts with the
active mark workflow only.

## Alternatives

### Karabiner-Elements

Karabiner-Elements can already approximate this workflow, but the configuration
becomes awkward because mark mode has to redefine every movement binding with
`Shift` added. This project tries a smaller model: keep movement bindings
elsewhere, and only add `Shift` while mark mode is active.

## Likely Implementation

Start with a small Swift daemon using a `CGEventTap`.

The event pipeline should be:

```text
read keyboard event
  -> normalize key and modifiers
  -> handle mark mode toggles/cancellations
  -> if mark mode is active and event is navigation, add Shift
  -> if mark mode is active and event is typing/action, deactivate mark mode
  -> emit synthetic event or pass through original
```

If a pure event tap is not reliable enough for modifier behavior, we can later
add a virtual HID backend. That should be a later step, not part of the first
prototype.

## Running

Build the daemon:

```sh
swift build
```

Run it:

```sh
swift run keebs --debug
```

The first run needs permissions in System Settings > Privacy & Security:

- Accessibility
- Input Monitoring

After granting permission, restart the daemon.

For event-level debugging, run:

```sh
swift run keebs --trace
```

If `Ctrl-Space` does not appear in the trace, macOS or another tool may be
handling it before the annotated session tap. Try the earlier session tap:

```sh
swift run keebs --trace --tap session
```

The default is:

```sh
swift run keebs --trace --tap annotated
```
