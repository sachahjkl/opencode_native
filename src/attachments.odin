// What goes with a prompt: files pasted, dropped or picked (the paperclip of the composer, composer.attach). An image, a
// PDF or a text file goes as a data URL, so a server on another machine gets it too; an image shows as a thumbnail over
// the composer, every one as its name. Another file (a program, an archive) goes in the text as its path, which the agent
// can read on its own machine.
package ocn

import "base:runtime"
import "core:encoding/base64"
import "core:fmt"
import "core:math"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"
import "gt:ascii"
import tasks "gt:tasks"
import "gt:platform"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

Attachment :: struct {
	name: string,      // (owned)
	uri:  string,      // data:<mime>;base64,... (owned)
	size: int,         // of the file, in bytes
	ref:  Image_Ref,   // an image's thumbnail (zero: not an image)
}

// A file on its way to a composer: read, typed and encoded on a thread of its own, its attachment posted back (attach_done).
// A file of megabytes takes longer to read and encode than a frame lasts. Its memory is the heap's on both sides.
Attach_Job :: struct {
	app:   ^App,
	chat:  string,                     // the session whose composer it goes to ("": the home page's) (owned)
	path:  string,                     // the file to read ("": `data` or `image` is given) (owned)
	name:  string,                     // (owned)
	mime:  string,                     // of `data` (a literal); a file's: by its extension and its bytes (attach_mime)
	data:  []u8,                       // (owned)
	image: platform.Clipboard_Image,   // pasted: encoded as PNG first (owned)
	decode: string,                    // `data` is a clipboard's image of this type (BMP, a DIB): decoded, then encoded as PNG (owned)
	// what came of it
	outcome: Attach_Outcome,
	uri:     string,                   // the data URL (owned)
	size:    int,                      // of the file, in bytes
}

Attach_Outcome :: enum u8 {
	Attached,
	Too_Large,        // past ATTACH_MAX_BYTES
	Not_Attachable,   // not an image, a PDF or text: its path goes in the text
	Unread,           // a folder, or a file that could not be read: its path goes in the text
	Bad_Image,        // a pasted image that could not be encoded
	Failed,           // the encoding failed (out of memory): nothing is said, as before
}

// Whether a file for the composer shown is still being read: it does not send yet (composer_held), what it sends would
// leave the file behind.
attaching :: proc(app: ^App) -> bool {
	for job in app.composer.attaching { if job.chat == app.chat.id { return true } }
	return false
}

// `job` goes to the chores, for the composer shown.
@(private = "file")
attach_start :: proc(app: ^App, job: ^Attach_Job) {
	job.app = app
	job.chat = strings.clone(app.chat.id, runtime.heap_allocator())
	append(&app.composer.attaching, job)
	sync.atomic_add(&app.pending, 1)
	tasks.add(ui.chores(), attach_run, job)
}

// The bytes `data` (copied: the caller keeps them) as a file `name` of type `mime`.
@(private = "file")
attach_bytes :: proc(app: ^App, data: []u8, mime, name: string) {
	h := runtime.heap_allocator()
	job := new(Attach_Job, h)
	job^ = {name = strings.clone(name, h), mime = mime, data = slice_clone(data, h)}
	attach_start(app, job)
}

@(private = "file")
slice_clone :: proc(data: []u8, allocator: runtime.Allocator) -> []u8 {
	out := make([]u8, len(data), allocator)
	copy(out, data)
	return out
}

// On the job's thread: the file read, its type, the size it may have, its data URL.
@(private = "file")
attach_run :: proc(data: rawptr) {
	job := (^Attach_Job)(data)
	h := runtime.heap_allocator()
	defer free_all(context.temp_allocator)
	switch {
	case job.path != "":
		if os.is_dir(job.path) { job.outcome = .Unread; break }
		data, err := os.read_entire_file(job.path, h)
		if err != nil { job.outcome = .Unread; break }
		job.data = data
		job.mime = attach_mime(job.path, data)
		if job.mime == "" { job.outcome = .Not_Attachable }
	case job.image.rgba != nil:
		job.data = platform.png_encode(job.image, h)
		platform.clipboard_image_destroy(&job.image, h)
		if len(job.data) == 0 { job.outcome = .Bad_Image }
	case job.decode != "":
		img, ok := platform.clipboard_image_decode(job.decode, job.data, h)
		delete(job.data, h)
		job.data = nil
		if !ok { job.outcome = .Bad_Image; break }
		job.data = platform.png_encode(img, h)
		platform.clipboard_image_destroy(&img, h)
		if len(job.data) == 0 { job.outcome = .Bad_Image }
	}
	if job.outcome == .Attached {
		if len(job.data) > ATTACH_MAX_BYTES {
			job.outcome = .Too_Large
		} else if b64, err := base64.encode(job.data, allocator = h); err != nil {
			job.outcome = .Failed
		} else {
			job.uri = strings.concatenate({"data:", job.mime, ";base64,", b64}, h)
			job.size = len(job.data)
			delete(b64, h)
		}
	}
	delete(job.data, h)
	job.data = nil
	if !ui.post(&job.app.state, attach_done, job) { attach_job_free(job) }
}

