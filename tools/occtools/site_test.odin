package occtools

import "core:encoding/json"
import "core:strings"
import "core:testing"
import tk_site "gt:site"

// (the steps themselves are tested in the toolkit: gt:site)

// The download links name the files of the last version: a download at once, not a page of GitHub.
@(test)
the_download_links_name_the_last_version :: proc(t: ^testing.T) {
	index, ok := tk_site.read_utf8("site/index.html")
	if !testing.expect(t, ok, "the home page") { return }
	testing.expect(t, strings.contains(index, "/releases/download/v" + VERSION_MARK + "/opencode-native-" + VERSION_MARK + "-windows-x64.exe"), "Windows: the release's file")
	testing.expect(t, strings.contains(index, "/releases/download/v" + VERSION_MARK + "/opencode-native-" + VERSION_MARK + "-linux-x64.tar.gz"), "Linux: the release's file")
}

@(test)
what_the_site_says_of_itself :: proc(t: ^testing.T) {
	m := site_meta()
	testing.expect(t, strings.has_suffix(m.url, "/"), "the addresses are made by following it")
	for text in ([]string{tk_site.structured_data(m), tk_site.web_manifest(m, "1x1")}) {
		value, err := json.parse(transmute([]byte)text, allocator = context.temp_allocator)
		testing.expect_value(t, err, json.Error.None)
		o, _ := value.(json.Object)
		testing.expect_value(t, o["name"].(json.String), "opencode native")
	}
	testing.expect(t, strings.contains(tk_site.structured_data(m), `"@type": "SoftwareApplication"`), "an application")
	testing.expect(t, strings.contains(tk_site.card_html(m, "x"), "<span>open</span>code <em>native</em>"), "the card's title")
}
