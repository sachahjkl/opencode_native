// Jump to message (Ctrl+Alt+G; src/md/features/jump.md): a toolkit palette of one source, the session's prompts, the
// newest first. Choosing one goes there as the prompt rail does (prompt_go).
package ocn

import "core:fmt"
import "core:strings"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// The prompt's first characters a row shows.
JUMP_TITLE_CHARS :: 120

Jump :: struct {
	pal:     ui.Command_Palette,
	prompts: ui.Palette_Source,
	due:     bool,   // jump_show: opened at the next build of the main window
}

// Opened at the next build (a command runs where a build may be closing another palette).
jump_show :: proc(app: ^App) { app.jump.due = true }

jump_shown :: proc(app: ^App) -> bool { return ui.palette_is_open(&app.jump.pal) }

// At each build of the main window, beside the main palette: opened when asked, a choice taken.
jump_build :: proc(app: ^App) {
	pane := main_pane(app)
	j := &app.jump
	if !ui.palette_has(&j.pal, &j.prompts) {
		j.prompts = {
			name = "prompt", title = i18n.later("Prompts"), listed = true, enter = i18n.later("Go"),
			read = jump_read, user = app,
			// (read again when a prompt comes or the session changes: never at a frame)
			poll = proc(_: ^ui.Command_Palette, src: ^ui.Palette_Source) {
				c := &main_pane((^App)(src.user)).chat
				src.version = c.gen << 32 | u64(len(c.messages)) + 1
			},
		}
		ui.palette_add(&j.pal, &j.prompts)
	}
	if j.due {
		j.due = false
		if pane.chat.id != "" { ui.palette_open(&j.pal) }
	}
	if c, ok := ui.palette_chosen(&j.pal); ok && c.source == &j.prompts { prompt_go(app, pane, c.id, ui.font_size()) }
}

jump_destroy :: proc(app: ^App) {
	ui.palette_destroy(&app.jump.pal)
	app.jump = {}
}

// The prompts of the conversation loaded, the newest first: "#n" and when it was sent beside its first line.
@(private = "file")
jump_read :: proc(p: ^ui.Command_Palette, src: ^ui.Palette_Source, q: ui.Palette_Question) {
	app := (^App)(src.user)
	pane := main_pane(app)   // (the jump list is the main view's)
	a: ui.Palette_Answer
	al := ui.palette_answer_allocator(&a)
	n := 0
	for &m in pane.chat.messages { if m.kind == .User { n += 1 } }
	a.items = make([]ui.Palette_Item, n, al)
	i := n
	for &m in pane.chat.messages {
		if m.kind != .User { continue }
		i -= 1
		title := strings.trim_space(first_line(m.text))
		a.items[i] = ui.palette_item_clone({
			id = m.id, title = ellipsize(title, JUMP_TITLE_CHARS), detail = fmt.tprintf("#%d", n - i),
			icon = lucide.MESSAGE_SQUARE_TEXT, tags = strings.fields(m.text, context.temp_allocator),
		}, al)
	}
	ui.palette_answer(q, &a)
}
