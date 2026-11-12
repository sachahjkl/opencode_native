package ocn

// A browser per session, of one tab or several, on a host that keeps what it is asked instead of asking a web view (Web_Host): which view, which address, shown
// or not. No window, no real page, nothing waited for: what a view says is said by the test, through what a real one calls.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import "core:testing"
import "gt:platform"
import "gt:ui"

Bench_View :: struct {
	urls:    [dynamic]string,   // every navigation asked for (owned)
	window:  ^platform.Window,
	bounds:  [4]int,
	visible: bool,
	closed:  bool,
	moves:   int,               // times it changed windows
	focused: int,               // times it was given the keyboard
}

// (Any window that is not the test's: the host only compares them.)
@(thread_local) bench_views: [dynamic]^Bench_View

bench_web_host :: proc() -> Web_Host {
	clear(&bench_views)
	return {
		open = proc(app: ^App, v: ^Web_View, parent: ^platform.Window) -> rawptr {
			b := new(Bench_View, runtime.heap_allocator())
			b.window = parent
			append(&bench_views, b)
			return b
		},
		close = proc(native: rawptr) { (^Bench_View)(native).closed = true },
		parent = proc(native: rawptr, w: ^platform.Window) {
			b := (^Bench_View)(native)
			b.window = w
			b.moves += 1
		},
		navigate = proc(native: rawptr, url: string) { append(&(^Bench_View)(native).urls, strings.clone(url)) },
		act = proc(native: rawptr, what: Web_Act) { if what == .Focus { (^Bench_View)(native).focused += 1 } },
		can = proc(native: rawptr, what: Web_Act) -> bool { return false },
		script = proc(native: rawptr, code: string, id: u64) {},
		capture = proc(native: rawptr, id: u64) {},
		place = proc(native: rawptr, x, y, w, h: int, visible: bool) {
			b := (^Bench_View)(native)
			b.bounds, b.visible = {x, y, w, h}, visible
		},
	}
}

// What the front tab's view says, a view made for it if it has none.
web_said :: proc(app: ^App, kind: Web_Event_Kind, id: u64, data: []u8) {
	tab := preview_front_made(app, &app.preview)
	if tab.view == nil { web_start(app, tab) }
	web_event_add(tab.view, kind, id, data)
}

@(private = "file")
fake :: proc(tab: ^Preview_Tab) -> ^Bench_View { return (^Bench_View)(tab.view.native) }

@(private = "file")
fr :: proc(app: ^App) -> ^Preview_Tab { return preview_front(&app.preview) }

@(private = "file")
words :: proc(s: string) -> []u8 { return transmute([]u8)s }

// The window goes to this session, as nav_apply would leave it, and the frame's point follows.
@(private = "file")
go_to :: proc(app: ^App, id: string, parent := "") {
	chat_reset(&app.chat)
	app.chat.id = strings.clone(id, app.chat.alloc)
	app.chat.have_self = true
	app.chat.self.parent = strings.clone(parent, app.chat.alloc)
	preview_follow(app)
}

@(private = "file")
go_home :: proc(app: ^App) {
	chat_home(app)
	preview_follow(app)
}

// A session with its browser open on `url`, loaded: what the panel would say.
@(private = "file")
with_page :: proc(app: ^App, id, url, title: string) {
	go_to(app, id)
	if !app.preview.open { preview_show(app) }
	loaded(app, url, title)
}

// The front tab goes to `url`, and it comes.
@(private = "file")
loaded :: proc(app: ^App, url, title: string) {
	preview_go(app, preview_front_made(app, &app.preview), url)
	web_said(app, .Ready, 0, nil)
	web_said(app, .Source, 0, words(url))
	web_said(app, .Title, 0, words(title))
	web_events_drain(app)
}

// A second tab of the session shown, loaded.
@(private = "file")
second_tab :: proc(app: ^App, url, title: string) -> ^Preview_Tab {
	tab := preview_tab_add(app, &app.preview)
	loaded(app, url, title)
	return tab
}

@(private = "file")
link :: proc(app: ^App) -> ^Browser_Link {
	l := new(Browser_Link)
	l.conn = app.conn
	l.socket, l.serial = 1, 1
	app.conn.browser = l
	return l
}

@(private = "file")
answers :: proc(l: ^Browser_Link) -> string {
	b := strings.builder_make(context.temp_allocator)
	for o in l.outbox {
		strings.write_string(&b, o.text)
		delete(o.text)
	}
	clear(&l.outbox)
	return strings.to_string(b)
}

// A call of an agent of `session`, as the server sends it. ("": one that names none.)
@(private = "file")
agent_call :: proc(app: ^App, l: ^Browser_Link, id: int, name, session: string, url := "http://x", tab := "", more := "") {
	meta := session != "" ? fmt.tprintf(`,"_meta":{{%s:%s}}`, jquote(BROWSER_SESSION_META), jquote(session)) : ""
	which := tab != "" ? fmt.tprintf(`,"tabID":%s`, jquote(tab)) : ""
	browser_message(app, {l, 1}, fmt.tprintf(`{{"jsonrpc":"2.0","id":%d,"method":"tools/call","params":{{"name":%s,"arguments":{{"url":%s%s%s}}%s}}}}`, id, jquote(name), jquote(url), which, more, meta))
}

