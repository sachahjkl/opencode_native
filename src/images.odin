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
import "core:thread"
import "gt:config"
import "gt:draw"
import "gt:platform"
import "gt:render"
import svg "gt:svg"
import "gt:ui"
import lucide "gt:lucide"

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
		thread.create_and_start_with_poly_data(job, image_decode_run, self_cleanup = true)
	}
}

// On a thread of its own: the decode, its answer posted to the interface's thread.
@(private = "file")
image_decode_run :: proc(job: ^Decode_Job) {
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
	thread.create_and_start_with_poly_data(job, image_decode_run, self_cleanup = true)
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
		case !job.ok || job.w == 0 || job.h == 0: ui.toast(.Bad, "The image could not be copied: it is unreadable")
		case !platform.clipboard_set_image(app.win, pixels): ui.toast(.Bad, "The image could not be copied")
		case: ui.toast(.Good, "Image copied")
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
	if e.tex == 0 { image_failed(e, "no room for its texture"); return }
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
	return e.error != "" ? fmt.tprintf("image unreadable: %s", e.error) : "image unreadable"
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
	ui.a11y({role = .Button, name = ref.name != "" ? ref.name : "Image"})
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
	if err != nil { ui.toast(.Bad, fmt.tprintf("Cannot read %s", path)); return }
	app.view_start = image_ref(string(data), .Bytes, "image", strings.clone(filepath.base(path)))
}

// What --image= waits for: open once decoded, said and given up on when it cannot be. (An empty file has nothing to decode: nothing would
// ever come, and the wait would draw frames for good.)
image_view_wait :: proc(app: ^App) {
	if app.view_start.key == 0 { return }
	s := image_get(app, app.view_start, 0)
	if s != nil && s.state == .Pending {
		animate(app)
		return
	}
	if s != nil && s.state == .Ready {
		image_view_open(app, app.view_start)
	} else {
		ui.toast(.Bad, "%s: %s", app.view_start.name, s != nil ? image_failed_words(s) : "image unreadable: the file is empty")
	}
	app.view_start.key = 0
}

// The viewer, on the whole image (decoded now if the thumbnail's was all there was: it waits for it).
image_view_open :: proc(app: ^App, ref: Image_Ref) {
	_ = image_get(app, ref, 0)
	app.view_key = (ref.key ~ u64(image_dim(app, 0)) * HASH_MIX_B) | 1
	image_ref_delete(&app.view_ref)
	app.view_ref = image_ref_clone(ref)
	delete(app.view_diagram)
	app.view_diagram = ""
	app.cx.open[.Viewer] = true
	app.view_zoom, app.view_pan = 1, {}
	app.view_resize_from = {}
	app.view_grown = false
}

IMAGE_NAME_CHARS :: 80
HEX_VIEWER_NAME  :: 0xe0e0e0ff
HEX_VIEWER_WELL  :: 0x070707ff
VIEWER_PAD_EM    :: 0.5   // around the picture (the edges' grips are there)
VIEWER_BAR_EM    :: 2.6   // the name, the size and the buttons, under the picture
VIEWER_MIN_W_EM  :: 26    // what the bar needs: a small picture gets room on its sides
VIEWER_SCALE_MIN :: 0.2   // the smallest viewer, of the most the window gives a picture (conversation.image_viewer_size)
VIEW_ZOOM_MIN    :: 0.5   // times what fits
VIEW_NATIVE_MAX  :: 8     // times the image's pixels at the interface's scale
VIEW_ZOOM_STEP   :: 1.25  // a notch of the wheel, a press of + or -
VIEW_DOUBLE_CLICK :: 2    // what a double click goes to, when what fits is already its pixels
VIEW_PAN_KEY     :: 0.1   // of the view, an arrow key

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

// What the view draws: an image's texture, or a diagram (as paths, at the zoom's scale, on the colour of code: its colours are
// the theme's).
@(private = "file")
View_Draw :: struct { tex: render.Texture, doc: ^svg.Document, size, pan: [2]f32 }

