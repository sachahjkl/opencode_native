// A tool call's input as it streams: the JSON fragments of `session.tool.input.delta`, read once each into the text of the
// input's one string field, if it has only that (src/md/features/freeform-tools.md).
package ocn

import "core:mem"
import "core:strconv"
import "core:unicode/utf8"

// Where the reading of the fragments is. Head: `{"<field>":"` is not whole yet. Text: in the field's string. Closed: its quote
// came. Not_One_Field: a second field, or a value that is not a string, or not JSON: nothing of it is shown.
Input_Stream_State :: enum u8 { Head, Text, Closed, Not_One_Field }

Input_Stream :: struct {
	state:   Input_Stream_State,
	text:    [dynamic]u8,   // the field's text so far, unescaped (in the chat's arena)
	pending: [dynamic]u8,   // what a fragment cut: the head so far, an escape or a UTF-8 sequence not whole yet
	long:    bool,          // the text is long (text_long), known as it grows: a build reads no text to know it
}

// The fragment `delta` added. Each byte is read once: what is whole goes into the text, the rest waits in `pending`.
input_stream_add :: proc(s: ^Input_Stream, delta: string, a: mem.Allocator) {
	if s.state == .Not_One_Field || len(delta) == 0 { return }
	if s.text.allocator.procedure == nil { s.text = make([dynamic]u8, a); s.pending = make([dynamic]u8, a) }
	data := delta
	if len(s.pending) > 0 {
		append(&s.pending, delta)
		data = string(s.pending[:])
	}
	had := len(s.text)
	used := input_stream_read(s, data)
	if !s.long { s.long = len(s.text) > TOOL_LINE_CHARS || text_long(string(s.text[had:])) }   // (only what came is read)
	rest := data[used:]
	if len(s.pending) > 0 {
		// (`rest` is the end of `pending` itself: moved to its start)
		copy(s.pending[:], rest)
		resize(&s.pending, len(rest))
	} else if len(rest) > 0 {
		append(&s.pending, rest)
	}
}

// The whole input, `full`, as `input.ended` says it: it has the last word. Decoded once; the text is replaced only if it differs.
input_stream_end :: proc(s: ^Input_Stream, full: string, a: mem.Allocator) {
	fresh: Input_Stream
	input_stream_add(&fresh, full, context.temp_allocator)
	if fresh.state == s.state && string(fresh.text[:]) == string(s.text[:]) { return }
	s.state, s.long = fresh.state, fresh.long
	s.text = make([dynamic]u8, 0, len(fresh.text), a)
	append(&s.text, string(fresh.text[:]))
	s.pending = make([dynamic]u8, a)
}

// The streamed text to show: the input is one string field so far, and its text is long (as a freeform tool's is: tool_freeform).
input_stream_shown :: proc(s: ^Input_Stream) -> (string, bool) {
	if s.state != .Text && s.state != .Closed { return "", false }
	return string(s.text[:]), s.long
}

// A value that goes on lines of its own: a line break, or longer than a line.
text_long :: proc(s: string) -> bool {
	for c in transmute([]u8)s { if c == '\n' { return true } }
	return len(s) > TOOL_LINE_CHARS
}

