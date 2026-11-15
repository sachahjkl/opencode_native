// A pane: what one shown conversation needs (src/md/features/chat-panes.md). The main view is pane 0; every piece of the program that
// read the one conversation reads the pane it is given, or, for what acts on the main view (the sidebar, the commands, the palette, the
// home page), main_pane.
package ocn

import "core:sync"
import remote "gt:remote"
import "gt:ui"

// The panes live in a fixed array inside App, not behind pointers that a close would free: a request's worker reads its pane's mark
// (req_unwanted) from another thread at any moment, and an address that never moves nor dies needs no lock nor reference count. A
// pane closed and opened again in the same slot moves its mark, so what was asked for the old one is dropped.
PANES_MAX :: 4
MAIN_PANE :: 0

Chat_Pane :: struct {
	shown:        bool,               // the slot holds a pane (MAIN_PANE always does: pane_is_shown)
	chat:         Chat,
	view:         Chat_View_State,    // where it is read, and how it moves (one per session shown: chat_view_start starts it over)
	conversation: Conversation,       // its column, its scroll box, its opened parts, its prompt rail (conversation.odin)
	find:         Find,               // find in it (find.odin)
	composer:     Composer,           // composer.odin
	read:         remote.Remote,      // the newest page of its conversation
	queue:        Queue,              // what waits in the inbox of its session (queue.odin)
	artifacts:    Chat_Artifacts,     // what its session made: cards in its conversation (schedules.odin)
	// (atomic) moves when it shows another conversation (pane_marked): what the requests' workers read of it. Not Chat.gen itself:
	// chat_reset writes it as a whole struct, which a worker cannot read while it is written.
	mark:         u64,
}

// Where the conversation shown is read, and how it moves: it starts over with another session.
Chat_View_State :: struct {
	opened_ms:    f64,           // when it was opened (it follows its bottom at first)
	chat_scroll:  Chat_Scroll,   // what the view does (scroll.odin: changed by chat_scroll_event alone)
	// its scroll target at the end of the last build, a measure and no state: a hand that moved it up since lets go of the bottom
	chat_target:  f32,
	restore_due:  ui.Deferred,   // a way back that gets nowhere is given up on (scroll.odin chat_scroll_due)
}

main_pane :: proc(app: ^App) -> ^Chat_Pane { return &app.panes[MAIN_PANE] }

pane_is_shown :: proc(app: ^App, i: int) -> bool { return i == MAIN_PANE || app.panes[i].shown }

// The slot of a pane of this app (what a request carries: its worker reads the mark there).
pane_index :: proc(app: ^App, pane: ^Chat_Pane) -> int {
	i := int(uintptr(pane) - uintptr(&app.panes[0])) / size_of(Chat_Pane)
	assert(i >= 0 && i < PANES_MAX && &app.panes[i] == pane)
	return i
}

// The pane a request was asked for.
req_pane :: proc(app: ^App, r: ^Request) -> ^Chat_Pane { return &app.panes[r.pane] }

// It shows another conversation: what was asked for the last one is no longer wanted.
pane_marked :: proc(pane: ^Chat_Pane) { sync.atomic_add(&pane.mark, 1) }

// Whether a shown pane shows that session.
pane_shows :: proc(app: ^App, sid: string) -> bool {
	if sid == "" { return false }
	for &pane, i in app.panes { if pane_is_shown(app, i) && pane.chat.id == sid { return true } }
	return false
}
