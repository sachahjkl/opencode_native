// Desktop integration on Windows: the client is one portable executable that installs itself, for the user only
// (HKEY_CURRENT_USER and the user's folders, never administrator rights):
//   %LOCALAPPDATA%\Programs\opencode-native\opencode-native.exe    the installed copy
//   Start menu\Programs\opencode native.lnk                         its launcher (and optionally one on the Desktop),
//                                                                   carrying the AppUserModelID the windows use, so a
//                                                                   pinned taskbar icon and the windows group together
//   HKCU\...\CurrentVersion\Uninstall\OpencodeNative                 the entry of Settings > Apps (uninstall from there)
// `--install [--desktop]`, `--uninstall`, `--status` do it without a window; the Setup dialog (setup.odin) does it with one.
// Installing over a copy that runs: its file is renamed to .old (a running program's file can be renamed, not
// overwritten), and the installed copy deletes the .old at its next start. Uninstalling the copy that runs: a hidden
// batch file in %TEMP% waits for it to end, then deletes it and the folder.
package occ

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import win "core:sys/windows"

APP_ID        :: "FromentSoftware.OpencodeNative"   // AppUserModelID of the windows and the shortcuts
APP_NAME      :: "opencode native"
APP_PUBLISHER :: "Froment Software"
EXE_NAME      :: "opencode-native.exe"
UNINSTALL_KEY :: `Software\Microsoft\Windows\CurrentVersion\Uninstall\OpencodeNative`
MARK_VALUE    :: "OpencodeNativeIntegration"         // in our registry key: the mark that makes it ours

Install_State :: enum u8 {
	Not_Installed,
	This_Copy,        // the running program is the installed copy, everything in place
	Repair,           // this is the installed copy, but a shortcut or the Settings entry is missing
	Other_Copy,       // a copy is installed elsewhere: this one runs standalone (Install replaces that one)
}

Install_Facts :: struct {
	state:     Install_State,
	dir:       string,   // where the installed copy is (or would go)
	exe:       string,
	running:   string,   // this program
	start_lnk: bool,
	desk_lnk:  bool,
	record:    bool,
	version:   string,   // of the installed copy, from its record
}

////////////////////////////////
// COM: IShellLinkW, IPersistFile, IPropertyStore (vtables in the order of the SDK headers; the offsets are what matters)

