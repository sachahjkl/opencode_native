// The site, made when it is deployed (.github/workflows/pages.yml) so that it cannot be behind a release:
//   occtools site build <site> <out>       the two steps below, <out> is what is published
//   occtools site changelog <site> <out>   <out> gets a copy of <site>, the history and the classic pages
//   occtools site meta <site> <out>        site_meta.odin: what a page says when it is shared, the files around the pages
//   occtools site card                     site_meta.odin: draws site/img/card.png, once, by hand
// The history comes from CHANGELOG.md: a page with every version (changelog.html) and the last ones on the home page, in place
// of <!-- whats-new -->. {{version}} in the home page is the last version: its download links name the files of that release, a
// download at once rather than a page of GitHub (the site is deployed when a release is: it cannot name a file not there yet). The classic presentation, classic/ (a line of plain links, a column of text with the news beside it,
// site/classic/classic.css), comes from the same sources: the home page's sections and the versions, their links moved into
// classic/. Each modern page's footer links its classic page ("Classic version"), each classic page the modern one ("Modern
// version"). CHANGELOG.md is Keep a Changelog: "## [x.y.z] - date", "### Added"..., "[x.y.z]: url" at the end.
//
// These pages were first made by JavaScript, and were compared with this byte for byte: the matchers here each say which regular
// expression they are, with what JS gives its "whitespace", ".", UTF-16 lengths and "$" in a replacement.
package occtools

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"

SITE_CHANGES      :: "CHANGELOG.md"
SITE_HOME         :: "index.html"
CHANGELOG_PAGE    :: "changelog.html"
FEATURES_PAGE     :: "features.html"       // the home's section that is a page of its own in classic/
SCREENSHOTS_PAGE  :: "screenshots.html"
FEATURES_ID       :: "features"
CLASSIC           :: "classic"             // the classic pages' folder in the site
CLASSIC_LINK      :: `<a href="classic/">Classic version</a>`   // in the home page's footer
WHATS_NEW         :: "<!-- whats-new -->"
VERSION_MARK      :: "{{version}}"   // in the home page: the last version
VERSIONS_OPEN     :: 6                     // versions unfolded on the page
NEWS_VERSIONS     :: 3                     // versions on the home page
NEWS_LEADS        :: 3                     // entries of each there
LEAD_LONGEST      :: 110                   // in UTF-16 units, as a JS string counts
LEAD_CUT          :: 107
SUB_ITEM_INDENT   :: 2

run_site :: proc(args: []string) -> int {
	what := len(args) > 0 ? args[0] : ""
	switch what {
	case "build", "changelog", "meta":
		if len(args) != 3 { break }
		site, out := args[1], args[2]
		if what == "changelog" { return site_changelog(site, out) }
		if what == "meta" { return site_meta(site, out) }
		if code := site_changelog(site, out); code != 0 { return code }
		return site_meta(out, out)
	case "card":
		if len(args) == 1 { return site_card() }
	case "check":
		return run_site_check(args[1:])
	}
	fmt.eprintln("site build|changelog|meta <site> <out> | card | check [--site folder] [--shot file.png] [--browser program]")
	return EXIT_USAGE
}

// The text of a file, which must be UTF-8: JS would have turned the rest into U+FFFD without a word.
read_utf8 :: proc(path: string) -> (text: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err); return "", false }
	if !utf8.valid_string(string(data)) { fmt.eprintfln("site: %s is not UTF-8", path); return "", false }
	return string(data), true
}

write_text :: proc(path, text: string) -> bool {
	err := os.write_entire_file(path, text)
	if err != nil { fmt.eprintfln("site: %s: %v", path, err) }
	return err == nil
}

// <out> gets what <site> has; what it had besides stays.
copy_site :: proc(site, out: string) -> bool {
	// (first: on Linux a folder that does not exist has no absolute path)
	if err := os.make_directory_all(out); err != nil && err != .Exist { fmt.eprintfln("site: %s: %v", out, err); return false }
	from, from_err := os.get_absolute_path(site, context.temp_allocator)
	to, to_err := os.get_absolute_path(out, context.temp_allocator)
	if from_err != nil || to_err != nil { fmt.eprintfln("site: no path for %s or %s", site, out); return false }
	if from == to || strings.has_prefix(to, cat(from, "/")) || strings.has_prefix(to, cat(from, "\\")) {
		fmt.eprintfln("site: cannot copy %s into itself", site)
		return false
	}
	if err := os.copy_directory_all(out, site); err != nil { fmt.eprintfln("site: copy to %s: %v", out, err); return false }
	return true
}

cat :: proc(parts: ..string) -> string { return strings.concatenate(parts, context.temp_allocator) }

put :: proc(b: ^strings.Builder, parts: ..string) {
	for p in parts { strings.write_string(b, p) }
}

