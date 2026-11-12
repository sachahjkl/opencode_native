package ocn

import "core:os"
import "core:strings"
import "core:testing"
import setup "gt:setup"
import "gt:ui"
import lucide "gt:lucide"

_ :: os        // (the tests of Windows)
_ :: strings

@(test)
links_allowed :: proc(t: ^testing.T) {
	for u in ([]string{"http://a.b", "https://a.b/c?d=e", "HTTPS://A.B", "mailto:a@b.c"}) { testing.expect(t, link_allowed(u), u) }
	for u in ([]string{"", "C:\\Windows\\System32\\calc.exe", "\\\\host\\share\\x.exe", "file:///C:/x.bat", "javascript:alert(1)", "src/main.odin", " https://a.b", "httpsx://a.b"}) {
		testing.expect(t, !link_allowed(u), u)
	}
}

@(test)
labels_keep_their_hashes :: proc(t: ^testing.T) {
	testing.expect_value(t, label_safe("plain # text"), "plain # text")
	testing.expect_value(t, label_safe("a##b"), "a#\u200b#b")
	testing.expect_value(t, label_safe("###"), "#\u200b#\u200b#")
}

@(test)
slider_focus_alone :: proc(t: ^testing.T) {
	testing.expect_value(t, slider_idle(800, 5, 400, 5), 400)   // a value the file allows, beyond the slider
	testing.expect_value(t, slider_idle(60, 5, 400, 5), 60)     // on its step: nothing moves
	testing.expect(t, abs(slider_idle(1.125, 0.6, 2.5, 0.05) - 1.15) < 0.051)
}

@(test)
config_files_only :: proc(t: ^testing.T) {
	for p in ([]string{"opencode.json", "\\\\host\\share\\x.json", "//host/x.json", "https://a.b/x.json"}) { testing.expect(t, !config_file_shaped(p), p) }
	when ODIN_OS == .Windows {
		testing.expect(t, config_file_shaped("C:\\Users\\me\\.config\\opencode\\opencode.JSONC"))
		testing.expect(t, !config_file_shaped("C:\\Users\\me\\run.exe"))
		testing.expect(t, !config_file_shaped("C:\\Users\\me\\run.bat"))
	} else {
		testing.expect(t, config_file_shaped("/home/me/.config/opencode/opencode.json"))
		testing.expect(t, !config_file_shaped("/home/me/run.sh"))
	}
}

@(test)
previews_read_as_text :: proc(t: ^testing.T) {
	testing.expect_value(t, preview_text("## Plan\n- first"), "Plan")
	testing.expect_value(t, preview_text("\n---\n\n- **Check** the `tests` first"), "Check the tests first")
	testing.expect_value(t, preview_text("3. Third item"), "Third item")
	testing.expect_value(t, preview_text("> quoted ~~old~~ text"), "quoted old text")
	testing.expect_value(t, preview_text("plain line\nsecond"), "plain line")
	testing.expect_value(t, preview_text("---\n\n"), "")
}

@(test)
the_card_says_its_state_once :: proc(t: ^testing.T) {
	v := Sub_View{state = .Running, started = 1000, model = "anthropic/m1"}
	testing.expect_value(t, state_when(v.state, v.started, 61000), "1m 00s")   // (its lamp says it runs)
	testing.expect_value(t, card_meta(&v, true), "m1")
	v.state = .Failed
	testing.expect_value(t, state_when(v.state, v.started, 61000), "failed · 1m 00s")
	testing.expect_value(t, card_meta(&v, false), "m1")
	v.state = .Done
	testing.expect_value(t, state_when(v.state, v.started, 61000), "done · 1m 00s")
	v.state = .Cancelled
	testing.expect_value(t, state_when(v.state, v.started, 61000), "stopped · 1m 00s")
	v.state = .Finishing
	testing.expect_value(t, state_when(v.state, v.started, 61000), "finishing · 1m 00s")
	v.state = .Background
	testing.expect_value(t, state_when(v.state, v.started, 0), "in background")
}

