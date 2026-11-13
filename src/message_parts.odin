// The parts of an agent's message that open and close: a tool call on the timeline, a reasoning.
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:strings"
import "gt:draw"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"


HEX_TOOL_DONE_PIP     :: 0x4f8a5eff
HEX_REASONING_TEXT    :: 0x9a9a9aff

part_open :: proc(app: ^App, id: string, default := false) -> bool {
	return app.conversation.expanded[hash.fnv64a(transmute([]u8)id)] or_else default
}

// Opens or closes a part from its header `head`: the header is the anchor of the scroll (frame keeps it where it was on
// screen, under the pointer, whatever grows or shrinks around it), and the conversation stops following its bottom.
part_toggle :: proc(app: ^App, id: string, head: ^ui.Box, default := false) {
	k := hash.fnv64a(transmute([]u8)id)
	app.conversation.expanded[k] = !(app.conversation.expanded[k] or_else default)
	chat_scroll_event(app, Scroll_Anchor{head, head.rect.min.y})
}

@(private = "file")
head_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	if b.hot_t > FADE_VISIBLE {
		r := b.rect
		draw.rect(dc, r, {1, 1, 1, 0.035 * b.hot_t}, 7 * ui.scale())
	}
}

tool_icon :: proc(name: string) -> string {
	switch {
	case strings.contains(name, "bash") || strings.contains(name, "shell") || strings.contains(name, "pty"): return lucide.SQUARE_TERMINAL
	case name == "read" || name == "view":                                                             return lucide.FILE
	case strings.contains(name, "edit") || name == "write" || strings.contains(name, "patch"):           return lucide.PENCIL
	case name == "glob" || name == "grep" || name == "list" || strings.contains(name, "search") || name == "find": return lucide.SEARCH
	case strings.contains(name, "web") || strings.contains(name, "fetch") || strings.contains(name, "browser"): return lucide.GLOBE
	case name == "task" || strings.contains(name, "agent"):                                              return lucide.BOT
	case strings.contains(name, "todo"):                                                                 return lucide.LIST
	}
	return lucide.WRENCH
}

status_color :: proc(s: Tool_Status) -> Color {
	switch s {
	case .Pending, .Unknown: return hex(HEX_FAINT)
	case .Running: return hex(HEX_YELLOW)
	case .Done:    return hex(HEX_GREEN)
	case .Error:   return hex(HEX_RED)
	}
	return {}
}

@(private = "file")
Rail_Draw :: struct { status: Tool_Status, above, below: bool, head: f32 }

// The timeline's gutter: a carved rail through the calls of a run, and at the height of the header the call's mark:
// a lamp while it runs, a pip once it is done, a red pip when it failed.
@(private = "file")
rail_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Rail_Draw)(user)
	r := b.rect
	if b.parent != nil { r.max.y = b.parent.rect.max.y }   // (the box is as tall as the header; the row may be taller)
	x := math.round((r.min.x + r.max.x) * 0.5)
	cy := math.round(r.min.y + d.head * 0.5)
	if d.above { draw_groove(dc, {x, r.min.y}, {x, cy}, true) }
	if d.below { draw_groove(dc, {x, cy}, {x, r.max.y}, true) }
	sz := math.round(d.head * 0.38)
	switch d.status {
	case .Running, .Pending:
		lit := PULSE_LIT_MIN + PULSE_LIT_SPAN * (0.5 + 0.5 * math.sin(f32(ui.now_ms()) * PULSE_RATE))
		draw_lamp(dc, {x, cy}, math.round(sz * 0.85), status_color(d.status), lit)
	case .Done:    draw_pip(dc, {x, cy}, sz, hex(HEX_TOOL_DONE_PIP))
	case .Error:   draw_pip(dc, {x, cy}, sz, hex(HEX_RED))
	case .Unknown: draw_pip(dc, {x, cy}, sz, status_color(d.status))
	}
}

TOOL_INPUT_LINES_MAX    :: 40
TOOL_ERROR_LINES_FOLDED :: 6
TOOL_IMAGE_OPEN_W_PX    :: 520
TOOL_IMAGE_OPEN_H_PX    :: 360
TOOL_IMAGE_W_PX         :: 240
TOOL_IMAGE_H_PX         :: 150