@(private = "file") CLSID_ShellLink    := win.GUID{0x00021401, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IShellLinkW    := win.GUID{0x000214F9, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IPersistFile   := win.GUID{0x0000010B, 0x0000, 0x0000, {0xC0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}}
@(private = "file") IID_IPropertyStore := win.GUID{0x886D8EEB, 0x8CF2, 0x4446, {0x8D, 0x02, 0xCD, 0xBA, 0x1D, 0xBD, 0xCF, 0x99}}

@(private = "file") Property_Key :: struct { fmtid: win.GUID, pid: u32 }
@(private = "file") PKEY_AppUserModel_ID := Property_Key{{0x9F4C2855, 0x9F79, 0x4B39, {0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3}}, 5}

// The real PROPVARIANT (24 bytes on 64-bit Windows; core:sys/windows declares a 16-byte one).
@(private = "file") Prop_Variant :: struct { vt: u16, reserved: [3]u16, pointer: rawptr, pad: u64 }
#assert(size_of(Prop_Variant) == 24)
@(private = "file") VT_LPWSTR :: u16(31)

@(private = "file") IShellLinkW :: struct { using vtbl: ^IShellLinkW_Vtbl }
@(private = "file") IShellLinkW_Vtbl :: struct {
	QueryInterface:      proc "system" (this: ^IShellLinkW, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:              proc "system" (this: ^IShellLinkW) -> u32,
	Release:             proc "system" (this: ^IShellLinkW) -> u32,
	GetPath:             proc "system" (this: ^IShellLinkW, file: [^]u16, cch: i32, find_data: rawptr, flags: u32) -> win.HRESULT,
	GetIDList:           rawptr,
	SetIDList:           rawptr,
	GetDescription:      rawptr,
	SetDescription:      proc "system" (this: ^IShellLinkW, name: cstring16) -> win.HRESULT,
	GetWorkingDirectory: rawptr,
	SetWorkingDirectory: proc "system" (this: ^IShellLinkW, dir: cstring16) -> win.HRESULT,
	GetArguments:        rawptr,
	SetArguments:        proc "system" (this: ^IShellLinkW, args: cstring16) -> win.HRESULT,
	GetHotkey:           rawptr,
	SetHotkey:           rawptr,
	GetShowCmd:          rawptr,
	SetShowCmd:          rawptr,
	GetIconLocation:     rawptr,
	SetIconLocation:     proc "system" (this: ^IShellLinkW, path: cstring16, index: i32) -> win.HRESULT,
	SetRelativePath:     rawptr,
	Resolve:             rawptr,
	SetPath:             proc "system" (this: ^IShellLinkW, path: cstring16) -> win.HRESULT,
}

@(private = "file") IPersistFile :: struct { using vtbl: ^IPersistFile_Vtbl }
@(private = "file") IPersistFile_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IPersistFile, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IPersistFile) -> u32,
	Release:        proc "system" (this: ^IPersistFile) -> u32,
	GetClassID:     rawptr,
	IsDirty:        rawptr,
	Load:           proc "system" (this: ^IPersistFile, file: cstring16, mode: u32) -> win.HRESULT,
	Save:           proc "system" (this: ^IPersistFile, file: cstring16, remember: win.BOOL) -> win.HRESULT,
	SaveCompleted:  rawptr,
	GetCurFile:     rawptr,
}

@(private = "file") IPropertyStore :: struct { using vtbl: ^IPropertyStore_Vtbl }
@(private = "file") IPropertyStore_Vtbl :: struct {
	QueryInterface: proc "system" (this: ^IPropertyStore, riid: ^win.GUID, out: ^rawptr) -> win.HRESULT,
	AddRef:         proc "system" (this: ^IPropertyStore) -> u32,
	Release:        proc "system" (this: ^IPropertyStore) -> u32,
	GetCount:       rawptr,
	GetAt:          rawptr,
	GetValue:       rawptr,
	SetValue:       proc "system" (this: ^IPropertyStore, key: ^Property_Key, value: ^Prop_Variant) -> win.HRESULT,
	Commit:         proc "system" (this: ^IPropertyStore) -> win.HRESULT,
}

foreign import shell32_ "system:Shell32.lib"
foreign import advapi32_ "system:Advapi32.lib"

@(default_calling_convention = "system", private = "file")
foreign shell32_ {
	SetCurrentProcessExplicitAppUserModelID :: proc(app_id: cstring16) -> win.HRESULT ---
}

@(default_calling_convention = "system", private = "file")
foreign advapi32_ {
	RegDeleteTreeW :: proc(key: win.HKEY, sub_key: cstring16) -> win.LSTATUS ---
}

@(private = "file")
wide :: proc(s: string) -> cstring16 { return win.utf8_to_wstring(s, context.temp_allocator) }

////////////////////////////////
// Places

@(private = "file")
known_folder :: proc(id: win.KNOWNFOLDERID) -> string {
	id := id
	path: win.LPWSTR
	if win.SHGetKnownFolderPath(&id, 0, nil, &path) < 0 || path == nil { return "" }
	defer win.CoTaskMemFree(path)
	s, _ := win.wstring_to_utf8_alloc(win.wstring(path), -1, context.temp_allocator)
	return s
}

install_dir :: proc() -> string {
	return pjoin({known_folder(win.FOLDERID_LocalAppData), "Programs", "opencode-native"})
}

@(private = "file")
start_lnk_path :: proc() -> string { return pjoin({known_folder(win.FOLDERID_Programs), APP_NAME + ".lnk"}) }

@(private = "file")
desk_lnk_path :: proc() -> string { return pjoin({known_folder(win.FOLDERID_Desktop), APP_NAME + ".lnk"}) }

running_exe :: proc() -> string {
	buf: [1024]u16
	n := win.GetModuleFileNameW(nil, &buf[0], len(buf))
	s, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s
}

same_path :: proc(a, b: string) -> bool {
	na := strings.to_lower(strings.trim_right(pclean(a), `\/`), context.temp_allocator)
	nb := strings.to_lower(strings.trim_right(pclean(b), `\/`), context.temp_allocator)
	return na == nb
}

////////////////////////////////
// Registry (HKCU only)

@(private = "file")
reg_set :: proc(path, name, value: string) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	w := win.utf8_to_utf16(value, context.temp_allocator)
	z := make([]u16, len(w) + 1, context.temp_allocator)
	copy(z, w)
	return win.RegSetValueExW(key, wide(name), 0, win.REG_SZ, cast(^win.BYTE)raw_data(z), win.DWORD(len(z) * 2)) == 0
}

