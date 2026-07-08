# Decision Log

Use this file for technical questions that were researched and resolved. Keep
entries short: a heading, the decision, and the reasoning that matters later.

## Use an Active CGEventTap for Key Events

For the MVP, listen to key events with a `CGEventTap` configured as an active
filter, not a passive listener.

An active event tap can pass events through unchanged, modify them, or suppress
them by returning `nil`. That is enough for mark mode: `Ctrl-Space` can be
consumed to toggle state, navigation events can be returned with `Shift` added,
and typing/action events can deactivate mark mode while passing through
unchanged. This keeps the first version driverless and avoids a virtual HID
device until we know the event-tap approach is not reliable enough.

## Use a Tail-Appended Annotated Session Event Tap

For the MVP, use a `CGEventTap` at `kCGAnnotatedSessionEventTap` with
`kCGTailAppendEventTap`.

This places the tap late in the global event stream and appends it after
pre-existing taps at that location, which gives us the best practical chance of
seeing events after other remappers have processed them. This is not an absolute
guarantee that we are last: another process can install a later tail tap, and
process-specific taps may still run closer to final app delivery. It is still
the right first choice for an app-agnostic mark-mode MVP.
