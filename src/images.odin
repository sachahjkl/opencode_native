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
// the viewer); nil: no image. Its text goes as it is: the cache's chores turn base64 into the file (pictures' prepare), so
// the interface's thread never decodes it, and the cache copies it only at a miss.
picture :: proc(app: ^App, ref: Image_Ref, need: f32) -> ^pictures.Picture {
	if ref.key == 0 || ref.data == "" { return nil }
	data := transmute([]u8)ref.data
	switch ref.encoding {
	case .Bytes:    return pictures.get(&app.pictures, ref.key, data, need)
	case .Base64:   return pictures.get(&app.pictures, ref.key, data, need, image_file_of_base64)
	case .Data_Url: return pictures.get(&app.pictures, ref.key, data, need, image_file_of_data_url)
	}
	return nil
}

// pictures' prepare, on its chores: the file of a base64 text, or of a data URL; text that is no base64 is no picture.
// (only a file of `allocator`: the cache frees what prepare gives, never the text it gave)
@(private = "file")
image_file_of_base64 :: proc(data: []u8, allocator: runtime.Allocator) -> ([]u8, bool) {
	file, owned := image_bytes({data = string(data), encoding = .Base64}, allocator)
	return owned ? file : nil, owned
}

@(private = "file")
image_file_of_data_url :: proc(data: []u8, allocator: runtime.Allocator) -> ([]u8, bool) {
	file, owned := image_bytes({data = string(data), encoding = .Data_Url}, allocator)
	return owned ? file : nil, owned
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
		draw_well(dc, r, rad, ui.theme_color("well"))
		// a slow shimmer while it decodes
		t := f32(ui.now_ms()) * SHIMMER_RATE
		x := r.min.x + (r.max.x - r.min.x) * (0.5 + 0.5 * math.sin(t))
		draw.rect(dc, {{x - 20 * s, r.min.y + 2 * s}, {x + 20 * s, r.max.y - 2 * s}}, {1, 1, 1, 0.03}, rad, 0, 14 * s)
	case .Failed:
		draw_well(dc, r, rad, between("well", "hue_red", 0.05))
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
			ui.next({width = ui.fill(), height = ui.fill(), fg = ui.theme_color("bad text"), font_size = math.round(em * FS_SMALL), text_align = .Center})
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
	if ui.flow({em * ui.SPACE_2, em * ui.SPACE_2}, id) {
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
	app.viewer.grown = false
	app.viewer.opened = true
	ui.view_open(&app.program_views, IMAGE_VIEW, app)
}

image_view_shown :: proc(app: ^App) -> bool { return ui.view_is_open(&app.program_views, IMAGE_VIEW) }

IMAGE_NAME_CHARS :: 80
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
// scale (a small one is not blown up; the person's grips can make it larger: image_view).
viewer_frame :: proc(image, room, chrome: [2]f32, ui_scale, scale, min_w: f32) -> Viewer_Frame {
	inner := [2]f32{max(1, room.x - chrome.x), max(1, room.y - chrome.y)}
	most := min(inner.x / image.x, inner.y / image.y)
	f: Viewer_Frame
	f.full = image * most
	f.fit = min(most * clamp(scale, VIEWER_SCALE_MIN, 1), ui_scale)
	f.picture = {max(1, math.round(image.x * f.fit)), max(1, math.round(image.y * f.fit))}
	f.panel = {max(f.picture.x + chrome.x, min(min_w, room.x)), f.picture.y + chrome.y}
	return f
}

// The share of the room a picture `full` large at the scale 1 takes when it fits `area` (frame pixels: the picture's area in the
// dialog the person sized): what the next pictures open at.
viewer_scale_of :: proc(area, full: [2]f32) -> f32 {
	return clamp(min(area.x / full.x, area.y / full.y), VIEWER_SCALE_MIN, 1)
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
	if app == nil { ui.machined_well(dc, b.rect, 0, ui.theme_color("well")); return }
	state := view_state(app, IMAGE_VIEW)
	radius: f32
	for a := b.parent; a != nil; a = a.parent {
		if a.name != fmt.tprintf("modal_view_%s", IMAGE_VIEW) { continue }
		inset := max(b.rect.min.x - a.rect.min.x, b.rect.min.y - a.rect.min.y)
		radius = ui.concentric_radius(ui.box_drawn_radii(state, a)[0], inset)
		break
	}
	ui.machined_well(dc, b.rect, radius, ui.theme_color("well"))
}

// The image viewer (IMAGE_VIEW): what it shows, and how it is zoomed, moved and sized. As a dialog it opens around its
// picture (ui.view_size) and keeps the size the person gives it; in every presentation the picture fits its area.
Image_Viewer :: struct {
	ref:         Image_Ref,   // what is shown: its picture in the cache, what Copy decodes again whole (its data and name owned)
	view:        ui.Preview,  // the zoom (times what fits) and the pan of the picture
	focus:       bool,        // just opened: the keyboard goes to the picture (its keys zoom and move it)
	grown:       bool,        // the person sized the dialog since it opened: it keeps their size, no longer the picture's
	opened:      bool,        // a picture was just given to it: the size the person gave the last one goes (image_view)
	asked:       [2]f32,      // the size its last build asked (ui.view_size, ems): the one this build is laid out at
	start:       Image_Ref,   // --image=<file>: opened in the viewer once it is decoded (its data owned)
}

// An image still being decoded: a moment.
@(private = "file")
image_viewer_wait :: proc(app: ^App, em: f32) {
	animate(app)
	ui.space(ui.SPACE_4)
	ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
	if ui.tags("weak") { ui.label(fmt.tprintf("%s###view_wait", i18n.tr("Opening the image…"))) }
	ui.space(ui.SPACE_4)
}

image_view :: proc(v: ^ui.View, app: ^App) {
	em := ui.font_size()
	sc := ui.scale()
	// what is shown: its pixels, and its texture
	e := picture(app, app.viewer.ref, 0)
	if e == nil || e.state == .Failed { ui.view_end(v, ui.VIEW_CANCELLED); return }
	name := app.viewer.ref.name != "" ? app.viewer.ref.name : i18n.tr("image")
	ui.view_title(v, ellipsize(name, IMAGE_NAME_CHARS))
	if e.state == .Pending {
		// (it opens around its picture: not at the kind's size with "Opening the image…", then around it)
		ui.view_not_ready(v)
		image_viewer_wait(app, em)
		return
	}
	source := [2]f32{f32(e.size.x), f32(e.size.y)}
	pad, bar := math.round(em * VIEWER_PAD_EM), math.round(em * VIEWER_BAR_EM)
	chrome := [2]f32{2 * pad, pad + bar}
	min_w := math.round(em * VIEWER_MIN_W_EM)
	if v.presentation == .Dialog {
		// (the dialog hugs the picture: the share of the window the person chose, its pixels at most)
		room := built_state(app).window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
		// (the view's header is the dialog's too: as tall as the last layout made it, its title wrapped or not)
		head := ui.prev_box("###view_header")
		head_h := head != nil ? head.rect.max.y - head.rect.min.y : ui.dense(em * ui.DIALOG_HEADER_EM)
		// (the dialog's border is inside its size: the toolkit's border_inset, private to it, for a panel that draws one.
		// Not counted, the picture's area was that much smaller than the picture)
		border := max(1, math.round(sc))
		frame_chrome := chrome + {2 * border, head_h + 2 * border}
		f := viewer_frame(source, room, frame_chrome, sc, app.prefs.viewer_scale, min_w)
		asked := f.panel / em
		// (a size the person gave it with its grips wins, as the toolkit keeps it: asking for the hug again would take it
		// back. The picture then fits the area their size leaves, and that area is the share the next pictures open at.
		// view_size first: it drops the size remembered from another opening, which is not this one's resize. It drops it
		// only when the size asked changes: a picture given to the viewer still open asks once for the kind's size first)
		if app.viewer.opened { ui.view_size(v, 0, 0); app.viewer.opened, app.viewer.asked = false, {} }
		if !app.viewer.grown {
			// (a size asked in a build is the next build's: this one was laid out at the size asked before. A dialog of a
			// known size shows in its first build, so that one waits for the hug)
			if app.viewer.asked != asked { ui.view_not_ready(v) }
			ui.view_size(v, asked.x, asked.y)
		}
		app.viewer.asked = asked
		size := ui.view_dialog_size(&app.program_views, IMAGE_VIEW)
		if size != {} && size != asked { app.viewer.grown = true }
		if app.viewer.grown {
			app.prefs.viewer_scale = viewer_scale_of(size * em - frame_chrome, f.full)
			viewer_resize_end(app)
		}
	}
	// (what fits, device pixels per image pixel: the preview's, from its area as laid out)
	fit := f32(1)
	closing := false
	{
		// a press around the picture closes the viewer, as one outside the dialog does (the buttons and the grips are over it)
		ui.next({width = ui.fill(), height = ui.fill(), axis = .Y})
		around := ui.build_box({.Clickable}, "###view_around")
		if ui.signal(around).pressed { closing = true }
		if ui.parent(around) {
			ui.spacer(ui.px(pad))
			// (the picture's area is all the body leaves above the bar, whatever size the dialog has: a box of the
			// picture's own size kept its height when the person made the dialog taller, and ran past its edge when the
			// picture grew wider than the dialog. Hugged, the dialog makes this area the picture's shape)
			ui.next({width = ui.fill(), height = ui.fill(), axis = .X})
			if ui.row() {
				ui.spacer(ui.px(pad))
				// (what fits the area, past its pixels as the person's size asks: grow)
				pv := &app.viewer.view
				pv_o := ui.Preview_Options{grow = true, zoom_max = VIEW_NATIVE_MAX * sc}
				ui.next({width = ui.fill(), height = ui.fill()})
				well := ui.build_box({.Clip}, "###view_well")
				well.custom = view_well_draw
				if ui.parent(well) {
					ui.next({width = ui.fill(), height = ui.fill()})
					ui.a11y({role = .Image, name = app.viewer.ref.name != "" ? app.viewer.ref.name : i18n.tr("Image")})
					res := ui.preview_image("###view", pv, e.texture, source, pv_o)
					if app.viewer.focus { ui.set_focus(res.box.key); app.viewer.focus = false }
					b := res.box
					on := ui.pointer_on(b)
					fit = res.fit
					picture := source * res.fit * pv.zoom
					if on && ui.mouse_pressed(.Left) && viewer_outside(ui.mouse_pos() - b.rect.min, b.rect.max - b.rect.min, picture, pv.pan) { closing = true }
					if ui.context_take(b) { ctx_open(app, .Image, image = app.viewer.ref) }
					if ui.key_press(.C, {.Ctrl}) { image_copy(app, app.viewer.ref) }
				}
				ui.spacer(ui.px(pad))
			}
			ui.next({width = ui.fill(), height = ui.px(bar), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.space(ui.SPACE_4)
				text("n", ellipsize(name, IMAGE_NAME_CHARS), ui.theme_color("text"), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
				ui.space(ui.SPACE_2)
				zoom := fit * app.viewer.view.zoom / sc * 100
				dims := fmt.tprintf("%d × %d  ·  %s", int(source.x), int(source.y), i18n.percent(f64(zoom) / 100))
				text("d", dims, ui.theme_color("faint text"), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
				ui.space(ui.SPACE_3)
				bh := math.round(em * BUTTON_SMALL_H_EM)
				most := max(1, VIEW_NATIVE_MAX * sc / fit)   // (as ui.preview's: its zoom_max over what fits)
				if ui.button("zoom_out", "−", o = {height = bh}).clicked { ui.preview_zoom_to(&app.viewer.view, app.viewer.view.zoom / ui.PREVIEW_ZOOM_STEP, ui.PREVIEW_ZOOM_MIN, most, {}) }
				ui.space(ui.SPACE_1)
				if ui.button("zoom_in", "+", o = {height = bh}).clicked { ui.preview_zoom_to(&app.viewer.view, app.viewer.view.zoom * ui.PREVIEW_ZOOM_STEP, ui.PREVIEW_ZOOM_MIN, most, {}) }
				ui.space(ui.SPACE_1)
				if ui.button("zoom_fit", i18n.tr("Fit"), o = {height = bh}).clicked { ui.preview_reset(&app.viewer.view) }
				ui.space(ui.SPACE_3)
				if ui.button("close", i18n.tr("Close"), lucide.X, {height = bh}).clicked { ui.view_end(v, ui.VIEW_CANCELLED) }
				ui.space(ui.SPACE_4)
			}
		}
	}
	// (a press that closes the menu over the viewer is the menu's)
	if closing && !ui.menu_any_open() { ui.view_end(v, ui.VIEW_CANCELLED) }
}

// The grip let go: the size chosen is saved (conversation.image_viewer_size), for the next pictures too.
@(private = "file")
viewer_resize_end :: proc(app: ^App) {
	if ui.active_key() != 0 { return }
	if abs(f64(app.prefs.viewer_scale) - config.float_of(&app.cfg_prefs, "conversation.image_viewer_size")) > SLIDER_EPSILON {
		pref_set_float(app, "conversation.image_viewer_size", app.prefs.viewer_scale)
	}
}
