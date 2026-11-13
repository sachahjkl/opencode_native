// Images: those attached to prompts, those tools hand back (screenshots, images read), and projects' logos. Each is
// decoded by the Rust library (PNG, JPEG, WebP, GIF, BMP) on a worker thread, scaled down to the size it is shown at (a
// thumbnail's, the viewer's: the whole of it), then kept as a texture keyed by a hash of its data and that size. The
// textures together hold no more than IMAGE_BUDGET_BYTES, the ones shown longest ago going first; a few decoders work at a
// time, and an image no longer shown when its turn comes is not decoded. (A 2048-pixel texture for every thumbnail of a
// long conversation held a gigabyte; a find that built them all decoded them all at once.) Thumbnails open the viewer,
// a dialog exactly around the image fitted to the window, at the size the person chose; both copy the image (image_copy).
package ocn

import "core:fmt"
import "core:hash"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "gt:config"
import tasks "gt:tasks"
import "gt:draw"
import "gt:platform"
import "gt:render"
import "gt:ui"
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
image_ref_clone :: proc(ref: Image_Ref) -> Image_Ref {
	if ref.key == 0 { return {} }
	return {key = ref.key, data = strings.clone(ref.data), encoding = ref.encoding, mime = strings.clone(ref.mime), name = strings.clone(ref.name)}
}

image_ref_delete :: proc(ref: ^Image_Ref) {
	delete(ref.data)
	delete(ref.mime)
	delete(ref.name)
	ref^ = {}
}

Image_State :: enum u8 { Pending, Ready, Failed }

Image_Entry :: struct {
	state:   Image_State,
	tex:     render.Texture,
	w, h:    int,
	used:    u64,      // the frame it was last shown in
	error:   string,   // (owned)
}

IMAGE_BUDGET_BYTES :: 96 << 20    // the pixels of every texture kept (those shown in this frame and the last ones stay whatever)
IMAGE_MAX_DIM_PX   :: 2048        // what a decode scales down to, when the textures allow more
IMAGE_DECODERS     :: 3           // decodes at a time
IMAGE_CLASS_STEP_PX :: 256        // the sizes decoded at: powers of two up to it, then its multiples
IMAGE_KEEP_FRAMES  :: 2           // an image shown this many frames ago is still shown (its decode goes on, its texture stays)

Decode_Job :: struct {
	app:      ^App,   // (for its thread: the_app is the interface's)
	key:      u64,
	data:     string,   // (owned copy)
	encoding: Image_Encoding,
	max_dim:  u32,
	mips:     bool,   // the whole image (the viewer: shown much smaller than it is); a thumbnail is decoded at its size, sharper without
	copy:     bool,   // for the clipboard (image_copy): its pixels at full size, no texture
	// the answer
	w, h:     u32,
	out:      Ocn_Buf,
	ok:       bool,
}

// The longest side an image is decoded at for a place whose longest side is `need` frame pixels (0: the whole image, up to
// what a texture holds). In classes: places of nearly one size share a texture, and a window resized does not decode again.
image_dim :: proc(app: ^App, need: f32) -> u32 {
	return image_dim_class(need, u32(min(IMAGE_MAX_DIM_PX, render.max_texture_size(&app.r))))
}

// (`most`: the longest side a texture may have here)
image_dim_class :: proc(need: f32, most: u32) -> u32 {
	if need <= 0 { return most }
	n := u32(max(1, math.ceil(need)))
	c: u32 = 32
	if n <= IMAGE_CLASS_STEP_PX {
		for c < n { c *= 2 }
	} else {
		c = (n + IMAGE_CLASS_STEP_PX - 1) / IMAGE_CLASS_STEP_PX * IMAGE_CLASS_STEP_PX
	}
	return min(c, most)
}

// The texture of `ref` for a place whose longest side is `need` frame pixels (0: the whole image), its decode asked for the first
// time (nil: no image).
image_get :: proc(app: ^App, ref: Image_Ref, need: f32) -> ^Image_Entry {
	if ref.key == 0 || ref.data == "" { return nil }
	dim := image_dim(app, need)
	key := (ref.key ~ u64(dim) * HASH_MIX_B) | 1
	if e, ok := &app.images[key]; ok {
		e.used = app.frame_no
		return e
	}
	app.images[key] = {state = .Pending, used = app.frame_no}
	job := new(Decode_Job)
	job^ = {app = app, key = key, data = strings.clone(ref.data), encoding = ref.encoding, max_dim = dim, mips = need <= 0}
	sync.atomic_add(&app.pending, 1)
	append(&app.cx.image_queue, job)
	images_pump(app)
	return &app.images[key]
}

