# Makes the release files of a finished build (build.bat) in build\dist:
#   opencode-native-<version>-windows-x64.exe    the program, one file (its icon, version, manifest, the Rust library and the
#                                                C runtime are in it): run it, or install it from its Setup (title bar menu)
#   SHA256SUMS.txt                               its SHA-256
#   NOTES.md                                     the release notes: the CHANGELOG's section of that version
#   powershell -NoProfile -File tools\package.ps1 [-Version 0.2.0]
param([string]$Version = '')
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Set-Location $root
if (-not $Version) {
    $m = Select-String -Path src\setup.odin -Pattern 'APP_VERSION\s*::\s*"([^"]+)"'
    $Version = $m.Matches[0].Groups[1].Value
}
if (-not (Test-Path build\opencode-native.exe)) { throw 'build\opencode-native.exe is missing: run build.bat first' }
$dist = Join-Path $root 'build\dist'
if (Test-Path $dist) { Get-ChildItem $dist -File | ForEach-Object { [IO.File]::Delete($_.FullName) } }
New-Item -ItemType Directory -Force $dist | Out-Null
$name = "opencode-native-$Version-windows-x64.exe"
Copy-Item build\opencode-native.exe (Join-Path $dist $name) -Force

$h = [Security.Cryptography.SHA256]::Create()
$s = [IO.File]::OpenRead((Join-Path $dist $name))
try { $sum = ([BitConverter]::ToString($h.ComputeHash($s)) -replace '-', '').ToLower() } finally { $s.Dispose(); $h.Dispose() }
Set-Content -Path (Join-Path $dist 'SHA256SUMS.txt') -Value "$sum  $name" -NoNewline

# the notes: the CHANGELOG's section of this version (from its heading to the next one)
$lines = Get-Content CHANGELOG.md
$start = -1
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match "^## \[$([regex]::Escape($Version))\]") { $start = $i + 1; continue }
    if ($start -ge 0 -and $lines[$i] -match '^## \[') { $end = $i; break }
}
if ($start -lt 0) { throw "CHANGELOG.md has no section for $Version" }
if (-not $end) { $end = $lines.Count }
$notes = ($lines[$start..($end - 1)] -join "`n").Trim()
$notes += "`n`nOne executable for Windows 10 and 11 (x64): run it, or install it for your user from its Setup (title bar menu > Setup...). It finds the opencode desktop app's server by itself."
Set-Content -Path (Join-Path $dist 'NOTES.md') -Value $notes
"packaged build\dist\$name ($sum)"
