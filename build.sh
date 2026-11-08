#!/usr/bin/env bash
# Builds opencode native on Linux. Output: build/opencode-native (one file: the Rust library, the icon font and the logo
# are in it; wgpu-native linked statically).
#   ./build.sh            at once, not optimized (what is tried)
#   ./build.sh release    optimized (what is released, and what is measured for speed)
#   ./build.sh debug      debug information
# Needs the Odin compiler (odin.version) with wgpu-native's static library in its vendor/wgpu/lib (the toolkit's tools/tk fetch_wgpu),
# clang (Odin links with it) and Rust (cargo, stable). At run time: Vulkan (mesa), libxkbcommon, and Wayland or X11.
# The toolkit is the submodule ext/gui_toolkit (git submodule update --init); GT=<folder> builds against another copy;
# OUT=<file> writes the program elsewhere; ODIN=<compiler> another Odin.
set -euo pipefail
cd "$(dirname "$0")"
ODIN="${ODIN:-odin}"
mkdir -p build
# What builds it is tools/occtools, here built first: the steps are the same on Windows (build.bat).
"$ODIN" build tools/occtools -collection:gt="${GT:-ext/gui_toolkit}" -out:build/occtools
ODIN="$ODIN" exec build/occtools build "$@"
