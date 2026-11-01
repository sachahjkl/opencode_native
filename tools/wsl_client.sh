#!/usr/bin/env bash
# Runs a Linux build of the client in WSL, on the opencode server of Windows (a relay brings that server's port into WSL) and
# with an empty settings folder. On NixOS, where nothing is in a standard path, it finds the libraries the client opens.
#   OC_PORT=<port> OC_PASSWORD=<password> tools/wsl_client.sh <program> [arguments]
# (tools/screenshots.mjs --linux starts it; the password comes by the environment so that no command line shows it.)
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"

# the flake's shell: socat, and the libraries the client opens
if [ -z "${IN_NIX_SHELL:-}" ] && command -v nix >/dev/null; then
  exec nix --extra-experimental-features "nix-command flakes" develop "$here/.." --command bash "$0" "$@"
fi
# the GPU through WSL, else the software driver; /usr/lib/wsl/lib is what the first one talks to
if [ -n "${MESA_ICD_DIR:-}" ]; then
  export LD_LIBRARY_PATH="/usr/lib/wsl/lib:$LD_LIBRARY_PATH"
  export VK_ICD_FILENAMES="$MESA_ICD_DIR/dzn_icd.x86_64.json:$MESA_ICD_DIR/lvp_icd.x86_64.json"
fi

settings="$(mktemp -d)"
trap 'rm -rf "$settings"; kill "${relay:-}" 2>/dev/null || true' EXIT
export XDG_CONFIG_HOME="$settings" OPENCODE_NATIVE_NO_SETUP=1
# (node.exe runs on the Windows side, where 127.0.0.1 is the server. From this folder: a colon in a path would end socat's argument)
(cd "$here" && exec socat "TCP-LISTEN:$OC_PORT,bind=127.0.0.1,fork,reuseaddr" "EXEC:node.exe stdio_tcp.mjs 127.0.0.1 $OC_PORT") &
relay=$!

# What the opencode service writes where it runs: the client finds "This computer" by itself, and no command line holds the password.
mkdir -p "$settings/state/opencode"
export XDG_STATE_HOME="$settings/state"
password="${OC_PASSWORD//\\/\\\\}"
printf '{"url":"http://127.0.0.1:%s","password":"%s"}\n' "$OC_PORT" "${password//\"/\\\"}" > "$settings/state/opencode/service.json"

program="$1"; shift
"$program" "$@"