@(private = "file")
attach_job_free :: proc(job: ^Attach_Job) {
	h := runtime.heap_allocator()
	delete(job.chat, h)
	delete(job.path, h)
	delete(job.name, h)
	delete(job.data, h)
	delete(job.uri, h)
	delete(job.decode, h)
	platform.clipboard_image_destroy(&job.image, h)
	free(job, h)
}

// On the interface's thread: the attachment goes to the composer of its session, or what is said of the file.
@(private = "file")
attach_done :: proc(data: rawptr, word: u64) {
	app := the_app
	job := (^Attach_Job)(data)
	defer attach_job_free(job)
	sync.atomic_sub(&app.pending, 1)
	for j, i in app.composer.attaching { if j == job { ordered_remove(&app.composer.attaching, i); break } }
	switch job.outcome {
	case .Attached:
		a := Attachment{name = strings.clone(job.name), uri = job.uri, size = job.size}
		job.uri = ""   // (the attachment's now)
		if strings.has_prefix(job.mime, "image/") { a.ref = image_ref(a.uri, .Data_Url, job.mime, a.name) }
		composer_take(app, job.chat, a, "")
	case .Too_Large:
		ui.announce(&app.announcer, .Warn, fmt.tprintf(i18n.tr("%s is too large to attach"), job.name))
	case .Not_Attachable:
		ui.announce(&app.announcer, .Warn, fmt.tprintf(i18n.tr("%s is not an image, a PDF or text: its path goes in the prompt"), job.name))
		composer_take(app, job.chat, nil, fmt.tprintf("%s ", job.path))
	case .Unread:
		composer_take(app, job.chat, nil, fmt.tprintf("%s ", job.path))
	case .Bad_Image:
		ui.announce(&app.announcer, .Bad, i18n.tr("The image could not be read"))
	case .Failed:
	}
}

// An image's type by its extension, among those this program shows ("": none of them).
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
// path goes in the text. It is read on a thread of its own (attach_run).
attach_path :: proc(app: ^App, path: string) {
	h := runtime.heap_allocator()
	job := new(Attach_Job, h)
	job^ = {path = strings.clone(path, h), name = strings.clone(base_name(path), h)}
	attach_start(app, job)
}

// The paperclip: the system's dialog, several files at once.
attach_pick :: proc(app: ^App) {
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("Attach files"), all_files = true, multiple = true, remember_id = "attach"}, proc(r: platform.Dialog_Result, user: rawptr) {
		if r.status == .Unsupported { ui.announce(&(^App)(user).announcer, .Bad, i18n.tr("This system has no file dialog")); return }
		if r.status != .Chosen { return }
		for p in r.paths { attach_path((^App)(user), p) }
	}, app)
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
		case len(d.image) > 0: attach_bytes(app, d.image, "image/png", fmt.tprintf("dropped-%d.png", attach_number(app)))
		case d.text != "":     area_insert(&app.composer.area, d.text)
		}
	}
}

// A paste in the composer (Ctrl+V, Shift+Insert, its menu's Paste). The clipboard belongs to another program, which may be slow
// or hung: its files, its image and its text are asked at once (platform.clipboard_request) and each answer is taken as it
// comes (composer_paste_event); nothing waits for them. When all three came, what the clipboard held decides: files are
// attached; an image is attached when no text came with it (a spreadsheet's cells come as both); text goes in at the caret.
Composer_Paste :: struct {
	files, image, text: u64,   // the requests not answered yet (0: answered)
	paths: [dynamic]string,    // (owned)
	data:  []u8,               // the image, still encoded (owned)
	mime:  string,             // ... its type (owned)
	words: string,             // (owned)
}

composer_paste :: proc(app: ^App) {
	p := &app.composer.paste
	composer_paste_clear(p)   // (a paste asked again: the last one's answers are dropped)
	p.files = platform.clipboard_request(app.win, .Files)
	p.image = platform.clipboard_request(app.win, .Image)
	p.text = platform.clipboard_request(app.win, .Text)
}

// An event of the main window: an answer to the paste waiting is kept (an event's strings live until the next poll).
composer_paste_event :: proc(app: ^App, e: platform.Event) {
	if e.kind != .Clipboard_Data { return }
	p := &app.composer.paste
	r := e.clipboard
	switch {
	case r.id == p.files:
		p.files = 0
		if r.ok { for x in r.files { append(&p.paths, strings.clone(x)) } }
	case r.id == p.image:
		p.image = 0
		if r.ok { p.data, p.mime = slice_clone(r.data, context.allocator), strings.clone(r.mime) }
	case r.id == p.text:
		p.text = 0
		if r.ok { p.words = strings.clone(r.text) }
	case:
		return
	}
	if p.files == 0 && p.image == 0 && p.text == 0 { composer_paste_done(app) }
}

