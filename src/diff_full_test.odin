package occ

import "core:testing"

@(private = "file")
L :: proc(sign: byte) -> Diff_Line { return Diff_Line{sign = sign} }

@(test)
a_changed_line_faces_itself :: proc(t: ^testing.T) {
	rows := diff_split_rows({L(' '), L('-'), L('-'), L('+'), L(' ')}, context.temp_allocator)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0], Split_Row{0, 0})
	testing.expect_value(t, rows[1], Split_Row{1, 3})
	testing.expect_value(t, rows[2], Split_Row{2, -1})
	testing.expect_value(t, rows[3], Split_Row{4, 4})
}

@(test)
what_is_only_added_has_nothing_on_the_left :: proc(t: ^testing.T) {
	rows := diff_split_rows({L('+'), L('+'), L('@'), L('-')}, context.temp_allocator)
	testing.expect_value(t, len(rows), 4)
	testing.expect_value(t, rows[0], Split_Row{-1, 0})
	testing.expect_value(t, rows[1], Split_Row{-1, 1})
	testing.expect_value(t, rows[2], Split_Row{2, 2})
	testing.expect_value(t, rows[3], Split_Row{3, -1})
}

@(test)
every_line_is_in_the_rows_once_on_its_side :: proc(t: ^testing.T) {
	lines := diff_parse("@@ -1,4 +1,4 @@\n a\n-b\n-c\n+d\n e\n@@ -20,2 +20,3 @@\n f\n+g\n h\n")
	rows := diff_split_rows(lines, context.temp_allocator)
	seen := make([]int, len(lines), context.temp_allocator)
	for r in rows {
		if r.left >= 0 { seen[r.left] += 1 }
		if r.right >= 0 && r.right != r.left { seen[r.right] += 1 }
	}
	for n in seen { testing.expect_value(t, n, 1) }
}

@(test)
the_layout_is_read_from_its_name :: proc(t: ^testing.T) {
	testing.expect_value(t, diff_layout_of("split"), Diff_Layout.Split)
	testing.expect_value(t, diff_layout_of("stacked"), Diff_Layout.Stacked)
	testing.expect_value(t, diff_layout_of("anything"), Diff_Layout.Stacked)
}