// Reads `data` from the state it is in; how many bytes it took (the rest is not whole yet).
@(private = "file")
input_stream_read :: proc(s: ^Input_Stream, data: string) -> (used: int) {
	i := 0
	for {
		switch s.state {
		case .Head:
			n, ok, whole := head_read(data)
			if !whole { return 0 }
			if !ok { s.state = .Not_One_Field; return len(data) }
			i = n
			s.state = .Text
		case .Text:
			text_loop: for i < len(data) {
				c := data[i]
				switch {
				case c == '"':
					s.state = .Closed
					i += 1
					break text_loop
				case c == '\\':
					n, r, ok, whole := escape_read(data[i:])
					if !whole { return i }
					if !ok { s.state = .Not_One_Field; return len(data) }
					b, w := utf8.encode_rune(r)
					append(&s.text, ..b[:w])
					i += n
				case c < 0x80:
					append(&s.text, c)
					i += 1
				case:
					// (a UTF-8 sequence a fragment cut waits for its end)
					w := utf8_width(c)
					if i + w > len(data) { return i }
					append(&s.text, data[i:i + w])
					i += w
				}
			}
			if s.state == .Text { return i }
		case .Closed:
			for i < len(data) {
				switch data[i] {
				case ' ', '\t', '\r', '\n', '}': i += 1
				case:
					s.state = .Not_One_Field   // (a second field: not one text)
					return len(data)
				}
			}
			return i
		case .Not_One_Field:
			return len(data)
		}
	}
}

// `{"<field>":"`, spaces allowed: how many bytes it takes. whole false: `data` ends before it is known; ok false: it is not that.
@(private = "file")
head_read :: proc(data: string) -> (n: int, ok, whole: bool) {
	i := 0
	skip :: proc(data: string, i: int) -> int {
		j := i
		for j < len(data) && (data[j] == ' ' || data[j] == '\t' || data[j] == '\r' || data[j] == '\n') { j += 1 }
		return j
	}
	expect :: proc(data: string, i: ^int, c: u8) -> (ok, whole: bool) {
		i^ = skip(data, i^)
		if i^ >= len(data) { return false, false }
		if data[i^] != c { return false, true }
		i^ += 1
		return true, true
	}
	if ok, whole = expect(data, &i, '{'); !ok { return }
	if ok, whole = expect(data, &i, '"'); !ok { return }
	for {   // the field's name: what it is matters not, only where it ends
		if i >= len(data) { return 0, false, false }
		if data[i] == '\\' { i += 2; continue }
		if data[i] == '"' { i += 1; break }
		i += 1
	}
	if ok, whole = expect(data, &i, ':'); !ok { return }
	if ok, whole = expect(data, &i, '"'); !ok { return }
	return i, true, true
}

// An escape at the start of `data` (`\n`, `\uXXXX`, a surrogate pair as two of them): its bytes and the character.
@(private = "file")
escape_read :: proc(data: string) -> (n: int, r: rune, ok, whole: bool) {
	if len(data) < 2 { return 0, 0, false, false }
	switch data[1] {
	case '"':  return 2, '"', true, true
	case '\\': return 2, '\\', true, true
	case '/':  return 2, '/', true, true
	case 'b':  return 2, '\b', true, true
	case 'f':  return 2, '\f', true, true
	case 'n':  return 2, '\n', true, true
	case 'r':  return 2, '\r', true, true
	case 't':  return 2, '\t', true, true
	case 'u':
		if len(data) < 6 { return 0, 0, false, false }
		hi, is := strconv.parse_uint(data[2:6], 16)
		if !is { return 0, 0, false, true }
		if hi < 0xD800 || hi > 0xDBFF { return 6, rune(hi), true, true }
		// a high surrogate: its low half follows, or the character is lost
		if len(data) < 12 { return 0, 0, false, false }
		if data[6] != '\\' || data[7] != 'u' { return 6, utf8.RUNE_ERROR, true, true }
		lo, is_lo := strconv.parse_uint(data[8:12], 16)
		if !is_lo || lo < 0xDC00 || lo > 0xDFFF { return 6, utf8.RUNE_ERROR, true, true }
		return 12, rune(0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)), true, true
	}
	return 0, 0, false, true
}

// The bytes of a UTF-8 sequence that starts with `c` (1 for a byte that starts none: shown as it is).
@(private = "file")
utf8_width :: proc(c: u8) -> int {
	switch {
	case c & 0xE0 == 0xC0: return 2
	case c & 0xF0 == 0xE0: return 3
	case c & 0xF8 == 0xF0: return 4
	}
	return 1
}
