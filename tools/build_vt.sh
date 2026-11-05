#!/usr/bin/env bash
# Builds libghostty-vt, the terminal emulation of the Terminal panel, into build/vt/libghostty-vt.a, linked into
# opencode-native. Ghostty's source and Zig are fetched here, into build/vt, and nowhere else.
# Pinned inputs: Ghostty by commit (the one Ghostling, its reference client, builds against), Zig by version and SHA-256.
# Does nothing when build/vt/STAMP says these same inputs were built.
set -euo pipefail
cd "$(dirname "$0")/.."
ghostty=f64f4aca2c29b554d111b36c3d946a9bddd159ff
zig_version=0.16.0
zig_sha=70e49664a74374b48b51e6f3fdfbf437f6395d42509050588bd49abe52ba3d00
out=build/vt
lib="$out/libghostty-vt.a"
stamp="$ghostty $zig_version linux"
if [ -f "$lib" ] && [ -f "$out/STAMP" ] && [ "$(cat "$out/STAMP")" = "$stamp" ]; then
  echo "libghostty-vt up to date in $out"
  exit 0
fi
mkdir -p "$out"
zig_dir="$PWD/$out/zig-x86_64-linux-$zig_version"
if [ ! -x "$zig_dir/zig" ]; then
  tarball="$out/zig.tar.xz"
  curl -fsSL "https://ziglang.org/download/$zig_version/zig-x86_64-linux-$zig_version.tar.xz" -o "$tarball"
  echo "$zig_sha  $tarball" | sha256sum -c --quiet
  tar -xf "$tarball" -C "$out"
  rm "$tarball"
fi
src="$out/ghostty"
if [ ! -d "$src/.git" ]; then
  mkdir -p "$src"
  git -C "$src" init -q
  git -C "$src" remote add origin https://github.com/ghostty-org/ghostty.git
fi
git -C "$src" fetch -q --depth 1 origin "$ghostty"
git -C "$src" -c advice.detachedHead=false checkout -q --force "$ghostty"
# (ReleaseFast: a debug build of it is very slow)
(cd "$src" && "$zig_dir/zig" build -Demit-lib-vt=true -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu)
found="$(find "$src/zig-out/lib" -name '*.a' | head -1)"
cp "$found" "$lib"
printf '%s' "$stamp" > "$out/STAMP"
echo "built $lib"
