#!/usr/bin/env bash
# Builds the client's Rust code (the native/ workspace) into build/native/libocc_native.a, the one Rust static library
# linked into opencode-native (tools/build_native.ps1 is the Windows side): HTTP and the event stream (ureq, rustls, the
# system's trust store), image decoding. Crates pinned by native/Cargo.lock (--locked).
#   tools/build_native.sh [--force]
# Does nothing when build/native/STAMP matches the hash of the sources, Cargo.lock and this script.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/native"
LIB="$OUT/libocc_native.a"
STAMP="$( { cat "$ROOT/native/Cargo.toml" "$ROOT/native/Cargo.lock" "$0"; find "$ROOT/native" -path "$ROOT/native/target" -prune -o \( -name '*.rs' -o -name Cargo.toml \) -print | LC_ALL=C sort | xargs cat; } | sha256sum | cut -d' ' -f1)"
if [ "${1:-}" != --force ] && [ -f "$LIB" ] && [ "$(cat "$OUT/STAMP" 2>/dev/null)" = "$STAMP" ]; then
  echo "occ_native up to date in $OUT"
  exit 0
fi
command -v cargo >/dev/null || { echo "cargo not found: install Rust (stable)"; exit 1; }
mkdir -p "$OUT"
(cd "$ROOT/native" && cargo build --release --locked --target-dir "$OUT/target")
cp "$OUT/target/release/libocc_native.a" "$LIB"
printf '%s' "$STAMP" > "$OUT/STAMP"
echo "built $LIB"
