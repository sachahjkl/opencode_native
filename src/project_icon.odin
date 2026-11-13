// A project's icon of the user's own: an image chosen here goes to the server as the project's icon override (a data URL,
// Project.icon.override), shown before the one the server found in the project; removed, the found one comes back. Every
// client shows the same (project.updated).
package ocn

import "base:runtime"

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "gt:platform"
import "gt:png"
import "gt:ui"
import lucide "gt:lucide"
import i18n "gt:i18n"

// The icon's side, at most (pixels): what is sent is the image made this small, as a PNG, whatever its size was (it is
// kept in the project and read with the projects by every client). Sharp at twice the sidebar's size, at 200 %.
PROJECT_ICON_SIDE :: 256

// The PATCH that puts `override` on a project's icon ("": none).
project_icon_body :: proc(override: string) -> string {
	return fmt.tprintf(`{{"icon":{{"override":%s}}}}`, jquote(override))
}

// The system's dialog, then the image on the project.
project_icon_pick :: proc(app: ^App, project: string) {
	if project == "" { return }
	filters := []platform.File_Filter{{name = i18n.tr("Images"), patterns = {"*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.bmp", "*.ico", "*.tif", "*.tiff"}}}
	ui.file_dialog(&app.state, .Open, {owner = app.win, title = i18n.tr("The project's icon"), filters = filters, remember_id = "project_icon"}, proc(r: platform.Dialog_Result, user: rawptr) {
		j := (^Icon_Job)(user)
		if r.status == .Unsupported { ui.announce(&j.app.announcer, .Bad, i18n.tr("This system has no file dialog")) }
		if r.status != .Chosen || len(r.paths) == 0 { icon_job_free(j); return }
		project_icon_set_file(j.app, j.project, r.paths[0])
		icon_job_free(j)
	}, icon_job_new(app, project, ""))
}

// An image file read, made an icon and encoded by a task (heap; icon_job_free).
@(private = "file")
Icon_Job :: struct { app: ^App, project, path, url: string, unreadable: bool }

@(private = "file")
icon_job_new :: proc(app: ^App, project, path: string) -> ^Icon_Job {
	a := runtime.heap_allocator()
	j := new(Icon_Job, a)
	j^ = {app = app, project = strings.clone(project, a), path = strings.clone(path, a)}
	return j
}

@(private = "file")
icon_job_free :: proc(data: rawptr) {
	j := (^Icon_Job)(data)
	a := runtime.heap_allocator()
	delete(j.project, a); delete(j.path, a); delete(j.url, a)
	free(j, a)
}

// An image file on the project, made PROJECT_ICON_SIDE at most (refused, with a toast, when it is no image). The file is
// read and decoded by a task: a disk and an image's size take their time.
project_icon_set_file :: proc(app: ^App, project, path: string) {
	ui.task(&app.state, proc(data: rawptr) {
		j := (^Icon_Job)(data)
		bytes, err := os.read_entire_file(j.path, context.temp_allocator)
		if err != nil { j.unreadable = true; return }
		png_data, ok := project_icon_png(bytes)
		if !ok { return }
		b64, _ := base64.encode(png_data, allocator = context.temp_allocator)
		j.url = strings.concatenate({"data:image/png;base64,", b64}, runtime.heap_allocator())
	}, proc(data: rawptr, _: u64) {
		j := (^Icon_Job)(data)
		defer icon_job_free(j)
		switch {
		case j.unreadable: ui.announce(&j.app.announcer, .Bad, fmt.tprintf(i18n.tr("%s cannot be read"), base_name(j.path)))
		case j.url == "":  ui.announce(&j.app.announcer, .Warn, fmt.tprintf(i18n.tr("%s is not an image this program reads (PNG, JPEG, GIF, WebP, BMP)"), base_name(j.path)))
		case: request(j.app, .Project_Icon, "PATCH", fmt.tprintf("/api/project/%s", j.project), project_icon_body(j.url), j.project)
		}
	}, icon_job_new(app, project, path), icon_job_free)
}

// An image's bytes as the icon: decoded, made PROJECT_ICON_SIDE at most (its proportions kept), a PNG (temp allocator).
project_icon_png :: proc(data: []u8) -> (out: []u8, ok: bool) {
	if len(data) == 0 { return }
	w, h: u32
	buf: Ocn_Buf
	if ocn_image_decode(raw_data(data), len(data), i32(Image_Encoding.Bytes), PROJECT_ICON_SIDE, &w, &h, &buf) != 0 { ocn_buf_free(buf); return }
	defer ocn_buf_free(buf)
	out = png.encode(buf.ptr[:buf.len], int(w), int(h), allocator = context.temp_allocator)
	return out, len(out) > 0
}

project_icon_remove :: proc(app: ^App, project: string) {
	if project == "" { return }
	request(app, .Project_Icon, "PATCH", fmt.tprintf("/api/project/%s", project), project_icon_body(""), project)
}

// (shown at once, as project.updated would)
project_icon_on_ok :: proc(app: ^App, r: ^Request, v: json.Value) { request(app, .Projects, "GET", "/api/project") }

// Whether the user gave the project an icon of their own.
project_icon_overridden :: proc(app: ^App, project: string) -> bool {
	p, ok := app.projects[project]
	return ok && p.overridden
}

// A menu's items for a project's icon.
project_icon_items :: proc(app: ^App, project: string) {
	if project == "" { return }
	if ui.menu_item(i18n.tr("Set the project's icon…"), icon = lucide.IMAGE).clicked { project_icon_pick(app, project) }
	if project_icon_overridden(app, project) {
		if ui.menu_item(i18n.tr("Remove the project's icon"), icon = lucide.TRASH_2).clicked { project_icon_remove(app, project) }
	}
}