////////////////////////////////
// Each session its own

@(test)
two_sessions_keep_their_page :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "Page A")
	with_page(app, "b", "http://b.local/", "Page B")
	testing.expect_value(t, fr(app).url, "http://b.local/")
	testing.expect_value(t, ui.field_string(&fr(app).field), "http://b.local/")
	go_to(app, "a")
	testing.expect_value(t, fr(app).url, "http://a.local/")
	testing.expect_value(t, fr(app).title, "Page A")
	testing.expect_value(t, ui.field_string(&fr(app).field), "http://a.local/")
	testing.expect_value(t, panel_title(app, u32(Panel.Preview)), "Page A")
	testing.expect_value(t, len(bench_views), 2)
}

@(test)
coming_back_does_not_load_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	a := fake(fr(app))
	with_page(app, "b", "http://b.local/", "B")
	b := fake(fr(app))
	for _ in 0 ..< 3 {
		go_to(app, "a")
		go_to(app, "b")
	}
	go_to(app, "a")
	testing.expect(t, fake(fr(app)) == a, "the same view")
	testing.expect(t, !a.closed && !b.closed, "both alive")
	testing.expect_value(t, len(a.urls), 1)
	testing.expect_value(t, len(b.urls), 1)
}

@(test)
only_the_page_shown_is_visible :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	a := fake(fr(app))
	app.preview.shown = true
	app.preview.body = {{10, 20}, {110, 220}}
	preview_place(app, false)
	testing.expect(t, a.visible, "shown")
	go_to(app, "b")
	testing.expect(t, !a.visible, "hidden the moment it stops being shown")
	testing.expect_value(t, a.bounds, [4]int{10, 20, 100, 200})   // (its page stays laid out)
	go_to(app, "a")
	app.preview.shown = true
	app.preview.body = {{10, 20}, {110, 220}}
	preview_place(app, false)
	testing.expect(t, a.visible, "shown again at the first frame, not after the pace of a move")
}

@(test)
what_a_parked_page_says_lands_in_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	v := fr(app).view
	with_page(app, "b", "http://b.local/", "B")
	web_event_add(v, .Nav_Start, 4, nil)
	web_event_add(v, .Source, 0, words("http://a.local/next"))
	web_event_add(v, .Title, 0, words("A, later"))
	web_events_drain(app)
	testing.expect_value(t, fr(app).url, "http://b.local/")
	testing.expect_value(t, fr(app).title, "B")
	testing.expect(t, !preview_loading(fr(app)), "nor is the page shown busy")
	done := [1]u8{1}
	go_to(app, "a")
	testing.expect_value(t, fr(app).url, "http://a.local/next")
	testing.expect_value(t, fr(app).title, "A, later")
	testing.expect_value(t, ui.field_string(&fr(app).field), "http://a.local/next")
	testing.expect(t, preview_loading(fr(app)), "still under way")
	web_event_add(v, .Loaded, 4, done[:])
	web_events_drain(app)
	testing.expect(t, !preview_loading(fr(app)), "over")
}

@(test)
a_session_that_never_opened_it_has_no_tab_and_no_view :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "its tab")
	go_to(app, "b")
	testing.expect(t, !app.preview.open, "not open")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab")
	testing.expect_value(t, len(bench_views), 1)
	go_to(app, "c")
	testing.expect_value(t, len(app.previews.by_session), 1)   // (a's alone: b held nothing)
	go_to(app, "a")
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "back with its session")
	testing.expect(t, ui.dock_shown(&app.dock, u32(Panel.Preview)), "in front")
}

@(test)
a_closed_tab_is_that_sessions_alone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	with_page(app, "b", "http://b.local/", "B")
	panel_close(app, u32(Panel.Preview))
	testing.expect(t, !app.preview.open, "b's closed")
	go_to(app, "a")
	testing.expect(t, app.preview.open, "a's is not")
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "and has its tab")
	go_to(app, "b")
	testing.expect(t, !app.preview.open, "b's stayed closed")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab")
	testing.expect_value(t, fr(app).url, "http://b.local/")   // (closed is not forgotten: Ctrl+Shift+B brings it)
}

// What is saved holds the panel: a session without a browser does not take its place from the others.
@(test)
another_session_is_no_change_of_the_layout :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	go_to(app, "b")
	testing.expect_value(t, app.dock.saved, app.dock.serial)
}

@(test)
the_home_page_has_a_browser_of_its_own :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app)
	loaded(app, "http://home.local/", "Home")
	go_to(app, "a")
	testing.expect_value(t, len(app.preview.tabs), 0)
	testing.expect(t, !app.preview.open, "the session has none")
	go_home(app)
	testing.expect_value(t, fr(app).url, "http://home.local/")
}

@(test)
what_is_open_beside_a_first_prompt_stays_with_its_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	preview_show(app)
	loaded(app, "http://home.local/", "Home")
	preview_adopt(app, "new")
	go_to(app, "new")
	testing.expect(t, app.preview.open, "it did not go away")
	testing.expect_value(t, len(fake(fr(app)).urls), 1)
	go_home(app)
	testing.expect(t, !app.preview.open, "the home page starts empty")
}

