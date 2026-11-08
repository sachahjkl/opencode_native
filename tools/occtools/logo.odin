// logo: the client's logo, a bolt of brushed silver on a machined dark tile, with hints of the peach accent: vertical gradients, a
// lit rim, shadows. Small sizes drop the shadows (detail picked from the size). Drawn by the toolkit's paint package.
//   occtools logo [--out folder] [--hint 0|1|2]      (default assets; hint 0: silver alone; 1: a peach edge; 2: and a warm tip)
// Writes logo.png (512), logo_256/64/32/16.png and opencode-native.ico (16/20/24/32/40/48/64/128/256, PNG entries).
package occtools

import "core:fmt"
import "core:os"
import "core:strconv"
import paint "gt:paint"

LOGO_DEFAULT_OUT :: "assets"
LOGO_ICO :: "opencode-native.ico"
// Supersampling: drawn at size * LOGO_SUPERSAMPLE, then scaled down.
LOGO_SUPERSAMPLE :: 4
// The drawing's grid: LOGO_GRID x LOGO_GRID units.
LOGO_GRID :: 64
LOGO_FILE_SIZES :: [?]int{512, 256, 64, 32, 16}
LOGO_ICO_SIZES :: [?]int{16, 20, 24, 32, 40, 48, 64, 128, 256}
LOGO_HINT_DEFAULT :: 1
LOGO_HINT_MAX :: 2
// The bolt, in grid units.
LOGO_BOLT :: [?][2]f32{{38, 8}, {17, 36}, {30, 36}, {26, 56}, {47, 27}, {34, 27}}
LOGO_BOLT_TOP :: 8
LOGO_BOLT_BOTTOM :: 56
LOGO_TILE_TOP :: 0x303030
LOGO_TILE_BOTTOM :: 0x0E0E0E
LOGO_PEACH :: 0xE8935A
LOGO_WARM_TIP :: 0xFAB283
LOGO_COOL_TIP :: 0x9C9C9C

run_logo :: proc(args: []string) -> int {
	out := LOGO_DEFAULT_OUT
	hint := LOGO_HINT_DEFAULT
	for i := 0; i < len(args); i += 1 {
		switch {
		case args[i] == "--out" && i + 1 < len(args):
			i += 1
			out = args[i]
		case args[i] == "--hint" && i + 1 < len(args):
			i += 1
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 0 || n > LOGO_HINT_MAX { fmt.eprintfln("logo: --hint 0, 1 or 2, not %s", args[i]); return EXIT_USAGE }
			hint = n
		case:
			fmt.eprintfln("logo: what is %s?", args[i])
			return EXIT_USAGE
		}
	}
	if err := os.make_directory_all(out); err != nil && !os.is_dir(out) { fmt.eprintfln("logo: %s cannot be made", out); return 1 }
	for size in LOGO_FILE_SIZES {
		name := size == 512 ? "logo.png" : fmt.tprintf("logo_%d.png", size)
		logo := draw_logo(size, hint)
		ok := paint.write_png(logo, fmt.tprintf("%s/%s", out, name))
		paint.canvas_destroy(&logo)
		if !ok { fmt.eprintfln("logo: %s cannot be written in %s", name, out); return 1 }
	}
	sizes := LOGO_ICO_SIZES
	entries: [len(LOGO_ICO_SIZES)]paint.Ico_Entry
	for size, i in sizes {
		logo := draw_logo(size, hint)
		entries[i] = {size, paint.png_encode(logo, context.temp_allocator)}
		paint.canvas_destroy(&logo)
	}
	ico := paint.ico_encode(entries[:], context.temp_allocator)
	if os.write_entire_file(fmt.tprintf("%s/%s", out, LOGO_ICO), ico) != nil { fmt.eprintfln("logo: %s cannot be written in %s", LOGO_ICO, out); return 1 }
	fmt.printfln("wrote %s: logo.png, logo_256/64/32/16.png, %s", out, LOGO_ICO)
	return 0
}

