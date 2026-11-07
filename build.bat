@echo off
:: Builds opencode native. Output: build\opencode-native.exe (one file: icon, version, manifest, the Rust library and the
:: C runtime are in it).
::   build.bat            at once, not optimized (what is tried: a second)
::   build.bat release    optimized (what is released, and what is measured for speed: a minute)
::   build.bat debug      debug information, console output, D3D debug layer
::   build.bat logo       draws the logo again (assets\, tools\make_logo.ps1)
:: Needs the Odin compiler (odin.version), MSVC (link.exe, rc.exe) and Rust (cargo, stable, x86_64-pc-windows-msvc).
:: The toolkit is the submodule ext\gui_toolkit (git submodule update --init); GT=<folder> builds against another copy,
:: OCC_ANY_ODIN=1 with another Odin than odin.version.
:: OUT=<file> writes the exe elsewhere (a copy that runs keeps build\opencode-native.exe locked).
setlocal
cd /D "%~dp0"
if /I "%1"=="logo" (
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_logo.ps1 || exit /b 1
  exit /b 0
)
if not exist build mkdir build
:: What builds it is tools\occtools, here built first: the steps are the same on Linux (build.sh).
odin build tools\occtools -out:build\occtools.exe || exit /b 1
build\occtools.exe build %*
