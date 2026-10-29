#!/usr/bin/env bash
# Builds opencode native on Linux. Output: build/opencode-native (one file: the Rust library, the icon font and the logo
# are in it; wgpu-native linked statically).
#   ./build.sh            optimized (what is released)
#   ./build.sh debug      debug information
# Needs the Odin compiler (odin.version) with wgpu-native's static library in its vendor/wgpu/lib (tools/fetch_wgpu.sh),
# clang (Odin links with it) and Rust (cargo, stable). At run time: Vulkan (mesa), libxkbcommon, and Wayland or X11.
# The toolkit is the submodule ext/gui_toolkit (git submodule update --init); GT=<folder> builds against another copy;
# OUT=<file> writes the program elsewhere; ODIN=<compiler> another Odin.
set -euo pipefail
cd "$(dirname "$0")"
GT="${GT:-ext/gui_toolkit}"
if [ ! -d "$GT/ui" ]; then
  if [ -d ../gui_toolkit/ui ]; then GT=../gui_toolkit; else echo "the toolkit is missing: git submodule update --init"; exit 1; fi
fi
OUT="${OUT:-build/opencode-native}"
ODIN="${ODIN:-odin}"
want="$(tr -d '[:space:]' < odin.version)"
if [ -z "${OCC_ANY_ODIN:-}" ] && ! "$ODIN" version 2>/dev/null | grep -q "$want"; then
  echo "This tree needs Odin $want (odin.version); found: $("$ODIN" version 2>&1 | head -1)"
  echo "Install that release, or set OCC_ANY_ODIN=1 to build anyway."
  exit 1
fi
tools/build_native.sh
mkdir -p "$(dirname "$OUT")"
flags=(-collection:gt="$GT" -out:"$OUT" -vet)
if [ "${1:-}" = debug ]; then
  "$ODIN" build src "${flags[@]}" -debug
else
  "$ODIN" build src "${flags[@]}" -o:speed
fi
echo "built $OUT (toolkit: $GT)"
