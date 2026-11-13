{
  description = "opencode native: a native desktop client for opencode";

  inputs = {
    # the toolkit is a submodule: the package builds from it
    self.submodules = true;
    nixpkgs.url = "https://flakehub.com/f/NixOS/nixpkgs/0.1";
    git-hooks = {
      url = "https://flakehub.com/f/cachix/git-hooks.nix/0.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = {
    nixpkgs,
    git-hooks,
    ...
  }: let
    system = "x86_64-linux";
    inherit (nixpkgs) lib;
    pkgs = nixpkgs.legacyPackages.${system};

    # Odin's Linux archive has no wgpu-native: it goes where vendor:wgpu looks for it (ext/gui_toolkit/tools/tk fetch_wgpu).
    wgpu = pkgs.fetchurl {
      url = "https://github.com/gfx-rs/wgpu-native/releases/download/v29.0.1.1/wgpu-linux-x86_64-release.zip";
      sha256 = "95a4d90c071005a98d03eab348beaa6b07e16eb00d1dcdb9f8348f75eb97ec5a";
    };

    # The compiler of odin.version (statically linked: nothing to patch).
    odin = pkgs.stdenv.mkDerivation {
      pname = "odin";
      version = "dev-2026-11";
      src = pkgs.fetchurl {
        url = "https://github.com/odin-lang/Odin/releases/download/dev-2026-11/odin-linux-amd64-dev-2026-11.tar.gz";
        sha256 = "65c9f6e97d6f8a30930e151f270ce5aeaa98fe8b2ba49fe067394e2af04f7618";
      };
      nativeBuildInputs = [pkgs.makeWrapper pkgs.unzip];
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
        makeWrapper $out/lib/odin/odin $out/bin/odin --set-default ODIN_ROOT $out/lib/odin/ \
          --prefix PATH : ${lib.makeBinPath [pkgs.clang pkgs.lld]}
      '';
    };

    # Ghostty's terminal emulation (libghostty-vt), as tools/ocntools/build.odin builds it: the commit of its tag vt-1.0.0.
    ghosttyCommit = "0fa3d577a5614150ff8e2c152de5fb9d5c6d2dec";
    ghosttySrc = pkgs.fetchFromGitHub {
      owner = "ghostty-org";
      repo = "ghostty";
      rev = ghosttyCommit;
      hash = "sha256-XHatB+PU7Os1/inapleBdUThGCAGhRnqT0o0EWpNa3s=";
    };
    zig = pkgs.zig_0_17;
    # the packages of its build.zig.zon, fetched once: the build makes no request
    ghosttyDeps = zig.fetchDeps {
      pname = "ghostty";
      version = "vt-1.0.0";
      src = ghosttySrc;
      fetchAll = true;
      hash = "sha256-FCYhIMDe9KNa1Qz2iZ5cfK1U+QwDGt6DdP1Wa3DpiEI=";
    };
    libghosttyVt = pkgs.stdenvNoCC.mkDerivation {
      pname = "libghostty-vt";
      version = "1.0.0";
      src = ghosttySrc;
      nativeBuildInputs = [zig];
      dontConfigure = true;
      buildPhase = ''
        runHook preBuild
        # the fetched packages as Zig's own cache has them (archives it unpacks itself)
        export ZIG_GLOBAL_CACHE_DIR="$TMPDIR/zig-cache"
        mkdir -p "$ZIG_GLOBAL_CACHE_DIR"
        cp -r ${ghosttyDeps} "$ZIG_GLOBAL_CACHE_DIR/p"
        chmod -R u+w "$ZIG_GLOBAL_CACHE_DIR"
        # (ReleaseFast: a debug build of it is very slow. The target: the ABI of the linker Odin uses)
        zig build -Demit-lib-vt=true -Doptimize=ReleaseFast -Dtarget=x86_64-linux-gnu
        runHook postBuild
      '';
      installPhase = ''
        runHook preInstall
        install -Dm644 "$(find zig-out/lib -name '*.a' | head -1)" "$out/lib/libghostty-vt.a"
        runHook postInstall
      '';
    };

    # What the client opens at run time (dlopen): nothing is in a standard path on NixOS.
    runtime = with pkgs; [
      vulkan-loader
      libxkbcommon
      wayland
      libx11
      libxcb
      libxcursor
      libxrandr
      libxi
      libxext
      libxcb-cursor
      fontconfig
      freetype
      dbus
    ];

    # APP_VERSION of src/setup.odin
    version = let
      line = lib.findFirst (lib.hasPrefix "APP_VERSION ::") "" (lib.splitString "\n" (builtins.readFile ./src/setup.odin));
    in
      builtins.head (builtins.match ''APP_VERSION :: "([^"]+)".*'' line);

    # The client, built from this tree as the release is: ocntools build release.
    opencode-native = pkgs.stdenv.mkDerivation {
      pname = "opencode-native";
      inherit version;
      src = lib.fileset.toSource {
        root = ./.;
        fileset = lib.fileset.difference ./. (lib.fileset.unions (map lib.fileset.maybeMissing [./site ./docs ./build]));
      };
      cargoDeps = pkgs.rustPlatform.importCargoLock {lockFile = ./native/Cargo.lock;};

      nativeBuildInputs = [
        odin
        pkgs.cargo
        pkgs.rustc
        pkgs.clang
        pkgs.lld
        pkgs.autoPatchelfHook
        pkgs.copyDesktopItems
      ];
      buildInputs = [pkgs.fontconfig pkgs.freetype pkgs.stdenv.cc.cc.lib];
      # the libraries it opens with dlopen go in its RUNPATH: no LD_LIBRARY_PATH, which the shells of its terminals would
      # inherit. The Vulkan driver is the system's (/run/opengl-driver).
      runtimeDependencies = runtime;
      dontStrip = true;
      # Odin links a foreign library as -l:<absolute path> with -L/, which the purity check of the linker wrapper drops
      NIX_ENFORCE_PURITY = 0;

      configurePhase = ''
        runHook preConfigure
        export HOME="$TMPDIR"
        # the crates of native/Cargo.lock, vendored: cargo makes no request
        mkdir -p "$HOME/.cargo"
        cat > "$HOME/.cargo/config.toml" <<EOF
        [source.crates-io]
        replace-with = "vendored-sources"
        [source.vendored-sources]
        directory = "$cargoDeps"
        EOF
        export CARGO_NET_OFFLINE=true
        # libghostty-vt, built above: the stamp ocntools writes when it builds it, so it does not fetch Zig and Ghostty
        mkdir -p build/vt
        cp ${libghosttyVt}/lib/libghostty-vt.a build/vt/libghostty-vt.a
        echo "${ghosttyCommit} 0.17.0 linux" > build/vt/STAMP
        runHook postConfigure
      '';

      buildPhase = ''
        runHook preBuild
        odin run tools/ocntools -collection:gt=ext/gui_toolkit/src -out:build/ocntools -- build release
        runHook postBuild
      '';

      desktopItems = [
        (pkgs.makeDesktopItem {
          name = "opencode-native";
          desktopName = "opencode native";
          genericName = "opencode client";
          comment = "A native desktop client for opencode. Not affiliated with the OpenCode team.";
          exec = "opencode-native %U";
          icon = "opencode-native";
          categories = ["Development"];
          startupWMClass = "opencode-native";
        })
      ];

      installPhase = ''
        runHook preInstall
        install -Dm755 build/opencode-native $out/bin/opencode-native
        for size in 16 32 64 256; do
          install -Dm644 assets/logo_$size.png "$out/share/icons/hicolor/''${size}x''${size}/apps/opencode-native.png"
        done
        install -Dm644 -t $out/share/doc/opencode-native LICENSE assets/GHOSTTY-LICENSE.txt
        runHook postInstall
      '';

      meta = {
        description = "A native desktop client for opencode";
        homepage = "https://github.com/sachahjkl/opencode_native";
        license = lib.licenses.mit;
        platforms = [system];
        mainProgram = "opencode-native";
      };
    };

    preCommit = git-hooks.lib.${system}.run {
      src = ./.;
      package = pkgs.prek;
      hooks = {
        alejandra.enable = true;
        deadnix.enable = true;
        statix.enable = true;
      };
    };
  in {
    packages.${system} = {
      inherit odin opencode-native libghosttyVt;
      default = opencode-native;
    };

    apps.${system}.default = {
      type = "app";
      program = lib.getExe opencode-native;
      meta.description = "opencode native, built from this tree";
    };

    checks.${system} = {
      inherit opencode-native;
      pre-commit = preCommit;
    };

    formatter.${system} = pkgs.alejandra;

    # nix develop: the compilers of ./build.sh and the libraries the client opens at run time.
    devShells.${system}.default = pkgs.mkShell {
      packages = [odin zig] ++ (with pkgs; [clang lld cargo rustc rsync socat git curl libwebp]) ++ preCommit.enabledPackages;
      buildInputs = [pkgs.fontconfig];
      # the system's Vulkan drivers where it has them; under WSL, ocntools wsl_client says which
      MESA_ICD_DIR = "${pkgs.mesa}/share/vulkan/icd.d";
      # (nix develop clears LD_LIBRARY_PATH if set as an attribute)
      shellHook =
        ''
          export LD_LIBRARY_PATH=${lib.makeLibraryPath (runtime ++ [pkgs.mesa])}
          export FONTCONFIG_FILE=${pkgs.makeFontsConf {fontDirectories = [pkgs.noto-fonts-color-emoji];}}
        ''
        + preCommit.shellHook;
    };
  };
}
