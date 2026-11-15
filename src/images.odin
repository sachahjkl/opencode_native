// Images: those attached to prompts, those tools hand back (screenshots, images read), and projects' logos. Their textures
// are the toolkit's picture cache (gt:pictures, app.pictures: size classes, a byte budget, decodes off the interface's
// thread); this file says which bytes an image is (its file, base64 text, a data URL) and how it is shown (src/md/features/images.md).
// Thumbnails open the viewer, a dialog exactly around the image fitted to the window, at the size the person chose; both copy
// the image (image_copy).
package ocn

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:hash"
import "core:math"
import "gt:image"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "gt:config"
import "gt:draw"
import "gt:platform"
import "gt:render"
import "gt:ui"
import pictures "gt:pictures"
import lucide "gt:lucide"
import i18n "gt:i18n"

// Odd 64-bit constants that spread the bits of what they multiply.
HASH_MIX_A :: 0x9e3779b97f4a7c15
HASH_MIX_B :: 0xc2b2ae3d27d4eb4f

Image_Encoding :: enum i32 { Bytes = 0, Base64 = 1, Data_Url = 2 }

// An image somewhere in the data: its text (base64 or a data URL, owned by whoever holds the reference), its key.
Image_Ref :: struct {
	key:      u64,
	data:     string,
	encoding: Image_Encoding,
	mime:     string,
	name:     string,
}

IMAGE_KEY_SAMPLE_BYTES :: 4096

// (the key hashes the first and last 4 KiB and the length: images of several MiB are read again with every page)
image_ref :: proc(data: string, encoding: Image_Encoding, mime, name: string) -> Image_Ref {
	b := transmute([]u8)data
	n := len(b)
	k := hash.fnv64a(b[:min(n, IMAGE_KEY_SAMPLE_BYTES)]) ~ hash.fnv64a(b[max(0, n - IMAGE_KEY_SAMPLE_BYTES):]) * 31 ~ u64(n) * HASH_MIX_A
	return {key = k | 1, data = data, encoding = encoding, mime = mime, name = name}
}

// A copy that owns its data, mime and name (image_ref_delete frees them).
image_ref_clone :: proc(ref: Image_Ref, allocator := context.allocator) -> Image_Ref {
	if ref.key == 0 { return {} }
	return {key = ref.key, data = strings.clone(ref.data, allocator), encoding = ref.encoding, mime = strings.clone(ref.mime, allocator), name = strings.clone(ref.name, allocator)}
}

image_ref_delete :: proc(ref: ^Image_Ref, allocator := context.allocator) {
	delete(ref.data, allocator)
	delete(ref.mime, allocator)
	delete(ref.name, allocator)
	ref^ = {}
}

// The file's bytes of `ref`: its own data when it is Bytes, else its base64 decoded in `allocator` (`owned`). Text that is
// no base64 is given as it is: the cache then says it is no picture file.
image_bytes :: proc(ref: Image_Ref, allocator := context.allocator) -> (data: []u8, owned: bool) {
	raw := transmute([]u8)ref.data
	if ref.encoding == .Bytes { return raw, false }
	text := ref.data
	if ref.encoding == .Data_Url {
		comma := strings.index_byte(text, ',')
		if comma < 0 { return raw, false }
		text = text[comma + 1:]
	}
	// (base64 split over lines, as a mail or a pasted block holds it)
	if strings.contains_any(text, " \n\r\t") {
		clean := strings.builder_make(0, len(text), context.temp_allocator)
		for c in transmute([]u8)text { if c != ' ' && c != '\n' && c != '\r' && c != '\t' { strings.write_byte(&clean, c) } }
		text = strings.to_string(clean)
	}
	decoded, err := base64.decode(text, allocator = allocator)
	if err != nil { return raw, false }   // (base64.decode freed its buffer)
	return decoded, true
}

// The picture of `ref` in the toolkit's cache, for a place whose longest side is `need` frame pixels (0: the whole image, for
// the viewer); nil: no image. Its bytes are made only when the cache does not hold that size: its base64 is not decoded at
// each frame.
picture :: proc(app: ^App, ref: Image_Ref, need: f32) -> ^pictures.Picture {
	if ref.key == 0 || ref.data == "" { return nil }
	if p := pictures.get(&app.pictures, ref.key, nil, need); p != nil { return p }
	h := runtime.heap_allocator()
	data, owned := image_bytes(ref, h)
	defer if owned { delete(data, h) }
	return pictures.get(&app.pictures, ref.key, data, need)
}

