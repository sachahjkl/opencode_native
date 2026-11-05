// What goes with a prompt: images pasted or dropped on the composer. They show as thumbnails over it until the prompt is
// sent. Files that are not images go in as their path, which the agent can read. A pasted image goes as a data URL.
package occ

import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:platform"
import "gt:ui"

Attachment :: struct {
	name: string,      // (owned)
	uri:  string,      // data:image/...;base64,... (owned)
	size: int,         // of the image, in bytes
	ref:  Image_Ref,   // its thumbnail
}

@(private = "file")
attach_bytes :: proc(app: ^App, data: []u8, mime, name: string) {
	if len(data) > ATTACH_MAX_BYTES { ui.toast(.Warn, "%s is too large to attach", name); return }
	b64, err := base64.encode(data, allocator = context.temp_allocator)
	if err != nil { return }
	uri := strings.concatenate({"data:", mime, ";base64,", b64})
	stored_name := strings.clone(name)
	append(&app.cx.attachments, Attachment{name = stored_name, uri = uri, size = len(data), ref = image_ref(uri, .Data_Url, mime, stored_name)})
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

// A file given to the composer: an image is attached, anything else goes in the text as its path.
attach_path :: proc(app: ^App, path: string) {
	if mime := image_mime(path); mime != "" {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err == nil { attach_bytes(app, data, mime, base_name(path)); return }
	}
	area_insert(&app.composer, fmt.tprintf("%s ", path))
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

// What the JSON of a prompt says of them (empty: none), and they are gone from the composer.
attachments_take :: proc(app: ^App) -> string {
	if len(app.cx.attachments) == 0 { return "" }
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `,"files":[`)
	for a, i in app.cx.attachments {
		if i > 0 { strings.write_byte(&b, ',') }
		fmt.sbprintf(&b, `{{"uri":%s,"name":%s}}`, jquote(a.uri), jquote(a.name))
	}
	strings.write_byte(&b, ']')
	attachments_clear(app)
	return strings.to_string(b)
}

attachments_clear :: proc(app: ^App) {
	for a in app.cx.attachments { delete(a.name); delete(a.uri) }
	clear(&app.cx.attachments)
}

// Over the text of the composer, in its well.
attachments_row :: proc(app: ^App, em: f32) {
	if len(app.cx.attachments) == 0 { return }
	sc := ui.scale()
	refs := make([]Image_Ref, len(app.cx.attachments), context.temp_allocator)
	for a, i in app.cx.attachments { refs[i] = a.ref }
	ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
	if ui.row(id = "###att_imgs") {
		ui.spacer(ui.px(em * 0.8))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .Y})
		if ui.column() { image_strip(app, "###att", refs, ATTACH_THUMB_W_PX * sc, ATTACH_THUMB_H_PX * sc) }
	}
	ui.spacer(ui.px(em * 0.25))
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
