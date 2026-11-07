// Two small machines the rest leans on. A Remote: what is read from the server and how that reading ended, whichever way it
// ended (net.odin answer settles it, nobody else), and read_shown, how a dialog says so. A Deferred: something to do a little after the last thing that asked for it,
// with a real deadline that wakes the window.
package occ

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "gt:ui"

Load_State :: enum u8 { Idle, Loading, Ready, Refused, Failed }

// Lives somewhere that does not move (App, App_Context, a panel's struct in them): a request keeps its address.
Remote :: struct {
	state:   Load_State,
	ticket:  u64,      // of the last reading: an answer with another one is of a reading given up, dropped before any handler
	message: string,   // why it did not end well: the server's words when it refused (owned)
	known:   bool,     // something was read since the last reset: a reading again leaves it on screen until it ends
}

// A new reading: what was on its way no longer counts. Then request(..., remote = x).
remote_begin :: proc(x: ^Remote) {
	x.ticket += 1
	remote_settle(x, .Loading, "")
}

// Nothing read, nothing on its way (the server changed: every feature's *_forget; a dialog opened on something else).
remote_reset :: proc(x: ^Remote) {
	x.ticket += 1
	x.known = false
	remote_settle(x, .Idle, "")
}

remote_settle :: proc(x: ^Remote, state: Load_State, message: string) {
	delete(x.message)
	x.state = state
	x.message = strings.clone(message)
	if state == .Ready { x.known = true }
}

// What was read is what is on screen: it came, or it is being read again.
remote_shows :: proc(x: ^Remote) -> bool { return x.state == .Ready || (x.state == .Loading && x.known) }

// It ended badly, and what it says is all there is.
remote_failed :: proc(x: ^Remote) -> bool { return x.state == .Failed || x.state == .Refused }

// What a reading says while it has nothing to show, the same in every dialog. `again`: it can be tried again.
read_words :: proc(app: ^App, x: ^Remote) -> (words: string, color: u32, again: bool) {
	switch x.state {
	case .Idle:    return online(app) ? "Reading…" : "Not connected: this is read when the server answers.", HEX_WEAK, false
	case .Loading: return "Reading…", HEX_WEAK, false
	case .Refused: return x.message, HEX_YELLOW, true
	case .Failed:  return x.message, HEX_RED, true
	case .Ready:
	}
	return "", HEX_WEAK, false
}

// In a dialog, in the place of what is read: true when that is there to show. Otherwise it says where the reading stands, and
// `ask` is what Try again runs.
read_shown :: proc(app: ^App, id: string, x: ^Remote, em: f32, ask: proc(app: ^App)) -> bool {
	if remote_shows(x) { return true }
	words, color, again := read_words(app, x)
	info_line(app, id, words, em, hex(color))
	if again {
		ui.spacer(ui.px(em * 0.4))
		if bevel_button(fmt.tprintf("%s_again", id), "Try again", ICO_REFRESH, .Normal, height = math.round(em * BUTTON_COMPACT_H_EM)).clicked { ask(app) }
	}
	return false
}

// What was in it goes, and it starts over. (Destroying an arena that is zero does nothing, and an arena destroyed can be destroyed again.)
arena_renew :: proc(a: ^virtual.Arena) -> mem.Allocator {
	virtual.arena_destroy(a)
	_ = virtual.arena_init_growing(a)
	return virtual.arena_allocator(a)
}

// The stream's clock: a count of what it said. A list and the stream have no clock in common: an answer is older than what the stream said after
// it was asked for.
Seq :: distinct u64

newer :: proc(at, asked_at: Seq) -> bool { return at > asked_at }

// What left a list lately, by id: a list asked before that still has it, and it does not come back. `most` holds it to a size, past what any
// answer on its way can matter.
Gone :: struct { id: string, at: Seq, delivered: bool }   // (id owned)

Gone_List :: struct { items: [dynamic]Gone }

gone_find :: proc(l: ^Gone_List, id: string) -> ^Gone {
	for &g in l.items { if g.id == id { return &g } }
	return nil
}

gone_add :: proc(l: ^Gone_List, id: string, at: Seq, most: int, delivered := false) {
	if gone_find(l, id) != nil { return }
	if len(l.items) >= most {
		delete(l.items[0].id)
		ordered_remove(&l.items, 0)
	}
	append(&l.items, Gone{strings.clone(id), at, delivered})
}

// A list asked for at `asked_at` has arrived: what left before it, it no longer has.
gone_settled :: proc(l: ^Gone_List, asked_at: Seq) {
	#reverse for g, i in l.items {
		if newer(g.at, asked_at) { continue }
		delete(g.id)
		ordered_remove(&l.items, i)
	}
}

gone_clear :: proc(l: ^Gone_List) {
	for g in l.items { delete(g.id) }
	clear(&l.items)
}

// Something to do once things are quiet: asked again it moves back, so that it comes after what asked for it (an event after
// a POST reads what that POST changed), but never later than `most` after the first asking: events without end still read.
// (`most` left out: no later than the first wait. To start a wait over, clear it first.)
Deferred :: struct { due_ms, latest_ms: f64 }   // (0: nothing asked)

// What the program puts off. Each is run (due_run: a new one does not compile until it says what it does) and wakes a window at rest, from one
// list.
Due :: enum u8 { Refresh, Facts, Children, Context, Restore, Term_Size, Side_Wake }

deferred_ask :: proc(d: ^Deferred, wait_ms: f64, most_ms: f64 = 0) {
	now := ui.now_ms()
	if d.due_ms == 0 { d.latest_ms = now + max(most_ms, wait_ms) }
	d.due_ms = min(now + wait_ms, d.latest_ms)
}

// Whether it is time, once: it is then no longer asked.
deferred_take :: proc(d: ^Deferred) -> bool {
	if d.due_ms == 0 || ui.now_ms() < d.due_ms { return false }
	d^ = {}
	return true
}

// In how long, in whole ms (at least 1), 0: nothing asked.
deferred_in_ms :: proc(d: ^Deferred) -> int {
	if d.due_ms == 0 { return 0 }
	return max(int(d.due_ms - ui.now_ms()) + 1, 1)
}