////////////////////////////////
// Sub-agents

@(test)
a_sub_agent_uses_its_sessions_browser :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "root", "http://r.local/", "R")
	view := fr(app).view
	go_to(app, "child", parent = "root")
	testing.expect(t, fr(app).view == view, "the same page")
	testing.expect_value(t, app.preview.key, "root")
}

// Opened by its address, nothing says yet whose it is: the page does not leave for that time.
@(test)
a_session_not_read_yet_moves_nothing :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "root", "http://r.local/", "R")
	chat_reset(&app.chat)
	app.chat.id = strings.clone("child", app.chat.alloc)
	preview_follow(app)
	testing.expect_value(t, app.preview.key, "root")
	app.chat.have_self = true
	app.chat.self.parent = strings.clone("root", app.chat.alloc)
	preview_follow(app)
	testing.expect_value(t, app.preview.key, "root")
	testing.expect(t, app.preview.open, "and it never closed")
}

@(test)
the_way_down_says_the_root_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "root", "http://r.local/", "R")
	append(&app.nav.drilled, strings.clone("root"))
	chat_reset(&app.chat)
	app.chat.id = strings.clone("child", app.chat.alloc)
	preview_follow(app)
	testing.expect_value(t, app.preview.key, "root")
}

////////////////////////////////
// The limit

@(test)
past_the_limit_the_view_shown_longest_ago_goes_and_its_address_stays :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	for i in 0 ..< PREVIEW_VIEWS_MOST { with_page(app, fmt.tprintf("s%d", i), fmt.tprintf("http://%d.local/", i), "T") }
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
	first, second := bench_views[0], bench_views[1]
	testing.expect(t, !first.closed, "none past the limit yet")
	with_page(app, "over", "http://over.local/", "T")
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
	testing.expect(t, first.closed, "the oldest went")
	testing.expect(t, !second.closed, "it alone")
	kept := preview_front(app.previews.by_session["s0"])
	testing.expect_value(t, kept.url, "http://0.local/")
	testing.expect(t, kept.view == nil && kept.web == nil, "no view")
	testing.expect(t, app.previews.by_session["s0"].open, "and still open")

	go_to(app, "s0")
	testing.expect(t, !fake(fr(app)).closed, "a new one")
	testing.expect(t, fake(fr(app)) != first, "not the one closed")
	testing.expect_value(t, fake(fr(app)).urls[0], "http://0.local/")
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
	testing.expect(t, second.closed, "the next oldest made room")
}

@(test)
the_limit_leaves_a_view_a_call_waits_on :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	for i in 0 ..< PREVIEW_VIEWS_MOST { with_page(app, fmt.tprintf("s%d", i), fmt.tprintf("http://%d.local/", i), "T") }
	first, second := bench_views[0], bench_views[1]
	agent_call(app, l, 1, "evaluate", "s0")
	preview_front(app.previews.by_session["s0"]).used = 0   // (the oldest, the call notwithstanding)
	with_page(app, "over", "http://over.local/", "T")
	testing.expect(t, !first.closed, "its answer comes from it")
	testing.expect(t, second.closed, "the next oldest went")
}

////////////////////////////////
// What goes

@(test)
a_server_left_forgets_every_sessions_page :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	parked := fr(app).view
	with_page(app, "b", "http://b.local/", "B")
	server_forget(app)
	testing.expect_value(t, len(app.previews.by_session), 0)
	testing.expect_value(t, len(app.previews.views), 0)
	for b in bench_views { testing.expect(t, b.closed, "every view") }
	testing.expect_value(t, len(app.preview.tabs), 0)
	testing.expect(t, !app.preview.open, "closed")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab")
	web_event_add(parked, .Title, 0, words("late"))   // (a script's answer on its way as it closed)
	testing.expect_value(t, len(parked.events), 0)
}

@(test)
a_deleted_session_takes_its_browser :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	with_page(app, "b", "http://b.local/", "B")
	preview_session_gone(app, "a")
	testing.expect(t, "a" not_in app.previews.by_session, "parked: at once")
	testing.expect(t, bench_views[0].closed, "its view")
	preview_session_gone(app, "b")
	testing.expect(t, !bench_views[1].closed, "shown: not while it shows")
	go_home(app)
	testing.expect(t, bench_views[1].closed, "the moment it stops")
	testing.expect_value(t, len(app.previews.by_session), 0)
}

////////////////////////////////
// The panel's window

@(private = "file")
in_a_window :: proc(app: ^App) -> ^Detached {
	d := new(Detached)
	d.panel = u32(Panel.Preview)
	d.win = new(platform.Window)
	append(&app.cx.detached, d)
	preview_move(app, d.win)
	ui.dock_close(&app.dock, d.panel)
	return d
}