esc :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		switch s[i] {
		case '&': strings.write_string(&b, "&amp;")
		case '<': strings.write_string(&b, "&lt;")
		case '>': strings.write_string(&b, "&gt;")
		case '"': strings.write_string(&b, "&quot;")
		case:     strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

// \s in JS, and what its trim() removes.
is_js_space :: proc(r: rune) -> bool {
	switch r {
	case '\t', '\n', 0x0B, 0x0C, '\r', ' ', 0xA0, 0x1680, 0x2000 ..= 0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000, 0xFEFF:
		return true
	}
	return false
}

js_trim :: proc(s: string) -> string { return strings.trim_right_proc(strings.trim_left_proc(s, is_js_space), is_js_space) }

// What "." does not match.
has_line_end :: proc(s: string) -> bool {
	return strings.contains_any(s, "\r\n") || strings.contains(s, "\u2028") || strings.contains(s, "\u2029")
}

is_word_byte :: proc(c: byte) -> bool {
	return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// toLowerCase(), but for one thing: a Greek sigma ending a word stays σ, where JS says ς. Headings and menu labels have none.
js_lower :: proc(s: string) -> string {
	dotted, _ := strings.replace_all(s, "\u0130", "i\u0307", context.temp_allocator)   // (the one letter that gets longer)
	return strings.to_lower(dotted, context.temp_allocator)
}

// How long a JS string says this is.
utf16_length :: proc(s: string) -> int {
	n := 0
	for r in s { n += r >= 0x10000 ? 2 : 1 }
	return n
}

// slice(0, n). Half of a pair is what JS keeps, and a file cannot hold it: U+FFFD is what it writes.
utf16_prefix :: proc(s: string, n: int) -> string {
	units := 0
	for r, i in s {
		width := r >= 0x10000 ? 2 : 1
		if units + width > n { return units < n ? cat(s[:i], "\ufffd") : s[:i] }
		units += width
	}
	return s
}

// /\r?\n/ as split(): a lone \r is not a line's end.
split_lines :: proc(text: string) -> []string {
	lines := strings.split(text, "\n", context.temp_allocator)
	for i in 0 ..< len(lines) - 1 { lines[i] = strings.trim_suffix(lines[i], "\r") }
	return lines
}

// The replacement text of String.replace, when it is not a function: a changelog entry saying "$&" gets what JS gives it.
// (No expression here has a group in those cases: "$1" stays as it is.)
expand_replacement :: proc(with, s: string, start, end: int) -> string {
	if strings.index_byte(with, '$') < 0 { return with }
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(with); i += 1 {
		if with[i] == '$' && i + 1 < len(with) {
			switch with[i + 1] {
			case '$':  strings.write_byte(&b, '$'); i += 1; continue
			case '&':  strings.write_string(&b, s[start:end]); i += 1; continue
			case '`':  strings.write_string(&b, s[:start]); i += 1; continue
			case '\'': strings.write_string(&b, s[end:]); i += 1; continue
			}
		}
		strings.write_byte(&b, with[i])
	}
	return strings.to_string(b)
}

replace_span :: proc(s, with: string, start, end: int) -> string {
	return cat(s[:start], expand_replacement(with, s, start, end), s[end:])
}

// s.replace("what", with).
replace_text :: proc(s, what, with: string) -> string {
	at := strings.index(s, what)
	return at < 0 ? s : replace_span(s, with, at, at + len(what))
}

// /open[\s\S]*?close/, what it matched. "": nothing, as take() said.
between :: proc(s, open, close: string) -> string {
	start := strings.index(s, open)
	if start < 0 { return "" }
	body := start + len(open)
	end := strings.index(s[body:], close)
	return end < 0 ? "" : s[start:body + end + len(close)]
}

// /<title>[^<]*<\/title>/
title_span :: proc(s: string) -> (start, end: int, ok: bool) {
	OPEN :: "<title>"
	CLOSE :: "</title>"
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return }
		start = from + at
		body := start + len(OPEN)
		stop := strings.index_byte(s[body:], '<')
		if stop >= 0 && strings.has_prefix(s[body + stop:], CLOSE) { return start, body + stop + len(CLOSE), true }
		from = body
	}
}

// /open[^>]*>/
tag_span :: proc(s, open: string) -> (start, end: int, ok: bool) {
	start = strings.index(s, open)
	if start < 0 { return }
	stop := strings.index_byte(s[start + len(open):], '>')
	if stop < 0 { return }
	return start, start + len(open) + stop + 1, true
}

// /prefix([^"]*)"after/: the value.
quoted_value :: proc(s, prefix, after: string) -> (value: string, ok: bool) {
	from := 0
	for {
		at := strings.index(s[from:], prefix)
		if at < 0 { return "", false }
		body := from + at + len(prefix)
		stop := strings.index_byte(s[body:], '"')
		if stop < 0 { return "", false }
		if strings.has_prefix(s[body + stop + 1:], after) { return s[body:body + stop], true }
		from = body
	}
}

// /<section id="\w+" class="download">[\s\S]*?<\/section>/
download_section :: proc(s: string) -> string {
	OPEN :: `<section id="`
	CLASS :: `" class="download">`
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return "" }
		start := from + at
		word := start + len(OPEN)
		end := word
		for end < len(s) && is_word_byte(s[end]) { end += 1 }
		if end > word && strings.has_prefix(s[end:], CLASS) {
			stop := strings.index(s[end:], "</section>")
			return stop < 0 ? "" : s[start:end + stop + len("</section>")]
		}
		from = word
	}
}

// /<script src="[^"]*"[^>]*><\/script>/
script_with_src :: proc(s: string) -> string {
	OPEN :: `<script src="`
	CLOSE :: "</script>"
	from := 0
	for {
		at := strings.index(s[from:], OPEN)
		if at < 0 { return "" }
		start := from + at
		body := start + len(OPEN)
		quote := strings.index_byte(s[body:], '"')
		if quote < 0 { return "" }
		stop := strings.index_byte(s[body + quote:], '>')
		if stop < 0 { return "" }
		end := body + quote + stop + 1
		if strings.has_prefix(s[end:], CLOSE) { return s[start:end + len(CLOSE)] }
		from = body
	}
}

