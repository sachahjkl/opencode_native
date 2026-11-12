package ocn

import "core:testing"
import diff "gt:diff"

// (the rows and what a view builds are gt:diff's, tested there: tests/diff)

@(test)
the_layout_is_read_from_its_name :: proc(t: ^testing.T) {
	testing.expect_value(t, diff_layout_of("split"), diff.Layout.Split)
	testing.expect_value(t, diff_layout_of("stacked"), diff.Layout.Stacked)
	testing.expect_value(t, diff_layout_of("anything"), diff.Layout.Stacked)
}