// Each state that ended has its sign and its intent; what goes on has none (a lamp).
@(test)
an_ended_state_has_its_sign :: proc(t: ^testing.T) {
	testing.expect_value(t, sub_state_sign(.Done), lucide.CHECK)
	testing.expect_value(t, sub_state_sign(.Failed), lucide.X)
	testing.expect_value(t, sub_state_sign(.Cancelled), lucide.SQUARE)
	testing.expect_value(t, sub_state_intent(.Done), ui.Intent.Success)
	testing.expect_value(t, sub_state_intent(.Failed), ui.Intent.Danger)
	testing.expect_value(t, sub_state_intent(.Cancelled), ui.Intent.Warning)
	for st in ([]Sub_State{.Starting, .Running, .Finishing}) {
		testing.expectf(t, sub_live(st) && sub_state_sign(st) == "" && sub_state_intent(st) == .Neutral, "%v goes on: a lamp", st)
	}
	for st in ([]Sub_State{.Done, .Failed, .Cancelled, .Background, .Unknown}) { testing.expectf(t, !sub_live(st), "%v: no lamp", st) }
}

@(test)
a_card_with_nothing_more_than_its_time_has_no_second_line :: proc(t: ^testing.T) {
	v := Sub_View{state = .Running, started = 1000}
	testing.expect_value(t, card_meta(&v, true), "")
	v.live, v.has_live = {activity = "shell: odin test"}, true
	testing.expect_value(t, card_meta(&v, true), "shell: odin test")
	testing.expect_value(t, card_meta(&v, false), "")   // (what it was doing is over with it)
}

@(test)
one_server_or_two :: proc(t: ^testing.T) {
	testing.expect(t, same_server("127.0.0.1", 4096, "localhost", 4096))
	testing.expect(t, same_server("host.example", 80, "host.example", 80))
	testing.expect(t, !same_server("127.0.0.1", 4096, "127.0.0.1", 4097), "another port is another server")
	testing.expect(t, !same_server("127.0.0.1", 4096, "evil.example", 4096))
	testing.expect(t, !same_server("127.0.0.1", 4096, "localhost.evil.example", 4096))
}

@(test)
passwords_in_the_file :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows {
		password := "s3cret \t with \u00fcnicode"
		field, ok := password_seal("a server", password)
		testing.expect(t, ok)
		testing.expect(t, !strings.contains(field, "s3cret"), "not in clear")
		got, stored, clear_text := password_from_field("a server", field)
		testing.expect_value(t, got, password)
		testing.expect_value(t, stored, "")
		testing.expect(t, !clear_text)
		got, stored, clear_text = password_from_field("a server", "dpapi:AAAAAAAA")
		testing.expect_value(t, got, "")
		testing.expect_value(t, stored, "dpapi:AAAAAAAA")   // this account cannot open it: it stays
		testing.expect(t, !clear_text)
	}
	// an older version's file
	got2, stored2, clear2 := password_from_field("a server", "old-password")
	testing.expect_value(t, got2, "old-password")
	testing.expect(t, clear2)
	testing.expect_value(t, stored2, "")
	got2, _, clear2 = password_from_field("a server", "")
	testing.expect_value(t, got2, "")
	testing.expect(t, !clear2)
}

// The user's answer in settings.txt: closed without one, not again for this version; an earlier "standalone" or
// "installed" stays, unless an upgrade was declined.
@(test)
setup_keeps_the_users_answer :: proc(t: ^testing.T) {
	none := setup.Facts{state = .Not_Installed}
	older := setup.Facts{state = .Other_Copy, version = "0.0.1"}
	dismissed := "dismissed:" + APP_VERSION
	expect :: proc(t: ^testing.T, ev: setup.Event, f: setup.Facts, saved, want: string, changed: bool, loc := #caller_location) {
		c, ch := setup_choice(ev, f, saved)
		testing.expect_value(t, c, want, loc = loc)
		testing.expect_value(t, ch, changed, loc = loc)
	}
	expect(t, .Installed, none, "", "installed", true)
	expect(t, .Kept_Standalone, none, "", "standalone", true)
	expect(t, .Dismissed, none, "", dismissed, true)
	expect(t, .Dismissed, none, "standalone", "standalone", false)
	expect(t, .Dismissed, none, "installed", "installed", false)
	expect(t, .Dismissed, older, "standalone", dismissed, true)   // (an upgrade declined: for this version)
	expect(t, .Uninstalled, none, "installed", "installed", false)
	expect(t, .None, none, "", "", false)
}

@(test)
the_viewer_stays_within_its_limits :: proc(t: ^testing.T) {
	testing.expect_value(t, view_pan_clamp({50, 50}, {100, 100}, {200, 200}), [2]f32{0, 0})
	testing.expect_value(t, view_pan_clamp({500, -500}, {400, 300}, {200, 200}), [2]f32{100, -50})
	testing.expect_value(t, view_pan_clamp({10, 10}, {400, 300}, {200, 200}), [2]f32{10, 10})
}

