package ocn

import "core:slice"
import "core:strings"
import "core:testing"

// The libraries a classic install on NixOS gets are those the Nix package opens (flake.nix's `runtime`, without mesa: the
// Vulkan driver is the system's).
@(test)
nixos_libraries_follow_the_flake :: proc(t: ^testing.T) {
	flake := string(#load("../flake.nix"))
	START :: "runtime = with pkgs; ["
	i := strings.index(flake, START)
	testing.expect(t, i >= 0, "flake.nix has its runtime list")
	if i < 0 { return }
	rest := flake[i + len(START):]
	names := strings.fields(rest[:strings.index_byte(rest, ']')], context.temp_allocator)
	testing.expect(t, len(names) > 0)
	for n in names {
		if n == "mesa" { continue }
		testing.expectf(t, slice.contains(NIXOS_LIBRARIES[:], n), "%s is in the runtime of flake.nix, not in NIXOS_LIBRARIES", n)
	}
}
