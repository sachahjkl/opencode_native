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
	blocks := parse_blocks(strings.to_string(b))
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