@(private = "file")
reg_set_dword :: proc(path, name: string, value: u32) -> bool {
	key: win.HKEY
	if win.RegCreateKeyExW(win.HKEY_CURRENT_USER, wide(path), 0, nil, win.REG_OPTION_NON_VOLATILE, win.KEY_SET_VALUE, nil, &key, nil) != 0 { return false }
	defer win.RegCloseKey(key)
	v := value
	return win.RegSetValueExW(key, wide(name), 0, win.REG_DWORD, cast(^win.BYTE)&v, 4) == 0
}

@(private = "file")
reg_get :: proc(path, name: string) -> (string, bool) {
	size: win.DWORD
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), wide(name), win.RRF_RT_REG_SZ, nil, nil, &size) != 0 || size < 2 { return "", false }
	buf := make([]u16, int(size) / 2 + 1, context.temp_allocator)
	if win.RegGetValueW(win.HKEY_CURRENT_USER, wide(path), wide(name), win.RRF_RT_REG_SZ, nil, raw_data(buf), &size) != 0 { return "", false }
	n := 0
	for n < len(buf) && buf[n] != 0 { n += 1 }
	s, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s, true
}

////////////////////////////////
// Shortcuts

@(private = "file")
make_shortcut :: proc(lnk, target: string) -> bool {
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer if hr >= 0 { win.CoUninitialize() }
	link: ^IShellLinkW
	if win.CoCreateInstance(&CLSID_ShellLink, nil, win.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, cast(^rawptr)&link) < 0 || link == nil { return false }
	defer link->Release()
	link->SetPath(wide(target))
	link->SetWorkingDirectory(wide(filepath.dir(target)))
	link->SetDescription(wide("A native client for the opencode server"))
	link->SetIconLocation(wide(target), 0)
	store: ^IPropertyStore
	if link->QueryInterface(&IID_IPropertyStore, cast(^rawptr)&store) >= 0 && store != nil {
		pv := Prop_Variant{vt = VT_LPWSTR, pointer = rawptr(wide(APP_ID))}
		store->SetValue(&PKEY_AppUserModel_ID, &pv)
		store->Commit()
		store->Release()
	}
	file: ^IPersistFile
	if link->QueryInterface(&IID_IPersistFile, cast(^rawptr)&file) < 0 || file == nil { return false }
	defer file->Release()
	return file->Save(wide(lnk), true) >= 0
}

// The program a shortcut runs ("" when it is not a shortcut we can read).
@(private = "file")
shortcut_target :: proc(lnk: string) -> string {
	if !os.exists(lnk) { return "" }
	hr := win.CoInitializeEx(nil, .APARTMENTTHREADED)
	defer if hr >= 0 { win.CoUninitialize() }
	link: ^IShellLinkW
	if win.CoCreateInstance(&CLSID_ShellLink, nil, win.CLSCTX_INPROC_SERVER, &IID_IShellLinkW, cast(^rawptr)&link) < 0 || link == nil { return "" }
	defer link->Release()
	file: ^IPersistFile
	if link->QueryInterface(&IID_IPersistFile, cast(^rawptr)&file) < 0 || file == nil { return "" }
	defer file->Release()
	if file->Load(wide(lnk), 0) < 0 { return "" }
	buf: [1024]u16
	if link->GetPath(&buf[0], len(buf), nil, 0x4) < 0 { return "" }   // SLGP_RAWPATH
	n := 0
	for n < len(buf) && buf[n] != 0 { n += 1 }
	s, _ := win.utf16_to_utf8(buf[:n], context.temp_allocator)
	return s
}

////////////////////////////////
// What is there

// The windows of this process group under the shortcuts' AppUserModelID (call before the first window).
set_app_id :: proc() { SetCurrentProcessExplicitAppUserModelID(wide(APP_ID)) }

