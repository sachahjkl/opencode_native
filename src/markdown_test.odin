package ocn

// The Markdown of the answers, what ocn adds to the toolkit's markdown package: its diagrams. (The blocks, their cache,
// the tables and the lists are tested in the toolkit: tests/markdown.)

import "base:runtime"
import "core:testing"

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
