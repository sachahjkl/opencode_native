// The signed manifests of a release (src/update, docs/updates.md).
//   odin run tools/update_tool -- keygen <file>                        the update key pair; <file> is outside the repository
//   odin run tools/update_tool -- pubkey                               the public key of $UPDATE_SIGNING_KEY
//   odin run tools/update_tool -- manifest <exe> <version> <channel> <out.json>   a manifest and its .sig, by $UPDATE_SIGNING_KEY
//   odin run tools/update_tool -- verify <file.json> <channel>         checks a manifest and its .sig with the built-in key
package update_tool

import "core:crypto"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import update "../../src/update"

KEY_ENV :: "UPDATE_SIGNING_KEY"

fail :: proc(args: ..any) -> ! {
	fmt.eprintln(..args)
	os.exit(1)
}

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

seed_of_env :: proc() -> [32]byte {
	text := os.get_env(KEY_ENV, context.temp_allocator)
	if text == "" { fail("no update key: set", KEY_ENV) }
	seed, ok := update.seed_decode(text)
	if !ok { fail(KEY_ENV, "is not an update private key (32 bytes of base64url)") }
	return seed
}

today :: proc() -> string {
	y, m, d := time.date(time.now())
	return fmt.tprintf("%04d-%02d-%02d", y, int(m), d)
}

main :: proc() {
	args := os.args[1:]
	if len(args) == 0 { fail("usage: keygen <file> | pubkey | manifest <exe> <version> <channel> <out.json> | verify <file.json> <channel>") }
	switch args[0] {
	case "keygen":
		if len(args) != 2 { fail("keygen <file>") }
		path := args[1]
		if in_git_tree(path) { fail("refusing to write a signing key inside a git work tree:", path) }
		if os.exists(path) { fail(path, "exists already: a second key would orphan the releases signed with the first") }
		seed: [32]byte
		crypto.rand_bytes(seed[:])
		text := update.seed_encode(seed[:], context.temp_allocator)
		pub, _ := update.public_key_of(seed[:], context.temp_allocator)
		if os.write_entire_file(path, transmute([]u8)text) != nil { fail("cannot write", path) }
		fmt.printfln("%s", pub)   // (the public half only: the private one stays in the file)
	case "pubkey":
		seed := seed_of_env()
		pub, _ := update.public_key_of(seed[:], context.temp_allocator)
		fmt.println(pub)
	case "manifest":
		if len(args) != 5 { fail("manifest <exe> <version> <channel> <out.json>") }
		exe, version, channel, out := args[1], args[2], args[3], args[4]
		seed := seed_of_env()
		data, err := os.read_entire_file(exe, context.allocator)
		if err != nil { fail("cannot read", exe) }
		m := update.Manifest{
			channel = channel, version = version, platform = update.PLATFORM_WINDOWS_X64,
			file = update.expected_file_name(version, update.PLATFORM_WINDOWS_X64, context.temp_allocator),
			sha256 = update.sha256_hex(data, context.temp_allocator), published = today(), size = i64(len(data)),
		}
		bytes := update.manifest_bytes(m)
		sig, ok := update.sign(seed[:], bytes, context.temp_allocator)
		if !ok { fail("cannot sign") }
		if os.write_entire_file(out, bytes) != nil { fail("cannot write", out) }
		if os.write_entire_file(fmt.tprintf("%s.sig", out), transmute([]u8)sig) != nil { fail("cannot write the signature") }
		fmt.printfln("%s: %s %s, %d bytes", out, channel, version, len(data))
	case "verify":
		if len(args) != 3 { fail("verify <file.json> <channel>") }
		data, e1 := os.read_entire_file(args[1], context.temp_allocator)
		sig, e2 := os.read_entire_file(fmt.tprintf("%s.sig", args[1]), context.temp_allocator)
		if e1 != nil || e2 != nil { fail("cannot read the manifest or its signature") }
		m, err := update.verify(data, string(sig), update.UPDATE_PUBLIC_KEY, update.PLATFORM_WINDOWS_X64, args[2], context.temp_allocator)
		if err != .None { fail(update.error_text(err)) }
		fmt.printfln("good: %s %s %s", m.channel, m.version, m.file)
	case:
		fail("unknown command", args[0])
	}
}
