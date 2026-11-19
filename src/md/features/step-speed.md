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

## A provider that sends its output at once

Some providers do not stream the answer's text. `claude-agent` (the Claude Agent SDK) streams reasoning in deltas, but
each text block comes whole. In an answer of text only, `firstToken` is then the arrival of the whole text, and
`streamed` follows it by a few tens of milliseconds. Real messages: `created` 162415, `firstToken` 167309, `streamed`
167368, 406 tokens out. The "first token" said 4.9 s, and the writing time of 59 ms gave 6881 tokens/s; at 46 ms it
fell under `STEP_WRITE_MIN_MS` and the footer showed no speed at all ("5.8 s first token", no tokens/s).

- **The output came at once** when end − first token is less than `STEP_BURST_SHARE` of end − start. On 67 real
  answers, steps that streamed had a share of 37 % or more; the others 9 % or less.
- **Such a step has no first token.** The time ocn has is the arrival of the output, not of its first token.
- **Its speed is a floor**: (output + reasoning) / (end − start). The model wrote within that time, which also holds
  the provider's wait before it, so it wrote at least that fast. It shows as "≥ 82 tokens/s". A model's line in the
  Statistics panel shows "≥" when one of its steps gave a floor.
- **Refused: a cap on plausible speeds.** A fast provider writes thousands of tokens a second; no cap separates it from
  a burst. The share of the step's time does.

## While an answer streams

The stream gives no token count during a step: `session.step.ended` gives the step's tokens, `session.usage.updated`
the session's totals after it. Text and reasoning deltas give characters only.

- **Refused: an estimate from characters.** It is a guess that changes with the language and the tokenizer, and the
  text of a provider that sends it whole comes in one delta.
- **The run's speed so far.** When a step starts, ocn sums the steps of the same run that ended before it (back to the
  prompt) and keeps their writing speed in the new step. The step's footer shows it while it streams; it changes once a
  step, from real counts. At the end, the footer shows the last step's own figures.
- A page read while a run goes on gives its last step the same sum.