// What a picture that cannot be shown says of itself.
picture_failed_words :: proc(p: ^pictures.Picture) -> string {
	return fmt.tprintf(i18n.tr("image unreadable: %s"), pictures.failure_words(p.why))
}

// A copy for the clipboard: the file decoded whole on the chores (heap; copy_job_free).
@(private = "file")
Copy_Job :: struct { app: ^App, ref: Image_Ref, img: image.Image, ok: bool }

// The image's pixels on the system's clipboard, at the size of its file. (The cache's textures are scaled down, and the
// GPU's are not read back: the file is decoded again whole, on the chores.)
image_copy :: proc(app: ^App, ref: Image_Ref) {
	if ref.key == 0 || ref.data == "" { return }
	h := runtime.heap_allocator()
	job := new(Copy_Job, h)
	job^ = {app = app, ref = image_ref_clone(ref, h)}
	ui.task(&app.state, proc(data: rawptr) {
		j := (^Copy_Job)(data)
		h := runtime.heap_allocator()
		bytes, owned := image_bytes(j.ref, h)
		defer if owned { delete(bytes, h) }
		j.img, _, j.ok = image.decode(bytes, h)
	}, proc(data: rawptr, _: u64) {
		j := (^Copy_Job)(data)
		defer copy_job_free(j)
		app := j.app
		w, h := j.img.width, j.img.height
		switch {
		case !j.ok || w == 0 || h == 0: ui.announce(&app.announcer, .Bad, i18n.tr("The image could not be copied: it is unreadable"))
		case !platform.clipboard_set_image(app.win, {rgba = j.img.pixels, size = {w, h}}): ui.announce(&app.announcer, .Bad, i18n.tr("The image could not be copied"))
		case: ui.announce(&app.announcer, .Good, i18n.tr("Image copied"))
		}
	}, job, copy_job_free)
}

@(private = "file")
copy_job_free :: proc(data: rawptr) {
	j := (^Copy_Job)(data)
	h := runtime.heap_allocator()
	image.destroy(&j.img, h)
	image_ref_delete(&j.ref, h)
	free(j, h)
}

////////////////////////////////
// Boxes

HEX_IMAGE_PENDING     :: 0x0b0b0bff
HEX_IMAGE_FAILED      :: 0x140b0bff
HEX_IMAGE_FAILED_TEXT :: 0xc08080ff
SHIMMER_RATE          :: 0.002   // radians per millisecond
THUMB_PENDING_SCALE   :: 0.6     // of the room given, until its size is known

@(private = "file")
Image_Draw :: struct { tex: render.Texture, radius: f32, frame: bool, state: pictures.Picture_State }

@(private = "file")
image_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Image_Draw)(user)
	s := ui.scale()
	r := b.rect
	rad := d.radius * s * corners()
	if d.frame { draw.box_shadow(dc, draw.rect_shift(r, {0, 2 * s}), radii4(rad), 5 * s, {0, 0, 0, 0.6}) }
	switch d.state {
	case .Ready:
		draw.image(dc, d.tex, r, {}, draw.WHITE, rad)
		if d.frame { draw.rect(dc, r, {1, 1, 1, 0.08 + 0.18 * b.hot_t}, rad, max(1, math.round(s))) }
	case .Pending:
		draw_well(dc, r, rad, hex(HEX_IMAGE_PENDING))
		// a slow shimmer while it decodes
		t := f32(ui.now_ms()) * SHIMMER_RATE
		x := r.min.x + (r.max.x - r.min.x) * (0.5 + 0.5 * math.sin(t))
		draw.rect(dc, {{x - 20 * s, r.min.y + 2 * s}, {x + 20 * s, r.max.y - 2 * s}}, {1, 1, 1, 0.03}, rad, 0, 14 * s)
	case .Failed:
		draw_well(dc, r, rad, hex(HEX_IMAGE_FAILED))
	}
}

