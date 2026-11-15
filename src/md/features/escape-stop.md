# Escape stops a run in two presses

Escape is the key that closes things: a list, a menu, a search, the editing of a pending message. While a run works, an
Escape that nothing took stopped the run at once. An Escape meant for something already closed, or pressed by habit in the
composer, cut a run that the person wanted to keep.

## The decision

- The first Escape arms the stop. It stops nothing. A banner at the top of the composer says, in the danger colour, that
  a second Escape stops the run.
- A second Escape while the stop is armed stops the run (`interrupt_session`).
- The arming ends by itself after `ESCAPE_STOP_MS`. It also ends when the run ends or another session is shown: an
  Escape after that arms again.
- The banner is in the composer, not in a toast: the eyes are on the composer when Escape is pressed. A toast appears
  under the header, far from it. The line "Esc to stop" at the end of the conversation scrolls away with it.
- Ctrl+Esc, the Stop buttons and the line's own "Esc to stop" link stop at once: they cannot be pressed by accident.

## One place

Both paths of Escape (the composer focused, and nothing focused, last in the frame) call `escape_stop`. One state
(`App.escape_stop`: the session armed, and until when) drives the banner, the stop and the end of the arming. The
banner asks for a wake at the end of the arming, so that it goes without other input.

## Refused

- A confirmation dialog: one more Escape to close it, and the run waits behind it.
- Arming per key pressed in between (typing disarms): a person who types and then presses Escape twice means it.
