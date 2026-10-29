# Builds the client's Rust code (the native\ workspace) into build\native\occ_native.lib, the one Rust static library
# linked into opencode-native.exe (no DLL to ship): HTTP and the event stream (ureq, rustls, the system's trust store).
#   powershell -NoProfile -File tools\build_native.ps1 [-Force]
# Pinned inputs: every crate by exact version in the crates' Cargo.toml and by SHA-256 in native\Cargo.lock (the build runs
# with --locked). Rust: the stable toolchain of rustup (x86_64-pc-windows-msvc).
# Does nothing when build\native\STAMP matches the hash of the sources, Cargo.lock and this script.
param([switch]$Force)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$ws = Join-Path $root 'native'
$out = Join-Path $root 'build\native'
$lib = Join-Path $out 'occ_native.lib'
$stampFile = Join-Path $out 'STAMP'

$inputs = @(Get-Item (Join-Path $ws 'Cargo.toml'), (Join-Path $ws 'Cargo.lock'), $PSCommandPath)
foreach ($c in Get-ChildItem $ws -Directory) {
    $inputs += @(Get-ChildItem (Join-Path $c.FullName 'src') -Recurse -File) + @(Get-Item (Join-Path $c.FullName 'Cargo.toml'))
}
$sha = [Security.Cryptography.SHA256]::Create()
$all = New-Object IO.MemoryStream
foreach ($f in ($inputs | Sort-Object FullName)) { $b = [IO.File]::ReadAllBytes($f.FullName); $all.Write($b, 0, $b.Length) }
$stamp = ([BitConverter]::ToString($sha.ComputeHash($all.ToArray())) -replace '-', '').ToLower()
if (-not $Force -and (Test-Path $lib) -and (Test-Path $stampFile) -and ((Get-Content $stampFile -Raw).Trim() -eq $stamp)) {
    "occ_native up to date in $out"
    exit 0
}
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) { throw 'cargo not found: install Rust with rustup (stable, x86_64-pc-windows-msvc)' }

New-Item -ItemType Directory -Force $out | Out-Null
Push-Location $ws
try {
    & cargo build --release --locked --target x86_64-pc-windows-msvc --target-dir (Join-Path $out 'target')
    if ($LASTEXITCODE) { throw "cargo build failed ($LASTEXITCODE)" }
} finally { Pop-Location }
Copy-Item (Join-Path $out 'target\x86_64-pc-windows-msvc\release\occ_native.lib') $lib -Force
Set-Content -Path $stampFile -Value $stamp -NoNewline
"built $lib"