// A thumbnail of `ref` fitting `max_w` x `max_h` (frame pixels), clickable: a click opens the viewer.
image_thumb :: proc(app: ^App, id: string, ref: Image_Ref, max_w, max_h: f32) -> ui.Signal {
	p := picture(app, ref, max(max_w, max_h))
	w, h := max_w * THUMB_PENDING_SCALE, max_h * THUMB_PENDING_SCALE
	state := pictures.Picture_State.Pending
	tex: render.Texture
	if p != nil {
		state, tex = p.state, p.texture
		if p.state == .Ready {
			k := min(max_w / f32(p.size.x), max_h / f32(p.size.y), 1 * ui.scale())
			w, h = math.round(f32(p.size.x) * k), math.round(f32(p.size.y) * k)
		}
	}
	if state == .Pending { animate(app) }
	ui.next({width = ui.px(w), height = ui.px(h), cursor = .Hand})
	ui.a11y({role = .Button, name = ref.name != "" ? ref.name : i18n.tr("Image")})
	b := ui.build_box({.Clickable, .Focusable}, id)
	d := ui.frame_new(Image_Draw)
	d^ = {tex = tex, radius = 6, frame = true, state = state}
	b.custom = image_draw
	b.custom_user = d
	sig := ui.signal(b)
	if sig.clicked && state == .Ready { image_view_open(app, ref) }
	// (before the message's: the innermost takes the right press)
	if state != .Failed { ctx_check(app, b, .Image, image = ref) }
	if state == .Failed {
		if ui.parent(b) {
			em := ui.font_size()
			ui.next({width = ui.fill(), height = ui.fill(), fg = hex(HEX_IMAGE_FAILED_TEXT), font_size = math.round(em * FS_SMALL), text_align = .Center})
			ui.build_box({.Draw_Text}, fmt.tprintf("%s###f", label_safe(picture_failed_words(p))))
		}
	}
	return sig
}

// A row of thumbnails that wraps (frame pixels for the size of each).
image_strip :: proc(app: ^App, id: string, refs: []Image_Ref, max_w, max_h: f32) {
	if len(refs) == 0 { return }
	em := ui.font_size()
	ui.next({width = ui.fill(), height = ui.children_sum()})
	if ui.flow({em * 0.5, em * 0.5}, id) {
		for ref, i in refs { image_thumb(app, fmt.tprintf("###img%d", i), ref, max_w, max_h) }
	}
}

// A small square logo (a project's), drawn from its texture; nothing while it decodes.
logo_of :: proc(app: ^App, id: string, ref: ^Image_Ref, size: f32) -> bool {
	if ref == nil { return false }
	p := picture(app, ref^, size)
	if p == nil || p.state != .Ready { return false }
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Image_Draw)
	d^ = {tex = p.texture, radius = 0.18 * size / ui.scale(), state = .Ready}
	b.custom = image_draw
	b.custom_user = d
	return true
}

////////////////////////////////
// The viewer

// --image=<file>: the viewer opens on a file, once decoded.
image_view_start :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("Cannot read %s"), path)); return }
	app.viewer.start = image_ref(string(data), .Bytes, "image", strings.clone(filepath.base(path)))
}

// What --image= waits for: open once decoded, said and given up on when it cannot be. (An empty file has nothing to decode: nothing would
// ever come, and the wait would draw frames for good.)
image_view_wait :: proc(app: ^App) {
	if app.viewer.start.key == 0 { return }
	s := picture(app, app.viewer.start, 0)
	if s != nil && s.state == .Pending {
		animate(app)
		return
	}
	if s != nil && s.state == .Ready {
		image_view_open(app, app.viewer.start)
	} else {
		ui.announce(&app.announcer, .Bad, fmt.tprintf("%s: %s", app.viewer.start.name, s != nil ? picture_failed_words(s) : i18n.tr("image unreadable: the file is empty")))
	}
	app.viewer.start.key = 0
}

// The viewer, on the whole image (decoded now if the thumbnail's was all there was: it waits for it).
image_view_open :: proc(app: ^App, ref: Image_Ref) {
	_ = picture(app, ref, 0)
	image_ref_delete(&app.viewer.ref)
	app.viewer.ref = image_ref_clone(ref)
	ui.preview_reset(&app.viewer.view)
	app.viewer.focus = true
	app.viewer.resize_from = {}
	app.viewer.grown = false
	ui.view_open(&app.program_views, IMAGE_VIEW, app)
}

