# Diagrams

A ```mermaid block is drawn as its diagram (`src/diagrams.odin`) with the toolkit's `gt:mermaid` and `gt:svg` (their
intent: the toolkit's `docs/diagrams.md`). A click opens it in the viewer, `DIAGRAM_VIEW`. This program decides when a
layout runs, what the viewer offers and what it remembers.

## Decisions

- **The conversation shows the diagram as its text says.** The layout of the text runs on the interface's thread at the
  block's first build: the block is closed, the layout takes milliseconds, and a block that jumps from text to diagram a
  frame later reads worse. Another direction runs as a task (`diagram_laid_out`), because only the viewer asks for it.
- **The viewer's choice of placement is the four directions.** Top to bottom, left to right, bottom to top, right to
  left: what `mermaid.Direction` offers. The choice shows only for a diagram that takes a direction
  (`mermaid.takes_direction`: a flowchart, a class, state, ER or requirement diagram). The choice that equals the text's
  own direction is `.Text`: the layout already made for the conversation, no second one.
- **A dropdown, not a segmented control.** The four words are long; four segments take the header's width from the
  title and the tools.
- **A new layout fits the view again.** The old layout stays shown, with "Laying out…", until the new one is ready;
  then the zoom and the pan reset. A zoom kept across a change of shape points at an empty part of a picture that turned
  90 degrees.
- **The choice is remembered per diagram, for the program's run.** `Diagram_Viewer.chosen` maps the hash of a
  diagram's text to its direction. The viewer opens a diagram again in the direction chosen for it, in the conversation
  where it was chosen or in another one. Choosing the text's own direction forgets the entry.

## Refused

- **A global direction (a preference).** A diagram's best direction depends on its shape: a long chain reads left to
  right, a deep tree top to bottom. One direction for all diagrams overrides each author's choice to fix one of them.
- **A direction per session.** A session holds diagrams of many shapes; the same reason applies.
- **A choice kept on disk.** It is a viewing aid; a diagram's text, which a model writes again and again with
  differences, is a poor key to keep for weeks. The map grows only with the person's own choices.
- **The conversation's drawing in the chosen direction.** The conversation shows what the answer says; the viewer is
  where a person looks at it another way. Copy as PNG copies what the place shows.
- **Other layout engines.** mermaid-svg 0.7.0 has one layout (Sugiyama). It reads `layout: elk` and `flowchart-elk` and
  lays them out the same way; `gt:mermaid` offers no engine to choose.
