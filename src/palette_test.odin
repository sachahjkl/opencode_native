package occ

import "core:strings"
import "core:testing"
import "gt:config"

// A switch of the palette shows the setting's title, as the settings say it, not its name ("permission.allow_all").
@(test)
a_palette_switch_shows_its_title :: proc(t: ^testing.T) {
	found := 0
	for d in PREF_DEFS {
		if d.name != "permission.allow_all" && d.name != "notify.permission" { continue }
		found += 1
		title := switch_title(d)
		testing.expectf(t, !strings.contains(title, ".") && !strings.contains(title, "_"), "a title, not the name: %q", title)
		testing.expectf(t, strings.contains(title, " › "), "its group, then its words: %q", title)
		testing.expectf(t, strings.has_suffix(title, config.title_of(d)), "the settings' words: %q", title)
	}
	testing.expect_value(t, found, 2)
}
