// What goes with a prompt: files pasted, dropped or picked (the paperclip of the composer, composer.attach). An image, a
// PDF or a text file goes as a data URL, so a server on another machine gets it too; an image shows as a thumbnail over
// the composer, every one as its name. Another file (a program, an archive) goes in the text as its path, which the agent
// can read on its own machine.
package occ

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:unicode/utf8"
import "gt:platform"
import "gt:ui"

Attachment :: struct {
	name: string,      // (owned)
	uri:  string,      // data:<mime>;base64,... (owned)
	size: int,         // of the file, in bytes
	ref:  Image_Ref,   // an image's thumbnail (zero: not an image)
}

@(private = "file")
attach_bytes :: proc(app: ^App, data: []u8, mime, name: string) {
	if len(data) > ATTACH_MAX_BYTES { ui.toast(.Warn, "%s is too large to attach", name); return }
	b64, err := base64.encode(data, allocator = context.temp_allocator)
	if err != nil { return }
	uri := strings.concatenate({"data:", mime, ";base64,", b64})
	stored_name := strings.clone(name)
	ref := strings.has_prefix(mime, "image/") ? image_ref(uri, .Data_Url, mime, stored_name) : Image_Ref{}
	append(&app.cx.attachments, Attachment{name = stored_name, uri = uri, size = len(data), ref = ref})
}

@(private = "file")
image_mime :: proc(path: string) -> string {
	switch strings.to_lower(filepath.ext(path), context.temp_allocator) {
	case ".png":           return "image/png"
	case ".jpg", ".jpeg":  return "image/jpeg"
	case ".gif":           return "image/gif"
	case ".webp":          return "image/webp"
	case ".bmp":           return "image/bmp"
	}
	return ""
}

// What a file goes as: an image's or a PDF's type by its extension, text/plain for text (UTF-8 without a NUL byte), ""
// for anything else. Pure.
attach_mime :: proc(path: string, data: []u8) -> string {
	if mime := image_mime(path); mime != "" { return mime }
	if strings.to_lower(filepath.ext(path), context.temp_allocator) == ".pdf" { return "application/pdf" }
	for b in data { if b == 0 { return "" } }
	return utf8.valid_string(string(data)) ? "text/plain" : ""
}

// A file given to the composer (pasted, dropped, picked): attached when it can go as a data URL (attach_mime), else its
// path goes in the text.
attach_path :: proc(app: ^App, path: string) {
	if !os.is_dir(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil {
			if mime := attach_mime(path, data); mime != "" { attach_bytes(app, data, mime, base_name(path)); return }
			ui.toast(.Warn, "%s is not an image, a PDF or text: its path goes in the prompt", base_name(path))
		}
	}
	area_insert(&app.composer, fmt.tprintf("%s ", path))
}

// The paperclip: the system's dialog, several files at once.
attach_pick :: proc(app: ^App) {
	r := platform.open_file_dialog({owner = app.win, title = "Attach files", all_files = true, multiple = true, remember_id = "attach"})
	defer platform.dialog_result_destroy(&r)
	if r.status == .Unsupported { ui.toast(.Bad, "This system has no file dialog"); return }
	if r.status != .Chosen { return }
	for p in r.paths { attach_path(app, p) }
}

// A drag over the window from another program: files, an image or text it carries go to the composer at the drop, where
// the composer is (a dialog open over it refuses the drop).
attach_drop_event :: proc(app: ^App, e: platform.Event) {
	#partial switch e.kind {
	case .Drop_Enter, .Drop_Over:
		platform.drop_set_effect(app.win, overlay_open(app) ? nil : platform.Drop_Effect.Copy)
	case .Drop_Leave:
		platform.drop_data_release(app.win)
	case .Drop:
		defer platform.drop_data_release(app.win)
		d := platform.drop_data(app.win)
		if d == nil || overlay_open(app) { return }
		switch {
		case len(d.files) > 0: for p in d.files { attach_path(app, p) }
		case len(d.image) > 0: attach_bytes(app, d.image, "image/png", fmt.tprintf("dropped-%d.png", len(app.cx.attachments) + 1))
		case d.text != "":     area_insert(&app.composer, d.text)
		}
	}
}

