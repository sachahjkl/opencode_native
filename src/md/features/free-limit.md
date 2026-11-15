# The free-limit panel

opencode's free models (OpenCode Zen) refuse a step once the free usage of the network is used up: the step fails with
an error of type `provider.free-limit`, often with `retryAfterMs`. With no paid provider, nothing the composer sends
can run until it resets. opencode 2.3.0's desktop shows a panel in the composer's place; opencode native does the same.

## The decision

- A `session.step.failed` whose error is `provider.free-limit`, in any session (the free usage is counted per
  network, not per session), notes when it resets: the event's time plus `retryAfterMs`, or one hour when the server
  gives none or one out of range (more than 45 days), as the desktop does.
- While that time is to come and no paid provider is there, the panel takes the composer's place: "Free limit
  reached", when it resets, and two acts: Subscribe to Go (its page) and Connect provider (the settings' accounts).
- Paid: a model of a provider other than `opencode`, or an `opencode` model with a price. It is read from the models
  when the catalogue changes (`catalog_version`), not at each frame. Connecting a provider ends the panel at once.
- The panel goes by itself when the time comes: it asks for a wake at that time.

## Refused

- Disabling the composer and saying it in a toast: the reader keeps typing a prompt that cannot go.
- Keeping the reset across a restart (the desktop persists it): a restart with the limit still on fails at the first
  step and shows the panel again; a file for one date is not worth its state.

## Subtle points

- The time is the event's (`created`), the server's clock: a late event does not move the reset.
- A newer refusal replaces the reset; an older one (an event replayed) does not shorten it.
