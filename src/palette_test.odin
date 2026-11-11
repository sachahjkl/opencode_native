package ocn

import "core:strings"
import "core:testing"
import "gt:config"
import "gt:ui"

// A switch of the palette shows the setting's title, as the settings say it, not its name ("appearance.system_title").
@(test)
a_palette_switch_shows_its_title :: proc(t: ^testing.T) {
	found := 0
	for d in PREF_DEFS {
		if d.name != "appearance.system_title" && d.name != "notify.permission" { continue }
		found += 1
		title := setting_title(d)
		testing.expectf(t, !strings.contains(title, ".") && !strings.contains(title, "_"), "a title, not the name: %q", title)
		testing.expectf(t, strings.contains(title, " › "), "its group, then its words: %q", title)
		testing.expectf(t, strings.has_suffix(title, config.title_of(d)), "the settings' words: %q", title)
	}
	testing.expect_value(t, found, 2)
}

// "animation" finds the animations' setting (a choice, not a switch: it was not listed).
@(test)
a_setting_that_is_no_switch_is_found :: proc(t: ^testing.T) {
	for d in PREF_DEFS {
		if d.name != "appearance.animations" { continue }
		testing.expect(t, !d.hidden && d.kind != .Bool, "a choice")
		_, _, ok := ui.fuzzy_words("animation", setting_title(d))
		testing.expectf(t, ok, "found by its title: %q", setting_title(d))
		return
	}
	testing.fail_now(t, "appearance.animations")
}

// The palette finds words, whole or as pieces that each begin a word, the whole first; letters scattered in a word find nothing
// ("prio" no longer found "Previous section").
@(test)
the_palette_finds_words_not_scattered_letters :: proc(t: ^testing.T) {
	app := new(App)
	defer free(app)
	items := []Pal_Item{
		{kind = .Command, id = "a", title = "Open a terminal in the session's folder"},
		{kind = .Command, id = "b", title = "Keyboard shortcuts"},
		{kind = .Command, id = "c", title = "Previous section"},
		{kind = .Command, id = "d", title = "Terminal"},
	}
	hits := palette_hits(app, items, "terminal")
	testing.expect_value(t, len(hits), 2)
	if len(hits) == 2 { testing.expect_value(t, items[hits[0].item].id, "d") }   // (at the start of its text)
	hits = palette_hits(app, items, "kesh")
	testing.expect_value(t, len(hits), 1)   // (keyboard shortcuts: pieces that begin its words)
	testing.expect_value(t, len(palette_hits(app, items, "pvsc")), 0)   // (scattered in its words: nothing)
}