// The tag around a piece of HTML taken away, and the blanks around that.
inner :: proc(html: string) -> string {
	s := js_trim(html)
	if strings.has_prefix(s, "<") {
		if end := strings.index_byte(s, '>'); end >= 0 { s = s[end + 1:] }
	}
	if strings.has_suffix(s, ">") {
		last := len(s) - 1
		from := strings.last_index_byte(s[:last], '>') + 1
		if close := strings.index(s[from:last], "</"); close >= 0 { s = s[:from + close] }
	}
	return js_trim(s)
}

// The words of a piece of HTML.
plain_text :: proc(html: string) -> string {
	tags := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(html); {
		if html[i] == '<' {
			if end := strings.index_byte(html[i + 1:], '>'); end > 0 { i += end + 2; continue }
		}
		strings.write_byte(&tags, html[i])
		i += 1
	}
	b := strings.builder_make(context.temp_allocator)
	blank := false
	for r in strings.to_string(tags) {
		if is_js_space(r) {
			if !blank { strings.write_byte(&b, ' ') }
		} else {
			strings.write_rune(&b, r)
		}
		blank = is_js_space(r)
	}
	return js_trim(strings.to_string(b))
}

slug :: proc(s: string) -> string {
	lower := js_lower(s)
	b := strings.builder_make(context.temp_allocator)
	gap := false
	for i in 0 ..< len(lower) {
		c := lower[i]
		if (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') {
			if gap && strings.builder_len(b) > 0 { strings.write_byte(&b, '-') }
			strings.write_byte(&b, c)
			gap = false
		} else {
			gap = true
		}
	}
	return strings.to_string(b)
}

// split(/(?<=[.:;])\s/)[0]
first_sentence :: proc(text: string) -> string {
	for r, i in text {
		if i > 0 && is_js_space(r) && strings.index_byte(".:;", text[i - 1]) >= 0 { return text[:i] }
	}
	return text
}

// /\*\*(.+?)\*\*/ at `at`.
match_bold :: proc(s: string, at: int) -> (bold: string, end: int, ok: bool) {
	if !strings.has_prefix(s[at:], "**") || at + len("**") >= len(s) { return }
	body := at + len("**")
	close := strings.index(s[body + 1:], "**")
	if close < 0 { return }
	stop := body + 1 + close
	if has_line_end(s[body:stop]) { return }
	return s[body:stop], stop + len("**"), true
}

// /^\[([^\]]+)\]/: the text in brackets, and what follows.
bracket :: proc(s: string) -> (name, rest: string, ok: bool) {
	if !strings.has_prefix(s, "[") { return }
	close := strings.index_byte(s[1:], ']')
	if close <= 0 { return }
	return s[1:1 + close], s[close + 2:], true
}

// /\[([^\]]+)\]\((https?:[^)\s]+)\)/ at `at`.
match_link :: proc(s: string, at: int) -> (label, url: string, end: int, ok: bool) {
	name, rest, found := bracket(s[at:])
	if !found || !strings.has_prefix(rest, "(") { return }
	address := rest[1:]
	scheme := 0
	if strings.has_prefix(address, "http:") {
		scheme = len("http:")
	} else if strings.has_prefix(address, "https:") {
		scheme = len("https:")
	} else {
		return
	}
	for r, i in address[scheme:] {
		if r == ')' {
			if i == 0 { return }
			url = address[:scheme + i]
			return name, url, len(s) - len(address) + scheme + i + 1, true
		}
		if is_js_space(r) { return }
	}
	return
}

CODE_OPEN  :: 0x01
CODE_CLOSE :: 0x02

