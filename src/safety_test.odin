package occ

import "core:testing"

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