install_facts :: proc() -> (f: Install_Facts) {
	f.running = running_exe()
	f.dir = install_dir()
	if loc, ok := reg_get(UNINSTALL_KEY, "InstallLocation"); ok && loc != "" { f.dir = loc }
	f.exe = pjoin({f.dir, EXE_NAME})
	_, f.record = reg_get(UNINSTALL_KEY, MARK_VALUE)
	f.version, _ = reg_get(UNINSTALL_KEY, "DisplayVersion")
	f.start_lnk = same_path(shortcut_target(start_lnk_path()), f.exe)
	f.desk_lnk = same_path(shortcut_target(desk_lnk_path()), f.exe)
	installed := os.exists(f.exe)
	switch {
	case !installed:                  f.state = .Not_Installed
	case !same_path(f.running, f.exe): f.state = .Other_Copy
	case !f.start_lnk || !f.record:   f.state = .Repair
	case:                             f.state = .This_Copy
	}
	return
}

////////////////////////////////
// Install and uninstall

// Copies this program into the install folder (unless it runs from there), writes the shortcuts and the Settings entry.
desktop_install :: proc(desktop_shortcut: bool) -> (ok: bool, msg: string) {
	src := running_exe()
	dir := install_dir()
	if loc, has := reg_get(UNINSTALL_KEY, "InstallLocation"); has && loc != "" { dir = loc }
	exe := pjoin({dir, EXE_NAME})
	if err := os.make_directory_all(dir); err != nil && !os.exists(dir) { return false, fmt.tprintf("cannot create %s", dir) }
	if !same_path(src, exe) {
		// a running installed copy: its file can be renamed, not overwritten
		if os.exists(exe) {
			old := strings.concatenate({exe, ".old"}, context.temp_allocator)
			_ = os.remove(old)
			if !win.MoveFileExW(wide(exe), wide(old), win.MOVEFILE_REPLACE_EXISTING) { return false, fmt.tprintf("cannot replace %s (in use?)", exe) }
		}
		if !win.CopyFileW(wide(src), wide(exe), false) { return false, fmt.tprintf("cannot copy the program to %s", exe) }
	}
	if !make_shortcut(start_lnk_path(), exe) { return false, "cannot write the Start menu shortcut" }
	if desktop_shortcut {
		if !make_shortcut(desk_lnk_path(), exe) { return false, "cannot write the Desktop shortcut" }
	} else if same_path(shortcut_target(desk_lnk_path()), exe) {
		_ = os.remove(desk_lnk_path())
	}
	size_kb := u32(0)
	if fi, err := os.stat(exe, context.temp_allocator); err == nil { size_kb = u32(fi.size / 1024) }
	k := UNINSTALL_KEY
	q := fmt.tprintf(`"%s"`, exe)
	ok = reg_set(k, "DisplayName", APP_NAME)
	ok = ok && reg_set(k, "DisplayVersion", APP_VERSION)
	ok = ok && reg_set(k, "Publisher", APP_PUBLISHER)
	ok = ok && reg_set(k, "InstallLocation", dir)
	ok = ok && reg_set(k, "DisplayIcon", fmt.tprintf("%s,0", exe))
	ok = ok && reg_set(k, "UninstallString", fmt.tprintf("%s --uninstall", q))
	ok = ok && reg_set(k, "QuietUninstallString", fmt.tprintf("%s --uninstall", q))
	ok = ok && reg_set(k, "URLInfoAbout", "https://opencode.ai")
	ok = ok && reg_set(k, MARK_VALUE, APP_ID)
	ok = ok && reg_set_dword(k, "NoModify", 1) && reg_set_dword(k, "NoRepair", 1) && reg_set_dword(k, "EstimatedSize", size_kb)
	if !ok { return false, "cannot write the Settings > Apps entry" }
	win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, 0, nil, nil)
	return true, exe
}