// A tool call on the timeline: a flat row (its header lights under the pointer), its input and output in wells when
// open. `above`, `below`: calls right before and after it, joined by the rail.
tool_part :: proc(app: ^App, p: ^Part, pid: string, em: f32, above := false, below := false) {
	open := part_open(app, p.tool_id != "" ? p.tool_id : pid, app.prefs.expand_tools)
	head_h := math.round(em * 2.0)
	running := p.status == .Running || p.status == .Pending
	if running { animate(app) }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = fmt.tprintf("###tp_%s", pid)) {
		ui.next({width = ui.px(math.round(em * 1.5)), height = ui.px(head_h)})   // (the rail draws down to the row's bottom: fill() in a row sized by its children resolves far above)
		gb := ui.build_box({}, "###rail")
		rd := ui.frame_new(Rail_Draw)
		rd^ = {p.status, above, below, head_h}
		gb.custom = rail_draw
		gb.custom_user = rd
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column(id = "###col") {
		// header (click to open)
		ui.next({width = ui.fill(), height = ui.px(head_h), axis = .X, cross = .Center})
		hb := ui.build_box({.Clickable, .Focusable}, "###head")
		hb.custom = head_draw
		hs := ui.signal(hb)
		if hs.clicked { part_toggle(app, p.tool_id != "" ? p.tool_id : pid, hb) }
		edits := tool_kind(p.tool_name) == .Edit
		if edits { _ = part_patch(p, app.chat.alloc) }
		if ui.parent(hb) {
			ui.spacer(ui.px(em * 0.5))
			failed := p.status == .Error
			glyph(tool_icon(p.tool_name), failed ? hex(HEX_RED) : hex(HEX_FAINT), math.round(em * ICON_REGULAR))
			ui.spacer(ui.px(em * 0.35))
			text("nm", p.tool_name != "" ? p.tool_name : "tool", failed ? hex(HEX_ERROR_TEXT) : running ? hex(HEX_TEXT) : hex(HEX_WEAK), ui.Style_Mod{font = app.mono_bold, font_size = math.round(em * FS_NOTE)})
			ui.spacer(ui.px(em * 0.6))
			text("sj", p.subject, hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)}, ui.fill())
			ui.spacer(ui.px(em * 0.4))
			if edits && p.added + p.removed > 0 {
				st := ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)}
				if p.added > 0 { text("ad", fmt.tprintf("+%d", p.added), hex(HEX_GREEN), st); ui.spacer(ui.px(em * 0.3)) }
				if p.removed > 0 { text("rm", fmt.tprintf("−%d", p.removed), hex(HEX_RED), st); ui.spacer(ui.px(em * 0.3)) }
				ui.spacer(ui.px(em * 0.2))
			}
			// how long it took, or has taken so far (it counts while it runs: animate above)
			// (and when, under the pointer: its start and its end. A click on it is the header's)
			if took := tool_elapsed(p, running, now_epoch_ms()); took != "" {
				ui.next({width = ui.text_size(0), height = ui.pct(1), fg = running ? hex(HEX_TEXT_SOFT) : hex(HEX_FAINT), font = app.mono, font_size = math.round(em * FS_CAPTION), text_pad = 0})
				tk := ui.signal(ui.build_box({.Draw_Text, .Clickable}, fmt.tprintf("%s###tk", took)))
				if tk.clicked { part_toggle(app, p.tool_id != "" ? p.tool_id : pid, hb) }
				if ui.hovered_for(tk) { if ui.tooltip() { ui.tooltip_text(tool_when(p, running, now_epoch_ms(), app.prefs.clock24)) } }
				ui.spacer(ui.px(em * 0.5))
			}
			glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY))
			ui.spacer(ui.px(em * 0.6))
		}
		// a shell call: it can go to the background while it holds the turn, and says so once it is there
		if bg, bg_running := part_background(app, p); bg || (running && tool_kind(p.tool_name) == .Shell) {
			ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
			if ui.row(.Center, id = "###bgrow") {
				ui.spacer(ui.px(em * 0.5))
				if bg {
					if bg_running { session_lamp("###bgl", LAMP_BACKGROUND, em); ui.spacer(ui.px(em * 0.35)) }
					text("bgt", bg_running ? i18n.tr("in background") : i18n.tr("finished in background"), hex(bg_running ? HEX_TEXT_SOFT : HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				} else if hint_action("###bgpush", i18n.tr("push to background"), em, app.mono, lucide.SEND_TO_BACK) {
					background_session(app, app.chat.id)
				}
				// (what it prints, as it prints it: the command at work, whether it holds the turn or runs in the background)
				if output_view_can(p) {
					ui.spacer(ui.px(em * 1.2))
					if hint_action("###bginspect", "inspect", em, app.mono, lucide.SQUARE_TERMINAL) { output_view_open_part(app, p) }
				}
			}
		}
		show_error := p.status == .Error && p.output != ""
		// (what changed in a file shows even folded, as images do: a screenshot, a diff are what one looks for)
		show_diff := edits && !open && p.status != .Error && p.patch != ""
		if open || show_error || show_diff || len(p.images) > 0 {
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
			if ui.row(id = "###bodyrow") {
				ui.spacer(ui.px(em * 0.6))
				ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
				if ui.column() {
					if open {
						tool_body(app, p, em)
					} else if show_diff {
						diff_view(app, "###diff", p.diff, p.patch, em, DIFF_FOLDED_LINES, tool_diff_title(p))
					} else if show_error {
						mono_well("###output", p.output, em, TOOL_ERROR_LINES_FOLDED, hex(HEX_ERROR_TEXT), &p.output_well, app.chat.alloc)
					}
					if len(p.images) > 0 {
						ui.spacer(ui.px(em * 0.5))
						sc := ui.scale()
						image_strip(app, "###imgs", p.images[:], (open ? TOOL_IMAGE_OPEN_W_PX : TOOL_IMAGE_W_PX) * sc, (open ? TOOL_IMAGE_OPEN_H_PX : TOOL_IMAGE_H_PX) * sc)
					}
					ui.spacer(ui.px(em * 0.6))
				}
				ui.spacer(ui.px(em * 0.6))
			}
		}
		}
	}
	if !below { ui.spacer(ui.px(em * 0.5)) }
}

