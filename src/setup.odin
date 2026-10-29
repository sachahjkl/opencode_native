// The version, the client's own preferences, the command line of the desktop integration, and the Setup dialog:
// install this copy for the user (Start menu, Settings > Apps), repair, or uninstall (desktop_windows.odin does the work).
package occ

import "core:fmt"
import "core:image/png"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "gt:draw"
import "gt:render"
import "gt:ui"

APP_VERSION :: "0.4.0"

LOGO_PNG :: #load("../assets/logo_256.png")

////////////////////////////////
// Preferences: %APPDATA%\opencode-native\settings.txt, "key=value" lines

settings_path :: proc() -> string {
	return pjoin({config_dir(), "settings.txt"})
}

settings_get :: proc(key: string) -> string {
	data, err := os.read_entire_file(settings_path(), context.temp_allocator)
	if err != nil { return "" }
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if i := strings.index_byte(line, '='); i > 0 && strings.trim_space(line[:i]) == key { return strings.trim_space(line[i + 1:]) }
	}
	return ""
}

settings_set :: proc(key, value: string) {
	data, _ := os.read_entire_file(settings_path(), context.temp_allocator)
	b := strings.builder_make(context.temp_allocator)
	text := string(data)
	for line in strings.split_lines_iterator(&text) {
		if i := strings.index_byte(line, '='); i > 0 && strings.trim_space(line[:i]) == key { continue }
		if strings.trim_space(line) != "" { fmt.sbprintf(&b, "%s\n", line) }
	}
	fmt.sbprintf(&b, "%s=%s\n", key, value)
	_ = os.make_directory_all(filepath.dir(settings_path()))
	_ = os.write_entire_file(settings_path(), transmute([]u8)strings.to_string(b))
}

////////////////////////////////
// Command line: --install [--desktop], --uninstall, --status (no window; exit code 0 = done / installed)

desktop_cli :: proc() -> (handled: bool, code: int) {
	args := os.args[1:]
	switch {
	case slice.contains(args, "--install"):
		ok, msg := desktop_install(slice.contains(args, "--desktop"))
		fmt.println(ok ? fmt.tprintf("installed: %s", msg) : fmt.tprintf("install failed: %s", msg))
		return true, ok ? 0 : 1
	case slice.contains(args, "--uninstall"):
		quiet := slice.contains(args, "--quiet")
		if !quiet && message_box("Remove opencode native from this computer?\n\n" + LBL_PIECES + " and the program are removed. Nothing on the opencode server changes.", true) != 6 { return true, 1 }
		ok, _, msg := desktop_uninstall()
		if !quiet { message_box(ok ? "opencode native was removed." : fmt.tprintf("The removal failed: %s", msg), false) }
		return true, ok ? 0 : 1
	case slice.contains(args, "--status"):
		f := install_facts()
		fmt.printfln("%v %s", f.state, f.exe)
		return true, f.state == .This_Copy || f.state == .Other_Copy ? 0 : f.state == .Repair ? 2 : 1
	}
	return false, 0
}


////////////////////////////////
// The logo, as a texture (the Setup dialog, the empty conversation)

Logo :: struct { tex: render.Texture, size: int }

logo_load :: proc(app: ^App) {
	img, err := png.load_from_bytes(LOGO_PNG, {.alpha_add_if_missing}, context.temp_allocator)
	if err != nil || img == nil || img.channels != 4 || img.depth != 8 { return }
	app.logo.tex = render.create_texture_rgba(&app.r, img.width, img.height)
	render.update_texture_rgba(&app.r, app.logo.tex, 0, 0, img.width, img.height, img.pixels.buf[:])
	app.logo.size = img.width
}

@(private = "file")
logo_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	app := (^App)(user)
	if app.logo.tex == 0 { return }
	draw.image(dc, app.logo.tex, b.rect)
}

// The logo in a square of `size` (frame pixels).
logo_box :: proc(app: ^App, id: string, size: f32) {
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.build_box({}, id)
	b.custom = logo_draw
	b.custom_user = app
}

