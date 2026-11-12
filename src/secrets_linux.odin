// The passwords on Linux: in the Secret Service (org.freedesktop.secrets, over the session bus), or where there is none in
// the servers' file, which only the user can read (servers_save writes it so). A locked keyring asks for a prompt this
// client does not show: it counts as none for a new password, and what is already in it waits, kept (Server.stored).
package ocn

import "base:runtime"
import "core:strings"
import "core:sync"
import "core:time"
import "gt:dbus"

@(private = "file") SECRET_BUS        :: "org.freedesktop.secrets"
@(private = "file") SECRET_PATH       :: "/org/freedesktop/secrets"
@(private = "file") SECRET_COLLECTION :: "/org/freedesktop/secrets/aliases/default"
@(private = "file") IFACE_SERVICE     :: "org.freedesktop.Secret.Service"
@(private = "file") IFACE_COLLECTION  :: "org.freedesktop.Secret.Collection"
@(private = "file") IFACE_ITEM        :: "org.freedesktop.Secret.Item"
@(private = "file") SECRET_CALL_MS    :: 3000
@(private = "file") IN_SERVICE_MARK   :: "secret-service:v1"   // the field of a password kept in the service
@(private = "file") DICT_ENTRY_ALIGN  :: 8
@(private = "file") ATTR_APP          :: "opencode-native"
@(private = "file") SECRET_ASK_S      :: 5   // how long what the service answered holds

// A connection and a session with the service (no encryption on the wire: the bus is local to the user).
@(private = "file")
secret_open :: proc() -> (conn: ^dbus.Conn, session: string, ok: bool) {
	conn = dbus.connect_bus(.Session)
	if conn == nil { return nil, "", false }
	w := dbus.body_writer()
	dbus.w_string(&w, "plain")
	dbus.arg_variant_string(&w, "")
	msg, called := dbus.call(conn, SECRET_BUS, SECRET_PATH, IFACE_SERVICE, "OpenSession", "sv", w.buf[:], SECRET_CALL_MS)
	if !called { dbus.conn_close(conn); return nil, "", false }
	r := dbus.msg_reader(&msg)
	dbus.read_variant_skip(&r)
	return conn, strings.clone(dbus.r_string(&r), context.temp_allocator), true
}

// The attributes that name a server's item (a{ss}).
@(private = "file")
write_attributes :: proc(w: ^dbus.Writer, name: string) {
	al, ac := dbus.w_array_begin(w, DICT_ENTRY_ALIGN)
	dbus.w_struct(w); dbus.w_string(w, "application"); dbus.w_string(w, ATTR_APP)
	dbus.w_struct(w); dbus.w_string(w, "server"); dbus.w_string(w, name)
	dbus.w_array_end(w, al, ac)
}

// The items of a server: those unlocked, those locked (object paths, in temp memory).
@(private = "file")
secret_search :: proc(conn: ^dbus.Conn, name: string) -> (unlocked, locked: []string, ok: bool) {
	w := dbus.body_writer()
	write_attributes(&w, name)
	msg, called := dbus.call(conn, SECRET_BUS, SECRET_PATH, IFACE_SERVICE, "SearchItems", "a{ss}", w.buf[:], SECRET_CALL_MS)
	if !called { return nil, nil, false }
	r := dbus.msg_reader(&msg)
	read :: proc(r: ^dbus.Reader) -> []string {
		list := make([dynamic]string, context.temp_allocator)
		end := dbus.r_array_begin(r, "o")
		for r.pos < end && !r.err { append(&list, strings.clone(dbus.r_string(r), context.temp_allocator)) }
		return list[:]
	}
	unlocked = read(&r)
	locked = read(&r)
	return unlocked, locked, !r.err
}

// Puts a password in the service; false: no service, or its keyring is locked.
secret_store :: proc(name, password: string) -> bool {
	conn, session, ok := secret_open()
	if !ok { return false }
	defer dbus.conn_close(conn)
	w := dbus.body_writer()
	pl, pc := dbus.arg_dict_begin(&w)
	dbus.arg_dict_entry(&w, "org.freedesktop.Secret.Item.Label")
	dbus.arg_variant_string(&w, strings.concatenate({"opencode native: ", name}, context.temp_allocator))
	dbus.arg_dict_entry(&w, "org.freedesktop.Secret.Item.Attributes")
	dbus.w_signature(&w, "a{ss}")
	write_attributes(&w, name)
	dbus.w_array_end(&w, pl, pc)
	dbus.w_struct(&w)
	dbus.w_string(&w, session)
	al, ac := dbus.w_array_begin(&w, 1)   // no parameters: the plain algorithm
	dbus.w_array_end(&w, al, ac)
	bl, bc := dbus.w_array_begin(&w, 1)
	dbus.w_bytes(&w, transmute([]u8)password)
	dbus.w_array_end(&w, bl, bc)
	dbus.w_string(&w, "text/plain")
	dbus.w_bool(&w, true)   // replaces the item of the same attributes
	msg, called := dbus.call(conn, SECRET_BUS, SECRET_COLLECTION, IFACE_COLLECTION, "CreateItem", "a{sv}(oayays)b", w.buf[:], SECRET_CALL_MS)
	if !called { return false }
	r := dbus.msg_reader(&msg)
	item := dbus.r_string(&r)
	return !r.err && item != "/"   // ("/": a prompt is asked for, the keyring is locked)
}