// The logo at `size` pixels.
draw_logo :: proc(size, hint: int) -> paint.Canvas {
	S := f32(size * LOGO_SUPERSAMPLE)
	big := paint.canvas_make(size * LOGO_SUPERSAMPLE, size * LOGO_SUPERSAMPLE)
	defer paint.canvas_destroy(&big)
	// (the committed pictures were GDI+'s: this puts the shapes where it put them)
	big.transform = paint.translate(paint.IDENTITY, paint.GDIPLUS_OFFSET, paint.GDIPLUS_OFFSET)
	detail := size >= 48 ? 2 : size >= 24 ? 1 : 0
	u := S / LOGO_GRID

	// the tile
	m := detail == 0 ? 1 * u : 3 * u
	r := 13 * u
	tile: paint.Path
	defer paint.path_destroy(&tile)
	paint.round_rect(&tile, m, m, S - 2 * m, S - 2 * m, r)
	paint.fill(&big, tile, paint.linear({0, m}, {0, S - m}, paint.hex(LOGO_TILE_TOP), paint.hex(LOGO_TILE_BOTTOM), .Repeat), .Even_Odd)
	if detail >= 1 {
		// lit rim (top) fading to nothing (bottom), and again from the top colour past 70 % (GDI+'s gradients repeat)
		rim: paint.Path
		defer paint.path_destroy(&rim)
		paint.round_rect(&rim, m + 1.2 * u, m + 1.2 * u, S - 2 * m - 2.4 * u, S - 2 * m - 2.4 * u, r - 1.2 * u)
		paint.stroke(&big, rim, {width = 1.4 * u}, paint.linear({0, m}, {0, S * 0.7}, paint.hex(0xFFFFFF, 70), paint.hex(0xFFFFFF, 0), .Repeat))
	}
	paint.stroke(&big, tile, {width = max(1.6 * u, LOGO_SUPERSAMPLE)}, paint.solid(paint.hex(0x000000, 230)))

	// the mark: a bolt of brushed silver, lit from above, with a warm edge of the peach accent where it would catch the light of the tile
	points: [len(LOGO_BOLT)][2]f32
	for p, i in LOGO_BOLT { points[i] = p * u }
	bolt: paint.Path
	defer paint.path_destroy(&bolt)
	paint.polygon(&bolt, points[:])
	moved :: proc(c: ^paint.Canvas, bolt: paint.Path, dx, dy: f32, color: paint.Color) {
		p := paint.path_clone(bolt)
		defer paint.path_destroy(&p)
		paint.path_transform(&p, paint.translate(paint.IDENTITY, dx, dy))
		paint.fill(c, p, paint.solid(color), .Even_Odd)
	}
	// its shadow on the tile, and the peach behind it
	if detail >= 1 {
		for k in ([?]int{3, 2, 1}) { moved(&big, bolt, 0, f32(k) * 0.8 * u, paint.hex(0x000000, 40 + 25 * (3 - k))) }
	}
	if hint >= 1 {
		d: f32 = detail == 0 ? 2.2 : 1.6
		moved(&big, bolt, -d * u, d * u, paint.hex(LOGO_PEACH))
	}
	// the face: silver, turning warm at its tip
	y0, y1 := LOGO_BOLT_TOP * u, LOGO_BOLT_BOTTOM * u
	face := paint.linear({0, y0 - 1}, {0, y1 + 1}, {}, {}, .Repeat)
	paint.set_stops(&face, {{0, paint.hex(0xFFFFFF)}, {0.45, paint.hex(0xDCDCDC)}, {0.72, paint.hex(0xB4B4B4)}, {1, paint.hex(hint >= 2 ? LOGO_WARM_TIP : LOGO_COOL_TIP)}})
	paint.fill(&big, bolt, face, .Even_Odd)
	if detail >= 1 {
		paint.stroke(&big, bolt, {width = max(0.7 * u, LOGO_SUPERSAMPLE)}, paint.solid(paint.hex(0x000000, 170)))
	}
	return paint.resize(big, size, size)
}
