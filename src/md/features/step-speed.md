# A step's speed (opencode 2.3.0)

opencode 2.3.0 records when a step's first token came. ocn reads from it how long a model waits before it answers and
how fast it writes.

## What the server sends

- **`session.step.started`**: `data.started`, when the request went out.
- **`session.step.first-token`**: no data of its own. The event's `created` is when the provider sent the first text,
  reasoning or tool input of the step. The stored message keeps it as `time.firstToken`.
- **`session.step.streamed`**: the event's `created` is when the provider's response ended, before tools settle. The
  stored message keeps it as `time.streamed`.
- **`session.step.ended`**: the event's `created` is the step's end (`time.completed`), after its tools; its tokens.
  `tokens.output` excludes `tokens.reasoning`.
- A step started again (the same message id) clears `firstToken`, `streamed` and `completed`.

## Decisions

- **Latency** is first token − start. **Writing speed** is (output + reasoning tokens) / (end of writing − first token).
  The end of writing is `streamed`; it is `completed` only when `streamed` is absent, because `completed` waits for
  the tools. Reasoning counts: the model wrote those tokens in that time, and leaving them out makes a thinking model
  look slow.
- **Computed when the data comes.** `step_speed_set` runs when a message is read or when one of these events changes
  it, and keeps the two figures in the message. The Statistics panel sums them per model in `local_stats`, which is
  made again only when the messages change.
- **Where it shows.** In the Statistics panel, a line under each model of the Models list: the mean latency and the
  writing speed of its steps. In the conversation, the usage line at the end of an answer adds that step's latency and
  speed. The Time section's "output pace" is gone: it divided the tokens by the steps' whole time, tools included,
  and said a slower, different figure next to the true one.
- **A step without a first token** (older than 2.3.0, or failed before any output) counts in no speed.
- **A writing time under `STEP_WRITE_MIN_MS`** gives no speed: a few tokens in one chunk give an absurd rate.
