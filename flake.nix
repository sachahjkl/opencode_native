{
  # What the Linux build and its tools need, as the CI has it: the same Odin and wgpu-native, pinned by the same SHA-256.
  #   nix develop                    a shell with the compilers and the libraries the client opens at run time
  #   nix develop -c ./build.sh      builds build/opencode-native
  # git submodule update --init first: the toolkit is ext/gui_toolkit.
  description = "opencode native: a native desktop client for the opencode server";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # Odin's Linux archive has no wgpu-native: it goes where vendor:wgpu looks for it (ext/gui_toolkit/tools/tk fetch_wgpu)
      wgpu = pkgs.fetchurl {
        url = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-linux-x86_64-release.zip";
        sha256 = "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a";
      };

      # (the compiler is statically linked: nothing to patch)
      odin = pkgs.stdenv.mkDerivation {
        pname = "odin";
        version = "dev-2026-11";
        src = pkgs.fetchurl {
          url = "https://github.com/odin-lang/Odin/releases/download/dev-2026-11/odin-linux-amd64-dev-2026-11.tar.gz";
          sha256 = "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618";
        };
        nativeBuildInputs = [ pkgs.makeWrapper pkgs.unzip ];
        dontBuild = true;
        dontStrip = true;
        dontPatchELF = true;
        installPhase = ''
          mkdir -p $out/lib/odin $out/bin
          cp -r . $out/lib/odin
          dest=$out/lib/odin/vendor/wgpu/lib/wgpu-linux-x86_64-release
          mkdir -p $dest
          unzip -qo ${wgpu} -d $dest
          echo 29.0.1.1 > $dest/VERSION
          makeWrapper $out/lib/odin/odin $out/bin/odin --set ODIN_ROOT $out/lib/odin/
        '';
      };

      # What the client opens at run time (dlopen): nothing is in a standard path on NixOS.
      runtime = with pkgs; [
        vulkan-loader mesa libxkbcommon wayland libx11 libxcb libxcursor libxrandr libxi libxext libxcb-cursor fontconfig freetype dbus
      ];

      # The latest Linux release, as published: the tag and the hash of its SHA256SUMS.txt.
      # The Vulkan driver is the system's (/run/opengl-driver): mesa is not in its RUNPATH.
      version = "0.20.0";
      opencode-native = pkgs.stdenv.mkDerivation {
        pname = "opencode-native";
        inherit version;
        src = pkgs.fetchurl {
          url = "https://github.com/sachahjkl/opencode_native/releases/download/v${version}/opencode-native-${version}-linux-x64.tar.gz";
          sha256 = "4b21b36be601931b2fbe674f840d1f0e7b4ba7a9662db4fab3cfc1849c67015e";
        };
        nativeBuildInputs = [ pkgs.autoPatchelfHook pkgs.copyDesktopItems ];
        buildInputs = [ pkgs.fontconfig pkgs.freetype pkgs.stdenv.cc.cc.lib ];
        # the libraries it opens with dlopen go in its RUNPATH: no LD_LIBRARY_PATH, which the shells of its terminals would inherit
        runtimeDependencies = pkgs.lib.remove pkgs.mesa runtime;
        dontBuild = true;
        dontStrip = true;
        desktopItems = [
          (pkgs.makeDesktopItem {
            name = "opencode-native";
            desktopName = "opencode native";
            genericName = "opencode client";
            comment = "A native desktop client for the opencode server. Not affiliated with the OpenCode team.";
            exec = "opencode-native %U";
            icon = "opencode-native";
            categories = [ "Development" ];
            startupWMClass = "opencode-native";
          })
        ];
        installPhase = ''
          runHook preInstall
          install -Dm755 opencode-native $out/bin/opencode-native
          install -Dm644 ${./assets/logo_256.png} $out/share/icons/hicolor/256x256/apps/opencode-native.png
          install -Dm644 -t $out/share/doc/opencode-native README.txt *LICENSE*
          runHook postInstall
        '';
        meta = {
          description = "A native desktop client for the opencode server";
          homepage = "https://github.com/sachahjkl/opencode_native";
          license = pkgs.lib.licenses.mit;
          platforms = [ system ];
          mainProgram = "opencode-native";
          sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
        };
      };
    in
    {
      packages.${system} = {
        inherit odin opencode-native;
        default = opencode-native;
      };

      apps.${system}.default = {
        type = "app";
        program = pkgs.lib.getExe opencode-native;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [ odin ] ++ (with pkgs; [ clang lld cargo rustc nodejs rsync socat ]);
        buildInputs = [ pkgs.fontconfig ];
        shellHook = "export LD_LIBRARY_PATH=${pkgs.lib.makeLibraryPath runtime} FONTCONFIG_FILE=${pkgs.makeFontsConf { fontDirectories = [ pkgs.noto-fonts-color-emoji ]; }}";   # (nix develop clears the variable if set as an attribute)
        # the system's Vulkan drivers where it has them; under WSL, tools/wsl_client.sh says which
        MESA_ICD_DIR = "${pkgs.mesa}/share/vulkan/icd.d";
      };
    };
}
