// A project's icon of the user's own: an image chosen here goes to the server as the project's icon override (a data URL,
// Project.icon.override), shown before the one the server found in the project; removed, the found one comes back. Every
// client shows the same (project.updated).
package ocn

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "gt:platform"
import "gt:png"
import "gt:ui"
import lucide "gt:lucide"

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
	filters := []platform.File_Filter{{name = "Images", patterns = {"*.png", "*.jpg", "*.jpeg", "*.gif", "*.webp", "*.bmp", "*.ico", "*.tif", "*.tiff"}}}
	r := platform.open_file_dialog({owner = app.win, title = "The project's icon", filters = filters, remember_id = "project_icon"})
	defer platform.dialog_result_destroy(&r)
	if r.status == .Unsupported { ui.toast(.Bad, "This system has no file dialog"); return }
	if r.status != .Chosen || len(r.paths) == 0 { return }
	project_icon_set_file(app, project, r.paths[0])
}

// An image file on the project, made PROJECT_ICON_SIDE at most (refused, with a toast, when it is no image).
project_icon_set_file :: proc(app: ^App, project, path: string) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil { ui.toast(.Bad, "%s cannot be read", base_name(path)); return }
	png_data, ok := project_icon_png(data)
	if !ok { ui.toast(.Warn, "%s is not an image this program reads (PNG, JPEG, GIF, WebP, BMP)", base_name(path)); return }
	b64, _ := base64.encode(png_data, allocator = context.temp_allocator)
	request(app, .Project_Icon, "PATCH", fmt.tprintf("/api/project/%s", project), project_icon_body(strings.concatenate({"data:image/png;base64,", b64}, context.temp_allocator)), project)
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

// Whether the user gave the project an icon of their own.
project_icon_overridden :: proc(app: ^App, project: string) -> bool {
	p, ok := app.projects[project]
	return ok && p.overridden
}

// A menu's items for a project's icon.
project_icon_items :: proc(app: ^App, project: string) {
	if project == "" { return }
	if ui.menu_item("Set the project's icon…", icon = lucide.IMAGE).clicked { project_icon_pick(app, project) }
	if project_icon_overridden(app, project) {
		if ui.menu_item("Remove the project's icon", icon = lucide.TRASH_2).clicked { project_icon_remove(app, project) }
	}
}
