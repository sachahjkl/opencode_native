# Writes build\version.h (the numbers of the VERSIONINFO resource) from APP_VERSION in src\setup.odin.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$m = Select-String -Path (Join-Path $root 'src\setup.odin') -Pattern 'APP_VERSION\s*::\s*"(\d+)\.(\d+)\.(\d+)"'
if (-not $m) { throw 'APP_VERSION not found in src\setup.odin' }
$g = $m.Matches[0].Groups
$v = "$($g[1].Value).$($g[2].Value).$($g[3].Value)"
$h = "#define OCC_VER_MAJOR $($g[1].Value)`r`n#define OCC_VER_MINOR $($g[2].Value)`r`n#define OCC_VER_PATCH $($g[3].Value)`r`n#define OCC_VER_STRING `"$v`"`r`n"
$out = Join-Path $root 'build\version.h'
New-Item -ItemType Directory -Force (Split-Path $out) | Out-Null
if (-not (Test-Path $out) -or [IO.File]::ReadAllText($out) -ne $h) { [IO.File]::WriteAllText($out, $h) }