@(private = "file")
view_draw :: proc(b: ^ui.Box, user: rawptr, dc: ^draw.Context) {
	d := (^View_Draw)(user)
	r := b.rect
	draw_well(dc, r, 0, hex(d.doc != nil ? HEX_CODE_WELL : HEX_VIEWER_WELL))
	c := (r.min + r.max) * 0.5 + d.pan
	draw.push_clip(dc, r)
	lo, hi := c - d.size * 0.5, c + d.size * 0.5
	if d.doc != nil {
		bold := ui.styled_face_of(&the_app.state, the_app.font, true, false)
		svg.draw_doc(dc, d.doc, lo, d.size.x / max(d.doc.view[2], 1), {regular = the_app.font, bold = bold})
	} else {
		draw.image(dc, d.tex, {{math.round(lo.x), math.round(lo.y)}, {math.round(hi.x), math.round(hi.y)}})
	}
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

// An image still being decoded: a moment, over the conversation dimmed.
@(private = "file")
image_viewer_wait :: proc(app: ^App, em: f32) {
	animate(app)
	if ui.modal("image_view", em * 12, &app.cx.open[.Viewer]) {
		dialog_backdrop()
		ui.spacer(ui.px(em))
		ui.next({width = ui.fill(), height = ui.px(em * 2), text_align = .Center})
		if ui.tags("weak") { ui.label("Opening the image…###view_wait") }
		ui.spacer(ui.px(em))
	}
}

image_viewer :: proc(app: ^App, em: f32) {
	image_view_wait(app)
	if !app.cx.open[.Viewer] { return }
	sc := ui.scale()
	// what is shown: its pixels (a diagram's: at the conversation's size), and what draws it
	source: [2]f32
	shown: View_Draw
	if app.view_diagram != "" {
		d := diagram_of(app, app.view_diagram, !app.cx.theme.light)
		if d == nil || d.why != "" { app.cx.open[.Viewer] = false; return }
		shown.doc = &d.doc
		source = {d.doc.view[2], d.doc.view[3]} * diagram_scale(em) / sc
	} else {
		e, ok := &app.images[app.view_key]
		if !ok || e.state == .Failed { app.cx.open[.Viewer] = false; return }
		e.used = app.frame_no
		if e.state == .Pending { image_viewer_wait(app, em); return }
		shown.tex = e.tex
		source = {f32(e.w), f32(e.h)}
	}
	diagram := shown.doc != nil
	pad, bar := math.round(em * VIEWER_PAD_EM), math.round(em * VIEWER_BAR_EM)
	chrome := [2]f32{2 * pad, pad + bar}
	room := app.state.window_size - 2 * math.round(em * ui.MODAL_MARGIN_EM)
	// (a diagram has no pixels of its own to stay within: it takes the share of the room at once)
	f := viewer_frame(source, room, chrome, sc, app.prefs.viewer_scale, math.round(em * VIEWER_MIN_W_EM), app.view_grown || diagram)
	view := f.picture
	max_zoom := max(1, VIEW_NATIVE_MAX * sc / f.fit)
	// (the dialog's size in logical pixels, as modal_sized keeps it: its grips write it)
	asked := f.panel / sc
	size := asked
	closing := false
	if ui.modal_sized("image_view", viewer_frame(source, room, chrome, sc, 1, math.round(em * VIEWER_MIN_W_EM)).panel, &size, &app.cx.open[.Viewer]) {
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
				picture := source * f.fit * app.view_zoom
				pannable := picture.x > view.x || picture.y > view.y
				ui.next({width = ui.px(view.x), height = ui.px(view.y), cursor = pannable ? (ui.active_key() != 0 ? .Grabbing : .Grab) : .Arrow})
				ui.a11y({role = .Image, name = diagram ? "A diagram" : app.view_ref.name != "" ? app.view_ref.name : "Image"})
				b := ui.build_box({.Clickable, .Scroll_Self}, "###view")
				sig := ui.signal(b)
				if sig.pressed && viewer_outside(sig.mouse, view, picture, app.view_pan) { closing = true }
				if ui.mouse_pressed(.Right) && rect_contains(b.rect, ui.mouse_pos()) && !app.cx.ctx_taken {
					if diagram { ctx_open(app, .Diagram, msg = app.view_diagram) } else { ctx_open(app, .Image, image = app.view_ref) }
				}
				if sig.scrolled.y != 0 {
					view_zoom_to(app, app.view_zoom * math.pow(f32(VIEW_ZOOM_STEP), -sig.scrolled.y), max_zoom, sig.mouse - view * 0.5)
				}
				if sig.pointer_pressed { app.view_grab = app.view_pan }
				if sig.dragging { app.view_pan = app.view_grab + sig.drag_delta }
				if sig.double_clicked {
					native := sc / f.fit
					view_zoom_to(app, app.view_zoom != 1 ? 1 : (native > 1 ? native : VIEW_DOUBLE_CLICK), max_zoom, sig.mouse - view * 0.5)
				}
				if ui.key_press(.C, {.Ctrl}) { if diagram { diagram_copy_png(app, app.view_diagram) } else { image_copy(app, app.view_ref) } }
				if ui.key_press(.Equal) || ui.key_press(.Num_Add) { view_zoom_to(app, app.view_zoom * VIEW_ZOOM_STEP, max_zoom, {}) }
				if ui.key_press(.Minus) || ui.key_press(.Num_Subtract) { view_zoom_to(app, app.view_zoom / VIEW_ZOOM_STEP, max_zoom, {}) }
				if ui.key_press(.N0) { app.view_zoom, app.view_pan = 1, {} }
				if ui.key_press(.Left) { app.view_pan.x += view.x * VIEW_PAN_KEY }
				if ui.key_press(.Right) { app.view_pan.x -= view.x * VIEW_PAN_KEY }
				if ui.key_press(.Up) { app.view_pan.y += view.y * VIEW_PAN_KEY }
				if ui.key_press(.Down) { app.view_pan.y -= view.y * VIEW_PAN_KEY }
				picture = source * f.fit * app.view_zoom
				app.view_pan = view_pan_clamp(app.view_pan, picture, view)
				d := ui.frame_new(View_Draw)
				d^ = shown
				d.size, d.pan = picture, app.view_pan
				b.custom = view_draw
				b.custom_user = d
				ui.spacer(ui.fill())
			}
			ui.next({width = ui.fill(), height = ui.px(bar), axis = .X, cross = .Center})
			if ui.row(.Center) {
				ui.spacer(ui.px(em))
				name := diagram ? "Mermaid diagram" : app.view_ref.name != "" ? app.view_ref.name : "image"
				text("n", ellipsize(name, IMAGE_NAME_CHARS), hex(HEX_VIEWER_NAME), ui.Style_Mod{font_size = math.round(em * FS_LABEL)}, ui.fill())
				ui.spacer(ui.px(em * 0.6))
				zoom := f.fit * app.view_zoom / sc * 100
				dims := diagram ? fmt.tprintf("%.0f %%", zoom) : fmt.tprintf("%d × %d  ·  %.0f %%", int(source.x), int(source.y), zoom)
				text("d", dims, hex(HEX_FAINT), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_SMALL)})
				ui.spacer(ui.px(em * 0.8))
				bh := math.round(em * BUTTON_SMALL_H_EM)
				if bevel_button("###zoom_out", "−", "", .Normal, height = bh).clicked { view_zoom_to(app, app.view_zoom / VIEW_ZOOM_STEP, max_zoom, {}) }
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###zoom_in", "+", "", .Normal, height = bh).clicked { view_zoom_to(app, app.view_zoom * VIEW_ZOOM_STEP, max_zoom, {}) }
				ui.spacer(ui.px(em * 0.3))
				if bevel_button("###zoom_fit", "Fit", "", .Normal, height = bh).clicked { app.view_zoom, app.view_pan = 1, {} }
				ui.spacer(ui.px(em * 0.8))
				if bevel_button("###close", "Close", lucide.X, .Normal, height = bh).clicked { app.cx.open[.Viewer] = false }
				ui.spacer(ui.px(em))
			}
		}
	}
	// (a press that closes the menu over the viewer is the menu's)
	if closing && !ui.ctx_menu_any_open() { app.cx.open[.Viewer] = false }
	viewer_resized(app, size, asked, f)
}

// The grips of the dialog moved (or a double click on one sent it back to its size): the picture takes the new size, its shape kept, and
// the size chosen is saved once the pointer lets go.
@(private = "file")
viewer_resized :: proc(app: ^App, size, asked: [2]f32, f: Viewer_Frame) {
	sc := ui.scale()
	switch {
	case size == {}:
		app.prefs.viewer_scale = 1
		app.view_resize_from = {}
		app.view_grown = false
	case size != asked:
		// (from the size shown: a picture held to its pixels shows less than the share saved)
		if app.view_resize_from == {} { app.view_resize_from = {asked.x, asked.y, f.picture.x / f.full.x} }
		app.view_grown = true
		from := app.view_resize_from
		app.prefs.viewer_scale = viewer_scale_of((size - from.xy) * sc, f.full, from.z)
	}
	if ui.active_key() != 0 { return }
	app.view_resize_from = {}
	if abs(f64(app.prefs.viewer_scale) - config.float_of(&app.cfg_prefs, "conversation.image_viewer_size")) > SLIDER_EPSILON {
		pref_set(app, "conversation.image_viewer_size", fmt.tprintf("%.3f", app.prefs.viewer_scale))
	}
}