@(test)
the_window_of_the_panel_follows_the_session_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.win = new(platform.Window)
	with_page(app, "a", "http://a.local/", "A")
	a := fake(fr(app))
	with_page(app, "b", "http://b.local/", "B")
	b := fake(fr(app))
	go_to(app, "a")
	d := in_a_window(app)
	testing.expect(t, a.window == d.win, "a's page in it")
	go_to(app, "b")
	testing.expect(t, b.window == d.win, "b's now")
	testing.expect(t, a.window == app.win, "a's waits in the main window")
	go_to(app, "c")
	testing.expect(t, b.window == app.win, "c has none: nothing stays in it")
	testing.expect(t, !d.closing, "the window stays, with an empty panel")
	testing.expect(t, !app.preview.open, "and c has opened nothing")
	go_to(app, "a")
	testing.expect(t, a.window == d.win, "back")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab while it has a window")
}

@(test)
closing_the_panel_closes_its_window :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.win = new(platform.Window)
	with_page(app, "a", "http://a.local/", "A")
	d := in_a_window(app)
	panel_close(app, u32(Panel.Preview))
	testing.expect(t, d.closing, "that way it goes")
}

// A view on its way cannot be moved: its Ready brings it to where the panel went meanwhile.
@(test)
a_view_on_its_way_finds_the_panel_where_it_went :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	app.win = new(platform.Window)
	go_to(app, "a")
	preview_show(app)
	b := fake(fr(app))
	d := in_a_window(app)
	testing.expect(t, b.window == app.win, "not yet")
	web_said(app, .Ready, 0, nil)
	web_events_drain(app)
	testing.expect(t, b.window == d.win, "there")
}

////////////////////////////////
// The agents

@(test)
an_agent_drives_its_sessions_page_out_of_sight :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	parked := fr(app).view
	a := fake(fr(app))
	with_page(app, "b", "http://b.local/", "B")
	b := fake(fr(app))
	agent_call(app, l, 1, "navigate", "a", url = "http://a.local/2")
	testing.expect_value(t, a.urls[len(a.urls) - 1], "http://a.local/2")
	testing.expect_value(t, len(b.urls), 1)
	testing.expect_value(t, app.preview.key, "b")
	web_event_add(parked, .Nav_Start, 9, nil)
	web_event_add(parked, .Source, 0, words("http://a.local/2"))
	done := [1]u8{1}
	web_event_add(parked, .Loaded, 9, done[:])
	web_events_drain(app)
	answer := answers(l)
	testing.expect(t, strings.contains(answer, `"id":1`) && strings.contains(answer, "a.local/2"), answer)
	testing.expect_value(t, fr(app).url, "http://b.local/")
}

@(test)
an_agent_opens_its_sessions_browser_without_showing_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	shown := fr(app).view
	agent_call(app, l, 1, "tabs_open", "other", url = "http://o.local/")
	testing.expect(t, fr(app).view == shown, "the page shown stays")
	e := app.previews.by_session["other"]
	testing.expect(t, e != nil && e.open, "open, where it is")
	testing.expect(t, !fake(preview_front(e)).visible, "out of sight")
	testing.expect(t, fake(preview_front(e)).bounds[2] > 0, "at a size its page can be read at")
	go_to(app, "other")
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "its tab when its session shows")
}

@(test)
a_sub_agents_call_goes_to_its_sessions_page :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "root", "http://r.local/", "R")
	root := fake(fr(app))
	with_page(app, "b", "http://b.local/", "B")
	append(&app.sessions, Session_Info{id = "child", parent = "root"})
	sessions_changed(app)
	agent_call(app, l, 1, "navigate", "child", url = "http://r.local/2")
	testing.expect_value(t, root.urls[len(root.urls) - 1], "http://r.local/2")
}

@(test)
a_call_that_names_no_session_drives_the_page_shown :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	agent_call(app, l, 1, "navigate", "", url = "http://a.local/2")
	testing.expect_value(t, fake(fr(app)).urls[1], "http://a.local/2")
}

@(test)
a_parked_page_has_no_picture_and_says_so_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	go_to(app, "b")
	agent_call(app, l, 1, "screenshot", "a")
	testing.expect(t, strings.contains(answers(l), "not on the screen"), "not after 30 s")
	testing.expect_value(t, len(app.browser.calls), 0)
}

// Each view numbers its navigations: the same number in two of them is two navigations.
@(test)
a_call_is_answered_by_its_own_view :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	va := fr(app).view
	agent_call(app, l, 1, "navigate", "a", url = "http://a.local/2")
	with_page(app, "b", "http://b.local/", "B")   // (the user went elsewhere meanwhile)
	vb := fr(app).view
	agent_call(app, l, 2, "navigate", "b", url = "http://b.local/2")
	web_event_add(va, .Nav_Start, 5, nil)
	web_event_add(vb, .Nav_Start, 5, nil)
	web_events_drain(app)
	done := [1]u8{1}
	web_event_add(vb, .Loaded, 5, done[:])
	web_events_drain(app)
	answer := answers(l)
	testing.expect(t, strings.contains(answer, `"id":2`) && !strings.contains(answer, `"id":1`), answer)
	web_event_add(va, .Source, 0, words("http://a.local/2"))
	web_event_add(va, .Loaded, 5, done[:])
	web_events_drain(app)
	answer = answers(l)
	testing.expect(t, strings.contains(answer, `"id":1`) && strings.contains(answer, "a.local/2"), answer)
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
a_script_is_answered_by_the_view_that_ran_it :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	va := fr(app).view
	web_said(app, .Ready, 0, nil)
	web_events_drain(app)
	agent_call(app, l, 1, "evaluate", "a")
	id := app.browser.calls[0].wait.(Wait_Script).id
	with_page(app, "b", "http://b.local/", "B")
	web_event_add(fr(app).view, .Script, id, words(`"from b"`))
	web_events_drain(app)
	testing.expect_value(t, answers(l), "")
	web_event_add(va, .Script, id, words(`"from a"`))
	web_events_drain(app)
	testing.expect(t, strings.contains(answers(l), "from a"), "its own")
}

