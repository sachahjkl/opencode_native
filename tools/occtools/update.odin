package occtools

// The signed manifests of a release (the toolkit's update package, src/update for the product, docs/updates.md).
//   occtools update keygen <file>                                the update key pair; <file> is outside the repository
//   occtools update pubkey                                       the public key of $UPDATE_SIGNING_KEY
//   occtools update manifest <exe> <version> <channel> <out.json>   a manifest and its .sig, by $UPDATE_SIGNING_KEY
//   occtools update verify <file.json> <channel>                 checks a manifest and its .sig with the built-in key

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import update "gt:update"
import occ_update "../../src/update"

KEY_ENV :: "UPDATE_SIGNING_KEY"

// Is `path` in a git work tree? A signing key there could be committed.
in_git_tree :: proc(path: string) -> bool {
	abs, err := filepath.abs(path, context.temp_allocator)
	if err != nil { return true }
	dir, _ := filepath.split(abs)
	for dir != "" {
		clean := strings.trim_right(dir, "\\/")
		if os.exists(fmt.tprintf("%s/.git", clean)) { return true }
		parent, _ := filepath.split(clean)
		if parent == dir || parent == "" { break }
		dir = parent
	}
	return false
}

@(private = "file")
seed_of_env :: proc() -> (seed: [32]byte, ok: bool) {
	text := os.get_env(KEY_ENV, context.temp_allocator)
	if text == "" { fmt.eprintfln("update: no update key: set %s", KEY_ENV); return }
	seed, ok = update.seed_decode(text)
	if !ok { fmt.eprintfln("update: %s is not an update private key (32 bytes of base64url)", KEY_ENV) }
	return
}

@(private = "file")
today :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

@(private = "file")
keygen :: proc(path: string) -> int {
	if in_git_tree(path) { fmt.eprintfln("update: refusing to write a signing key inside a git work tree: %s", path); return 1 }
	if os.exists(path) { fmt.eprintfln("update: %s exists already: a second key would orphan the releases signed with the first", path); return 1 }
	seed: [32]byte
	crypto.rand_bytes(seed[:])
	text := update.seed_encode(seed[:], context.temp_allocator)
	pub, _ := update.public_key_of(seed[:], context.temp_allocator)
	if os.write_entire_file(path, transmute([]u8)text) != nil { fmt.eprintfln("update: cannot write %s", path); return 1 }
	fmt.printfln("%s", pub)   // (the public half only: the private one stays in the file)
	return 0
}

// A manifest of the release file `exe` for `channel`, and its signature, by $UPDATE_SIGNING_KEY (release dist).
manifest :: proc(exe, version, channel, out: string) -> int {
	seed, ok := seed_of_env()
	if !ok { return 1 }
	// the platform is the one whose release name the program has
	platform := ""
	for p in update.PLATFORMS { if filepath.base(exe) == update.expected_file_name(occ_update.PRODUCT, version, p, context.temp_allocator) { platform = p } }
	if platform == "" { fmt.eprintfln("update: %s is not named as the program of a release of %s", exe, version); return 1 }
	data, err := os.read_entire_file(exe, context.allocator)
	if err != nil { fmt.eprintfln("update: cannot read %s", exe); return 1 }
	m := update.manifest_of(occ_update.PRODUCT, data, version, platform, channel, today(), context.temp_allocator)
	bytes := update.manifest_bytes(occ_update.PRODUCT, m)
	sig, signed := update.sign(occ_update.PRODUCT, seed[:], bytes, context.temp_allocator)
	if !signed { fmt.eprintln("update: cannot sign"); return 1 }
	if os.write_entire_file(out, bytes) != nil { fmt.eprintfln("update: cannot write %s", out); return 1 }
	if os.write_entire_file(fmt.tprintf("%s.sig", out), transmute([]u8)sig) != nil { fmt.eprintln("update: cannot write the signature"); return 1 }
	fmt.printfln("%s: %s %s, %d bytes", out, channel, version, len(data))
	return 0
}

@(private = "file")
verify :: proc(file, channel: string) -> int {
	data, e1 := os.read_entire_file(file, context.temp_allocator)
	sig, e2 := os.read_entire_file(fmt.tprintf("%s.sig", file), context.temp_allocator)
	if e1 != nil || e2 != nil { fmt.eprintln("update: cannot read the manifest or its signature"); return 1 }
	// the platform is in the manifest's name: update-<platform>-<channel>.json
	platform := ""
	for p in update.PLATFORMS { if filepath.base(file) == update.manifest_name(p, channel, context.temp_allocator) { platform = p } }
	if platform == "" { fmt.eprintfln("update: %s is not named update-<platform>-<channel>.json for that channel", file); return 1 }
	m, err := update.verify(occ_update.PRODUCT, data, string(sig), platform, channel, context.temp_allocator)
	if err != .None { fmt.eprintln(update.error_text(err)); return 1 }
	fmt.printfln("good: %s %s %s", m.channel, m.version, m.file)
	return 0
}

run_update :: proc(args: []string) -> int {
	what := len(args) > 0 ? args[0] : ""
	switch {
	case what == "keygen" && len(args) == 2:
		return keygen(args[1])
	case what == "pubkey" && len(args) == 1:
		seed, ok := seed_of_env()
		if !ok { return 1 }
		pub, _ := update.public_key_of(seed[:], context.temp_allocator)
		fmt.println(pub)
		return 0
	case what == "manifest" && len(args) == 5:
		return manifest(args[1], args[2], args[3], args[4])
	case what == "verify" && len(args) == 3:
		return verify(args[1], args[2])
	}
	fmt.eprintln("update: keygen <file> | pubkey | manifest <exe> <version> <channel> <out.json> | verify <file.json> <channel>")
	return EXIT_USAGE
}
