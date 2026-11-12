// Where the conversation is read, as one state: what the view does with its scroll box in each build. Everything that moves it
// (a hand, a page read, Back, a part opened, the end reached) is an event of chat_scroll_event, the one place the state changes;
// chat_scroll_place and chat_scroll_settle put it on the box around each build, and main_builds runs the builds it asks for.
package ocn

import "core:strings"
import "gt:ui"

// The bottom is followed: what grows there stays in view. `jump`: reached at once in this frame, no glide (its first page just came,
// the view was built anew, or this frame's layout moved the bottom).
Scroll_Following :: struct { jump: bool }
// The reader's place: the box keeps its offset.
Scroll_Free :: struct {}
// A box kept at `y` on screen through this frame's builds (main_builds): a part's header just opened or closed, under the pointer
// (--seek-subagent: a card brought near the top). `keep`: a message built whatever, the one a page read above was holding (owned).
Scroll_Anchored :: struct { box: ^ui.Box, y: f32, keep: string }
// A page came in above: `msg`, at the top of the view, stays where it is. Taken in the next placing, where its box is known
// (chat_scroll_place): then Anchored, or Free when there is nothing to hold. (owned)
Scroll_Keeping :: struct { msg: string }
// Back or Forward: the view goes to `msg`, `dy` into it, as the lazy column pins it, until it stays `still` builds without
// moving (NAV_RESTORE_STILL). Until it gets there the bottom is not followed; a clock gives up on it (Due.Restore). (owned)
Scroll_Restoring :: struct { msg: string, dy: f32, still: int }

Chat_Scroll :: union #no_nil { Scroll_Following, Scroll_Free, Scroll_Anchored, Scroll_Keeping, Scroll_Restoring }

Scroll_Signal :: enum u8 {
	Opened,           // a conversation or the home page shown anew
	Go_Bottom,        // Latest, a prompt sent: what the reader asks wins over a view going back
	Moved_Up,         // a hand moved the view up from the bottom, or find took it to a match
	At_Bottom,        // a build ended at the bottom, and following is wanted
	Off_Bottom,       // a build ended elsewhere, or following is not wanted (the preference, the home page)
	Snap,             // shown at the bottom at once in this frame
	Restore_End,      // the reader moved (wheel, key, scroll bar), or the way back gave up (clock, a page not read)
	Restore_Missing,  // the message gone back to is in no page: the end instead
	Frame_Done,       // the frame's builds are over: what held for them lets go
}
// (the strings are borrowed: chat_scroll_event clones what the state keeps)
Scroll_Older_Page  :: struct { msg: string }               // a page read above; `msg` at the top of the view
Scroll_Anchor      :: struct { box: ^ui.Box, y: f32 }      // keep `box` at `y` (nil: nothing to hold)
Scroll_Restore     :: struct { msg: string, dy: f32 }      // go back to `msg`, `dy` into it
Scroll_Hold_View   :: struct { msg: string, dy: f32 }      // the conversation built in other boxes: keep what is read
Scroll_Restore_Held :: struct { found, moved: bool }       // a build pinned the message (ui.lazy_pinned)

Chat_Scroll_Event :: union { Scroll_Signal, Scroll_Older_Page, Scroll_Anchor, Scroll_Restore, Scroll_Hold_View, Scroll_Restore_Held }

// The transitions, and nothing else: no memory, no box touched, no clock (chat_scroll_event does those).
chat_scroll_step :: proc(s: Chat_Scroll, e: Chat_Scroll_Event) -> Chat_Scroll {
	_, following := s.(Scroll_Following)
	_, free := s.(Scroll_Free)
	switch v in e {
	case Scroll_Signal:
		switch v {
		case .Opened, .Go_Bottom:
			return Scroll_Following{}
		case .Moved_Up, .Off_Bottom:
			if following { return Scroll_Free{} }
		case .At_Bottom:
			if free { return Scroll_Following{} }
		case .Snap:
			if following { return Scroll_Following{jump = true} }
		case .Restore_End:
			if _, ok := s.(Scroll_Restoring); ok { return Scroll_Free{} }
		case .Restore_Missing:
			if _, ok := s.(Scroll_Restoring); ok { return Scroll_Following{jump = true} }
		case .Frame_Done:
			#partial switch _ in s {
			case Scroll_Following:               return Scroll_Following{}
			case Scroll_Anchored, Scroll_Keeping: return Scroll_Free{}
			}
		}
	case Scroll_Older_Page:
		// (following, the bottom stays; going back, the pin holds the message; sent to the start (Home), chat_scroll_place lets it go)
		if free && v.msg != "" { return Scroll_Keeping{v.msg} }
	case Scroll_Anchor:
		keep := ""
		#partial switch k in s {
		case Scroll_Keeping:  keep = k.msg
		case Scroll_Anchored: keep = k.keep
		}
		if v.box != nil { return Scroll_Anchored{v.box, v.y, keep} }
		if _, ok := s.(Scroll_Keeping); ok { return Scroll_Free{} }
	case Scroll_Restore:
		if v.msg != "" { return Scroll_Restoring{msg = v.msg, dy = v.dy} }
	case Scroll_Hold_View:
		if following { return Scroll_Following{jump = true} }
		if v.msg != "" { return Scroll_Restoring{msg = v.msg, dy = v.dy} }
	case Scroll_Restore_Held:
		if r, ok := s.(Scroll_Restoring); ok {
			r.still = v.found && !v.moved ? r.still + 1 : 0
			if r.still >= NAV_RESTORE_STILL { return Scroll_Free{} }
			return r
		}
	}
	return s
}