// Ctrl+V in the composer, before the editor takes the key. What is on the clipboard decides: an image or files are
// attached here, text is the editor's own paste. True when it was taken.
attach_paste :: proc(app: ^App) -> bool {
	fmts := platform.clipboard_formats()
	if .Files in fmts {
		if paths, ok := platform.clipboard_get_files(app.win, context.temp_allocator); ok && len(paths) > 0 {
			for p in paths { attach_path(app, p) }
			return true
		}
	}
	if .Image in fmts && .Text not_in fmts {
		img, ok := platform.clipboard_get_image(app.win)
		if !ok { return false }
		defer platform.clipboard_image_destroy(&img)
		png := platform.png_encode(img, context.temp_allocator)
		if len(png) == 0 { ui.toast(.Bad, "The image could not be read"); return true }
		attach_bytes(app, png, "image/png", fmt.tprintf("pasted-%d.png", len(app.cx.attachments) + 1))
		return true
	}
	return false
}

// An attachment read back from a prompt's JSON (outgoing.odin).
attachment_of :: proc(uri, name: string) -> Attachment {
	a := Attachment{name = strings.clone(name), uri = strings.clone(uri)}
	a.size = len(uri) * 3 / 4   // (base64: about what it says)
	if strings.has_prefix(uri, "data:image/") {
		mime, _, _ := strings.partition(uri[len("data:"):], ";")
		a.ref = image_ref(a.uri, .Data_Url, mime, a.name)
	}
	return a
}

// What the JSON of a prompt says of these and of the files and agents named in `text` (empty: none).
prompt_fields :: proc(attachments: []Attachment, mentions: []Mention, text: string) -> string {
	files := strings.builder_make(context.temp_allocator)
	agents := strings.builder_make(context.temp_allocator)
	for a in attachments {
		if strings.builder_len(files) > 0 { strings.write_byte(&files, ',') }
		fmt.sbprintf(&files, `{{"uri":%s,"name":%s}}`, jquote(a.uri), jquote(a.name))
	}
	for &m in mentions {
		mention, ok := mention_json(&m, text)
		if !ok { continue }   // (taken out of the text since)
		list := m.kind == .File ? &files : &agents
		if strings.builder_len(list^) > 0 { strings.write_byte(list, ',') }
		if m.kind == .File {
			fmt.sbprintf(list, `{{"uri":%s,"name":%s,"mention":%s}}`, jquote(m.target), jquote(m.name), mention)
		} else {
			fmt.sbprintf(list, `{{"name":%s,"mention":%s}}`, jquote(m.target), mention)
		}
	}
	out := ""
	if strings.builder_len(files) > 0 { out = fmt.tprintf(`,"files":[%s]`, strings.to_string(files)) }
	if strings.builder_len(agents) > 0 { out = fmt.tprintf(`%s,"agents":[%s]`, out, strings.to_string(agents)) }
	return out
}


// Over the text of the composer, in its well.
attachments_row :: proc(app: ^App, em: f32) {
	if len(app.cx.attachments) == 0 { return }
	sc := ui.scale()
	refs := make([dynamic]Image_Ref, context.temp_allocator)
	for a in app.cx.attachments { if a.ref.key != 0 { append(&refs, a.ref) } }
	if len(refs) > 0 {
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row(id = "###att_imgs") {
			ui.spacer(ui.px(em * 0.8))
			ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
			if ui.column() { image_strip(app, "###att", refs[:], ATTACH_THUMB_W_PX * sc, ATTACH_THUMB_H_PX * sc) }
		}
		ui.spacer(ui.px(em * 0.25))
	}
	ui.next({width = ui.fill(), height = ui.children_sum(), gap = {em * 0.4, em * 0.3}})
	gone := -1
	if ui.flow({em * 0.4, em * 0.3}, "###att_names") {
		for a, i in app.cx.attachments {
			ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###att%d", i)) {
				ui.spacer(ui.px(em * 0.8))
				text("n", fmt.tprintf("%s  %s", a.name, kfmt(f64(a.size))), hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.2))
				if glyph_button("###x", ICO_CANCEL, math.round(em * 1.3)).clicked { gone = i }
			}
		}
	}
	if gone >= 0 {
		delete(app.cx.attachments[gone].name)
		delete(app.cx.attachments[gone].uri)
		ordered_remove(&app.cx.attachments, gone)
	}
}