// Removes the shortcuts (ours only), the Settings entry and the installed files. When the installed copy is the one
// running, its file and folder go once it has ended (`deferred`).
desktop_uninstall :: proc() -> (ok: bool, deferred: bool, msg: string) {
	f := install_facts()
	for lnk in ([]string{start_lnk_path(), desk_lnk_path()}) {
		if same_path(shortcut_target(lnk), f.exe) { _ = os.remove(lnk) }
	}
	if _, ours := reg_get(UNINSTALL_KEY, MARK_VALUE); ours {
		r := RegDeleteTreeW(win.HKEY_CURRENT_USER, wide(UNINSTALL_KEY))
		if r != 0 && r != win.LSTATUS(win.ERROR_FILE_NOT_FOUND) { return false, false, "cannot remove the Settings > Apps entry" }
	}
	if os.exists(f.exe) {
		if same_path(f.running, f.exe) {
			if !schedule_removal(f.exe, f.dir) { return false, false, "cannot schedule the removal of the program" }
			deferred = true
		} else {
			if os.remove(f.exe) != nil { return false, false, fmt.tprintf("cannot delete %s (in use?)", f.exe) }
			_ = os.remove(strings.concatenate({f.exe, ".old"}, context.temp_allocator))
			_ = win.RemoveDirectoryW(wide(f.dir))   // (only when empty)
		}
	}
	win.SHChangeNotify(win.SHCNE_ASSOCCHANGED, 0, nil, nil)
	return true, deferred, ""
}

// A hidden batch file that deletes the program once this process has let go of it (it tries again every second, for a
// minute at most), then the folder when it is empty, then itself. Its console is hidden, not absent (CREATE_NO_WINDOW):
// the commands it runs need one.
@(private = "file")
schedule_removal :: proc(exe, dir: string) -> bool {
	pid := win.GetCurrentProcessId()
	bat := pjoin({os.get_env("TEMP", context.temp_allocator), fmt.tprintf("opencode-native-uninstall-%d.cmd", pid)})
	script := fmt.tprintf(
		"@echo off\r\nset n=0\r\n:retry\r\ndel /f /q \"%s\" 2>nul\r\nif not exist \"%s\" goto done\r\nset /a n+=1\r\nif %%n%% geq 60 goto done\r\nping -n 2 127.0.0.1 >nul\r\ngoto retry\r\n:done\r\ndel /f /q \"%s.old\" 2>nul\r\nrmdir \"%s\" 2>nul\r\n(goto) 2>nul & del \"%%~f0\"\r\n",
		exe, exe, exe, dir)
	if os.write_entire_file(bat, transmute([]u8)script) != nil { return false }
	cmd := fmt.tprintf(`cmd.exe /d /c "%s"`, bat)
	wcmd := win.utf8_to_utf16(cmd, context.temp_allocator)
	z := make([]u16, len(wcmd) + 1, context.temp_allocator)
	copy(z, wcmd)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	tmp := wide(os.get_env("TEMP", context.temp_allocator))   // (not the folder being deleted)
	if !win.CreateProcessW(nil, cstring16(raw_data(z)), nil, nil, false, win.CREATE_NO_WINDOW | win.CREATE_NEW_PROCESS_GROUP, nil, tmp, &si, &pi) { return false }
	win.CloseHandle(pi.hThread)
	win.CloseHandle(pi.hProcess)
	return true
}

// The installed copy cleans what a replacement left beside it.
desktop_clean_old :: proc() {
	exe := running_exe()
	_ = os.remove(strings.concatenate({exe, ".old"}, context.temp_allocator))
}

// Starts the installed copy (after an install from a downloaded copy).
launch :: proc(exe: string) -> bool {
	wcmd := win.utf8_to_utf16(fmt.tprintf(`"%s"`, exe), context.temp_allocator)
	z := make([]u16, len(wcmd) + 1, context.temp_allocator)
	copy(z, wcmd)
	si := win.STARTUPINFOW{cb = size_of(win.STARTUPINFOW)}
	pi: win.PROCESS_INFORMATION
	if !win.CreateProcessW(nil, cstring16(raw_data(z)), nil, nil, false, 0, nil, wide(filepath.dir(exe)), &si, &pi) { return false }
	win.CloseHandle(pi.hThread)
	win.CloseHandle(pi.hProcess)
	return true
}

@(private = "file")
pclean :: proc(p: string) -> string {
	s, _ := filepath.clean(p, context.temp_allocator)
	return s
}

// A path made of `parts` (temp memory).
pjoin :: proc(parts: []string) -> string {
	s, _ := filepath.join(parts, context.temp_allocator)
	return s
}