// The message a state keeps ("": none), and where.
@(private = "file")
scroll_msg :: proc(s: ^Chat_Scroll) -> ^string {
	#partial switch &v in s^ {
	case Scroll_Anchored:  return &v.keep
	case Scroll_Keeping:   return &v.msg
	case Scroll_Restoring: return &v.msg
	}
	return nil
}

// The one door of the state: the step, then what it owns and the clock of a way back.
chat_scroll_event :: proc(app: ^App, e: Chat_Scroll_Event) {
	old := app.chat_scroll
	app.chat_scroll = chat_scroll_step(old, e)
	was, now := "", ""
	if p := scroll_msg(&old); p != nil { was = p^ }
	if p := scroll_msg(&app.chat_scroll); p != nil {
		now = p^
		// (a message carried from one state to the next is the same string: only one from the event is new)
		if raw_data(now) != raw_data(was) || len(now) != len(was) { p^ = len(now) > 0 ? strings.clone(now) : "" }
		now = p^
	}
	if len(was) > 0 && raw_data(now) != raw_data(was) { delete(was) }
	_, was_restoring := old.(Scroll_Restoring)
	_, restoring := app.chat_scroll.(Scroll_Restoring)
	// (a page read on the way, a long history's, gives it a whole wait again: the limit is on a view that no longer gets anywhere.
	// Asked again as it stands, a Deferred would keep its first bound)
	again := false
	#partial switch _ in e { case Scroll_Restore, Scroll_Hold_View, Scroll_Older_Page: again = true }
	if restoring && (!was_restoring || again) {
		app.cx.due[.Restore] = {}
		deferred_ask(&app.cx.due[.Restore], NAV_RESTORE_WAIT_MS)
	}
	if was_restoring && !restoring { app.cx.due[.Restore] = {} }
}

chat_following :: proc(app: ^App) -> bool {
	_, ok := app.chat_scroll.(Scroll_Following)
	return ok
}

chat_anchored :: proc(app: ^App) -> bool {
	_, ok := app.chat_scroll.(Scroll_Anchored)
	return ok
}

// Another conversation shown, or the home page (opened_ms 0): its view starts over, following its bottom.
chat_view_start :: proc(app: ^App, opened_ms: f64) {
	chat_scroll_event(app, Scroll_Signal.Opened)   // (frees what the last state kept: Following keeps nothing, it is the zero state)
	app.view = {opened_ms = opened_ms}
}

// After a page was read: a message gone back to that is in none of them (its session changed) is given up, and the view takes the end.
chat_scroll_restore_check :: proc(app: ^App) {
	r, ok := app.chat_scroll.(Scroll_Restoring)
	if !ok || app.chat.older != "" || find_message(&app.chat, r.msg) != nil { return }
	chat_scroll_event(app, Scroll_Signal.Restore_Missing)
}

// Before the conversation is built: what a hand did to the box since the last build (begin_build moved it), then the state put on it.
chat_scroll_place :: proc(app: ^App, sb: ^ui.Box, em: f32) {
	if app.chat.id == "" { chat_scroll_event(app, Scroll_Signal.Off_Bottom) }   // (the home page is read from its top)
	if sb == nil { return }
	// (the wheel's click scrolls it by steps of a pixel a frame or less: under any slack, each one counts)
	auto := ui.autoscroll_running(&app.state)
	slack := auto ? AUTOSCROLL_SLACK_PX : BOTTOM_SLACK_PX * ui.scale()
	by_hand := chat_keys(app, sb, em) || app.state.scroll_delta != {} || ui.active_key() != 0 || auto
	if scrollbar_held(app, sb) { chat_scroll_event(app, Scroll_Signal.Restore_End) }   // (as the wheel and the keys do: main_input)
	limit := ui.view_limit(sb)
	// the scrollbar's drag, the wheel, the keyboard moved it: up means let go of the bottom, or following it would put it back at
	// once and the thumb would stay stuck there. Only a hand: a box built anew starts at its top, and that is no reader going up.
	if by_hand && sb.view_target.y < app.chat_target - (auto ? 0 : 1) && sb.view_target.y < limit - slack {
		chat_scroll_event(app, Scroll_Signal.Moved_Up)
	}
	#partial switch s in app.chat_scroll {
	case Scroll_Following:
		sb.view_target.y = limit
		// (the tray that opens under it moves it: a glide of its own on top of that one would lag behind it)
		if s.jump || app.cx.was_gliding { sb.view_off.y = limit }
	case Scroll_Keeping:
		// its box as the last build left it: where it must stay. (A view sent to the start (Home) stays at the top instead: that is
		// what reads the pages up to it.)
		b := app.chat.view_box
		if b != nil && (app.chat.view_msg != s.msg || sb.view_top_held[1]) { b = nil }
		chat_scroll_event(app, Scroll_Anchor{b, b != nil ? b.rect.min.y : 0})
	}
}

// After the conversation is built: follow the bottom while the reader is there.
chat_scroll_settle :: proc(app: ^App, sb: ^ui.Box) {
	if sb == nil { return }
	limit := ui.view_limit(sb)
	at_bottom := sb.view_target.y >= limit - (ui.autoscroll_running(&app.state) ? AUTOSCROLL_SLACK_PX : BOTTOM_SLACK_PX * ui.scale())
	// (with following off, only the first moments of a conversation just opened follow its bottom)
	follow := (app.prefs.follow || ui.now_ms() - app.opened_ms < OPENED_FOLLOW_MS) && app.chat.id != ""
	chat_scroll_event(app, at_bottom && follow ? Scroll_Signal.At_Bottom : Scroll_Signal.Off_Bottom)
	app.chat_target = sb.view_target.y
}
