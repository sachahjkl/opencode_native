// Images: those attached to prompts, those tools hand back (screenshots, images read), and projects' logos. Each is
// decoded once by the Rust library (PNG, JPEG, WebP, GIF, BMP; scaled down to fit a texture) on a worker thread, then
// kept as a texture keyed by a hash of its data. Thumbnails open a viewer that fits the image to the window.
package occ

import "core:fmt"
import "core:hash"
import "core:math"
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

// (the key hashes the first and last 4 KiB and the length: images of several MiB are read again with every page)
image_ref :: proc(data: string, encoding: Image_Encoding, mime, name: string) -> Image_Ref {
	b := transmute([]u8)data
	n := len(b)
	k := hash.fnv64a(b[:min(n, 4096)]) ~ hash.fnv64a(b[max(0, n - 4096):]) * 31 ~ u64(n) * 0x9e3779b97f4a7c15
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
	job^ = {key = ref.key, data = strings.clone(ref.data), encoding = ref.encoding, max_dim = u32(min(2048, render.max_texture_size(&app.r)))}
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
		draw_well(dc, r, rad, hex(0x0b0b0bff))
		// a slow shimmer while it decodes
		t := f32(ui.now_ms()) * 0.002
		x := r.min.x + (r.max.x - r.min.x) * (0.5 + 0.5 * math.sin(t))
		draw.rect(dc, {{x - 20 * s, r.min.y + 2 * s}, {x + 20 * s, r.max.y - 2 * s}}, {1, 1, 1, 0.03}, rad, 0, 14 * s)
	case .Failed:
		draw_well(dc, r, rad, hex(0x140b0bff))
	}
}

// A thumbnail of `ref` fitting `max_w` x `max_h` (frame pixels), clickable: a click opens the viewer.
image_thumb :: proc(app: ^App, id: string, ref: Image_Ref, max_w, max_h: f32) -> ui.Signal {
	e := image_get(app, ref)
	w, h := max_w * 0.6, max_h * 0.6
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
			ui.next({width = ui.fill(), height = ui.fill(), fg = hex(0xc08080ff), font_size = math.round(em * 0.8), text_align = .Center})
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

image_view_open :: proc(app: ^App, ref: Image_Ref) {
	delete(app.view_name)
	app.view_key = ref.key
	app.view_name = strings.clone(ref.name)
	app.view_open = true
}

image_viewer :: proc(app: ^App, em: f32) {
	if !app.view_open { return }
	e, ok := &app.images[app.view_key]
	if !ok || e.state != .Ready { app.view_open = false; return }
	e.used = app.frame_no
	win := app.ui_state.window_size
	sc := ui.scale()
	// the image fits 90 % of the window (never enlarged beyond its pixels times the scale)
	k := min(win.x * 0.9 / f32(e.w), (win.y * 0.9 - em * 4) / f32(e.h), sc)
	w, h := math.round(f32(e.w) * k), math.round(f32(e.h) * k)
	if ui.modal("image_view", max(w + em * 2, em * 22), &app.view_open, max(0.02, (win.y - h - em * 5) * 0.5 / win.y)) {
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.children_sum(), axis = .X})
		if ui.row() {
			ui.spacer(ui.px(em))
			ui.next({width = ui.px(w), height = ui.px(h)})
			b := ui.build_box({.Clickable}, "###view")
			d := ui.frame_new(Image_Draw)
			d^ = {tex = e.tex, radius = 4, frame = false, state = .Ready}
			b.custom = image_draw
			b.custom_user = d
			if ui.signal(b).clicked { app.view_open = false }
			ui.spacer(ui.px(em))
		}
		ui.next({width = ui.fill(), height = ui.px(em * 2.6), axis = .X, cross = .Center})
		if ui.row(.Center) {
			ui.spacer(ui.px(em))
			name := app.view_name != "" ? app.view_name : "image"
			text("n", ellipsize(name, 80), hex(0xe0e0e0ff), ui.Style_Mod{font_size = math.round(em * 0.9)}, ui.fill())
			text("d", fmt.tprintf("%d × %d", e.w, e.h), hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * 0.76)})
			ui.spacer(ui.px(em * 0.8))
			if bevel_button("###close", "Close", ICO_CANCEL, .Normal, height = math.round(em * 1.8)).clicked { app.view_open = false }
			ui.spacer(ui.px(em))
		}
		ui.spacer(ui.px(em * 0.4))
	}
}