@(test)
a_view_that_goes_answers_its_calls_and_no_others :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	agent_call(app, l, 1, "navigate", "a", url = "http://a.local/2")
	with_page(app, "b", "http://b.local/", "B")
	agent_call(app, l, 2, "navigate", "b", url = "http://b.local/2")
	preview_session_gone(app, "a")
	answer := answers(l)
	testing.expect(t, strings.contains(answer, `"id":1`) && strings.contains(answer, "closed"), answer)
	testing.expect_value(t, len(app.browser.calls), 1)
	testing.expect_value(t, app.browser.calls[0].id, "2")
}

@(test)
a_view_that_fails_ends_its_own_calls_alone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	va := fr(app).view
	agent_call(app, l, 1, "navigate", "a")
	with_page(app, "b", "http://b.local/", "B")
	agent_call(app, l, 2, "navigate", "b")
	web_event_add(va, .Failed, 0, words("no runtime"))
	web_events_drain(app)
	_, failed := preview_front(app.previews.by_session["a"]).web.(Web_Failed)
	testing.expect(t, failed, "in its Preview")
	_, also := fr(app).web.(Web_Failed)
	testing.expect(t, !also, "not in the one shown")
	testing.expect_value(t, len(app.browser.calls), 1)
	testing.expect_value(t, app.browser.calls[0].id, "2")
}

// A move of the folder closes the socket: what waits on it would never be answered.
@(test)
the_socket_moves_after_the_calls_that_wait :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	app.prefs.browser_tools = true
	with_page(app, "a", "http://a.local/", "A")
	app.chat.self.directory = strings.clone("C:/a", app.chat.alloc)
	browser_tick(app)
	_, moved := browser_link_target(l)
	agent_call(app, l, 1, "navigate", "a")
	chat_reset(&app.chat)
	app.chat.id = strings.clone("b", app.chat.alloc)
	app.chat.have_self = true
	app.chat.self.directory = strings.clone("C:/b", app.chat.alloc)
	preview_follow(app)
	browser_tick(app)
	testing.expect(t, !browser_link_moved(l, moved), "the call waits")
	testing.expect_value(t, sync.atomic_load(&l.socket), u64(1))
	browser_calls_drop(app, {l, 1})
	browser_tick(app)
	testing.expect(t, browser_link_moved(l, moved), "then it moves")
}

////////////////////////////////
// The tabs of a session

@(test)
two_tabs_of_a_session_keep_their_pages :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	testing.expect(t, fake(one) != fake(two), "a view each")
	testing.expect(t, !fake(one).visible, "the one behind is hidden")
	testing.expect_value(t, panel_title(app, u32(Panel.Preview)), "Two")
	preview_tab_front(app, &app.preview, one)
	testing.expect_value(t, ui.field_string(&fr(app).field), "http://one.local/")
	testing.expect_value(t, panel_title(app, u32(Panel.Preview)), "One")
	testing.expect_value(t, len(fake(one).urls), 1)
	testing.expect_value(t, len(fake(two).urls), 1)
	testing.expect(t, ui.dock_has(&app.dock, u32(Panel.Preview)), "one panel")
	testing.expect_value(t, len(ui.dock_tabs(&app.dock, ui.dock_leaf_of(&app.dock, u32(Panel.Preview)))), 1)
}

@(test)
a_tab_says_to_its_own_page_whichever_is_in_front :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	web_event_add(one.view, .Title, 0, words("One, later"))
	web_events_drain(app)
	testing.expect_value(t, one.title, "One, later")
	testing.expect_value(t, two.title, "Two")
}

@(test)
closing_the_front_tab_shows_its_neighbour :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	three := second_tab(app, "http://three.local/", "Three")
	preview_tab_front(app, &app.preview, two)
	view := fake(two)
	preview_tab_close(app, &app.preview, two)
	testing.expect(t, view.closed, "its view went")
	testing.expect(t, fr(app) == three, "the next one")
	preview_tab_close(app, &app.preview, three)
	testing.expect(t, fr(app) == one, "at the end of the row: the one before")
	testing.expect_value(t, len(fake(one).urls), 1)
	testing.expect(t, app.preview.open, "the panel stays")
}

@(test)
closing_a_tab_behind_leaves_the_one_in_front :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	preview_tab_close(app, &app.preview, one)
	testing.expect(t, fr(app) == two, "it stays")
	testing.expect_value(t, app.preview.front, 0)
}

