<#
.SYNOPSIS
    Remove local ZMK build artifacts.

.DESCRIPTION
    By default removes the build output (.build/) and produced firmware/.
    Use -All to also delete the .zmk-workspace/ (the cloned ZMK source + Zephyr),
    which forces a full first-time setup on the next build.

.PARAMETER All
    Also delete .zmk-workspace/ (forces re-clone + west update next build).

.EXAMPLE
    .\scripts\clean.ps1
    Clear build output and firmware, keep the toolchain workspace.

.EXAMPLE
    .\scripts\clean.ps1 -All
    Nuke everything, including the cloned ZMK/Zephyr workspace.
#>
[CmdletBinding()]
param(
    [switch]$All
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

$paths = @(
    (Join-Path $Root '.build'),
    (Join-Path $Root 'firmware')
)
if ($All) {
    $paths += (Join-Path $Root '.zmk-workspace')
}

foreach ($p in $paths) {
    if (Test-Path $p) {
        Write-Host "Removing $p" -ForegroundColor Yellow
        Remove-Item -Recurse -Force $p
    } else {
        Write-Host "Skip (not present): $p" -ForegroundColor DarkGray
    }
}

Write-Host "Clean complete." -ForegroundColor Green
if ($All) {
    Write-Host "Next build will re-clone ZMK and re-run west update (slower first build)." -ForegroundColor Cyan
}