reasoning_part :: proc(app: ^App, p: ^Part, pid: string, em: f32) {
	if app.prefs.reasoning == "hidden" { return }
	open := part_open(app, pid, app.prefs.reasoning == "expanded")
	ui.next({width = ui.fill(), height = ui.px(math.round(em * 1.9)), axis = .X, cross = .Center})
	hb := ui.build_box({.Clickable, .Focusable}, fmt.tprintf("###rh_%s", pid))
	hb.custom = head_draw
	hs := ui.signal(hb)
	if hs.clicked { part_toggle(app, pid, hb) }
	if ui.parent(hb) {
		ui.spacer(ui.px(em * 0.2))
		glyph(lucide.LIGHTBULB, hex(HEX_FAINT), math.round(em * ICON_REGULAR))
		ui.spacer(ui.px(em * 0.3))
		// (a run over says no more about this part: it thought)
		text("t", p.done || !app.chat.busy ? i18n.tr("Thought") : i18n.tr("Thinking…"), hex(HEX_WEAK), ui.Style_Mod{font_size = math.round(em * FS_NOTE)})
		ui.spacer(ui.px(em * 0.5))
		if !open {
			text("pv", preview_text(string(p.text[:])), hex(HEX_FAINT), ui.Style_Mod{font_size = math.round(em * FS_NOTE)}, ui.fill())
		} else { ui.spacer(ui.fill()) }
		glyph(open ? lucide.CHEVRON_DOWN : lucide.CHEVRON_RIGHT, hex(HEX_FAINT), math.round(em * ICON_TINY))
		ui.spacer(ui.px(em * 0.4))
	}
	if open {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if rail_row(fmt.tprintf("###rb_%s", pid), with_alpha(hex(HEX_WEAK), 0.4)) {
			ui.spacer(ui.px(em * 0.9))
			runs := link_runs(&p.text_runs, string(p.text[:]), {italic = true, color = hex(HEX_REASONING_TEXT)}, app.chat.alloc)
			ui.next({width = ui.fill(), font_size = math.round(em * FS_LABEL), flags = {.Selectable}})
			link_clicked(ui.rich_paragraph("###t", runs))
		}
	}
	ui.spacer(ui.px(em * 0.5))
}
