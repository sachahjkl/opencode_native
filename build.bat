@echo off
:: Builds opencode native. Output: build\opencode-native.exe (one file: icon, version, manifest, the Rust library and the
:: C runtime are in it).
::   build.bat            optimized (what is released)
::   build.bat debug      debug information, console output, D3D debug layer
::   build.bat logo       draws the logo again (assets\, tools\make_logo.ps1)
:: Needs the Odin compiler (odin.version), MSVC (link.exe, rc.exe) and Rust (cargo, stable, x86_64-pc-windows-msvc).
:: The toolkit is the submodule ext\gui_toolkit (git submodule update --init); GT=<folder> builds against another copy.
setlocal
cd /D "%~dp0"
if /I "%1"=="logo" (
  powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_logo.ps1 || exit /b 1
  exit /b 0
)
if not exist build mkdir build
if not defined GT set "GT=ext\gui_toolkit"
if not exist %GT%\ui (
  if exist ..\gui_toolkit\ui (
    set "GT=..\gui_toolkit"
  ) else (
    echo the toolkit is missing: git submodule update --init
    exit /b 1
  )
)

:: the Odin compiler this tree is written for (odin.version); OCC_ANY_ODIN=1 skips the check
set /p OCC_ODIN=<odin.version
if not defined OCC_ANY_ODIN (
  odin version 2>nul | findstr /C:"%OCC_ODIN%" >nul || (
    echo This tree needs Odin %OCC_ODIN% ^(odin.version^); found:
    odin version
    echo Install that release, or set OCC_ANY_ODIN=1 to build anyway.
    exit /b 1
  )
)

:: the Rust library (HTTP, event stream, images): does nothing when it is up to date
powershell -NoProfile -ExecutionPolicy Bypass -File tools\build_native.ps1 || exit /b 1
:: the numbers of the version resource, from APP_VERSION
powershell -NoProfile -ExecutionPolicy Bypass -File tools\make_version_h.ps1 || exit /b 1

:: the C runtime linked in (no vcruntime140.dll to ship)
set FLAGS=-collection:gt=%GT% -out:build/opencode-native.exe -vet -resource:res/opencode-native.rc -extra-linker-flags:"/NODEFAULTLIB:vcruntime.lib /DEFAULTLIB:libvcruntime.lib"
if /I "%1"=="debug" (
  odin build src %FLAGS% -debug
) else (
  odin build src %FLAGS% -o:speed -subsystem:windows
)
if errorlevel 1 exit /b 1
echo built build\opencode-native.exe (toolkit: %GT%)