////////////////////////////////
// The Setup dialog

Setup_UI :: struct {
	open:      bool,
	facts:     Install_Facts,
	desktop:   bool,
	message:   string,   // the result of the last action (owned)
	good:      bool,
	installed: string,   // an install just made: the copy to start (owned)
}

setup_open :: proc(app: ^App) {
	app.setup.open = true
	setup_refresh(app)
	app.setup.desktop = app.setup.facts.desk_lnk
}

setup_refresh :: proc(app: ^App) {
	f := install_facts()
	f.dir = strings.clone(f.dir)
	f.exe = strings.clone(f.exe)
	f.running = strings.clone(f.running)
	f.version = strings.clone(f.version)
	delete(app.setup.facts.dir); delete(app.setup.facts.exe); delete(app.setup.facts.running); delete(app.setup.facts.version)
	app.setup.facts = f
}

@(private = "file")
set_message :: proc(app: ^App, good: bool, msg: string) {
	delete(app.setup.message)
	app.setup.message = strings.clone(msg)
	app.setup.good = good
}

// At the start of a copy that is not the installed one, unless the user said "standalone" (for good) or closed the
// dialog for this version.
setup_offer_at_start :: proc(app: ^App) {
	if os.get_env("OPENCODE_NATIVE_NO_SETUP", context.temp_allocator) != "" { return }
	choice := settings_get("setup")
	if choice == "standalone" || choice == fmt.tprintf("dismissed:%s", APP_VERSION) { return }
	f := install_facts()
	if f.state == .Not_Installed || f.state == .Repair { setup_open(app) }
}

