# jog installer for Windows (PowerShell).
#   irm https://raw.githubusercontent.com/thevahidal/jog/master/install.ps1 | iex
#
# NOTE: jog shells out to a POSIX `sh` for git and plugins. For the full
# experience on Windows, run jog inside WSL or Git Bash (use install.sh there).
# This native binary works, but plugins/git features need `sh` on PATH.
$ErrorActionPreference = "Stop"

$repo  = "thevahidal/jog"
$asset = "jog-x86_64-windows.exe"
$dir   = "$env:LOCALAPPDATA\jog"
$url   = "https://github.com/$repo/releases/latest/download/$asset"

New-Item -ItemType Directory -Force -Path $dir | Out-Null
Write-Host "jog: downloading $asset…"
Invoke-WebRequest -Uri $url -OutFile "$dir\jog.exe"

Write-Host "jog: installed to $dir\jog.exe"
if ($env:PATH -notlike "*$dir*") {
    Write-Host "jog: add it to your PATH →  setx PATH `"$dir;$env:PATH`""
}
Write-Host "jog: tip — for full functionality, run jog inside WSL or Git Bash."
