package occtools

import "core:strings"
import "core:testing"

VT_SAMPLE :: `
/* a comment with typedef enum { NOT_ONE = 9 } in it */
#define SHIFT 8
#define MASK \
  ((GhosttyStyleFlags)(0x7u << SHIFT))
#define FLAG ((GhosttyStyleFlags)(1u << 3))
#define PASTE (ghostty_mode_new(2004, false))
#define ANSI (ghostty_mode_new(4, true))
typedef uint16_t GhosttyMods;
typedef enum GHOSTTY_ENUM_TYPED {
  KEY_NONE = 0,   // the first
  KEY_B,
  KEY_C,
  KEY_TEN = 10,
  KEY_ELEVEN,
  KEY_MAX_VALUE = GHOSTTY_ENUM_MAX_VALUE,
} GhosttyKey;
GHOSTTY_API GhosttyResult ghostty_a(const GhosttyAllocator* allocator, GhosttyTerminal* out,
                                    uint16_t cols);
GHOSTTY_API void ghostty_b(GhosttyTerminal terminal, const uint8_t *data, size_t len);
GHOSTTY_API bool ghostty_c(GhosttyKey key, GhosttyMods mods, GhosttyString map, void* out);
GHOSTTY_API void ghostty_d(void);
GHOSTTY_API void ghostty_e(GhosttyUnknown thing);
`

@(private = "file")
sample :: proc() -> ^Vt_Headers {
	h := new(Vt_Headers, context.temp_allocator)
	h.numbers = make(map[string]i64, context.temp_allocator)
	h.defines = make(map[string]string, context.temp_allocator)
	h.enums = make(map[string]bool, context.temp_allocator)
	h.scalars = make(map[string]string, context.temp_allocator)
	h.calls = make(map[string]string, context.temp_allocator)
	vt_read(h, VT_SAMPLE)
	return h
}

@(test)
an_enumerator_follows_the_last :: proc(t: ^testing.T) {
	h := sample()
	testing.expect_value(t, h.numbers["KEY_NONE"], 0)
	testing.expect_value(t, h.numbers["KEY_C"], 2)
	testing.expect_value(t, h.numbers["KEY_ELEVEN"], 11)
	testing.expect(t, "NOT_ONE" not_in h.numbers, "what is in a comment is not read")
	testing.expect(t, "KEY_MAX_VALUE" not_in h.numbers, "nor the size of an enum")
}

@(test)
a_define_is_worked_out :: proc(t: ^testing.T) {
	h := sample()
	mask, has_mask := vt_eval(h, h.defines["MASK"])
	testing.expect(t, has_mask, "over two lines, naming another")
	testing.expect_value(t, mask, 0x700)
	flag, _ := vt_eval(h, h.defines["FLAG"])
	testing.expect_value(t, flag, 8)
	paste, _ := vt_eval(h, h.defines["PASTE"])
	testing.expect_value(t, paste, 2004)
	ansi, _ := vt_eval(h, h.defines["ANSI"])
	testing.expect_value(t, ansi, 4 | 1 << VT_ANSI_BIT)
	_, known := vt_eval(h, "NOBODY")
	testing.expect(t, !known, "a name nobody defines is no number")
}

@(test)
a_call_is_said_in_odin :: proc(t: ^testing.T) {
	h := sample()
	a, a_ok := vt_call(h, "ghostty_a", h.calls["ghostty_a"])
	testing.expect(t, a_ok)
	testing.expect_value(t, a, "\tghostty_a :: proc(allocator: rawptr, out: ^Vt_Terminal, cols: u16) -> i32 ---")
	b, _ := vt_call(h, "ghostty_b", h.calls["ghostty_b"])
	testing.expect_value(t, b, "\tghostty_b :: proc(terminal: Vt_Terminal, data: [^]u8, len: uint) ---")
	c, _ := vt_call(h, "ghostty_c", h.calls["ghostty_c"])
	testing.expect_value(t, c, "\tghostty_c :: proc(key: i32, mods: u16, map_: Vt_String, out: rawptr) -> bool ---")
	d, _ := vt_call(h, "ghostty_d", h.calls["ghostty_d"])
	testing.expect_value(t, d, "\tghostty_d :: proc() ---")
	_, known := vt_call(h, "ghostty_e", h.calls["ghostty_e"])
	testing.expect(t, !known, "a type nobody named stops it: its layout would be a guess")
}

@(test)
what_went_stops_the_file :: proc(t: ^testing.T) {
	_, problems := vt_generate(sample(), "c0ffee")
	testing.expect(t, len(problems) > 0)
	joined := strings.join(problems, "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "no number GHOSTTY_SUCCESS"), joined)
	testing.expect(t, strings.contains(joined, "no call ghostty_terminal_new"), joined)
	testing.expect(t, strings.contains(joined, "do not follow each other"), joined)
}