setup_dialog :: proc(app: ^App, em: f32) {
	st := &app.setup
	was_open := st.open
	if ui.modal("setup", em * 36, &st.open, 0.18) {
		dialog_backdrop()
		f := &st.facts
		ui.spacer(ui.px(em * 1.3))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em * 1.5))
			logo_box(app, "###setup_logo", math.round(em * 4.2))
			ui.spacer(ui.px(em * 1.1))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() {
				ui.spacer(ui.px(em * 0.4))
				text("t", "opencode native", hex(0xffffffff), ui.Style_Mod{font_size = math.round(em * 1.5), height = ui.px(em * 2)})
				text("v", fmt.tprintf("version %s  ·  Froment Software", APP_VERSION), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.78), height = ui.px(em * 1.3)})
				ui.spacer(ui.px(em * 0.7))
				col := hex(HEX_YELLOW)
				state := ""
				switch f.state {
				case .Not_Installed: state = "Not installed: this copy runs on its own."
				case .This_Copy:     state = "Installed: this is the installed copy."; col = hex(HEX_GREEN)
				case .Repair:        state = "Installed, but a shortcut or the Settings entry is missing."; col = hex(HEX_RED)
				case .Other_Copy:    state = fmt.tprintf("A copy is installed (%s): this one runs on its own.", f.version != "" ? f.version : "?")
				}
				ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
				if ui.row(.Center) {
					lamp("###sl", col, 1, size = em * 0.9)
					ui.spacer(ui.px(em * 0.45))
					text("s", state, hex(HEX_TEXT), ui.Style_Mod{font_size = math.round(em * 0.92)}, ui.fill())
				}
			}
			ui.spacer(ui.px(em * 1.5))
		}
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em * 1.5))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if well("###where", radius = 8, base = 0x0a0a0aff) {
				ui.spacer(ui.px(em * 0.6))
				line :: proc(id, k, v: string, em: f32) {
					ui.next({width = ui.fill(), height = ui.px(em * 1.5), axis = .X, cross = .Center})
					if ui.row(.Center, id = id) {
						ui.spacer(ui.px(em * 0.8))
						text("k", k, hex(HEX_FAINT), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.75)}, ui.px(em * 7.5))
						text("v", v, hex(0xc8c8c8ff), ui.Style_Mod{font = the_app.mono, font_size = math.round(em * 0.75)}, ui.fill())
						ui.spacer(ui.px(em * 0.8))
					}
				}
				line("###l1", "program", f.exe, em)
				line("###l2", LBL_MENU, f.start_lnk ? LBL_MENU_ITEM : "-", em)
				line("###l3", LBL_RECORD, f.record ? LBL_RECORD_IT : "-", em)
				line("###l4", "this copy", f.running, em)
				ui.spacer(ui.px(em * 0.6))
			}
			ui.spacer(ui.px(em * 1.5))
		}
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em * 1.3))
			if ui.tags("weak") { ui.checkbox("###desk", "Shortcut on the Desktop", &st.desktop) }
		}
		if st.message != "" {
			ui.spacer(ui.px(em * 0.5))
			ui.next({width = ui.fill(), height = ui.px(em * 1.6), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em * 1.5))
				glyph(st.good ? ICO_CHECK : ICO_WARN, st.good ? hex(HEX_GREEN) : hex(HEX_RED), math.round(em * 0.85))
				ui.spacer(ui.px(em * 0.3))
				text("m", st.message, st.good ? hex(HEX_GREEN) : hex(HEX_RED), ui.Style_Mod{font_size = math.round(em * 0.88)}, ui.fill())
			}
		}
		ui.spacer(ui.px(em * 1.1))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X, cross = .Center})
		if ui.row(.Center) {
			ui.spacer(ui.px(em * 1.5))
			if f.state == .This_Copy || f.state == .Repair || f.state == .Other_Copy {
				if bevel_button("###uninstall", "Uninstall", ICO_DELETE, .Danger).clicked {
					ok, deferred, msg := desktop_uninstall()
					if ok {
						set_message(app, true, deferred ? "Removed. The program is deleted when this window closes." : "Removed.")
					} else { set_message(app, false, msg) }
					setup_refresh(app)
				}
			}
			ui.spacer(ui.fill())
			// just installed: what is left to do is to start that copy (four buttons overflowed the dialog)
			just_installed := st.installed != "" && f.state != .This_Copy
			if just_installed {
				if bevel_button("###close", "Close", "", .Normal).clicked { st.open = false }
				ui.spacer(ui.px(em * 0.5))
				if bevel_button("###launch", "Open installed copy", ICO_RIGHT, .Accent).clicked {
					if launch(st.installed) { app.quit = true }
				}
			} else if f.state == .Not_Installed || f.state == .Other_Copy {
				if bevel_button("###standalone", "Keep standalone", "", .Normal).clicked {
					settings_set("setup", "standalone")
					st.open = false
				}
				ui.spacer(ui.px(em * 0.5))
			} else {
				if bevel_button("###close", "Close", "", .Normal).clicked { st.open = false }
				ui.spacer(ui.px(em * 0.5))
			}
			if !just_installed {
				label := "Install"
				switch f.state {
				case .Not_Installed: label = "Install"
				case .Other_Copy:    label = "Replace installed copy"
				case .Repair:        label = "Repair"
				case .This_Copy:     label = "Update shortcuts"
				}
				if bevel_button("###install", label, ICO_CHECK, .Accent).clicked {
					ok, msg := desktop_install(st.desktop)
					if ok {
						settings_set("setup", "installed")
						running_installed := same_path(running_exe(), msg)
						set_message(app, true, running_installed ? "Done: everything is in place." : "Installed. Start it from " + LBL_START + ", or now:")
						if !running_installed {
							delete(st.installed)
							st.installed = strings.clone(msg)
						}
					} else { set_message(app, false, msg) }
					setup_refresh(app)
				}
			}
			ui.spacer(ui.px(em * 1.5))
		}
		ui.spacer(ui.px(em * 1.3))
	}
	// closed without an answer: not again for this version
	if was_open && !st.open {
		c := settings_get("setup")
		if c != "standalone" && c != "installed" { settings_set("setup", fmt.tprintf("dismissed:%s", APP_VERSION)) }
	}
}
