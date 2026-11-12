package ocn

// The Markdown of the answers: what the blocks are laid out with.

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:testing"

// A list's numbers take the width of its widest ("10." is not cut); its levels are measured apart; another list is
// measured on its own; what is not a list has no marker.
@(test)
a_list_takes_the_width_of_its_widest_number :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	b := strings.builder_make(context.temp_allocator)
	for i in 1 ..= 10 { fmt.sbprintf(&b, "%d. item\n", i) }
	strings.write_string(&b, "   - under ten\n\nA paragraph.\n\n1. alone\n2. two\n")
	doc := Md_Doc{alloc = context.temp_allocator}
	md_read(&doc, strings.to_string(b))
	blocks := doc.blocks
	measure :: proc(s: string, size: f32) -> f32 { return f32(len(s)) * 8 }   // (8 px a character)
	w := list_marker_widths(blocks[:], measure, 16, 20, 4)
	kinds := make([dynamic]string, context.temp_allocator)
	for bl in blocks { append(&kinds, fmt.tprintf("%v", bl.kind)) }
	if !testing.expectf(t, len(blocks) == 14, "the blocks: %v", kinds) { return }
	for i in 0 ..< 10 { testing.expectf(t, w[i] == 3 * 8 + 4, "item %d: as wide as \"10.\" and the gap: %v", i + 1, w[i]) }
	testing.expect_value(t, w[10], 20)   // (a bullet one level under: the least)
	testing.expect_value(t, w[11], 0)    // (a paragraph)
	testing.expect_value(t, w[12], 20)   // ("1." and "2.": the least is wider)
	testing.expect_value(t, w[13], 20)
}

// The blocks as a line each: what they are and their lines (a doc read whole and one read as its text grew must say the same).
@(private = "file")
md_shape :: proc(d: ^Md_Doc) -> string {
	b := strings.builder_make(context.temp_allocator)
	for &bl in d.blocks {
		fmt.sbprintf(&b, "%v %d %q %q %v |", bl.kind, bl.level, bl.marker, bl.lang, bl.closed)
		for l in md_lines(d, &bl) { fmt.sbprintf(&b, " %q", l) }
		strings.write_byte(&b, '\n')
	}
	return strings.to_string(b)
}

// An answer streams into its buffer: at every length, the blocks kept and read again from the last one are those of the whole
// text read anew, and the last block's text is the new one. A text in another buffer is read whole.
@(test)
a_growing_text_reads_as_the_whole_text :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	SRC :: "# Title\nA first line\nand its second.\n\n- one\n- two\n  1. under\n\n> a quote\n> goes on\n\n```odin\nx := 1\n\n```\n| a | b |\n|---|:-:|\n| 1 | 2 |\n\n---\nThe end, at https://example.com."
	text := make([dynamic]u8, 0, len(SRC) + 1, context.temp_allocator)   // (room for all of it: the buffer does not move)
	kept := Md_Doc{alloc = context.temp_allocator}
	src_all := SRC   // (a constant string is not indexed by a variable)
	for i in 0 ..< len(src_all) {
		append(&text, src_all[i])
		src := string(text[:])
		md_read(&kept, src)
		whole := Md_Doc{alloc = context.temp_allocator}
		md_read(&whole, strings.clone(src, context.temp_allocator))
		if !testing.expectf(t, md_shape(&kept) == md_shape(&whole), "at %d bytes:\n%s\nread whole:\n%s", i + 1, md_shape(&kept), md_shape(&whole)) { return }
		if n := len(kept.blocks); n > 0 && kept.blocks[n - 1].kind != .Rule && kept.blocks[n - 1].kind != .Table {
			testing.expect_value(t, md_text(&kept, n - 1), md_text(&whole, n - 1))
		}
	}
	// the same length, another buffer: read again whole
	other := strings.clone(SRC, context.temp_allocator)
	other_b := transmute([]u8)other
	other_b[2] = 'X'
	md_read(&kept, other)
	testing.expect_value(t, md_lines(&kept, &kept.blocks[0])[0], "Xitle")
}

// A gantt chart in seconds since 1970 (dateFormat X), as a model writes the timing of its calls, is a diagram.
@(test)
a_gantt_in_seconds_is_a_diagram :: proc(t: ^testing.T) {
	context.allocator = runtime.heap_allocator()
	app := bench_new()
	defer diagrams_free(app)
	GANTT :: "gantt\n    title Déroulé des trois appels\n    dateFormat X\n    axisFormat %S s\n    section Parallèle\n    Lecture du dossier      :a1, 0, 1\n    Code Mode               :a2, 0, 2\n    Sous-agent explore      :a3, 0, 3\n    section Séquentiel\n    Rédaction de la réponse :after a3, 1\n"
	d := diagram_of(app, GANTT, true)
	if !testing.expect(t, d != nil) { return }
	testing.expectf(t, d.why == "", "a diagram: %s", d.why)
	testing.expect(t, len(d.doc.items) > 0, "its shapes and words")
}
