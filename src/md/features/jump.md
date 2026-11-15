# Jump to a message

opencode 2.3.0's desktop app has "Jump to message" (Ctrl+Alt+G, and in its palette): a search of the session's prompts
that scrolls the conversation to the one chosen. opencode native has it the same way.

## The decision

- A second toolkit palette (`ui.Command_Palette`, `src/jump.odin`) with one source and no prefix: a chooser. Its items
  are the session's prompts, the newest first: one types a few words of what one asked, Enter goes there.
- The command `session.jump` (Ctrl+Alt+G) opens it, from the keys and from the main palette, where every command is.
- Choosing a prompt does what a click on the prompt rail's mark does (`prompt_go`): the view goes to the prompt, the
  column keeps it there while the heights around it settle, and the prompt's plate takes the keyboard.

## Refused

- A prefix of the main palette: the shared table of prefixes is the toolkit's, closed (palette.md). A chooser of its
  own is how the toolkit gives one list to search.
- A list of its own made for the occasion: the palette already ranks on its chores, keeps the selection and reads keys.

## Subtle points

- The prompts are those loaded. A long session read page by page lists what the conversation holds; an older prompt
  comes once its page is read (scrolling up, or the find).
- The source's version follows the chat (its `gen` and its count of messages): it is read again when a prompt comes or
  the session changes, never at a frame.
