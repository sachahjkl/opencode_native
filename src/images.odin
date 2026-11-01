// Images: those attached to prompts, those tools hand back (screenshots, images read), and projects' logos. Each is
// decoded once by the Rust library (PNG, JPEG, WebP, GIF, BMP; scaled down to fit a texture) on a worker thread, then
// kept as a texture keyed by a hash of its data. Thumbnails open a viewer that fits the image to the window.
package occ

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:thread"
import "gt:draw"
import "gt:render"
import "gt:ui"

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

Image_State :: enum u8 { Pending, Ready, Failed }

Image_Entry :: struct {
	state:   Image_State,
	tex:     render.Texture,
	w, h:    int,
	used:    u64,      // the frame it was last shown in
	error:   string,   // (owned)
}

MAX_TEXTURES :: 96
IMAGE_MAX_DIM_PX :: 2048   // what a decode scales down to, when the textures allow more

@(private = "file")
Decode_Job :: struct {
	key:      u64,
	data:     string,   // (owned copy)
	encoding: Image_Encoding,
	max_dim:  u32,
	// the answer
	w, h:     u32,
	out:      Occ_Buf,
	ok:       bool,
}

// The texture of `ref`, decoding it when first asked for (nil while it is not known yet).
image_get :: proc(app: ^App, ref: Image_Ref) -> ^Image_Entry {
	if ref.key == 0 || ref.data == "" { return nil }
	if e, ok := &app.images[ref.key]; ok {
		e.used = app.frame_no
		return e
	}
	app.images[ref.key] = {state = .Pending, used = app.frame_no}
	job := new(Decode_Job)
	job^ = {key = ref.key, data = strings.clone(ref.data), encoding = ref.encoding, max_dim = u32(min(IMAGE_MAX_DIM_PX, render.max_texture_size(&app.r)))}
	sync.atomic_add(&app.pending, 1)
	thread.create_and_start_with_poly_data(job, proc(job: ^Decode_Job) {
		r := occ_image_decode(raw_data(job.data), len(job.data), i32(job.encoding), job.max_dim, &job.w, &job.h, &job.out)
		job.ok = r == 0
		if !ui.post(&the_app.ui_state, image_decoded, job) { occ_buf_free(job.out); delete(job.data); free(job) }
	}, self_cleanup = true)
	return &app.images[ref.key]
}

// On the interface's thread: the pixels become a texture.
@(private = "file")
image_decoded :: proc(data: rawptr, word: u64) {
	app := the_app
	job := (^Decode_Job)(data)
	defer { occ_buf_free(job.out); delete(job.data); free(job) }
	sync.atomic_sub(&app.pending, 1)
	e, ok := &app.images[job.key]
	if !ok { return }
	if !job.ok || job.w == 0 || job.h == 0 {
		e.state = .Failed
		e.error = strings.clone(string(job.out.ptr[:job.out.len]))
		return
	}
	e.tex = render.create_texture_rgba(&app.r, int(job.w), int(job.h))
	if e.tex == 0 { e.state = .Failed; return }
	render.update_texture_rgba(&app.r, e.tex, 0, 0, int(job.w), int(job.h), job.out.ptr[:job.out.len])
	e.w, e.h = int(job.w), int(job.h)
	e.state = .Ready
	images_trim(app)
}

// Keeps at most MAX_TEXTURES textures: the ones shown longest ago go (they are decoded again when shown).
images_trim :: proc(app: ^App) {
	for len(app.images) > MAX_TEXTURES {
		oldest: u64
		best := max(u64)
		for k, e in app.images {
			if e.state != .Pending && e.used < best && e.used + 2 < app.frame_no { best, oldest = e.used, k }
		}
		if oldest == 0 { return }
		e := app.images[oldest]
		if e.tex != 0 { render.destroy_texture(&app.r, e.tex) }
		delete(e.error)
		delete_key(&app.images, oldest)
	}
}

////////////////////////////////
// Boxes

HEX_IMAGE_PENDING     :: 0x0b0b0bff
HEX_IMAGE_FAILED      :: 0x140b0bff
HEX_IMAGE_FAILED_TEXT :: 0xc08080ff
SHIMMER_RATE          :: 0.002   // radians per millisecond
THUMB_PENDING_SCALE   :: 0.6     // of the room given, until its size is known

@(private = "file")
Image_Draw :: struct { tex: render.Texture, radius: f32, frame: bool, state: Image_State }