// A server's password from the service.
secret_fetch :: proc(name: string) -> (password: string, ok: bool) {
	conn, session, opened := secret_open()
	if !opened { return "", false }
	defer dbus.conn_close(conn)
	unlocked, _, found := secret_search(conn, name)
	if !found || len(unlocked) == 0 { return "", false }
	w := dbus.body_writer()
	dbus.w_string(&w, session)
	msg, called := dbus.call(conn, SECRET_BUS, unlocked[0], IFACE_ITEM, "GetSecret", "o", w.buf[:], SECRET_CALL_MS)
	if !called { return "", false }
	r := dbus.msg_reader(&msg)
	dbus.r_align_entry(&r)
	_ = dbus.r_string(&r)
	r.pos = dbus.r_array_begin(&r, "y")   // (the parameters)
	end := dbus.r_array_begin(&r, "y")
	if r.err || end > len(r.buf) { return "", false }
	return strings.clone(string(r.buf[r.pos:end]), context.temp_allocator), true
}

// Takes a server's items out of the service.
secret_delete :: proc(name: string) {
	conn, _, ok := secret_open()
	if !ok { return }
	defer dbus.conn_close(conn)
	unlocked, locked, found := secret_search(conn, name)
	if !found { return }
	for list in ([][]string{unlocked, locked}) {
		for item in list { dbus.call(conn, SECRET_BUS, item, IFACE_ITEM, "Delete", "", nil, SECRET_CALL_MS) }
	}
}

// Whether there is a service to speak to. (Asked by the dialog at each frame: not at each one, and not once for good, a service may start.)
secret_available :: proc() -> bool {
	@(static) asked: time.Tick
	@(static) known, available: bool
	if !known || time.duration_seconds(time.tick_since(asked)) >= SECRET_ASK_S {
		available = false
		if conn, _, ok := secret_open(); ok { dbus.conn_close(conn); available = true }
		known, asked = true, time.tick_now()
	}
	return available
}

@(private = "file") in_clear: map[string]bool   // the servers whose password had to stay in the file, at their last save (keys owned)
@(private = "file") in_clear_lock: sync.Mutex   // (a save seals on a chore, the dialog reads it in a frame)

// See os_windows.odin. Without a usable service the field is the password: the file is only the user's. What is said of a server is what its
// last save found: a keyring unlocked since, and the next save moves the password there.
password_seal :: proc(name, password: string) -> (field: string, ok: bool) {
	stored := secret_store(name, password)
	sync.mutex_guard(&in_clear_lock)
	if key, _ := delete_key(&in_clear, name); key != "" { delete(key, runtime.heap_allocator()) }
	if stored { return IN_SERVICE_MARK, true }
	in_clear[strings.clone(name, runtime.heap_allocator())] = true
	return password, true
}

// (A field may name the item it stands for: a server renamed while its keyring was locked keeps the item it had.)
password_open :: proc(name, field: string) -> (password: string, sealed, ok: bool) {
	if !strings.has_prefix(field, IN_SERVICE_MARK) { return "", false, false }
	key := name
	if len(field) > len(IN_SERVICE_MARK) && field[len(IN_SERVICE_MARK)] == ':' { key = field[len(IN_SERVICE_MARK) + 1:] }
	password, ok = secret_fetch(key)
	return password, true, ok
}

// The field of a password that stays under `name`, whatever the server is called next.
password_field_of :: proc(name, field: string) -> string {
	if field != IN_SERVICE_MARK { return field }
	return strings.concatenate({IN_SERVICE_MARK, ":", name}, context.temp_allocator)
}

password_forget :: proc(name: string) { secret_delete(name) }

password_note :: proc() -> string {
	sync.lock(&in_clear_lock)
	none_in_clear := len(in_clear) == 0
	sync.unlock(&in_clear_lock)
	if secret_available() && none_in_clear { return "" }
	return "No usable Secret Service (none here, or its keyring is locked): the password stays in clear in servers.txt, which only you can read (mode 0600)."
}