image_view_shown :: proc(app: ^App) -> bool { return ui.view_is_open(&app.program_views, IMAGE_VIEW) }

IMAGE_NAME_CHARS :: 80
HEX_VIEWER_NAME  :: 0xe0e0e0ff
HEX_VIEWER_WELL  :: 0x070707ff
VIEWER_PAD_EM    :: 0.5   // around the picture (the edges' grips are there)
VIEWER_BAR_EM    :: 2.6   // the name, the size and the buttons, under the picture
VIEWER_MIN_W_EM  :: 26    // what the bar needs: a small picture gets room on its sides
VIEWER_SCALE_MIN :: 0.2   // the smallest viewer, of the most the window gives a picture (conversation.image_viewer_size)
VIEW_NATIVE_MAX  :: 8     // times the image's pixels at the interface's scale (ui.preview's zoom_max)

// Where the viewer is, from the image alone: the dialog hugs the picture, so all the black around it is outside the viewer.
Viewer_Frame :: struct {
	full:    [2]f32,   // the picture at the scale 1: the most `room` gives it
	picture: [2]f32,   // its box: `full` times the scale chosen, whole pixels
	panel:   [2]f32,   // the dialog: the picture and the chrome, never narrower than the bar needs (nor than the room)
	fit:     f32,      // frame pixels per image pixel, at the zoom 1
}

// `image`: its pixels; `room`: what the window gives the dialog; `chrome`: what the dialog takes beside the picture; `scale`: the size the
// person chose (conversation.image_viewer_size), a share of the room. A picture opens no larger than its pixels times the interface's
// scale (a small one is not blown up); `grown`: the person dragged the viewer's grips since it opened, and it takes what they ask, up to
// the room.
viewer_frame :: proc(image, room, chrome: [2]f32, ui_scale, scale, min_w: f32, grown := false) -> Viewer_Frame {
	inner := [2]f32{max(1, room.x - chrome.x), max(1, room.y - chrome.y)}
	most := min(inner.x / image.x, inner.y / image.y)
	f: Viewer_Frame
	f.full = image * most
	f.fit = most * clamp(scale, VIEWER_SCALE_MIN, 1)
	if !grown { f.fit = min(f.fit, ui_scale) }
	f.picture = {max(1, math.round(image.x * f.fit)), max(1, math.round(image.y * f.fit))}
	f.panel = {max(f.picture.x + chrome.x, min(min_w, room.x)), f.picture.y + chrome.y}
	return f
}

// The scale an edge or a corner dragged by `delta` (frame pixels, the dialog's size since the press) asks for, from `from`: by the side
// that moved most, the other follows the picture's shape.
viewer_scale_of :: proc(delta, full: [2]f32, from: f32) -> f32 {
	a := abs(delta.x) >= abs(delta.y) ? 0 : 1
	return clamp(from + delta[a] / full[a], VIEWER_SCALE_MIN, 1)
}

// Whether `p` (from the view's corner) misses the picture: `picture` its size, its centre `pan` from the view's, clipped by the view.
viewer_outside :: proc(p, view, picture, pan: [2]f32) -> bool {
	c := view * 0.5 + pan
	lo := [2]f32{max(0, c.x - picture.x * 0.5), max(0, c.y - picture.y * 0.5)}
	hi := [2]f32{min(view.x, c.x + picture.x * 0.5), min(view.y, c.y + picture.y * 0.5)}
	return !(p.x >= lo.x && p.x < hi.x && p.y >= lo.y && p.y < hi.y)
}

// The black behind the picture, where it is zoomed out or moved (ui.preview draws only the picture). Its corners are
// concentric with the dialog's: inset by the padding, a square corner would show a corner in a corner.
@(private = "file")
view_well_draw :: proc(b: ^ui.Box, _: rawptr, dc: ^draw.Context) {
	// (the state of the window drawn, as corners(): ui.current_state is the open build's, nil while a frame is drawn)
	app := the_app
	if app == nil { ui.machined_well(dc, b.rect, 0, hex(HEX_VIEWER_WELL)); return }
	state := view_state(app, IMAGE_VIEW)
	radius: f32
	for a := b.parent; a != nil; a = a.parent {
		if a.name != fmt.tprintf("modal_view_%s", IMAGE_VIEW) { continue }
		inset := max(b.rect.min.x - a.rect.min.x, b.rect.min.y - a.rect.min.y)
		radius = ui.concentric_radius(ui.box_drawn_radii(state, a)[0], inset)
		break
	}
	ui.machined_well(dc, b.rect, radius, hex(HEX_VIEWER_WELL))
}