// **bold**, `code`, [text](url). Code first: what is in it is not markup.
inline :: proc(text: string) -> string {
	code := make([dynamic]string, context.temp_allocator)
	marked := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(text); {
		if text[i] == '`' {
			close := strings.index_byte(text[i + 1:], '`')
			if close > 0 {
				append(&code, cat("<code>", esc(text[i + 1:i + 1 + close]), "</code>"))
				fmt.sbprintf(&marked, "%c%d%c", CODE_OPEN, len(code) - 1, CODE_CLOSE)
				i += close + 2
				continue
			}
		}
		strings.write_byte(&marked, text[i])
		i += 1
	}
	s := esc(strings.to_string(marked))

	bold := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if strong, end, ok := match_bold(s, i); ok {
			put(&bold, "<strong>", strong, "</strong>")
			i = end
		} else {
			strings.write_byte(&bold, s[i])
			i += 1
		}
	}
	s = strings.to_string(bold)

	links := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if label, url, end, ok := match_link(s, i); ok {
			put(&links, `<a href="`, url, `">`, label, "</a>")
			i = end
		} else {
			strings.write_byte(&links, s[i])
			i += 1
		}
	}
	s = strings.to_string(links)

	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if s[i] == CODE_OPEN {
			digits := i + 1
			n := 0
			for digits < len(s) && s[digits] >= '0' && s[digits] <= '9' {
				n = min(n * 10 + int(s[digits] - '0'), len(code))   // (past the end is all that counts)
				digits += 1
			}
			if digits > i + 1 && digits < len(s) && s[digits] == CODE_CLOSE {
				// (a mark that was in the text itself, with no code behind it: what JS prints for it)
				strings.write_string(&b, n < len(code) ? code[n] : "undefined")
				i = digits + 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

Item :: struct {
	text:   string,
	subs:   [dynamic]string,
	in_sub: bool,   // the last line went to a sub-item
}

Block :: struct {
	text:    string,          // a paragraph
	items:   [dynamic]^Item,  // a list
	is_list: bool,
}

// /^(\s*)- (.*)$/: the indentation counts characters, as a JS string does.
list_line :: proc(l: string) -> (indent: int, text: string, ok: bool) {
	start := len(l)
	for r, i in l {
		if !is_js_space(r) { start = i; break }
		indent += 1
	}
	rest := l[start:]
	if !strings.has_prefix(rest, "- ") || has_line_end(rest) { return 0, "", false }
	return indent, rest[len("- "):], true
}

// /^### (.+)$/
section_line :: proc(l: string) -> (name: string, ok: bool) {
	if !strings.has_prefix(l, "### ") { return }
	name = l[len("### "):]
	return name, name != "" && !has_line_end(name)
}

// A version's text as blocks: paragraphs and lists (an entry may span lines; indented "- " are its sub-items).
blocks :: proc(lines: []string) -> []^Block {
	out := make([dynamic]^Block, context.temp_allocator)
	list, para: ^Block
	item: ^Item
	for raw in lines {
		l := strings.trim_right_proc(raw, is_js_space)
		if js_trim(l) == "" {
			list, para, item = nil, nil, nil
			continue
		}
		if indent, text, ok := list_line(l); ok {
			if list == nil {
				list = new(Block, context.temp_allocator)
				list.is_list = true
				list.items = make([dynamic]^Item, context.temp_allocator)
				append(&out, list)
			}
			para = nil
			if indent >= SUB_ITEM_INDENT && item != nil {
				append(&item.subs, text)
				item.in_sub = true
			} else {
				item = new(Item, context.temp_allocator)
				item.text = text
				item.subs = make([dynamic]string, context.temp_allocator)
				append(&list.items, item)
			}
		} else if item != nil {
			if item.in_sub {
				last := &item.subs[len(item.subs) - 1]
				last^ = cat(last^, " ", js_trim(l))
			} else {
				item.text = cat(item.text, " ", js_trim(l))
			}
		} else if para != nil {
			para.text = cat(para.text, " ", js_trim(l))
		} else {
			para = new(Block, context.temp_allocator)
			para.text = js_trim(l)
			append(&out, para)
		}
	}
	return out[:]
}

Section :: struct {
	name:  string,
	lines: [dynamic]string,
}

Release :: struct {
	version, date, link: string,
	intro:               [dynamic]string,
	sections:            [dynamic]^Section,
}

// /^## \[([^\]]+)\]/: the version, and what follows it on the line.
version_heading :: proc(l: string) -> (version, rest: string, ok: bool) {
	if !strings.has_prefix(l, "## ") { return }
	return bracket(l[len("## "):])
}

// What starts a text and is not a blank: \S+.
first_word :: proc(s: string) -> string {
	for r, i in s {
		if is_js_space(r) { return s[:i] }
	}
	return s
}

parse_changelog :: proc(text: string) -> []^Release {
	lines := split_lines(text)
	links := make(map[string]string, context.temp_allocator)
	for l in lines {
		name, rest, ok := bracket(l)
		if !ok || !strings.has_prefix(rest, ":") { continue }
		url := first_word(strings.trim_left_proc(rest[1:], is_js_space))
		if url != "" { links[name] = url }
	}
	releases := make([dynamic]^Release, context.temp_allocator)
	r: ^Release
	sec: ^Section
	for l in lines {
		if version, rest, ok := version_heading(l); ok {
			r, sec = nil, nil
			if js_lower(version) != "unreleased" {
				r = new(Release, context.temp_allocator)
				r.version = version
				if strings.has_prefix(rest, " - ") { r.date = first_word(rest[len(" - "):]) }
				r.link = links[version]
				r.intro = make([dynamic]string, context.temp_allocator)
				r.sections = make([dynamic]^Section, context.temp_allocator)
				append(&releases, r)
			}
			continue
		}
		if strings.has_prefix(l, "## ") { r = nil; continue }
		if r == nil { continue }
		if _, rest, ok := bracket(l); ok && strings.has_prefix(rest, ":") { continue }
		if name, ok := section_line(l); ok {
			sec = new(Section, context.temp_allocator)
			sec.name = js_trim(name)
			sec.lines = make([dynamic]string, context.temp_allocator)
			append(&r.sections, sec)
			continue
		}
		append(sec != nil ? &sec.lines : &r.intro, l)
	}
	return releases[:]
}

render_blocks :: proc(bs: []^Block) -> string {
	b := strings.builder_make(context.temp_allocator)
	for block, i in bs {
		if i > 0 { strings.write_byte(&b, '\n') }
		if !block.is_list {
			put(&b, "<p>", inline(block.text), "</p>")
			continue
		}
		strings.write_string(&b, "<ul>")
		for item in block.items {
			put(&b, "<li>", inline(item.text))
			if len(item.subs) > 0 {
				strings.write_string(&b, "<ul>")
				for sub in item.subs { put(&b, "<li>", inline(sub), "</li>") }
				strings.write_string(&b, "</ul>")
			}
			strings.write_string(&b, "</li>")
		}
		strings.write_string(&b, "</ul>")
	}
	return strings.to_string(b)
}

entries :: proc(r: ^Release) -> []^Item {
	out := make([dynamic]^Item, context.temp_allocator)
	for s in r.sections {
		for block in blocks(s.lines[:]) {
			if block.is_list { append(&out, ..block.items[:]) }
		}
	}
	return out[:]
}

// What an entry is about: its bold start, else its first sentence.
lead :: proc(text: string) -> string {
	if bold, _, ok := match_bold(text, 0); ok { return cat("<strong>", inline(bold), "</strong>") }
	first := first_sentence(text)
	if utf16_length(first) <= LEAD_LONGEST { return inline(first) }
	cut, _ := strings.replace_all(utf16_prefix(first, LEAD_CUT), "`", "", context.temp_allocator)
	cut, _ = strings.replace_all(cut, "*", "", context.temp_allocator)
	return inline(cat(cut, "…"))
}

leads :: proc(all: []^Item) -> string {
	b := strings.builder_make(context.temp_allocator)
	for e in all[:min(NEWS_LEADS, len(all))] { put(&b, "<li>", lead(e.text), "</li>") }
	return strings.to_string(b)
}

release_html :: proc(r: ^Release, open: bool) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<details class="release" id="v`, esc(r.version), `"`, open ? " open" : "", ">\n")
	put(&b, `<summary><span class="ver">`, esc(r.version), `</span><span class="date">`, esc(r.date), "</span>")
	if r.link != "" { put(&b, `<a class="rel" href="`, esc(r.link), `">release</a>`) }
	put(&b, "</summary>\n", render_blocks(blocks(r.intro[:])), "\n")
	for s, i in r.sections {
		if i > 0 { strings.write_byte(&b, '\n') }
		put(&b, `<h3 class="`, esc(js_lower(s.name)), `">`, esc(s.name), "</h3>\n", render_blocks(blocks(s.lines[:])))
	}
	put(&b, "\n</details>")
	return strings.to_string(b)
}

news_html :: proc(rs: []^Release) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<section id="news" class="news">
<h2>What's new</h2>
<div class="grid">
`)
	for r, i in rs {
		if i > 0 { strings.write_byte(&b, '\n') }
		all := entries(r)
		anchor := cat(`<a href="changelog.html#v`, esc(r.version), `">`)
		put(&b, `<article class="card"><h3>`, anchor, esc(r.version), `</a> <span class="date">`, esc(r.date), "</span></h3>\n<ul>", leads(all), "</ul>")
		if more := len(all) - NEWS_LEADS; more > 0 { put(&b, `<p class="small">`, anchor, "and ", fmt.tprint(more), " more</a></p>") }
		strings.write_string(&b, "</article>")
	}
	put(&b, `
</div>
<p class="all"><a class="btn" href="changelog.html">All versions</a></p>
</section>`)
	return strings.to_string(b)
}