@(private = "file")
image_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^Image_Draw)(user)
	s := ui.scale()
	r := b.rect
	rad := d.radius * s
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
	e := image_get(app, ref)
	w, h := max_w * THUMB_PENDING_SCALE, max_h * THUMB_PENDING_SCALE
	state := Image_State.Pending
	tex: render.Texture
	if e != nil {
		state, tex = e.state, e.tex
		if e.state == .Ready {
			k := min(max_w / f32(e.w), max_h / f32(e.h), 1 * ui.scale())
			w, h = math.round(f32(e.w) * k), math.round(f32(e.h) * k)
		}
	}
	if state == .Pending { app.animating = true }
	ui.next({width = ui.px(w), height = ui.px(h), cursor = .Hand})
	ui.a11y({role = .Button, name = ref.name != "" ? ref.name : "Image"})
	b := ui.build_box({.Clickable, .Focusable}, id)
	d := ui.frame_new(Image_Draw)
	d^ = {tex = tex, radius = 6, frame = true, state = state}
	b.custom = image_draw
	b.custom_user = d
	sig := ui.signal(b)
	if sig.clicked && state == .Ready { image_view_open(app, ref) }
	if state == .Failed {
		if ui.parent(b) {
			em := ui.font_size()
			ui.next({width = ui.fill(), height = ui.fill(), fg = hex(HEX_IMAGE_FAILED_TEXT), font_size = math.round(em * FS_SMALL), text_align = .Center})
			ui.build_box({.Draw_Text}, "image unreadable###f")
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
	e := image_get(app, ref^)
	if e == nil || e.state != .Ready { return false }
	ui.next({width = ui.px(size), height = ui.px(size)})
	b := ui.build_box({}, id)
	d := ui.frame_new(Image_Draw)
	d^ = {tex = e.tex, radius = 0.18 * size / ui.scale(), state = .Ready}
	b.custom = image_draw
	b.custom_user = d
	return true
}

////////////////////////////////
// The viewer

// --image=<file>: the viewer opens on a file, once decoded.
image_view_start :: proc(app: ^App, path: string) {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil { ui.toast(.Bad, fmt.tprintf("Cannot read %s", path)); return }
	app.view_start = image_ref(string(data), .Bytes, "image", strings.clone(filepath.base(path)))
}

image_view_open :: proc(app: ^App, ref: Image_Ref) {
	delete(app.view_name)
	app.view_key = ref.key
	app.view_name = strings.clone(ref.name)
	app.view_open = true
	app.view_zoom, app.view_pan = 1, {}
}

VIEWER_FILL      :: 0.9   // of the window
VIEWER_CHROME_EM :: 4     // what the viewer takes around the picture, in height
IMAGE_NAME_CHARS :: 80
HEX_VIEWER_NAME  :: 0xe0e0e0ff
HEX_VIEWER_WELL  :: 0x070707ff
VIEW_ZOOM_MIN    :: 0.5   // times what fits
VIEW_NATIVE_MAX  :: 8     // times the image's pixels at the interface's scale
VIEW_ZOOM_STEP   :: 1.25  // a notch of the wheel, a press of + or -
VIEW_DOUBLE_CLICK :: 2    // what a double click goes to, when what fits is already its pixels
VIEW_PAN_KEY     :: 0.1   // of the view, an arrow key

@(private = "file")
View_Draw :: struct { tex: render.Texture, size, pan: [2]f32 }

@(private = "file")
view_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^View_Draw)(user)
	r := b.rect
	draw_well(dc, r, 4 * ui.scale(), hex(HEX_VIEWER_WELL))
	c := (r.min + r.max) * 0.5 + d.pan
	draw.push_clip(dc, r)
	lo, hi := c - d.size * 0.5, c + d.size * 0.5
	draw.image(dc, d.tex, {{math.round(lo.x), math.round(lo.y)}, {math.round(hi.x), math.round(hi.y)}})
	draw.pop_clip(dc)
}

// How far the picture may go: none across a side it fits, else until its edge meets the view's.
view_pan_clamp :: proc(pan, picture, view: [2]f32) -> [2]f32 {
	reach := [2]f32{max(0, (picture.x - view.x) * 0.5), max(0, (picture.y - view.y) * 0.5)}
	return {clamp(pan.x, -reach.x, reach.x), clamp(pan.y, -reach.y, reach.y)}
}

// The zoom asked for, within its limits, keeping the point `at` of the view (from its centre) where it is.
view_zoom_to :: proc(app: ^App, zoom, max_zoom: f32, at: [2]f32) {
	z := clamp(zoom, VIEW_ZOOM_MIN, max_zoom)
	app.view_pan = at - (at - app.view_pan) * (z / app.view_zoom)
	app.view_zoom = z
}