// Decoders for what waits, the last asked for first (what is on screen now, when the view went by many). What is no longer shown
// when its turn comes is let go: asked again if it is shown again.
images_pump :: proc(app: ^App) {
	q := &app.cx.image_queue
	for app.cx.image_decoding < IMAGE_DECODERS && len(q) > 0 {
		job := pop(q)
		if e, ok := app.images[job.key]; !ok || e.used + IMAGE_KEEP_FRAMES < app.frame_no {
			delete_key(&app.images, job.key)
			delete(job.data)
			free(job)
			sync.atomic_sub(&app.pending, 1)
			continue
		}
		app.cx.image_decoding += 1
		tasks.add(ui.chores(), image_decode_run, job)
	}
}

// On a thread of the chores: the decode, its answer posted to the interface's thread.
@(private = "file")
image_decode_run :: proc(data: rawptr) {
	job := (^Decode_Job)(data)
	r := ocn_image_decode(raw_data(job.data), len(job.data), i32(job.encoding), job.max_dim, &job.w, &job.h, &job.out)
	job.ok = r == 0
	if !ui.post(&job.app.state, image_decoded, job) { ocn_buf_free(job.out); delete(job.data); free(job) }
}

// The image's pixels on the system's clipboard, at the size of its file. (The textures are scaled down, and the GPU's are not read
// back: the data is decoded again whole, on a thread, outside the queue of what is shown.)
image_copy :: proc(app: ^App, ref: Image_Ref) {
	if ref.key == 0 || ref.data == "" { return }
	job := new(Decode_Job)
	job^ = {app = app, data = strings.clone(ref.data), encoding = ref.encoding, max_dim = 0, copy = true}
	sync.atomic_add(&app.pending, 1)
	tasks.add(ui.chores(), image_decode_run, job)
}

// On the interface's thread: the pixels become a texture, or go to the clipboard.
@(private = "file")
image_decoded :: proc(data: rawptr, word: u64) {
	app := the_app
	job := (^Decode_Job)(data)
	defer { ocn_buf_free(job.out); delete(job.data); free(job) }
	sync.atomic_sub(&app.pending, 1)
	if job.copy {
		pixels := platform.Clipboard_Image{rgba = job.out.ptr[:job.out.len], size = {int(job.w), int(job.h)}}
		switch {
		case !job.ok || job.w == 0 || job.h == 0: ui.announce(&app.announcer, .Bad, i18n.tr("The image could not be copied: it is unreadable"))
		case !platform.clipboard_set_image(app.win, pixels): ui.announce(&app.announcer, .Bad, i18n.tr("The image could not be copied"))
		case: ui.announce(&app.announcer, .Good, i18n.tr("Image copied"))
		}
		return
	}
	defer images_pump(app)
	app.cx.image_decoding -= 1
	e, ok := &app.images[job.key]
	if !ok { return }
	if !job.ok || job.w == 0 || job.h == 0 {
		image_failed(e, string(job.out.ptr[:job.out.len]))
		return
	}
	e.tex = render.create_texture_rgba(&app.r, int(job.w), int(job.h), mips = job.mips)
	if e.tex == 0 { image_failed(e, i18n.tr("no room for its texture")); return }
	render.update_texture_rgba(&app.r, e.tex, 0, 0, int(job.w), int(job.h), job.out.ptr[:job.out.len])
	e.w, e.h = int(job.w), int(job.h)
	e.state = .Ready
	images_trim(app)
}

image_failed :: proc(e: ^Image_Entry, why: string) {
	e.state = .Failed
	delete(e.error)
	e.error = strings.clone(why)
}

// What a picture that cannot be shown says of itself.
image_failed_words :: proc(e: ^Image_Entry) -> string {
	return e.error != "" ? fmt.tprintf(i18n.tr("image unreadable: %s"), e.error) : i18n.tr("image unreadable")
}

