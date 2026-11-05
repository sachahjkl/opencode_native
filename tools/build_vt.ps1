# Builds libghostty-vt, the terminal emulation of the Terminal panel, into build\vt\ghostty-vt-static.lib, linked into
# opencode-native.exe (no DLL to ship). Ghostty's source and Zig are fetched here, into build\vt, and nowhere else.
#   powershell -NoProfile -File tools\build_vt.ps1 [-Force]
# Pinned inputs: Ghostty by commit (the one Ghostling, its reference client, builds against), Zig by version and SHA-256.
# Does nothing when build\vt\STAMP says these same inputs were built.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$ghostty = 'f64f4aca2c29b554d111b36c3d946a9bddd159ff'
$zigVersion = '0.16.0'
$zigSha = '68659eb5f1e4eb1437a722f1dd889c5a322c9954607f5edcf337bc3684a75a7e'
$root = Split-Path $PSScriptRoot -Parent
$out = Join-Path $root 'build\vt'
$lib = Join-Path $out 'ghostty-vt-static.lib'
$stampFile = Join-Path $out 'STAMP'
$stamp = "$ghostty $zigVersion windows"
if (-not $Force -and (Test-Path $lib) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "libghostty-vt up to date in $out"
    exit 0
}
New-Item -ItemType Directory -Force $out | Out-Null

$zigDir = Join-Path $out "zig-x86_64-windows-$zigVersion"
$zig = Join-Path $zigDir 'zig.exe'
if (-not (Test-Path $zig)) {
    $zip = Join-Path $out 'zig.zip'
    $ProgressPreference = 'SilentlyContinue'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest "https://ziglang.org/download/$zigVersion/zig-x86_64-windows-$zigVersion.zip" -OutFile $zip -UseBasicParsing
    if ((Get-FileHash $zip -Algorithm SHA256).Hash.ToLower() -ne $zigSha) { Remove-Item $zip; throw 'Zig: the SHA-256 does not match' }
    tar -xf $zip -C $out
    if ($LASTEXITCODE) { throw "Zig: could not be extracted ($LASTEXITCODE)" }
    Remove-Item $zip
}

$src = Join-Path $out 'ghostty'
if (-not (Test-Path (Join-Path $src '.git'))) {
    New-Item -ItemType Directory -Force $src | Out-Null
    git -C $src init -q
    git -C $src remote add origin https://github.com/ghostty-org/ghostty.git
}
git -C $src fetch -q --depth 1 origin $ghostty
if ($LASTEXITCODE) { throw "Ghostty: could not be fetched ($LASTEXITCODE)" }
git -C $src -c advice.detachedHead=false checkout -q --force $ghostty
if ($LASTEXITCODE) { throw "Ghostty: could not be checked out ($LASTEXITCODE)" }

# (the ABI of the MSVC linker Odin uses; ReleaseFast: a debug build of it is very slow)
Push-Location $src
try {
    & $zig build -Demit-lib-vt=true -Doptimize=ReleaseFast -Dtarget=x86_64-windows-msvc
    if ($LASTEXITCODE) { throw "zig build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Copy-Item (Join-Path $src 'zig-out\lib\ghostty-vt-static.lib') $lib -Force
Set-Content -Path $stampFile -Value $stamp -NoNewline
"built $lib"
