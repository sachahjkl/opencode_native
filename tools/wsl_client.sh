#!/usr/bin/env bash
# Runs a Linux build of the client in WSL, on the opencode server of Windows (a relay brings that server's port into WSL) and
# with an empty settings folder. On NixOS, where nothing is in a standard path, it finds the libraries the client opens.
#   OC_PORT=<port> OC_PASSWORD=<password> tools/wsl_client.sh <program> [arguments]
# (tools/screenshots.mjs --linux starts it; the password comes by the environment so that no command line shows it.)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

if ! command -v socat >/dev/null; then
  exec nix-shell -p socat --run "$(printf '%q ' bash "$0" "$@")"
fi

if command -v nix >/dev/null; then
  nx=(nix --extra-experimental-features "nix-command flakes")
  libs=/usr/lib/wsl/lib
  for p in vulkan-loader mesa libxkbcommon wayland libx11 libxcb libxcursor libxrandr libxi libxext fontconfig freetype dbus; do
    libs="$libs:$("${nx[@]}" build --no-link --print-out-paths "nixpkgs#$p.out")/lib"
  done
  export LD_LIBRARY_PATH="$libs"
  mesa="$("${nx[@]}" build --no-link --print-out-paths nixpkgs#mesa.out)"
  export VK_ICD_FILENAMES="$mesa/share/vulkan/icd.d/dzn_icd.x86_64.json"
fi

settings="$(mktemp -d)"
trap 'rm -rf "$settings"; kill "${relay:-}" 2>/dev/null || true' EXIT
export XDG_CONFIG_HOME="$settings" OPENCODE_NATIVE_NO_SETUP=1
socat "TCP-LISTEN:$OC_PORT,bind=127.0.0.1,fork,reuseaddr" \
  "EXEC:node.exe '$(wslpath -w "$here/stdio_tcp.mjs")' 127.0.0.1 $OC_PORT" &
relay=$!

program="$1"; shift
"$program" "--url=http://127.0.0.1:$OC_PORT" "--password=$OC_PASSWORD" "$@"