FILTER :: `<script>
  // unfolds what a link points at; the filter keeps the versions whose text has all the words
  const open = () => { const t = location.hash && document.getElementById(location.hash.slice(1)); if (t && t.tagName === 'DETAILS') { t.open = true; t.scrollIntoView() } };
  addEventListener('hashchange', open); open();
  const all = [...document.querySelectorAll('.release')], box = document.getElementById('filter'), count = document.getElementById('count');
  const was = new Map(all.map((d) => [d, d.open]));
  box.addEventListener('input', () => {
    const words = box.value.toLowerCase().split(/\s+/).filter(Boolean);
    let n = 0;
    for (const d of all) {
      const hit = words.every((w) => d.textContent.toLowerCase().includes(w));
      d.hidden = !hit;
      if (hit) n++;
      d.open = words.length ? hit : was.get(d);
    }
    count.textContent = words.length ? n + ' of ' + all.length + ' versions' : all.length + ' versions';
  });
</script>`

// A link of the home page, moved into classic/: a page keeps its name (its classic one), a section of the home is its classic
// page or the classic home's, a file stays the site's ("img/x.png" -> "../img/x.png").
classic_link :: proc(href: string) -> string {
	scheme := 0
	for scheme < len(href) && ((href[scheme] >= 'a' && href[scheme] <= 'z') || (href[scheme] >= 'A' && href[scheme] <= 'Z')) { scheme += 1 }
	if scheme > 0 && scheme < len(href) && href[scheme] == ':' { return href }
	parts := strings.split(href, "#", context.temp_allocator)
	path := parts[0]
	id := len(parts) > 1 ? parts[1] : ""
	if path == "" {
		if id == "" { return SITE_HOME }
		return id == FEATURES_ID ? FEATURES_PAGE : cat(SITE_HOME, "#", id)
	}
	return path == SITE_HOME || path == CHANGELOG_PAGE ? href : cat("../", href)
}

// Every /\b(href|src)="([^"]*)"/ of a piece of HTML, moved into classic/.
classic_html :: proc(html: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(html); {
		attribute := ""
		if strings.has_prefix(html[i:], `href="`) { attribute = "href" } else if strings.has_prefix(html[i:], `src="`) { attribute = "src" }
		if attribute != "" && (i == 0 || !is_word_byte(html[i - 1])) {
			body := i + len(attribute) + len(`="`)
			if close := strings.index_byte(html[body:], '"'); close >= 0 {
				put(&b, attribute, `="`, classic_link(html[body:body + close]), `"`)
				i = body + close + 1
				continue
			}
		}
		strings.write_byte(&b, html[i])
		i += 1
	}
	return strings.to_string(b)
}

