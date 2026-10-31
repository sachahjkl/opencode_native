package occ

import "core:os"
import "core:strings"
import "core:testing"

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
	testing.expect_value(t, card_meta(&v, true, 61000), "1m 00s · m1")
	v.state = .Failed
	testing.expect_value(t, card_meta(&v, false, 61000), "failed · 1m 00s · m1")
	v.state = .Done
	testing.expect_value(t, card_meta(&v, false, 61000), "1m 00s · m1")
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

when ODIN_OS == .Windows {
	@(test)
	a_failed_install_puts_the_copy_back :: proc(t: ^testing.T) {
		dir := pjoin({os.get_env("TEMP", context.temp_allocator), "oc_install_test"})
		_ = os.make_directory_all(dir)
		defer os.remove_all(dir)
		exe := pjoin({dir, "installed.exe"})
		testing.expect(t, os.write_entire_file(exe, "the installed copy") == nil)
		msg, ok := install_copy(pjoin({dir, "no such program.exe"}), exe)
		testing.expect(t, !ok, msg)
		data, err := os.read_entire_file(exe, context.temp_allocator)
		testing.expect(t, err == nil && string(data) == "the installed copy")
		good := pjoin({dir, "new.exe"})
		testing.expect(t, os.write_entire_file(good, "the new copy") == nil)
		_, ok = install_copy(good, exe)
		testing.expect(t, ok)
		data, err = os.read_entire_file(exe, context.temp_allocator)
		testing.expect(t, err == nil && string(data) == "the new copy")
	}
}
