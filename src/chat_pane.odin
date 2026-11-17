// A pane: what one shown conversation needs (src/md/features/chat-panes.md). The main view is pane 0; every piece of the program that
// read the one conversation reads the pane it is given, or, for what acts on the main view (the sidebar, the commands, the palette, the
// home page), main_pane.
package ocn

import "core:strings"
import "core:sync"
import "gt:draw"
import remote "gt:remote"
import "gt:ui"

// The panes live in a fixed array inside App, not behind pointers that a close would free: a request's worker reads its pane's mark
// (req_unwanted) from another thread at any moment, and an address that never moves nor dies needs no lock nor reference count. A
// pane closed and opened again in the same slot moves its mark, so what was asked for the old one is dropped.
PANES_MAX :: 4
MAIN_PANE :: 0

Chat_Pane :: struct {
	shown:        bool,               // the slot holds a pane (MAIN_PANE always does: pane_open)
	chat:         Chat,
	view:         Chat_View_State,    // where it is read, and how it moves (one per session shown: chat_view_start starts it over)
	conversation: Conversation,       // its column, its scroll box, its opened parts, its prompt rail (conversation.odin)
	composer:     Composer,           // composer.odin
	read:         remote.Remote,      // the newest page of its conversation
	queue:        Queue,              // what waits in the inbox of its session (queue.odin)
	artifacts:    Chat_Artifacts,     // what its session made: cards in its conversation (schedules.odin)
	throbber:     Throbber,           // the word of its run (throbber.odin): two runs shown would flip one board between theirs
	// its conversation's zoom, keyed by the session shown in App.session_zooms (zooms_load sets the memory): the zoom keys
	// act on it while the keyboard is in the pane, Ctrl+wheel while the pointer is over it
	zone:         ui.Zoom_Zone,
	// the /btw it shows the prompt of (its Outgoing's id, 0: none): with no session yet, the pane waits for its fork (pane_forking);
	// then the prompt shows until its session has it (btw.odin)
	aside:        u64,
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
	left_down:    bool,          // the left button is held in its window (chat_selecting), from its presses and releases
	selecting:    bool,          // a selecting drag holds the pointer in this build (chat_scroll_place, for chat_scroll_settle)
}

main_pane :: proc(app: ^App) -> ^Chat_Pane { return &app.panes[MAIN_PANE] }

// Whether pane `i` shows a session (the main view's home page included). A pane that waits for its fork shows none: its empty id is
// not the home page's, and what goes to a session shown (its events, its draft, what failed) must not land in it.
pane_is_shown :: proc(app: ^App, i: int) -> bool { return pane_open(app, i) && !pane_forking(&app.panes[i]) }

// Whether slot `i` holds a pane, shown or waiting for its fork.
pane_open :: proc(app: ^App, i: int) -> bool { return i == MAIN_PANE || app.panes[i].shown }

// It is the panel of a /btw whose fork is not made yet (chat-panes.md, "The panel opens at once").
pane_forking :: proc(pane: ^Chat_Pane) -> bool { return pane.shown && pane.aside != 0 && pane.chat.id == "" }

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

// A free slot, or nil: every pane is shown.
pane_free :: proc(app: ^App) -> ^Chat_Pane {
	for &pane, i in app.panes { if i != MAIN_PANE && !pane.shown { return &pane } }
	return nil
}

// `pane`, other than the main view, shows session `sid`: what open_chat does, without what is the main view's (Back and
// Forward, the last session kept, the activity, What you missed).
pane_show :: proc(app: ^App, pane: ^Chat_Pane, sid: string) {
	assert(pane != main_pane(app))
	if pane.shown && pane.chat.id == sid { return }
	id := strings.clone(sid, context.temp_allocator)   // (it may live in the arena chat_reset drops)
	if pane.shown { pane_leave(app, pane) }
	pane.shown, pane.aside = true, 0
	pane_enter(app, pane, id)
	pane_follow(app, pane)
}

// `pane` waits for the fork of /btw `out`, asked from `from`: shown, with no session. What it showed goes as when it is closed. Its
// composer shows the agent and the model of `from`, which the fork will have (with no session, it would show the home page's).
pane_wait_fork :: proc(app: ^App, pane, from: ^Chat_Pane, out: u64) {
	assert(pane != main_pane(app))
	agent := strings.clone(shown_agent(app, from), context.temp_allocator)
	model, provider := shown_model(app, from)
	model, provider = strings.clone(model, context.temp_allocator), strings.clone(provider, context.temp_allocator)
	variant := strings.clone(shown_variant(app, from), context.temp_allocator)
	if !pane_forking(pane) {
		if pane.shown { pane_close(app, pane) }
		chat_reset(&pane.chat)
		pane_marked(pane)
		chat_view_start(pane, ui.now_ms())
	}
	pane.shown, pane.aside = true, out
	c := &pane.chat
	c.chose_agent, c.chose_model, c.chose_provider, c.chose_variant = strings.clone(agent, c.alloc), strings.clone(model, c.alloc), strings.clone(provider, c.alloc), strings.clone(variant, c.alloc)
}

// What its composer holds, before it shows something else. Waiting for its fork it has no session to keep it in a draft: the main
// composer takes it.
@(private = "file")
pane_leave :: proc(app: ^App, pane: ^Chat_Pane) {
	if pane_forking(pane) { composer_give(app, pane, main_pane(app)) } else { draft_leave(app, pane) }
}

// It shows nothing any more: its composer's text waits in its session's draft, its slot is free, and what was asked for it
// is dropped (its mark moved).
pane_close :: proc(app: ^App, pane: ^Chat_Pane) {
	assert(pane != main_pane(app))
	if !pane.shown { return }
	pane_leave(app, pane)
	pane.aside = 0
	find_pane_closed(app, pane)
	chat_reset(&pane.chat)
	pane_marked(pane)
	queue_switch(app, pane)
	pane.composer.focused, pane.composer.focus_next = false, false
	pane.composer.slash_pick.open = false
	pane.shown = false
}

// The pane the keyboard is in: the panel's while the focus is in its view, else the main view's.
keys_pane :: proc(app: ^App) -> ^Chat_Pane {
	if p := btw_pane(app); p != nil && ui.view_has_focus(&app.program_views, BTW_VIEW) { return p }
	return main_pane(app)
}

// The pane whose column is under `pos` in the window being built (its last layout; outside a build, the main window), else the
// main view. (A pane in another window has no box in this one's State.)
pane_at :: proc(app: ^App, pos: [2]f32) -> ^Chat_Pane {
	s := built_state(app)
	for &pane, i in app.panes {
		if i == MAIN_PANE || !pane.shown || pane.conversation.root == 0 { continue }
		b := s.boxes[pane.conversation.root] or_else nil
		if b != nil && ui.box_current(s, b) && draw.rect_contains(b.rect, pos) { return &pane }
	}
	return main_pane(app)
}