// The bar's links, from another page than the home.
bar_for_page :: proc(bar: string) -> string {
	s, _ := strings.replace_all(bar, `href="#"`, `href="index.html"`, context.temp_allocator)
	OPEN :: `href="#`
	b := strings.builder_make(context.temp_allocator)
	for i := 0; i < len(s); {
		if strings.has_prefix(s[i:], OPEN) {
			word := i + len(OPEN)
			end := word
			for end < len(s) && is_word_byte(s[end]) { end += 1 }
			if end > word && end < len(s) && s[end] == '"' {
				put(&b, `href="index.html#`, s[word:end], `"`)
				i = end + 1
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

Card :: struct {
	title, body, id, summary: string,
}

// /<article class="card">\s*<h3>([\s\S]*?)<\/h3>([\s\S]*?)<\/article>/g
feature_cards :: proc(section: string) -> []Card {
	OPEN :: `<article class="card">`
	out := make([dynamic]Card, context.temp_allocator)
	from := 0
	for {
		at := strings.index(section[from:], OPEN)
		if at < 0 { break }
		from += at + len(OPEN)
		h := strings.trim_left_proc(section[from:], is_js_space)
		if !strings.has_prefix(h, "<h3>") { continue }
		h = h[len("<h3>"):]
		title_end := strings.index(h, "</h3>")
		if title_end < 0 { break }
		rest := h[title_end + len("</h3>"):]
		body_end := strings.index(rest, "</article>")
		if body_end < 0 { break }
		title, body := h[:title_end], rest[:body_end]
		summary := first_sentence(plain_text(body))
		if summary != "" && strings.index_byte(".;:", summary[len(summary) - 1]) >= 0 { summary = summary[:len(summary) - 1] }
		append(&out, Card{title = title, body = js_trim(body), id = slug(plain_text(title)), summary = summary})
		from = len(section) - len(rest) + body_end + len("</article>")
	}
	return out[:]
}

Link :: struct {
	href, label: string,
}

// /<a href="([^"]*)">([^<]*)<\/a>/g
nav_links :: proc(nav: string) -> []Link {
	OPEN :: `<a href="`
	out := make([dynamic]Link, context.temp_allocator)
	from := 0
	for {
		at := strings.index(nav[from:], OPEN)
		if at < 0 { break }
		body := from + at + len(OPEN)
		from = body
		quote := strings.index_byte(nav[body:], '"')
		if quote < 0 { break }
		text := body + quote + 1
		if !strings.has_prefix(nav[text:], ">") { continue }
		text += 1
		stop := strings.index_byte(nav[text:], '<')
		if stop < 0 { break }
		if !strings.has_prefix(nav[text + stop:], "</a>") { continue }
		append(&out, Link{nav[body:body + quote], nav[text:text + stop]})
		from = text + stop + len("</a>")
	}
	return out[:]
}

// /<a [^>]*?href="([^"]*)"[^>]*>([\s\S]*?)<\/a>/g
action_links :: proc(html: string) -> []Link {
	OPEN :: "<a "
	HREF :: `href="`
	out := make([dynamic]Link, context.temp_allocator)
	from := 0
	next: for {
		at := strings.index(html[from:], OPEN)
		if at < 0 { break }
		start := from + at + len(OPEN)
		from = start
		tag_end := strings.index_byte(html[start:], '>')
		if tag_end < 0 { tag_end = len(html) - start }
		// (the first href that the rest of the expression can follow: a lazy match stops at the first that works)
		for p := start; p <= start + tag_end; p += 1 {
			if !strings.has_prefix(html[p:], HREF) { continue }
			body := p + len(HREF)
			quote := strings.index_byte(html[body:], '"')
			if quote < 0 { continue }
			close := strings.index_byte(html[body + quote:], '>')
			if close < 0 { continue }
			label := body + quote + close + 1
			stop := strings.index(html[label:], "</a>")
			if stop < 0 { continue }
			append(&out, Link{html[body:body + quote], html[label:label + stop]})
			from = label + stop + len("</a>")
			continue next
		}
	}
	return out[:]
}

// The text of a link's content: its markup gone (a button's logo, the spans of its lines), a space where a tag was, one space
// between words. A download button says what it does (its get-main): the files are the download section's, as plain links.
plain_label :: proc(label: string) -> string {
	html := label
	MAIN :: `class="get-main"`
	if at := strings.index(html, MAIN); at >= 0 {
		open := strings.index_byte(html[at:], '>')
		close := open < 0 ? -1 : strings.index(html[at + open:], "</span>")
		if close >= 0 { html = html[at + open + 1:at + open + close] }
	}
	b := strings.builder_make(context.temp_allocator)
	space := false
	for i := 0; i < len(html); i += 1 {
		c := html[i]
		if c == '<' {
			if close := strings.index_byte(html[i:], '>'); close >= 0 { i += close; space = true; continue }
		}
		if c == ' ' || c == '\n' || c == '\t' || c == '\r' { space = true; continue }
		if space && strings.builder_len(b) > 0 { strings.write_byte(&b, ' ') }
		space = false
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

Classic_Frame :: struct {
	icon, logo, title, tagline: string,
	nav:                        []Link,
	foot_before, foot_after:    string,
}

Classic_Page :: struct {
	file, title, description, modern, main, scripts: string,
}

classic_page :: proc(frame: Classic_Frame, p: Classic_Page) -> string {
	b := strings.builder_make(context.temp_allocator)
	put(&b, `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>`, p.title, `</title>
<meta name="description" content="`, p.description, `">
`, classic_html(frame.icon), `
<link rel="stylesheet" href="classic.css">
</head>
<body>
<a class="skip" href="#main">Skip to content</a>
<div class="page">
<header class="masthead">
<img src="`, classic_link(frame.logo), `" alt="" width="48" height="48">
<a class="name" href="index.html">`, frame.title, `</a>
<span class="tagline">`, frame.tagline, `</span>
</header>
<nav class="site" aria-label="Site">
`)
	for link, i in frame.nav {
		if i > 0 { strings.write_string(&b, "\n<span class=\"sep\" aria-hidden=\"true\">-</span>") }
		put(&b, `<a href="`, link.href, `"`, link.href == p.file ? ` aria-current="page"` : "", ">", link.label, "</a>")
	}
	put(&b, `
</nav>
`, p.main, `
<footer class="foot">
`, classic_html(frame.foot_before), `<a href="`, p.modern, `">Modern version</a>`, classic_html(frame.foot_after), `
</footer>
</div>
`, p.scripts, `</body>
</html>
`)
	return strings.to_string(b)
}

news_item :: proc(r: ^Release, name: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "<div class=\"item\">\n")
	if r.date != "" { put(&b, `<time class="date" datetime="`, esc(r.date), `">`, esc(r.date), "</time>: ") }
	put(&b, `<a href="changelog.html#v`, esc(r.version), `">`, esc(name), " ", esc(r.version), "</a> released.\n<ul>", leads(entries(r)), "</ul>\n</div>")
	return strings.to_string(b)
}

Page :: struct {
	path, text: string,   // the path is the site's
}

// Every page this step makes, from the home page and the versions. why: what the home page lacks.
make_pages :: proc(index: string, releases: []^Release) -> (pages: []Page, why: string) {
	if !strings.contains(index, WHATS_NEW) { return nil, cat("no ", WHATS_NEW) }
	shown := releases[:min(NEWS_VERSIONS, len(releases))]
	out := make([dynamic]Page, context.temp_allocator)
	append(&out, Page{SITE_HOME, replace_text(index, WHATS_NEW, news_html(shown))})

	title_at, title_end, has_title := title_span(index)
	name := has_title ? inner(index[title_at:title_end]) : ""
	footer := between(index, "<footer>", "</footer>")
	if !strings.contains(footer, CLASSIC_LINK) { return nil, cat("no ", CLASSIC_LINK, " in the footer") }

	versions := strings.builder_make(context.temp_allocator)
	put(&versions, `<p class="lead">Every version of `, esc(name), ", newest first. The format is ", `<a href="https://keepachangelog.com/en/1.1.0/">Keep a Changelog</a>, the versions follow <a href="https://semver.org">semantic versioning</a>.</p>
<div class="filter"><input id="filter" type="search" placeholder="Filter by a word or a version" aria-label="Filter the versions by a word"><span id="count" class="small">`, fmt.tprint(len(releases)), " versions</span></div>\n")
	for r, i in releases {
		if i > 0 { strings.write_byte(&versions, '\n') }
		strings.write_string(&versions, release_html(r, i < VERSIONS_OPEN))
	}
	changelog_intro := strings.to_string(versions)

	// the page wears the home page's head, bar, footer and script
	head := between(index, "<head>", "</head>")
	if at, end, ok := title_span(head); ok { head = replace_span(head, cat("<title>Changelog · ", name, "</title>"), at, end) }
	if at, end, ok := tag_span(head, `<meta name="description"`); ok {
		head = replace_span(head, cat(`<meta name="description" content="Every version of `, esc(name), `, newest first.">`), at, end)
	}
	bar := bar_for_page(between(index, `<header class="bar">`, "</header>"))
	script := between(index, "<script>", "</script>")
	modern_foot := replace_text(footer, CLASSIC_LINK, cat(`<a href="`, CLASSIC, `/changelog.html">Classic version</a>`))
	append(&out, Page{CHANGELOG_PAGE, cat(`<!doctype html>
<html lang="en">
`, head, `
<body>
`, bar, `

<main class="changelog">
<h1>Changelog</h1>
`, changelog_intro, `
</main>

`, modern_foot, `
`, script, `
`, FILTER, `
</body>
</html>
`)})

	hero := between(index, `<section class="hero">`, "</section>")
	title := inner(between(hero, "<h1>", "</h1>"))
	logo, _ := quoted_value(hero, `<img class="mark" src="`, "")
	description, _ := quoted_value(index, `<meta name="description" content="`, ">")
	wide := between(index, `<figure class="shot wide">`, "</figure>")
	gallery := between(index, `<section class="gallery">`, "</section>")
	download := download_section(index)
	cards := feature_cards(between(index, `<section id="features"`, "</section>"))
	parts := [?]struct {what, part: string}{{"hero", hero}, {"title", title}, {"logo", logo}, {"wide", wide}, {"gallery", gallery}, {"download", download}}
	for p in parts {
		if p.part == "" { return nil, cat("no ", p.what, " for the classic pages") }
	}
	if len(cards) == 0 { return nil, "no features for the classic pages" }

	// the nav line: the home, the modern bar's links, the screenshots after the features
	nav := make([dynamic]Link, context.temp_allocator)
	append(&nav, Link{SITE_HOME, "home"})
	for link in nav_links(between(index, `<nav id="nav">`, "</nav>")) { append(&nav, Link{classic_link(link.href), js_lower(link.label)}) }
	after := len(nav)
	for link, i in nav {
		if link.href == FEATURES_PAGE { after = i + 1; break }
	}
	inject_at(&nav, after, Link{SCREENSHOTS_PAGE, "screenshots"})

	icon := ""
	if at, end, ok := tag_span(index, `<link rel="icon"`); ok { icon = index[at:end] }
	foot := strings.split(inner(footer), CLASSIC_LINK, context.temp_allocator)
	frame := Classic_Frame{icon = icon, logo = logo, title = title, tagline = description, nav = nav[:], foot_before = foot[0], foot_after = foot[1]}

	home_main := strings.builder_make(context.temp_allocator)
	put(&home_main, `<div class="columns">
<main id="main">
<h1>Welcome to `, title, `</h1>
<p>`, classic_html(inner(between(hero, `<p class="lead">`, "</p>"))), `</p>
<p class="download">`)
	for link, i in action_links(between(hero, `<div class="actions">`, "</div>")) {
		if i > 0 { strings.write_string(&home_main, " - ") }
		put(&home_main, `<a href="`, classic_link(link.href), `">`, plain_label(link.label), "</a>")
	}
	put(&home_main, `
<br><span class="small">`, inner(between(hero, `<p class="small">`, "</p>")), `</span></p>
<h2>Features</h2>
<ul class="features">
`)
	for c, i in cards {
		if i > 0 { strings.write_byte(&home_main, '\n') }
		put(&home_main, `<li><a href="`, FEATURES_PAGE, "#", c.id, `">`, c.title, "</a>: ", c.summary, "</li>")
	}
	put(&home_main, `
</ul>
`, classic_html(download), `
</main>
<aside aria-labelledby="news">
<h2 id="news">News</h2>
`)
	for r, i in shown {
		if i > 0 { strings.write_byte(&home_main, '\n') }
		strings.write_string(&home_main, news_item(r, name))
	}
	put(&home_main, `
<p><a class="all" href="changelog.html">- all news -</a></p>
</aside>
</div>`)
	append(&out, Page{cat(CLASSIC, "/", SITE_HOME), classic_page(frame, {
		file = SITE_HOME, title = name, description = description, modern = "../", main = strings.to_string(home_main),
	})})

	features_main := strings.builder_make(context.temp_allocator)
	strings.write_string(&features_main, "<main id=\"main\">\n<h1>Features</h1>\n")
	for c, i in cards {
		if i > 0 { strings.write_byte(&features_main, '\n') }
		put(&features_main, `<article class="card" id="`, c.id, "\">\n<h2>", c.title, "</h2>\n", classic_html(c.body), "\n</article>")
	}
	strings.write_string(&features_main, "\n</main>")
	append(&out, Page{cat(CLASSIC, "/", FEATURES_PAGE), classic_page(frame, {
		file = FEATURES_PAGE, title = cat("Features · ", name), description = cat("What ", esc(name), " does."), modern = "../#features",
		main = strings.to_string(features_main),
	})})

	append(&out, Page{cat(CLASSIC, "/", SCREENSHOTS_PAGE), classic_page(frame, {
		file = SCREENSHOTS_PAGE, title = cat("Screenshots · ", name), description = cat("Screenshots of ", esc(name), "."), modern = "../",
		main = cat("<main id=\"main\">\n<h1>Screenshots</h1>\n", classic_html(wide), "\n", classic_html(gallery), "\n</main>"),
		scripts = cat(classic_html(script_with_src(index)), "\n"),
	})})

	append(&out, Page{cat(CLASSIC, "/", CHANGELOG_PAGE), classic_page(frame, {
		file = CHANGELOG_PAGE, title = cat("Changelog · ", name), description = cat("Every version of ", esc(name), ", newest first."),
		modern = "../changelog.html", main = cat("<main id=\"main\" class=\"changelog\">\n<h1>Changelog</h1>\n", changelog_intro, "\n</main>"),
		scripts = cat(FILTER, "\n"),
	})})
	return out[:], ""
}

// The home page with the last version where it says VERSION_MARK.
with_version :: proc(index, version: string) -> string {
	s, _ := strings.replace_all(index, VERSION_MARK, version, context.temp_allocator)
	return s
}

// (CHANGELOG.md is the repository's: main stands at its root.)
site_changelog :: proc(site, out: string) -> int {
	index, has_index := read_utf8(cat(site, "/", SITE_HOME))
	changes, has_changes := read_utf8(SITE_CHANGES)
	if !has_index || !has_changes { return 1 }
	releases := parse_changelog(changes)
	if len(releases) == 0 { fmt.eprintfln("site: no version in %s", SITE_CHANGES); return 1 }
	pages, why := make_pages(with_version(index, releases[0].version), releases)
	if why != "" { fmt.eprintfln("site: %s/%s: %s", site, SITE_HOME, why); return 1 }
	if !copy_site(site, out) { return 1 }
	for page in pages {
		if !write_text(cat(out, "/", page.path), page.text) { return 1 }
	}
	fmt.printfln("%d versions: %s/%s, the last %d on the home page", len(releases), out, CHANGELOG_PAGE, NEWS_VERSIONS)
	fmt.printfln("the classic pages: %s/%s", out, CLASSIC)
	return 0
}