@(test)
closing_the_last_tab_closes_the_panel_of_that_session_alone :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://a.local/", "A")
	with_page(app, "b", "http://b.local/", "B")
	preview_tab_close_front(app)
	testing.expect(t, !app.preview.open, "closed")
	testing.expect(t, !ui.dock_has(&app.dock, u32(Panel.Preview)), "no tab in the dock")
	testing.expect_value(t, len(app.preview.tabs), 0)
	go_to(app, "a")
	testing.expect(t, app.preview.open, "the other session's stays")
	testing.expect_value(t, fr(app).url, "http://a.local/")
}

@(test)
another_session_shown_keeps_the_tabs_and_the_one_in_front :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	preview_tab_front(app, &app.preview, one)
	with_page(app, "b", "http://b.local/", "B")
	go_to(app, "a")
	testing.expect_value(t, len(app.preview.tabs), 2)
	testing.expect(t, fr(app) == one, "the one left in front")
	testing.expect(t, app.preview.tabs[1] == two, "the other behind it")
	testing.expect_value(t, len(fake(one).urls), 1)
	testing.expect_value(t, len(fake(two).urls), 1)
	testing.expect(t, !fake(two).visible, "hidden")
}

@(test)
a_link_goes_to_the_front_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	preview_go(app, fr(app), "http://link.local/")
	testing.expect_value(t, len(app.preview.tabs), 2)
	testing.expect_value(t, fake(two).urls[1], "http://link.local/")
	testing.expect_value(t, len(fake(one).urls), 1)
}

// A click comes in the middle of a build that is going through the tabs.
@(test)
what_the_strip_asks_is_done_where_nothing_is_built :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	app.preview.due_close = two
	testing.expect_value(t, len(app.preview.tabs), 2)
	preview_follow(app)
	testing.expect_value(t, len(app.preview.tabs), 1)
	testing.expect(t, fr(app) == one, "its neighbour")
	testing.expect(t, app.preview.due_close == nil, "once")
	testing.expect(t, one.focus_page, "it takes the keyboard when it shows")
}

@(test)
ctrl_w_in_the_page_closes_its_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	second_tab(app, "http://two.local/", "Two")
	web_event_add(fr(app).view, .Key, u64('W'), nil, ctrl = true)
	web_events_drain(app)
	preview_follow(app)
	testing.expect_value(t, len(app.preview.tabs), 1)
	web_event_add(fr(app).view, .Key, u64('W'), nil, ctrl = false)   // (no Ctrl, or Ctrl and Shift: on_web)
	web_events_drain(app)
	preview_follow(app)
	testing.expect_value(t, len(app.preview.tabs), 1)
}

@(test)
ctrl_t_and_ctrl_w_stay_free_outside_the_panel :: proc(t: ^testing.T) {
	for &c in COMMANDS {
		if c.id != "view.preview_tab" && c.id != "view.preview_tab_close" { continue }
		testing.expect(t, c.key == .None, "no key of the table: a shell or the composer would lose it")
	}
	testing.expect(t, command_find("view.preview_tab") != nil, "in the palette")
	testing.expect(t, command_find("view.preview_tab_close") != nil, "in the palette")
}

// A new tab is laid out before it has a view: the view that comes is told where it goes all the same.
@(test)
a_view_made_after_its_tab_was_laid_out_is_placed :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	tab := preview_tab_add(app, &app.preview)
	app.preview.shown = true
	app.preview.body = {{10, 20}, {110, 220}}
	preview_place(app, false)
	preview_commit(app, tab, "http://two.local/")
	preview_place(app, false)
	testing.expect(t, fake(tab).visible, "it shows")
	testing.expect_value(t, fake(tab).bounds, [4]int{10, 20, 100, 200})
}

// Enter in the address of a tab whose view is still to come: the keyboard goes to the page, or the address keeps what was typed.
@(test)
the_page_takes_the_keyboard_when_its_view_comes :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	tab := preview_tab_add(app, &app.preview)
	preview_commit(app, tab, "two.local")
	testing.expect_value(t, fake(tab).focused, 0)
	app.preview.shown = true
	app.preview.body = {{10, 20}, {110, 220}}
	preview_place(app, false)
	web_event_add(tab.view, .Ready, 0, nil)
	web_event_add(tab.view, .Nav_Start, 1, nil)
	web_events_drain(app)
	testing.expect_value(t, fake(tab).focused, 0)   // (just made: a view does nothing with it, and says nothing)
	done := [1]u8{1}
	web_event_add(tab.view, .Loaded, 1, done[:])
	web_events_drain(app)
	testing.expect_value(t, fake(tab).focused, 1)
	preview_commit(app, tab, "three.local")
	testing.expect_value(t, fake(tab).focused, 2)
	testing.expect_value(t, fake(one).focused, 0)
}

@(test)
a_new_tab_costs_no_view_until_it_has_an_address :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	preview_tab_add(app, &app.preview)
	testing.expect_value(t, len(app.previews.views), 1)
	preview_go(app, fr(app), "http://two.local/")
	testing.expect_value(t, len(app.previews.views), 2)
}

////////////////////////////////
// The agents and the tabs

