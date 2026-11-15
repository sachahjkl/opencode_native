# Queue first (Alt+Enter)

While a run of the shown session works, Alt+Enter in the composer queues its prompt **first**: before the prompts that
already wait for the end of the run (delivery "queue"). Steered prompts are not part of that order and stay as they are.
With nothing running, Alt+Enter sends as Enter does. opencode 2.3.0's desktop has the same key.

Code: `src/queue.odin` (section "Queue first"), the key in `src/composer.odin`, the request kinds in `src/net.odin`.

## The server cannot reorder

The inbox has no move: an item can only be admitted (POST prompt, at the end) or cancelled (DELETE). A reorder therefore
re-admits the suffix that changes, as the desktop does (`packages/app/src/session/composer/queue.ts`, `rewrite`):

1. The new prompt goes with delivery "queue", as Enter's queue would. Its answer gives its id.
2. Every other queued prompt, in list order, is admitted again with the same payload (`prompt_of_payload`, `"resume":false`),
   one at a time: the copies land after the new prompt.
3. When every copy is in, the originals are cancelled, one at a time, in order.

The list then reads: new prompt, old prompts in their order. Prompts that came after the new one (another client's) are
moved too, so that the new prompt is first among all queued ones.

## Admit before cancel

Cancel-then-send (as an edit does, `queue_edit_commit`) loses a prompt if the send fails: its file may be gone, the server
may refuse. Admit-then-cancel never loses one: until step 3 the originals are all there, and a failure only has to withdraw
the copies already admitted. That is the desktop's order, and the reason for it.

## The state machine

`Queue_First` on the Queue, one reorder at a time:

- **Idle**: nothing moves. `outs` holds the Alt+Enter prompts on their way, `waiting` the ones admitted and waiting
  for their reorder.
- **Copying**: the copy of `moves[at]` is on its way. The originals show "changing…" and have no actions.
- **Cancelling**: every copy is in; the cancel of `moves[at]`'s original is on its way.
- **Withdrawing**: the reorder stopped; the DELETEs of the copies admitted (and the answer of the copy on its way) are
  awaited, then Idle.

Each reorder has a `run` number, carried in the tags of its requests. An answer of an older run is an orphan: a copy is
withdrawn, the rest is ignored.

## The copies' ids are the client's

Each copy is sent with an `id` minted here before its POST (`message_id_new`, the server's ascending message id:
`msg_`, 12 hex digits of ms × 0x1000 + a per-millisecond counter, 14 random characters), and the inbox item takes that
id, as the desktop does. The machine records it before sending, so a copy is known by its id whatever arrives first,
its `enqueued` event or its answer. A copy whose answer never came (transport failure, an unreadable answer) may still
be on the server: it is withdrawn by that id, and a 404 on a withdraw counts as done (the server never took it). A copy
refused (a status from 400) is not in the inbox: nothing to withdraw.

Letting the server name the copies was refused: the copy is then unknown until its answer, an event before it cannot be
told from another client's prompt, and a lost answer leaves a copy that cannot be found.

The copy on its way is never withdrawn before its POST answers: requests have no order between them, and a DELETE that
passes its POST would answer 404 and leave the copy in.

A second Alt+Enter while a reorder runs **waits**: its prompt goes at once (it is not lost if the client stops), and its
reorder starts when the machine is Idle again, on the list as it is then. The newest Alt+Enter ends first, as a reader
expects. Queueing it at the end instead was refused: the key would then do the opposite of what it says.

## The list never shows a prompt twice

A hidden item is exactly an item whose id is a copy's minted id of the current run, while its original is still listed
or while the copy is being withdrawn. The original keeps its place until its cancel, then the copy shows: at every moment
each prompt shows once.

## Failures and changes meanwhile

- A copy that fails: the copies admitted are withdrawn, and the failed one too unless the server refused it. The queue
  holds what it held, the new prompt last.
- During Copying, an original or the new prompt leaves (delivered, cancelled elsewhere): the queue changed under the
  reorder (the desktop fails "Queued prompts changed before reordering"). It stops as above; the new prompt stays where it
  is.
- During Cancelling, an original that leaves by another way than its own cancel (delivered when the run ended, cancelled
  elsewhere): its copy is now a duplicate and is withdrawn. A cancel that fails: the copies of the originals not cancelled
  yet are withdrawn. The content stays intact; the order is partly moved.
- The session left or the server left: Copying withdraws the copies admitted, and the one on its way when its answer
  comes; Cancelling sends the remaining cancels at once, since every copy is in and the originals must go.
- The new prompt itself fails: it comes back to the composer as any prompt does; no reorder.
- A slash command with Alt+Enter goes queued, without reorder: a command is not a prompt the inbox can copy.

## Subtle points

- An original that is busy (being steered, removed, edited) when the reorder would start: the reorder does not start.
- A reload of the list (`queue_load`) that drops an original counts as that original leaving.
- A withdraw that fails leaves a duplicate in the queue, shown as such: the reader can remove it.
