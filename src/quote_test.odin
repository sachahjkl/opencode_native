package ocn

import "core:fmt"
import "core:strings"
import "core:testing"

// jquote as it was, a rune at a time: the reference of the one that copies runs whole.
jquote_reference :: proc(s: string, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(&b, `\"`)
		case '\\': strings.write_string(&b, `\\`)
		case '\n': strings.write_string(&b, `\n`)
		case '\r': strings.write_string(&b, `\r`)
		case '\t': strings.write_string(&b, `\t`)
		case:
			if r < 0x20 { fmt.sbprintf(&b, `\u%04x`, int(r)) } else { strings.write_rune(&b, r) }
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

@(private = "file")
expect_jquote :: proc(t: ^testing.T, s: string, loc := #caller_location) {
	got, want := jquote(s), jquote_reference(s)
	testing.expectf(t, got == want, "jquote of % x: %q, not %q", transmute([]u8)s, got, want, loc = loc)
}

// The same literal as a rune at a time wrote it: every byte value, an escape or a rune past ASCII at every place of every
// length up to 64 (four registers and every tail), bytes that are no UTF-8 (alone, cut short, overlong, a surrogate) as
// U+FFFD, U+FFFD itself, a data URL of megabytes.
@(test)
jquote_is_the_rune_one :: proc(t: ^testing.T) {
	expect_jquote(t, "")
	all: [256]u8
	for &c, i in all { c = u8(i) }
	expect_jquote(t, string(all[:]))
	for c in 0 ..< 256 { expect_jquote(t, string(all[c:c + 1])) }
	INSERTS :: [?]string{"\"", "\\", "\n", "\r", "\t", "\x00", "\x1f", "\x7f", "é", "中文", "\U0001F600", "�", "\xff", "\x80", "\xc3", "\xe2\x82", "\xc0\x80", "\xed\xa0\x80", "\xf5\x80\x80\x80", "é\xffé"}
	inserts := INSERTS
	for n in 0 ..= 64 {
		plain := strings.repeat("aB0+/=", 11, context.temp_allocator)[:n]
		expect_jquote(t, plain)
		for at in 0 ..= n {
			for ins in inserts { expect_jquote(t, strings.concatenate({plain[:at], ins, plain[at:]}, context.temp_allocator)) }
		}
	}
	url := strings.concatenate({"data:image/png;base64,", strings.repeat("iVBORw0KGgo+/=", 300_000, context.temp_allocator)}, context.temp_allocator)
	got := jquote(url)
	testing.expect(t, got == jquote_reference(url), "a data URL of megabytes")
	testing.expect_value(t, len(got), len(url) + 2)
}

// A prompt's body as the interface's thread made it before (prompt_fields and jquote as they were): the reference of
// prompt_body.
prompt_body_reference :: proc(text: string, attachments: []Attachment, mentions: []Mention, fields: string) -> string {
	files := strings.builder_make(context.temp_allocator)
	agents := strings.builder_make(context.temp_allocator)
	for a in attachments {
		if strings.builder_len(files) > 0 { strings.write_byte(&files, ',') }
		fmt.sbprintf(&files, `{{"uri":%s,"name":%s}}`, jquote_reference(a.uri), jquote_reference(a.name))
	}
	for &m in mentions {
		mention, ok := mention_json(&m, text)
		if !ok { continue }
		list := m.kind == .File ? &files : &agents
		if strings.builder_len(list^) > 0 { strings.write_byte(list, ',') }
		if m.kind == .File {
			fmt.sbprintf(list, `{{"uri":%s,"name":%s,"mention":%s}}`, jquote_reference(m.target), jquote_reference(m.name), mention)
		} else {
			fmt.sbprintf(list, `{{"name":%s,"mention":%s}}`, jquote_reference(m.target), mention)
		}
	}
	out := ""
	if strings.builder_len(files) > 0 { out = fmt.tprintf(`,"files":[%s]`, strings.to_string(files)) }
	if strings.builder_len(agents) > 0 { out = fmt.tprintf(`%s,"agents":[%s]`, out, strings.to_string(agents)) }
	return fmt.tprintf(`{{"text":%s%s%s}}`, jquote_reference(text), out, fields)
}