@(test)
tabs_list_says_the_real_tabs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	agent_call(app, l, 1, "tabs_list", "a")
	answer := answers(l)
	testing.expect(t, strings.contains(answer, one.id) && strings.contains(answer, two.id), answer)
	testing.expect(t, strings.contains(answer, "one.local") && strings.contains(answer, "two.local"), answer)
	testing.expect(t, strings.contains(answer, fmt.tprintf(`focusedTabID\":\"%s`, two.id)), answer)
}

@(test)
an_agents_tab_id_reaches_its_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	agent_call(app, l, 1, "navigate", "a", url = "http://one.local/2", tab = one.id)
	testing.expect_value(t, fake(one).urls[1], "http://one.local/2")
	testing.expect_value(t, len(fake(two).urls), 1)
	testing.expect(t, fr(app) == two, "it stays behind")
	with_page(app, "b", "http://b.local/", "B")
	agent_call(app, l, 2, "navigate", "a", url = "http://two.local/2", tab = two.id)
	testing.expect_value(t, fake(two).urls[1], "http://two.local/2")
	testing.expect_value(t, len(fake(fr(app)).urls), 1)
	testing.expect_value(t, app.preview.key, "b")
}

@(test)
no_tab_id_is_the_front_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	two := second_tab(app, "http://two.local/", "Two")
	agent_call(app, l, 1, "navigate", "a", url = "http://two.local/2")
	testing.expect_value(t, fake(two).urls[1], "http://two.local/2")
	testing.expect_value(t, len(fake(one).urls), 1)
}

@(test)
an_unknown_tab_id_is_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	agent_call(app, l, 1, "navigate", "a", tab = "tab_nothing")
	answer := answers(l)
	testing.expect(t, strings.contains(answer, "no tab tab_nothing") && strings.contains(answer, `"isError":true`), answer)
	testing.expect_value(t, len(fake(fr(app)).urls), 1)
	testing.expect_value(t, len(app.browser.calls), 0)
}

@(test)
a_tab_of_another_session_is_refused :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://a.local/", "A")
	theirs := fr(app)
	with_page(app, "b", "http://b.local/", "B")
	agent_call(app, l, 1, "navigate", "b", tab = theirs.id)
	testing.expect(t, strings.contains(answers(l), "no tab"), "an agent drives its session's pages")
	testing.expect_value(t, len(fake(theirs).urls), 1)
}

@(test)
a_tab_closed_is_an_unknown_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	two := second_tab(app, "http://two.local/", "Two")
	id := strings.clone(two.id)
	preview_tab_close(app, &app.preview, two)
	agent_call(app, l, 1, "navigate", "a", tab = id)
	testing.expect(t, strings.contains(answers(l), "no tab"), "refused")
}

@(test)
tabs_open_opens_a_new_tab_and_says_its_id :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	agent_call(app, l, 1, "tabs_open", "a", url = "http://new.local/")
	testing.expect_value(t, len(app.preview.tabs), 2)
	opened := app.preview.tabs[1]
	testing.expect(t, fr(app) == opened, "in front")
	testing.expect_value(t, fake(opened).urls[0], "http://new.local/")
	testing.expect_value(t, len(fake(one).urls), 1)
	web_event_add(opened.view, .Nav_Start, 3, nil)
	done := [1]u8{1}
	web_event_add(opened.view, .Loaded, 3, done[:])
	web_events_drain(app)
	answer := answers(l)
	testing.expect(t, strings.contains(answer, opened.id), answer)
}

@(test)
tabs_open_can_leave_the_page_in_front :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	agent_call(app, l, 1, "tabs_open", "a", url = "http://new.local/", more = `,"focus":false`)
	testing.expect_value(t, len(app.preview.tabs), 2)
	testing.expect(t, fr(app) == one, "it stays")
	testing.expect(t, !fake(app.preview.tabs[1]).visible, "out of sight")
}

// The panel opened for the call: the tab it opened with is the one asked for, not a blank one beside it.
@(test)
the_first_tabs_open_of_a_session_is_its_first_tab :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	agent_call(app, l, 1, "tabs_open", "fresh", url = "http://new.local/")
	e := app.previews.by_session["fresh"]
	testing.expect_value(t, len(e.tabs), 1)
	agent_call(app, l, 2, "tabs_open", "fresh", url = "http://two.local/")
	testing.expect_value(t, len(e.tabs), 2)   // (the first was asked for an address, which has not come yet)
}

@(test)
tabs_focus_brings_a_tab_of_any_of_the_sessions_tabs :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	second_tab(app, "http://two.local/", "Two")
	with_page(app, "b", "http://b.local/", "B")
	agent_call(app, l, 1, "tabs_focus", "a", tab = one.id)
	testing.expect_value(t, app.preview.key, "b")   // (what the user reads stays)
	go_to(app, "a")
	testing.expect(t, fr(app) == one, "in front when its session shows")
}

@(test)
a_tab_behind_has_no_picture_and_says_so_at_once :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	second_tab(app, "http://two.local/", "Two")
	agent_call(app, l, 1, "screenshot", "a", tab = one.id)
	testing.expect(t, strings.contains(answers(l), "not on the screen"), "not after 30 s")
}

