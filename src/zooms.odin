// Zooms kept by id, beside the preferences: a shell's (by its id on the server, terminal_zoom.txt) and a session's
// conversation (by the session's id, session_zoom.txt). One "id<TAB>zoom" a line; the zoom at rest (1 for a shell, the
// preference for a session) is not kept, so that it follows that rest when it changes.
package ocn

import "core:fmt"
import "core:strconv"
import "core:strings"
import store "gt:store"

// (Where they are written, `file`, is given to each procedure that writes: app.stores.)
Kept_Zooms :: struct {
	by_id: map[string]f32,   // (keys owned)
}

// From the file as read at the start: kept here as numbers, read at each frame that shows them.
zooms_load :: proc(z: ^Kept_Zooms, file: ^store.Store, least, most: f32) {
	for e in store.list(file) {
		if v, ok := strconv.parse_f32(e.value); ok { z.by_id[strings.clone(e.key)] = clamp(v, least, most) }
	}
}

zoom_of :: proc(z: ^Kept_Zooms, id: string, rest: f32) -> f32 { return z.by_id[id] or_else rest }

// `id`'s zoom: `rest` forgets it (it follows the rest again).
zoom_keep :: proc(z: ^Kept_Zooms, file: ^store.Store, id: string, zoom, rest: f32) {
	if id == "" { return }
	if zoom == rest {
		zoom_forget(z, file, id)
		return
	}
	if id not_in z.by_id { z.by_id[strings.clone(id)] = zoom } else { z.by_id[id] = zoom }
	store.set(file, id, fmt.tprintf("%v", zoom))   // (%v: read back, the same number)
}

zoom_forget :: proc(z: ^Kept_Zooms, file: ^store.Store, id: string) {
	if id not_in z.by_id { return }
	key, _ := delete_key(&z.by_id, id)
	delete(key)
	store.remove(file, id)
}
