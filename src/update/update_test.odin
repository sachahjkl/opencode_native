package update

import "core:testing"

@(private = "file") TEST_SEED := [32]byte{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32}

@(private = "file")
signed :: proc(channel, version: string) -> (bytes: []byte, sig, key: string) {
	m := Manifest{channel = channel, version = version, platform = PLATFORM_WINDOWS_X64, file = expected_file_name(version, PLATFORM_WINDOWS_X64, context.temp_allocator), sha256 = sha256_hex([]byte{1}, context.temp_allocator), size = MIN_BINARY, published = "2026-11-05"}
	bytes = manifest_bytes(m, context.temp_allocator)
	sig, _ = sign(TEST_SEED[:], bytes, context.temp_allocator)
	key, _ = public_key_of(TEST_SEED[:], context.temp_allocator)
	return
}

@(test)
a_signed_manifest_of_its_channel_is_read :: proc(t: ^testing.T) {
	b, sig, key := signed("beta", "1.2.3")
	m, err := check_release(b, sig, key, PLATFORM_WINDOWS_X64, "beta", "1.2.2", "", context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	testing.expect_value(t, m.version, "1.2.3")
}

@(test)
a_beta_served_on_the_stable_channel_is_refused :: proc(t: ^testing.T) {
	b, sig, key := signed("beta", "1.2.3")
	_, err := check_release(b, sig, key, PLATFORM_WINDOWS_X64, "stable", "1.2.2", "", context.temp_allocator)
	testing.expect_value(t, err, Error.Wrong_Channel)
}

@(test)
a_changed_manifest_is_refused :: proc(t: ^testing.T) {
	b, sig, key := signed("stable", "1.2.3")
	b[len(b) - 3] ~= 1
	_, err := verify(b, sig, key, PLATFORM_WINDOWS_X64, "stable", context.temp_allocator)
	testing.expect_value(t, err, Error.Bad_Signature)
}

@(test)
an_older_or_equal_version_is_refused :: proc(t: ^testing.T) {
	b, sig, key := signed("stable", "1.2.3")
	_, same := check_release(b, sig, key, PLATFORM_WINDOWS_X64, "stable", "1.2.3", "", context.temp_allocator)
	testing.expect_value(t, same, Error.Not_Newer)
	_, older := check_release(b, sig, key, PLATFORM_WINDOWS_X64, "stable", "2.0.0", "", context.temp_allocator)
	testing.expect_value(t, older, Error.Not_Newer)
}

@(test)
a_file_that_is_not_the_signed_one_is_refused :: proc(t: ^testing.T) {
	data := []byte{1, 2, 3}
	m := Manifest{size = 3, sha256 = sha256_hex(data, context.temp_allocator)}
	testing.expect_value(t, check_binary(m, data), Error.None)
	testing.expect_value(t, check_binary(m, []byte{1, 2}), Error.Size_Mismatch)
	testing.expect_value(t, check_binary(m, []byte{1, 2, 4}), Error.Hash_Mismatch)
}

@(test)
the_linux_program_is_named_and_checked_as_one :: proc(t: ^testing.T) {
	testing.expect_value(t, expected_file_name("1.2.3", PLATFORM_LINUX_X64, context.temp_allocator), "opencode-native-1.2.3-linux-x64")
	testing.expect_value(t, expected_file_name("1.2.3", PLATFORM_WINDOWS_X64, context.temp_allocator), "opencode-native-1.2.3-windows-x64.exe")
	testing.expect(t, is_program(transmute([]byte)string("\x7fELF\x02"), PLATFORM_LINUX_X64), "ELF on Linux")
	testing.expect(t, !is_program(transmute([]byte)string("MZ\x90"), PLATFORM_LINUX_X64), "no PE on Linux")
	testing.expect(t, is_program(transmute([]byte)string("MZ\x90"), PLATFORM_WINDOWS_X64), "PE on Windows")
	m := Manifest{channel = "stable", version = "1.2.3", platform = PLATFORM_LINUX_X64, file = expected_file_name("1.2.3", PLATFORM_LINUX_X64, context.temp_allocator), sha256 = sha256_hex([]byte{1}, context.temp_allocator), size = MIN_BINARY, published = "2026-11-08"}
	b := manifest_bytes(m, context.temp_allocator)
	sig, _ := sign(TEST_SEED[:], b, context.temp_allocator)
	key, _ := public_key_of(TEST_SEED[:], context.temp_allocator)
	_, err := check_release(b, sig, key, PLATFORM_LINUX_X64, "stable", "1.2.2", "", context.temp_allocator)
	testing.expect_value(t, err, Error.None)
	_, other := check_release(b, sig, key, PLATFORM_WINDOWS_X64, "stable", "1.2.2", "", context.temp_allocator)
	testing.expect_value(t, other, Error.Wrong_Platform)
}