// The image viewer (IMAGE_VIEW): what it shows, and how it is zoomed, moved and sized. As a dialog it hugs its picture
// (ui.view_size, at each build); docked, floating or in a window of its own, the picture fits the room it is given.
Image_Viewer :: struct {
	ref:         Image_Ref,   // what is shown: its picture in the cache, what Copy decodes again whole (its data and name owned)
	view:        ui.Preview,  // the zoom (times what fits) and the pan of the picture
	focus:       bool,        // just opened: the keyboard goes to the picture (its keys zoom and move it)
	resize_from: [3]f32,      // a grip of the viewer held: the dialog's size (ems) and scale at its press ({}: none)
	grown:       bool,        // the viewer's grips were dragged since it opened: its picture may pass its pixels (viewer_frame)
	start:       Image_Ref,   // --image=<file>: opened in the viewer once it is decoded (its data owned)
}

// An image still being decoded: a moment.
@(private = "file")
image_viewer_wait :: proc(app: ^App, em: f32) {
	animate(app)
	ui.spacer(ui.px(em))
	ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
	if ui.tags("weak") { ui.label(fmt.tprintf("%s###view_wait", i18n.tr("Opening the image…"))) }
	ui.spacer(ui.px(em))
}

image_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	sc := ui.scale()
	// what is shown: its pixels, and its texture
	e := picture(app, app.viewer.ref, 0)
	if e == nil || e.state == .Failed { ui.view_end(v, ui.VIEW_CANCELLED); return }
	name := app.viewer.ref.name != "" ? app.viewer.ref.name : i18n.tr("image")
	ui.view_title(v, ellipsize(name, IMAGE_NAME_CHARS))
	if e.state == .Pending { image_viewer_wait(app, em); return }
	source := [2]f32{f32(e.size.x), f32(e.size.y)}
	pad, bar := math.round(em * VIEWER_PAD_EM), math.round(em * VIEWER_BAR_EM)
	chrome := [2]f32{2 * pad, pad + bar}
	min_w := math.round(em * VIEWER_MIN_W_EM)
	dialog := v.presentation == .Dialog
	f: Viewer_Frame
	if dialog {
		// (the dialog hugs the picture: the share of the window the person chose, its pixels at most until they grow it)
		room := built_state(app).window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
		// (the view's header is the dialog's too: as tall as the last layout made it, its title wrapped or not)
		head := ui.prev_box("###view_header")
		head_h := head != nil ? head.rect.max.y - head.rect.min.y : ui.dense(em * ui.DIALOG_HEADER_EM)
		f = viewer_frame(source, room, chrome + {0, head_h}, sc, app.prefs.viewer_scale, min_w, app.viewer.grown)
		asked := f.panel / em
		ui.view_size(v, asked.x, asked.y)
		// (its grips: the size the person gives it, while the press lasts, is the scale asked)
		if size := ui.view_dialog_size(&app.program_views, IMAGE_VIEW); size != {} && size != asked { viewer_resized(app, size, asked, f, em) }
		viewer_resize_end(app)
	} else {
		f = viewer_frame(source, ui.view_room(v), chrome, sc, 1, min_w, grown = true)
	}
	view := f.picture
	closing := false
	{
		// a press around the picture closes the viewer, as one outside the dialog does (the buttons and the grips are over it)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		around := ui.build_box({.Clickable}, "###view_around")
		if ui.signal(around).pressed { closing = true }
		if ui.parent(around) {
			ui.spacer(ui.px(pad))
			ui.next({width = ui.fill(), height = ui.px(view.y), axis = .X})
			if ui.row() {
				ui.spacer(ui.fill())
				// (the box is the picture's shape: what fits is f.fit, past its pixels as the viewer's size asks: grow)
				pv := &app.viewer.view
				pv_o := ui.Preview_Options{grow = true, zoom_max = VIEW_NATIVE_MAX * sc}
				ui.next({width = ui.px(view.x), height = ui.px(view.y)})
				well := ui.build_box({}, "###view_well")
				well.custom = view_well_draw
				if ui.parent(well) {
					ui.next({width = ui.fill(), height = ui.fill()})
					ui.a11y({role = .Image, name = app.viewer.ref.name != "" ? app.viewer.ref.name : i18n.tr("Image")})
					res := ui.preview_image("###view", pv, e.texture, source, pv_o)
					if app.viewer.focus { ui.set_focus(res.box.key); app.viewer.focus = false }
					b := res.box
					on := ui.pointer_on(b)
					picture := source * res.fit * pv.zoom
					if on && ui.mouse_pressed(.Left) && viewer_outside(ui.mouse_pos() - b.rect.min, view, picture, pv.pan) { closing = true }
					if ui.context_take(b) { ctx_open(app, .Image, image = app.viewer.ref) }
					if ui.key_press(.C, {.Ctrl}) { image_copy(app, app.viewer.ref) }
				}
				ui.spacer(ui.fill())
			}
			ui.next({width = ui.fill(), height = ui.px(bar), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em))
				text("n", ellipsize(name, IMAGE_NAME_CHARS), hex(HEX_VIEWER_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
				ui.spacer(ui.px(em * 0.6))
				zoom := f.fit * app.viewer.view.zoom / sc * 100
				dims := fmt.tprintf("%d × %d  ·  %s", int(source.x), int(source.y), i18n.percent(f64(zoom) / 100))
				text("d", dims, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.px(em * 0.8))
				bh := math.round(em * BUTTON_SMALL_H_EM)
				most := max(1, VIEW_NATIVE_MAX * sc / f.fit)   // (as ui.preview's: its zoom_max over what fits)
				if ui.button("zoom_out", "−", o = {height = bh}).clicked { ui.preview_zoom_to(&app.viewer.view, app.viewer.view.zoom / ui.PREVIEW_ZOOM_STEP, ui.PREVIEW_ZOOM_MIN, most, {}) }
				ui.spacer(ui.px(em * 0.3))
				if ui.button("zoom_in", "+", o = {height = bh}).clicked { ui.preview_zoom_to(&app.viewer.view, app.viewer.view.zoom * ui.PREVIEW_ZOOM_STEP, ui.PREVIEW_ZOOM_MIN, most, {}) }
				ui.spacer(ui.px(em * 0.3))
				if ui.button("zoom_fit", i18n.tr("Fit"), o = {height = bh}).clicked { ui.preview_reset(&app.viewer.view) }
				ui.spacer(ui.px(em * 0.8))
				if ui.button("close", i18n.tr("Close"), lucide.X, {height = bh}).clicked { ui.view_end(v, ui.VIEW_CANCELLED) }
				ui.spacer(ui.px(em))
			}
		}
	}
	// (a press that closes the menu over the viewer is the menu's)
	if closing && !ui.menu_any_open() { ui.view_end(v, ui.VIEW_CANCELLED) }
}

// The grips of the dialog moved: the picture takes the new size, its shape kept (the scale from the size at the press, by
// the side that moved most). (`size`, `asked`: the dialog's, in ems)
@(private = "file")
viewer_resized :: proc(app: ^App, size, asked: [2]f32, f: Viewer_Frame, em: f32) {
	// (from the size shown: a picture held to its pixels shows less than the share saved)
	if app.viewer.resize_from == {} { app.viewer.resize_from = {asked.x, asked.y, f.picture.x / f.full.x} }
	app.viewer.grown = true
	from := app.viewer.resize_from
	app.prefs.viewer_scale = viewer_scale_of((size - from.xy) * em, f.full, from.z)
}

// The grip let go: the size chosen is saved (conversation.image_viewer_size), for the next pictures too.
@(private = "file")
viewer_resize_end :: proc(app: ^App) {
	if ui.active_key() != 0 || app.viewer.resize_from == {} { return }
	app.viewer.resize_from = {}
	if abs(f64(app.prefs.viewer_scale) - config.float_of(&app.cfg_prefs, "conversation.image_viewer_size")) > SLIDER_EPSILON {
		pref_set_float(app, "conversation.image_viewer_size", app.prefs.viewer_scale)
	}
}
