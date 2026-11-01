#!/usr/bin/env bash
# Builds the Linux client from this tree, in Linux, without a release (tools/screenshots.mjs --linux-build starts it from
# Windows): a copy in a Linux folder, since the Rust and Odin outputs are not to mix with those of Windows in build/.
#   tools/wsl_build.sh [folder]      default ~/.cache/opencode-native-build; the program: <folder>/build/opencode-native
set -euo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
dest="${1:-$HOME/.cache/opencode-native-build}"
if [ -z "${IN_NIX_SHELL:-}" ] && command -v nix >/dev/null; then
  exec nix --extra-experimental-features "nix-command flakes" develop "$here" --command bash "$0" "$dest"
fi
mkdir -p "$dest"
rsync -a --delete --exclude build --exclude target --exclude .git --exclude .claude --exclude '*.exe' --exclude '*.pdb' "$here/" "$dest/"
cd "$dest"
./build.sh
echo "$dest/build/opencode-native"