// Keeps the textures within IMAGE_BUDGET_BYTES: the ones shown longest ago go (they are decoded again when shown).
images_trim :: proc(app: ^App) {
	held := 0
	for _, e in app.images { held += e.w * e.h * 4 }
	for held > IMAGE_BUDGET_BYTES {
		oldest: u64
		best := max(u64)
		for k, e in app.images {
			if e.state != .Pending && e.used < best && e.used + IMAGE_KEEP_FRAMES < app.frame_no { best, oldest = e.used, k }
		}
		if oldest == 0 { return }
		held -= app.images[oldest].w * app.images[oldest].h * 4
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
	e := image_get(app, ref, max(max_w, max_h))
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
			ui.build_box({.Draw_Text}, fmt.tprintf("%s###f", label_safe(image_failed_words(e))))
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
	e := image_get(app, ref^, size)
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
	if err != nil { ui.announce(&app.announcer, .Bad, fmt.tprintf(i18n.tr("Cannot read %s"), path)); return }
	app.viewer.start = image_ref(string(data), .Bytes, "image", strings.clone(filepath.base(path)))
}

// What --image= waits for: open once decoded, said and given up on when it cannot be. (An empty file has nothing to decode: nothing would
// ever come, and the wait would draw frames for good.)
image_view_wait :: proc(app: ^App) {
	if app.viewer.start.key == 0 { return }
	s := image_get(app, app.viewer.start, 0)
	if s != nil && s.state == .Pending {
		animate(app)
		return
	}
	if s != nil && s.state == .Ready {
		image_view_open(app, app.viewer.start)
	} else {
		ui.announce(&app.announcer, .Bad, fmt.tprintf("%s: %s", app.viewer.start.name, s != nil ? image_failed_words(s) : i18n.tr("image unreadable: the file is empty")))
	}
	app.viewer.start.key = 0
}

// The viewer, on the whole image (decoded now if the thumbnail's was all there was: it waits for it).
image_view_open :: proc(app: ^App, ref: Image_Ref) {
	_ = image_get(app, ref, 0)
	app.viewer.key = (ref.key ~ u64(image_dim(app, 0)) * HASH_MIX_B) | 1
	image_ref_delete(&app.viewer.ref)
	app.viewer.ref = image_ref_clone(ref)
	app.cx.open[.Viewer] = true
	ui.preview_reset(&app.viewer.view)
	app.viewer.focus = true
	app.viewer.resize_from = {}
	app.viewer.grown = false
}

IMAGE_NAME_CHARS :: 80
HEX_VIEWER_NAME  :: 0xe0e0e0ff
HEX_VIEWER_WELL  :: 0x070707ff
VIEWER_PAD_EM    :: 0.5   // around the picture (the edges' grips are there)
VIEWER_BAR_EM    :: 2.6   // the name, the size and the buttons, under the picture
VIEWER_MIN_W_EM  :: 26    // what the bar needs: a small picture gets room on its sides
VIEWER_SCALE_MIN :: 0.2   // the smallest viewer, of the most the window gives a picture (conversation.image_viewer_size)
VIEW_NATIVE_MAX  :: 8     // times the image's pixels at the interface's scale (ui.preview's zoom_max)

// Where the viewer is, from the image alone: the panel hugs the picture, so all the black around it is outside the viewer.
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
	radius: f32
	for a := b.parent; a != nil; a = a.parent {
		if a.name != "modal_image_view" { continue }
		inset := max(b.rect.min.x - a.rect.min.x, b.rect.min.y - a.rect.min.y)
		radius = ui.concentric_radius(ui.box_drawn_radii(ui.current_state(), a)[0], inset)
		break
	}
	ui.machined_well(dc, b.rect, radius, hex(HEX_VIEWER_WELL))
}

// The image viewer (open: Dialog.Viewer): what it shows, and how it is zoomed, moved and sized.
Image_Viewer :: struct {
	key:         u64,
	ref:         Image_Ref,   // what is shown: what Copy decodes again whole (its data and name owned)
	view:        ui.Preview,  // the zoom (times what fits) and the pan of the picture
	focus:       bool,        // just opened: the keyboard goes to the picture (its keys zoom and move it)
	resize_from: [3]f32,      // a grip of the viewer held: the dialog's size (logical pixels) and scale at its press ({}: none)
	grown:       bool,        // the viewer's grips were dragged since it opened: its picture may pass its pixels (viewer_frame)
	start:       Image_Ref,   // --image=<file>: opened in the viewer once it is decoded (its data owned)
}