// The viewer is the picture and its chrome, nothing more: the black around a picture smaller than the dialog was taken for the outside,
// and a click there did not close it.
@(test)
the_viewer_hugs_the_picture :: proc(t: ^testing.T) {
	room, chrome := [2]f32{1200, 900}, [2]f32{16, 58}
	f := viewer_frame({1000, 500}, room, chrome, 1, 1, 300)
	testing.expect_value(t, f.picture, [2]f32{1000, 500})   // (never beyond its pixels)
	testing.expect_value(t, f.panel, [2]f32{1016, 558})
	f = viewer_frame({1000, 500}, room, chrome, 2, 1, 300)
	testing.expect_value(t, f.picture, [2]f32{1184, 592})   // as wide as the room: its height follows
	testing.expect_value(t, f.panel, [2]f32{1200, 650})
	f = viewer_frame({400, 2000}, room, chrome, 1, 1, 300)
	testing.expect_value(t, f.picture, [2]f32{168, 842})    // as tall as the room
	testing.expect_value(t, f.panel, [2]f32{300, 900})      // (the bar's width: room on the picture's sides)
	f = viewer_frame({1000, 500}, room, chrome, 2, 0.5, 300)
	testing.expect_value(t, f.picture, [2]f32{592, 296})    // the size chosen, of the most the room gives
	testing.expect_value(t, f.full, [2]f32{1184, 592})
	f = viewer_frame({1000, 500}, room, chrome, 2, 0, 300)
	testing.expect_value(t, f.picture, [2]f32{237, 118})    // (no smaller than VIEWER_SCALE_MIN)
	f = viewer_frame({40, 40}, {200, 900}, chrome, 1, 1, 300)
	testing.expect_value(t, f.panel, [2]f32{200, 98})       // never wider than the room
	// a small picture opens at its pixels; once the person drags the grips, it takes the size asked, up to the room
	f = viewer_frame({100, 50}, room, chrome, 1, 1, 300)
	testing.expect_value(t, f.picture, [2]f32{100, 50})
	f = viewer_frame({100, 50}, room, chrome, 1, 1, 300, grown = true)
	testing.expect_value(t, f.picture, [2]f32{1184, 592})
	f = viewer_frame({100, 50}, room, chrome, 1, 0.5, 300, grown = true)
	testing.expect_value(t, f.picture, [2]f32{592, 296})
}

@(test)
a_grip_of_the_viewer_sets_its_scale :: proc(t: ^testing.T) {
	near :: proc(a, b: f32) -> bool { return abs(a - b) < 1e-5 }
	full := [2]f32{1000, 500}
	testing.expect(t, near(viewer_scale_of({100, 0}, full, 0.5), 0.6), "an edge to the right")
	testing.expect(t, near(viewer_scale_of({0, -100}, full, 0.5), 0.3), "the bottom edge up")
	testing.expect(t, near(viewer_scale_of({100, 60}, full, 0.5), 0.6), "a corner: the side that moved most")
	testing.expect(t, near(viewer_scale_of({-2000, 0}, full, 0.5), VIEWER_SCALE_MIN), "no smaller than its least")
	testing.expect(t, near(viewer_scale_of({2000, 0}, full, 0.5), 1), "no larger than the room")
}

@(test)
a_press_outside_the_picture_misses_it :: proc(t: ^testing.T) {
	view := [2]f32{400, 200}
	testing.expect(t, !viewer_outside({10, 10}, view, view, {}), "the picture fills the view")
	testing.expect(t, viewer_outside({10, 10}, view, {200, 100}, {}), "zoomed out: the black around it")
	testing.expect(t, !viewer_outside({200, 100}, view, {200, 100}, {}), "its middle")
	testing.expect(t, viewer_outside({150, 60}, view, {200, 100}, {100, 0}), "moved right: what it left")
	testing.expect(t, !viewer_outside({210, 60}, view, {200, 100}, {100, 0}), "moved right: where it went")
	testing.expect(t, !viewer_outside({0, 0}, view, {800, 400}, {100, 0}), "zoomed in: everywhere in the view")
	testing.expect(t, viewer_outside({-1, 0}, view, {800, 400}, {100, 0}), "but not beyond it")
}
