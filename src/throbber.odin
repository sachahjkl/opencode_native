// What says that a run goes on. By default a word from a split-flap board: it says what the agent does now (reading, editing,
// thinking), its letters fall in place when it changes, and one flips from time to time. It moves by steps, at a pace of its
// own: nothing glides, so no frame late can show. appearance.throbber chooses another one.
package occ

import "core:fmt"
import "core:math"
import "gt:draw"
import "gt:ui"

Throbber :: struct {
	word:     string,   // the one shown (a literal, or in the chat's arena: a literal is all it is given)
	since_ms: f64,      // when it changed
}

// What the agent does now, in one word, from the last thing it started.
run_word :: proc(app: ^App) -> string {
	c := &app.chat
	#reverse for &m in c.messages {
		if m.kind != .Assistant { continue }
		#reverse for &p in m.parts {
			if p.kind == .Text && !p.done { return "writing" }
			if p.kind == .Reasoning && !p.done { return "thinking" }
			if p.kind == .Tool && (p.status == .Running || p.status == .Pending) {
				switch tool_kind(p.tool_name) {
				case .Edit:   return "editing"
				case .Read:   return "reading"
				case .Search: return "searching"
				case .Shell:  return "running"
				case .Todo:   return "planning"
				case .Other:
					if p.sub_agent != "" { return "delegating" }
					return "working"
				}
			}
		}
		break
	}
	return "thinking"
}

// A cheap, repeatable shuffle: the same step gives the same letter.
@(private = "file")
scramble :: proc(i, step: int) -> u32 {
	x := u32(i * 2654435761 + step * 40503)
	x ~= x >> 13
	x *= 0x5bd1e995
	return x ~ (x >> 15)
}

// The letter at `i` on the board at this moment.
@(private = "file")
board_letter :: proc(word: string, i: int, since, now: f64) -> string {
	step := int((now - since) / THROBBER_STEP_MS)
	glyphs := THROBBER_GLYPHS
	// (each letter stops on its own step, from the left; then one of them flips, for two steps, now and then)
	settled := step >= THROBBER_SETTLE * (i + 1) / len(word)
	round := step / THROBBER_FLIP_STEPS
	flip := step > THROBBER_SETTLE && step % THROBBER_FLIP_STEPS < 2 && int(scramble(0, round) % u32(len(word))) == i
	if settled && !flip { return word[i:i + 1] }
	k := int(scramble(i, step) % u32(len(glyphs)))
	return glyphs[k:k + 1]
}

// What keeps it alive between two flips: a wave of light that runs along the word, all the time.
@(private = "file")
board_light :: proc(i: int, now: f64) -> f32 {
	t := f32(now) * THROBBER_WAVE_RATE - f32(i) * THROBBER_WAVE_PITCH
	w := 0.5 + 0.5 * math.sin(t)
	return THROBBER_LIGHT_MIN + (1 - THROBBER_LIGHT_MIN) * w * w * w
}

@(private = "file")
Orbit_Draw :: struct { color: Color }

// Dots that go round each other.
@(private = "file")
orbit_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	col := (^Orbit_Draw)(user).color
	c := draw.rect_center(b.rect)
	r := (b.rect.max.y - b.rect.min.y) * 0.32
	t := f32(ui.now_ms()) * ORBIT_RATE
	for k in 0 ..< ORBIT_DOTS {
		a := t + f32(k) * math.TAU / ORBIT_DOTS
		size := r * (0.34 + 0.16 * math.sin(a * 0.5 + f32(k)))
		p := Vec2{c.x + math.cos(a) * r, c.y + math.sin(a) * r * 0.62}
		draw.rect(dc, {p - size, p + size}, with_alpha(col, 0.55 + 0.45 * math.sin(a)), size)
	}
}

// `width`, `height`: frame pixels. `id` tells two of them apart.
throbber :: proc(app: ^App, id: string, color: Color, width, height: f32, em: f32) {
	animate(app)
	switch app.prefs.throbber {
	case "scanner":
		scanner(id, color, width, height)
	case "orbit":
		ui.next({width = ui.px(height * 2), height = ui.px(height * 1.4)})
		b := ui.build_box({}, id)
		d := ui.frame_new(Orbit_Draw)
		d.color = color
		b.custom = orbit_draw
		b.custom_user = d
	case "none":
	case:
		t := &app.throbber
		word := run_word(app)
		now := ui.now_ms()
		if word != t.word { t.word, t.since_ms = word, now }
		st := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_NOTE)}
		ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.4)), axis = .X, cross = .Center})
		if ui.row(.Center, id = id) {
			for i in 0 ..< len(word) {
				text(fmt.tprintf("c%d", i), board_letter(word, i, t.since_ms, now), with_alpha(color, board_light(i, now)), st)
			}
		}
	}
}