// An image still being decoded: a moment, over the conversation dimmed.
@(private = "file")
image_viewer_wait :: proc(app: ^App, em: f32) {
	animate(app)
	if ui.modal("image_view", &app.cx.open[.Viewer], {width_em = 12}) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label(fmt.tprintf("%s###view_wait", i18n.tr("Opening the image…"))) }
		ui.spacer(ui.px(em))
	}
}

image_viewer :: proc(app: ^App, em: f32) {
	image_view_wait(app)
	if !app.cx.open[.Viewer] { return }
	sc := ui.scale()
	// what is shown: its pixels, and its texture
	e, ok := &app.images[app.viewer.key]
	if !ok || e.state == .Failed { app.cx.open[.Viewer] = false; return }
	e.used = app.frame_no
	if e.state == .Pending { image_viewer_wait(app, em); return }
	source := [2]f32{f32(e.w), f32(e.h)}
	pad, bar := math.round(em * VIEWER_PAD_EM), math.round(em * VIEWER_BAR_EM)
	chrome := [2]f32{2 * pad, pad + bar}
	room := app.state.window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
	f := viewer_frame(source, room, chrome, sc, app.prefs.viewer_scale, math.round(em * VIEWER_MIN_W_EM), app.viewer.grown)
	view := f.picture
	// (the dialog's size in ems, as ui.modal keeps it: its grips write it)
	asked := f.panel / em
	size := asked
	closing := false
	natural := viewer_frame(source, room, chrome, sc, 1, math.round(em * VIEWER_MIN_W_EM)).panel / em
	if ui.modal("image_view", &app.cx.open[.Viewer], {width_em = natural.x, height_em = natural.y, size = &size}) {
		dialog_backdrop()
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
					res := ui.preview_image("###view", pv, e.tex, source, pv_o)
					if app.viewer.focus { ui.set_focus(res.box.key); app.viewer.focus = false }
					b := res.box
					on := ui.pointer_on(b)
					picture := source * res.fit * pv.zoom
					if on && ui.mouse_pressed(.Left) && viewer_outside(ui.mouse_pos() - b.rect.min, view, picture, pv.pan) { closing = true }
					if on && ui.mouse_pressed(.Right) && !app.ctx_menu.taken {
						ctx_open(app, .Image, image = app.viewer.ref)
					}
					if ui.key_press(.C, {.Ctrl}) { image_copy(app, app.viewer.ref) }
				}
				ui.spacer(ui.fill())
			}
			ui.next({width = ui.fill(), height = ui.px(bar), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em))
				name := app.viewer.ref.name != "" ? app.viewer.ref.name : i18n.tr("image")
				text("n", ellipsize(name, IMAGE_NAME_CHARS), hex(HEX_VIEWER_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
				ui.spacer(ui.px(em * 0.6))
				zoom := f.fit * app.viewer.view.zoom / sc * 100
				dims := fmt.tprintf("%d × %d  ·  %.0f %%", int(source.x), int(source.y), zoom)
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
				if ui.button("close", i18n.tr("Close"), lucide.X, {height = bh}).clicked { app.cx.open[.Viewer] = false }
				ui.spacer(ui.px(em))
			}
		}
	}
	// (a press that closes the menu over the viewer is the menu's)
	if closing && !ui.menu_any_open() { app.cx.open[.Viewer] = false }
	viewer_resized(app, size, asked, f, em)
}

// The grips of the dialog moved (or a double click on one sent it back to its size): the picture takes the new size, its shape kept, and
// the size chosen is saved once the pointer lets go.
@(private = "file")
viewer_resized :: proc(app: ^App, size, asked: [2]f32, f: Viewer_Frame, em: f32) {
	switch {
	case size == {}:
		app.prefs.viewer_scale = 1
		app.viewer.resize_from = {}
		app.viewer.grown = false
	case size != asked:
		// (from the size shown: a picture held to its pixels shows less than the share saved)
		if app.viewer.resize_from == {} { app.viewer.resize_from = {asked.x, asked.y, f.picture.x / f.full.x} }
		app.viewer.grown = true
		from := app.viewer.resize_from
		app.prefs.viewer_scale = viewer_scale_of((size - from.xy) * em, f.full, from.z)
	}
	if ui.active_key() != 0 { return }
	app.viewer.resize_from = {}
	if abs(f64(app.prefs.viewer_scale) - config.float_of(&app.cfg_prefs, "conversation.image_viewer_size")) > SLIDER_EPSILON {
		pref_set_float(app, "conversation.image_viewer_size", app.prefs.viewer_scale)
	}
}
