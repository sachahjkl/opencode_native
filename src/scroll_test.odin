package ocn

// Where the conversation is read: the transitions of its state alone (scroll.odin), without a window.

import "core:fmt"
import "core:testing"
import "gt:ui"

// The state in words: a failure says what it was.
@(private = "file")
said :: proc(s: Chat_Scroll) -> string {
	switch v in s {
	case Scroll_Following: return v.jump ? "following, at once" : "following"
	case Scroll_Free:      return "free"
	case Scroll_Anchored:  return fmt.tprintf("anchored at %v, keeping %q", v.y, v.keep)
	case Scroll_Keeping:   return fmt.tprintf("keeping %s", v.msg)
	case Scroll_Restoring: return fmt.tprintf("restoring %s at %v, still %d", v.msg, v.dy, v.still)
	}
	return ""
}

@(test)
the_bottom_is_left_by_a_hand_and_taken_back_at_it :: proc(t: ^testing.T) {
	s: Chat_Scroll   // (the zero state: a conversation opened follows its bottom)
	testing.expect_value(t, said(s), "following")
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)
	testing.expect_value(t, said(s), "following")
	s = chat_scroll_step(s, Scroll_Signal.Snap)
	testing.expect_value(t, said(s), "following, at once")
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)
	testing.expect_value(t, said(s), "following, at once")   // (the frame's builds keep it)
	s = chat_scroll_step(s, Scroll_Signal.Frame_Done)
	testing.expect_value(t, said(s), "following")
	// a page read above while following: the bottom stays
	s = chat_scroll_step(s, Scroll_Older_Page{"m1"})
	testing.expect_value(t, said(s), "following")
	// a hand moves it up: let go of
	s = chat_scroll_step(s, Scroll_Signal.Moved_Up)
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(s, Scroll_Signal.Off_Bottom)
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(s, Scroll_Signal.Snap)
	testing.expect_value(t, said(s), "free")   // (a first page or a view built anew does not fetch a reader who went up)
	// back at the bottom: followed again
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)
	testing.expect_value(t, said(s), "following")
	// following not wanted (the preference, the home page)
	s = chat_scroll_step(s, Scroll_Signal.Off_Bottom)
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(s, Scroll_Signal.Go_Bottom)
	testing.expect_value(t, said(s), "following")
}

@(test)
a_page_read_above_a_free_view_keeps_its_first_message :: proc(t: ^testing.T) {
	head: ui.Box
	s: Chat_Scroll = Scroll_Free{}
	s = chat_scroll_step(s, Scroll_Older_Page{"m1"})
	testing.expect_value(t, said(s), "keeping m1")
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)   // (what a build ends at changes nothing while it holds)
	testing.expect_value(t, said(s), "keeping m1")
	s = chat_scroll_step(s, Scroll_Anchor{&head, 40})   // (its box found: held where it was on screen)
	testing.expect_value(t, said(s), "anchored at 40, keeping \"m1\"")
	if a, ok := s.(Scroll_Anchored); ok { testing.expect(t, a.box == &head, "its box") }
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)
	s = chat_scroll_step(s, Scroll_Signal.Off_Bottom)
	testing.expect_value(t, said(s), "anchored at 40, keeping \"m1\"")
	s = chat_scroll_step(s, Scroll_Signal.Frame_Done)
	testing.expect_value(t, said(s), "free")
	// nothing to hold (no box, or a view sent to the start): the reader's place
	s = chat_scroll_step(s, Scroll_Older_Page{"m2"})
	s = chat_scroll_step(s, Scroll_Anchor{nil, 0})
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(s, Scroll_Older_Page{""})
	testing.expect_value(t, said(s), "free")
	// a part opened: its header held, from any state, the bottom let go of until the frame ends
	s = Scroll_Following{}
	s = chat_scroll_step(s, Scroll_Anchor{&head, 12})
	testing.expect_value(t, said(s), "anchored at 12, keeping \"\"")
	s = chat_scroll_step(s, Scroll_Signal.Frame_Done)
	testing.expect_value(t, said(s), "free")
	// a page that came, then a part opened in the same build: both held
	s = chat_scroll_step(s, Scroll_Older_Page{"m3"})
	s = chat_scroll_step(s, Scroll_Anchor{&head, 30})
	s = chat_scroll_step(s, Scroll_Anchor{&head, 50})
	testing.expect_value(t, said(s), "anchored at 50, keeping \"m3\"")
}

@(test)
a_view_going_back_holds_until_it_stays_then_is_the_readers :: proc(t: ^testing.T) {
	s: Chat_Scroll
	s = chat_scroll_step(s, Scroll_Restore{"m", 5})
	testing.expect_value(t, said(s), "restoring m at 5, still 0")
	s = chat_scroll_step(s, Scroll_Signal.At_Bottom)   // (not followed until it got there)
	s = chat_scroll_step(s, Scroll_Signal.Snap)
	s = chat_scroll_step(s, Scroll_Signal.Frame_Done)
	s = chat_scroll_step(s, Scroll_Older_Page{"x"})   // (the pin holds it: no page keeping)
	testing.expect_value(t, said(s), "restoring m at 5, still 0")
	for _ in 0 ..< NAV_RESTORE_STILL - 1 { s = chat_scroll_step(s, Scroll_Restore_Held{found = true}) }
	testing.expect_value(t, said(s), fmt.tprintf("restoring m at 5, still %d", NAV_RESTORE_STILL - 1))
	s = chat_scroll_step(s, Scroll_Restore_Held{found = true, moved = true})   // (the heights around it settled again)
	testing.expect_value(t, said(s), "restoring m at 5, still 0")
	s = chat_scroll_step(s, Scroll_Restore_Held{})   // (not built yet)
	testing.expect_value(t, said(s), "restoring m at 5, still 0")
	for _ in 0 ..< NAV_RESTORE_STILL { s = chat_scroll_step(s, Scroll_Restore_Held{found = true}) }
	testing.expect_value(t, said(s), "free")
	// what ends it
	s = chat_scroll_step(Scroll_Restoring{msg = "m"}, Scroll_Signal.Restore_End)
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(Scroll_Restoring{msg = "m"}, Scroll_Signal.Go_Bottom)
	testing.expect_value(t, said(s), "following")
	s = chat_scroll_step(Scroll_Restoring{msg = "m"}, Scroll_Signal.Restore_Missing)
	testing.expect_value(t, said(s), "following, at once")
	s = chat_scroll_step(Scroll_Restoring{msg = "m"}, Scroll_Signal.Opened)
	testing.expect_value(t, said(s), "following")
	// what does not touch a view that is not going back
	s = chat_scroll_step(Scroll_Free{}, Scroll_Signal.Restore_Missing)
	testing.expect_value(t, said(s), "free")
	s = chat_scroll_step(Scroll_Following{}, Scroll_Signal.Restore_End)
	testing.expect_value(t, said(s), "following")
	s = chat_scroll_step(Scroll_Free{}, Scroll_Restore{"", 0})
	testing.expect_value(t, said(s), "free")
	// the conversation built in other boxes: the bottom at once, or the message read
	s = chat_scroll_step(Scroll_Following{}, Scroll_Hold_View{"m", 3})
	testing.expect_value(t, said(s), "following, at once")
	s = chat_scroll_step(Scroll_Free{}, Scroll_Hold_View{"m", 3})
	testing.expect_value(t, said(s), "restoring m at 3, still 0")
	s = chat_scroll_step(Scroll_Free{}, Scroll_Hold_View{"", 0})
	testing.expect_value(t, said(s), "free")
}
