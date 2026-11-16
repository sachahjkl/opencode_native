# Freeform tool input (opencode 2.3.0)

A freeform tool takes plain text, not a JSON object: opencode's `execute` (code mode, a text) and `patch` (a Lark
grammar) are two. Only the provider's wire carries the raw text (OpenAI custom tools). Everywhere a client sees it,
the input is the normal object `{<field>: <text>}`, the tool's one required string parameter
(`packages/ai/src/protocols/openai-freeform.ts`).

## What the server sends

- **`session.tool.input.delta`**: `{id, delta}`, fragments of the input as JSON text. A freeform call's raw text is
  re-encoded so that its fragments match a JSON tool's: the first is `{"<field>":"` and the escaped text, the next
  are escaped text, the last closes with `"}`.
- **`session.tool.input.ended`**: `{id, text}`, the whole JSON text.
- **`session.tool.called`**: `{id, input}`, the object. `native` may say `custom: true` (OpenAI only): ocn does not
  rely on it.
- **A stored call still streaming**: `state: {status: "streaming", input: "<the JSON text so far>"}`, a string.

## Decisions

- **The shape decides, not a list of names.** An input of one field whose value is a long string (a line break, or
  longer than a line) shows that text as it is, in a well, without its key. The tool's name in the header already says
  what the text is for, and the key alone adds nothing. That is the shape a freeform tool has by definition, and it
  also fits a JSON tool of one long field.
- **The stream shows it as it comes.** ocn reads the deltas of every call into `Input_Stream`, an explicit state
  machine: `Head` (until `{"<field>":"` is whole), `Text` (the string's characters, unescaped as they come), `Closed`
  (its quote came), `Not_One_Field` (another field, or a value that is not a string: nothing is shown until the call).
  The streamed text shows while the call is pending, once it is long, by the same rule as above.
- **Incremental.** Each delta is decoded once, from where the last one stopped. An escape or a UTF-8 sequence cut by a
  fragment waits in a few pending bytes. A build does no decoding.
- **`input.ended` has the last word** on the streamed text. Its text is decoded again once; the buffer is replaced
  only if the result differs.
- **A stored string input is a stream, not an input.** Before, it showed as one quoted JSON string. Now it goes through
  the same decoder, and the call has no input until it is called.
- **This decoder could move to `gt:json`** if another program reads streamed JSON. ocn alone does now.
