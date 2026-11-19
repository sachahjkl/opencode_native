// What the rest leans on. How a dialog says where a reading (gt:remote's Remote: settled in net.odin answer, nobody else) stands, and its
// Try again: read_shown. The stream's clock and what left a list lately. What the program puts off (gt:ui's Deferred: a real deadline
// that wakes the window).
package ocn

import "core:fmt"
import "core:math"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import remote "gt:remote"
import i18n "gt:i18n"

// What a reading says while it has nothing to show, the same in every dialog. `again`: it can be tried again.
// `intent`: what it means, its colour (Neutral: weak words).
read_words :: proc(app: ^App, x: ^remote.Remote) -> (words: string, intent: ui.Intent, again: bool) {
	switch x.state {
	case .Idle:    return online(app) ? i18n.tr("Reading…") : i18n.tr("Not connected: this is read when the server answers."), .Neutral, false
	case .Loading: return i18n.tr("Reading…"), .Neutral, false
	case .Refused: return x.message, .Warning, true
	case .Failed:  return x.message, .Danger, true
	case .Ready:
	}
	return "", .Neutral, false
}

// In a dialog, in the place of what is read: true when that is there to show. Otherwise it says where the reading stands, and
// `ask` is what Try again runs.
read_shown :: proc(app: ^App, id: string, x: ^remote.Remote, em: f32, ask: proc(app: ^App)) -> bool {
	if remote.shows(x) { return true }
	if read_pending(app, x) { app.reads_waiting = true }
	words, intent, again := read_words(app, x)
	info_line(app, id, words, em, intent == .Neutral ? ui.theme_color("weak text") : ui.hue(ui.intent_hue(intent)))
	if again {
		ui.space(ui.SPACE_2)
		if ui.button(fmt.tprintf("%s_again", id), i18n.tr("Try again"), lucide.REFRESH_CW, {height = math.round(em * BUTTON_COMPACT_H_EM)}).clicked { ask(app) }
	}
	return false
}

// It has nothing to show and its answer is on its way: asked, or about to be asked of a server that is there. (A refusal,
// a failure or no server is an answer: what it says is all there is.)
read_pending :: proc(app: ^App, x: ^remote.Remote) -> bool {
	return !remote.shows(x) && (x.state == .Loading || (x.state == .Idle && online(app)))
}

// At the top of a view's build that shows readings (read_shown): while one of them waits for its answer, its dialog stays
// unseen (ui.view_not_ready, 100 ms at most from its opening). It opens with what was read, at its size, not with
// "Reading…" that a moment later grows into the answer. Once shown, a reading again says "Reading…" in place.
@(deferred_in = dialog_reads_end)
dialog_reads :: proc(app: ^App, v: ^ui.View) { app.reads_waiting = false }

@(private = "file")
dialog_reads_end :: proc(app: ^App, v: ^ui.View) {
	if app.reads_waiting { ui.view_not_ready(v) }
	app.reads_waiting = false
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

// What the program puts off (app.cx.due: ui.Deferred each). Each is run (due_run: a new one does not compile until it says what it
// does) and wakes a window at rest, from one list.
Due :: enum u8 { Refresh, Facts, Children, Context, Term_Size, Side_Wake, Drafts, Downloads }