@(private = "file")
composer_paste_done :: proc(app: ^App) {
	p := &app.composer.paste
	defer composer_paste_clear(p)
	switch {
	case len(p.paths) > 0:
		for x in p.paths { attach_path(app, x) }
	case len(p.data) > 0 && p.words == "":
		n := attach_number(app)
		switch {
		case ascii.equal_fold(p.mime, "image/png"):  attach_bytes(app, p.data, "image/png", fmt.tprintf("pasted-%d.png", n))
		case ascii.equal_fold(p.mime, "image/jpeg"): attach_bytes(app, p.data, "image/jpeg", fmt.tprintf("pasted-%d.jpg", n))
		case:
			// (another type, a Windows DIB: decoded and encoded as PNG on the job's thread)
			h := runtime.heap_allocator()
			job := new(Attach_Job, h)
			job^ = {name = fmt.aprintf("pasted-%d.png", n, allocator = h), mime = "image/png", data = slice_clone(p.data, h), decode = strings.clone(p.mime, h)}
			attach_start(app, job)
		}
	case p.words != "":
		// (as the editor's own paste makes them: its line ends and no tabs)
		text, _ := strings.replace_all(p.words, "\r\n", "\n", context.temp_allocator)
		text, _ = strings.replace_all(text, "\r", "\n", context.temp_allocator)
		text, _ = strings.replace_all(text, "\t", "    ", context.temp_allocator)
		area_insert(&app.composer.area, text)
	}
}

composer_paste_clear :: proc(p: ^Composer_Paste) {
	for x in p.paths { delete(x) }
	delete(p.paths); delete(p.data); delete(p.mime); delete(p.words)
	p^ = {}
}

// The number in the name of an image pasted or dropped: past those attached and those on their way.
@(private = "file")
attach_number :: proc(app: ^App) -> int { return len(app.composer.attachments) + len(app.composer.attaching) + 1 }

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
	b := strings.builder_make(context.temp_allocator)
	prompt_fields_into(&b, attachments, mentions, text)
	return strings.to_string(b)
}

// prompt_fields, written to `b`: an attachment's data URL is quoted there once, not copied again into a list and then a
// string (it is megabytes).
prompt_fields_into :: proc(b: ^strings.Builder, attachments: []Attachment, mentions: []Mention, text: string) {
	files := 0
	for a in attachments {
		strings.write_string(b, files == 0 ? `,"files":[` : ",")
		strings.write_string(b, `{"uri":`)
		jquote_into(b, a.uri)
		strings.write_string(b, `,"name":`)
		jquote_into(b, a.name)
		strings.write_byte(b, '}')
		files += 1
	}
	for &m in mentions {
		if m.kind != .File { continue }
		mention, ok := mention_json(&m, text)
		if !ok { continue }   // (taken out of the text since)
		strings.write_string(b, files == 0 ? `,"files":[` : ",")
		fmt.sbprintf(b, `{{"uri":%s,"name":%s,"mention":%s}}`, jquote(m.target), jquote(m.name), mention)
		files += 1
	}
	if files > 0 { strings.write_byte(b, ']') }
	agents := 0
	for &m in mentions {
		if m.kind == .File { continue }
		mention, ok := mention_json(&m, text)
		if !ok { continue }
		strings.write_string(b, agents == 0 ? `,"agents":[` : ",")
		fmt.sbprintf(b, `{{"name":%s,"mention":%s}}`, jquote(m.target), mention)
		agents += 1
	}
	if agents > 0 { strings.write_byte(b, ']') }
}


// Over the text of the composer, in its well.
attachments_row :: proc(app: ^App, em: f32) {
	if len(app.composer.attachments) == 0 { return }
	sc := ui.scale()
	refs := make([dynamic]Image_Ref, context.temp_allocator)
	for a in app.composer.attachments { if a.ref.key != 0 { append(&refs, a.ref) } }
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
		for a, i in app.composer.attachments {
			ui.next({width = ui.children_sum(), height = ui.px(math.round(em * 1.5)), axis = .X, cross = .Center})
			if ui.row(.Center, id = fmt.tprintf("###att%d", i)) {
				ui.spacer(ui.px(em * 0.8))
				text("n", fmt.tprintf("%s  %s", a.name, kfmt(f64(a.size))), hex(HEX_WEAK), ui.Style_Mod{font = app.mono, font_size = math.round(em * FS_CAPTION)})
				ui.spacer(ui.px(em * 0.2))
				ui.next({width = ui.px(math.round(em * 1.3)), height = ui.px(math.round(em * 1.3))})
				if ui.button("x", icon = lucide.X).clicked { gone = i }
			}
		}
	}
	if gone >= 0 {
		delete(app.composer.attachments[gone].name)
		delete(app.composer.attachments[gone].uri)
		ordered_remove(&app.composer.attachments, gone)
	}
}
