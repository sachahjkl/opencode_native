#!/usr/bin/env bash
# Makes the Linux release file of a finished build (build.sh) in build/dist:
#   opencode-native-<version>-linux-x64.tar.gz    opencode-native-<version>/ with the program (one file: the Rust library,
#                                                 the text backend, wgpu-native, the icon font and the logo are in it),
#                                                 the licences and a README; install it from its Setup (title bar menu) or
#                                                 with ./opencode-native --install
#   tools/package.sh [version]
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:-$(sed -n 's/^APP_VERSION *:: *"\(.*\)"/\1/p' src/setup.odin)}"
[ -f build/opencode-native ] || { echo "build/opencode-native is missing: run ./build.sh first"; exit 1; }
name="opencode-native-$VERSION"
stage="build/stage/$name"
rm -rf build/stage && mkdir -p "$stage" build/dist
cp build/opencode-native "$stage/"
cp LICENSE "$stage/LICENSE"
cp assets/fonts/*-LICENSE.txt "$stage/"
cat > "$stage/README.txt" <<TXT
opencode native $VERSION for Linux (x64): a native desktop client for the opencode server.

  ./opencode-native              run it (it finds the opencode server of this computer by itself)
  ./opencode-native --install    install it for your user: ~/.local/share/opencode-native, an entry in the applications
                                 menu, its icon (or from its Setup: title bar menu > Setup...)
  ./opencode-native --url=https://host:port --password=...    another server

Needs: Vulkan (mesa-vulkan-drivers or your GPU's driver, libvulkan1), libxkbcommon, fontconfig, and Wayland or X11.
https://github.com/sachahjkl/opencode_native
TXT
tar -C build/stage -czf "build/dist/$name-linux-x64.tar.gz" "$name"
echo "packaged build/dist/$name-linux-x64.tar.gz"