@(test)
a_tab_id_lasts_and_is_never_given_again :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	one := fr(app)
	id := strings.clone(one.id)
	two := second_tab(app, "http://two.local/", "Two")
	gone := strings.clone(two.id)
	go_to(app, "b")
	go_to(app, "a")
	testing.expect_value(t, one.id, id)
	preview_tab_close(app, &app.preview, two)
	testing.expect(t, preview_tab_add(app, &app.preview).id != gone, "a new tab, a new id")
}

////////////////////////////////
// The limit, across tabs

@(test)
the_limit_counts_every_tab_of_every_session :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://0.local/", "T")
	behind := fr(app)
	id := strings.clone(behind.id)
	for i in 1 ..< PREVIEW_VIEWS_MOST { second_tab(app, fmt.tprintf("http://%d.local/", i), "T") }
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
	testing.expect(t, behind.view != nil, "none past the limit yet")
	with_page(app, "b", "http://over.local/", "T")
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
	testing.expect(t, behind.view == nil, "the tab shown longest ago, in the session parked")
	testing.expect_value(t, behind.url, "http://0.local/")
	testing.expect_value(t, behind.id, id)

	go_to(app, "a")
	preview_tab_front(app, &app.preview, behind)
	testing.expect(t, behind.view != nil, "shown: a view again")
	testing.expect_value(t, fake(behind).urls[0], "http://0.local/")
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
}

@(test)
the_limit_takes_a_tab_behind_before_the_page_on_the_screen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://0.local/", "T")
	first := fr(app)
	for i in 1 ..< PREVIEW_VIEWS_MOST { second_tab(app, fmt.tprintf("http://%d.local/", i), "T") }
	last := second_tab(app, "http://last.local/", "T")
	testing.expect(t, first.view == nil, "the oldest, behind")
	testing.expect(t, last.view != nil && fr(app) == last, "not what is shown")
	for tab in app.preview.tabs[1:] { testing.expect(t, tab.view != nil, "it alone") }
}

// However long ago it was shown: what is on the screen is not what the limit is for.
@(test)
the_limit_never_takes_the_page_on_the_screen :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://0.local/", "T")
	for i in 1 ..< PREVIEW_VIEWS_MOST { second_tab(app, fmt.tprintf("http://%d.local/", i), "T") }
	shown := fr(app)
	shown.used = 0
	behind := preview_tab_add(app, &app.preview, front = false)
	web_navigate(app, behind, "http://behind.local/")
	testing.expect(t, shown.view != nil, "it stays")
	testing.expect_value(t, len(app.previews.views), PREVIEW_VIEWS_MOST)
}

// As the tools' own ids go: a client may hold it to that form.
@(test)
a_tab_id_has_the_form_of_one :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	with_page(app, "a", "http://one.local/", "One")
	id := fr(app).id
	testing.expect_value(t, len(id), len("tab_") + 36)
	testing.expect(t, strings.has_prefix(id, "tab_"), id)
	for c in id[len("tab_"):] { testing.expect(t, c == '-' || c >= '0' && c <= '9' || c >= 'a' && c <= 'f', id) }
}

@(test)
an_agent_reaches_a_tab_the_limit_took :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	with_page(app, "a", "http://0.local/", "T")
	first := fr(app)
	for i in 1 ..= PREVIEW_VIEWS_MOST { second_tab(app, fmt.tprintf("http://%d.local/", i), "T") }
	testing.expect(t, first.view == nil, "taken")
	agent_call(app, l, 1, "navigate", "a", url = "http://0.local/2", tab = first.id)
	testing.expect(t, first.view != nil, "a view again")
	urls := fake(first).urls
	testing.expect_value(t, urls[len(urls) - 1], "http://0.local/2")
}

// An agent at work in a folder keeps its tools when another folder is shown; done, the link goes.
@(test)
a_folder_at_work_keeps_its_link :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	l := link(app)
	app.prefs.browser_tools = true
	app.link = .Online
	app.sessions = make([dynamic]Session_Info)
	append(&app.sessions, Session_Info{id = "a", directory = "C:/a"})
	sessions_changed(app)
	with_page(app, "a", "http://a.local/", "A")
	app.chat.self.directory = strings.clone("C:/a", app.chat.alloc)
	browser_tick(app)
	_, moved := browser_link_target(l)
	app.busy["a"] = true

	chat_reset(&app.chat)
	app.chat.id = strings.clone("b", app.chat.alloc)
	app.chat.have_self = true
	app.chat.self.directory = strings.clone("C:/b", app.chat.alloc)
	preview_follow(app)
	browser_tick(app)
	testing.expect(t, !browser_link_moved(l, moved), "it stays with the agent")
	testing.expect(t, !sync.atomic_load(&l.stop))
	testing.expect(t, app.conn.browser != l, "another takes what is shown")
	testing.expect_value(t, app.conn.browser.dir, "C:/b")
	testing.expect_value(t, len(app.conn.browsers_left), 1)

	// A message of that socket is still answered.
	browser_message(app, {l, 1}, `{"jsonrpc":"2.0","id":9,"method":"ping"}`)
	testing.expect(t, strings.contains(answers(l), `"id":9`))

	delete_key(&app.busy, "a")
	browser_tick(app)
	testing.expect(t, sync.atomic_load(&l.stop), "the agent done, it goes")
	testing.expect_value(t, len(app.conn.browsers_left), 0)
}