image_viewer :: proc(app: ^App, em: f32) {
	if app.view_start.key != 0 {
		if s := image_get(app, app.view_start); s != nil && s.state != .Pending {
			if s.state == .Ready { image_view_open(app, app.view_start) }
			app.view_start.key = 0
		} else { app.animating = true }
	}
	if !app.view_open { return }
	e, ok := &app.images[app.view_key]
	if !ok || e.state != .Ready { app.view_open = false; return }
	e.used = app.frame_no
	win := app.ui_state.window_size
	sc := ui.scale()
	view := [2]f32{math.round(win.x * VIEWER_FILL - em * 2), math.round(win.y * VIEWER_FILL - em * VIEWER_CHROME_EM)}
	// fits the view, never enlarged beyond its pixels times the scale; then the reader's zoom
	fit := min(view.x / f32(e.w), view.y / f32(e.h), sc)
	max_zoom := max(1, VIEW_NATIVE_MAX * sc / fit)
	if ui.modal("image_view", view.x + em * 2, &app.view_open, max(0.02, (win.y - view.y - em * 5) * 0.5 / win.y)) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em))
			picture := [2]f32{f32(e.w), f32(e.h)} * fit * app.view_zoom
			pannable := picture.x > view.x || picture.y > view.y
			ui.next({width = ui.px(view.x), height = ui.px(view.y), cursor = pannable ? (ui.active_key() != 0 ? .Grabbing : .Grab) : .Arrow})
			ui.a11y({role = .Image, name = app.view_name != "" ? app.view_name : "Image"})
			b := ui.build_box({.Clickable, .Scroll_Self}, "###view")
			sig := ui.signal(b)
			if sig.scrolled.y != 0 {
				view_zoom_to(app, app.view_zoom * math.pow(f32(VIEW_ZOOM_STEP), -sig.scrolled.y), max_zoom, sig.mouse - view * 0.5)
			}
			if sig.pressed { app.view_grab = app.view_pan }
			if sig.dragging { app.view_pan = app.view_grab + sig.drag_delta }
			if sig.double_clicked {
				native := sc / fit
				view_zoom_to(app, app.view_zoom != 1 ? 1 : (native > 1 ? native : VIEW_DOUBLE_CLICK), max_zoom, sig.mouse - view * 0.5)
			}
			if ui.key_press(.Equal) || ui.key_press(.Num_Add) { view_zoom_to(app, app.view_zoom * VIEW_ZOOM_STEP, max_zoom, {}) }
			if ui.key_press(.Minus) || ui.key_press(.Num_Subtract) { view_zoom_to(app, app.view_zoom / VIEW_ZOOM_STEP, max_zoom, {}) }
			if ui.key_press(.N0) { app.view_zoom, app.view_pan = 1, {} }
			if ui.key_press(.Left) { app.view_pan.x += view.x * VIEW_PAN_KEY }
			if ui.key_press(.Right) { app.view_pan.x -= view.x * VIEW_PAN_KEY }
			if ui.key_press(.Up) { app.view_pan.y += view.y * VIEW_PAN_KEY }
			if ui.key_press(.Down) { app.view_pan.y -= view.y * VIEW_PAN_KEY }
			picture = [2]f32{f32(e.w), f32(e.h)} * fit * app.view_zoom
			app.view_pan = view_pan_clamp(app.view_pan, picture, view)
			d := ui.frame_new(View_Draw)
			d^ = {e.tex, picture, app.view_pan}
			b.custom = view_draw
			b.custom_user = d
			ui.spacer(ui.px(em))
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2.6), axis = .X, cross = .Center})
		if ui.row(.Center) {
			ui.spacer(ui.px(em))
			name := app.view_name != "" ? app.view_name : "image"
			text("n", ellipsize(name, IMAGE_NAME_CHARS), hex(HEX_VIEWER_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
			text("d", fmt.tprintf("%d × %d  ·  %.0f %%", e.w, e.h, fit * app.view_zoom / sc * 100), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
			ui.spacer(ui.px(em * 0.8))
			bh := math.round(em * BUTTON_SMALL_H_EM)
			if bevel_button("###zoom_out", "−", "", .Normal, height = bh).clicked { view_zoom_to(app, app.view_zoom / VIEW_ZOOM_STEP, max_zoom, {}) }
			ui.spacer(ui.px(em * 0.3))
			if bevel_button("###zoom_in", "+", "", .Normal, height = bh).clicked { view_zoom_to(app, app.view_zoom * VIEW_ZOOM_STEP, max_zoom, {}) }
			ui.spacer(ui.px(em * 0.3))
			if bevel_button("###zoom_fit", "Fit", "", .Normal, height = bh).clicked { app.view_zoom, app.view_pan = 1, {} }
			ui.spacer(ui.px(em * 0.8))
			if bevel_button("###close", "Close", ICO_CANCEL, .Normal, height = bh).clicked { app.view_open = false }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.4))
	}
}
