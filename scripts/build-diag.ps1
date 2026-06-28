<#
.SYNOPSIS
    Build a DIAGNOSTIC firmware that maps each physical button to a plain letter,
    to verify which switches actually register in a key tester.

.DESCRIPTION
    Produces firmware\crabulik_console-nice_nano-diag.uf2 using a throwaway keymap
    (config\boards\shields\crabulik_console\diag\crabulik_console-diag.keymap) instead of the production keymap:

        Pin 2  (017)   -> A    (US button)
        Pin 3  (020)   -> B    (UA button)
        Pin 6  (P1.00) -> C    (Clear-Bluetooth button)
        Pin 9  (1.06)  -> D    (EC11 push-click / Button 4)
        Pin 18 (1.15)  -> I    (Button 5 / Prev track)
        Pin 19 (0.02)  -> J    (Button 6 / Next track)
        EC11 rotation  -> E / F     Mouse wheel -> G / H

    Your real keymap is NOT touched — ZMK's -DKEYMAP_FILE override is used, and the
    build goes to its own directory / output name. Flash this image, press each
    button in any key tester (each working button types its letter; a dead or
    unwired button types nothing), then reflash the normal firmware to restore
    real behavior.

    Requires the ZMK workspace to already exist (run scripts\build.ps1 once first).

.PARAMETER Image
    Override the Docker image tag. Default: zmkfirmware/zmk-build-arm:stable

.EXAMPLE
    .\scripts\build-diag.ps1
    Build the diagnostic image, then:
        .\scripts\flash.ps1 -Firmware crabulik_console-nice_nano-diag.uf2
#>
[CmdletBinding()]
param(
    [string]$Image = 'zmkfirmware/zmk-build-arm:stable'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# --- Prerequisite checks ----------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: 'docker' was not found on PATH. Install/launch Docker Desktop." -ForegroundColor Red
    exit 1
}
try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Host "ERROR: Docker is installed but the engine is not responding. Start Docker Desktop and retry." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $Root '.zmk-workspace/zmk/zephyr'))) {
    Write-Host "ERROR: ZMK workspace not found. Run .\scripts\build.ps1 once first to set it up." -ForegroundColor Red
    exit 1
}
if (-not (Test-Path (Join-Path $Root 'config/boards/shields/crabulik_console/diag/crabulik_console-diag.keymap'))) {
    Write-Host "ERROR: diagnostic keymap not found at config\boards\shields\crabulik_console\diag\crabulik_console-diag.keymap" -ForegroundColor Red
    exit 1
}

$board    = 'nice_nano//zmk'
$shield   = 'crabulik_console'
$name     = 'crabulik_console-nice_nano-diag'
# Build inside the container's OWN filesystem (/tmp), NOT the /work bind mount.
# On Docker Desktop for Windows a freshly created build dir on the bind mount
# intermittently breaks the CMake configure, because files are not yet readable/
# writable right after they're created (e.g. ".config cannot be read", or
# "zephyr.dts.new: No such file or directory"). /tmp is a local overlay FS with
# no such lag. Only the finished .uf2 is copied back to /work at the very end.
$buildDir = "/tmp/$name"
$keymap   = '/work/config/boards/shields/crabulik_console/diag/crabulik_console-diag.keymap'

# --- Generate the in-container build script (LF line endings) ---------------
$lines = @(
    'set -euo pipefail'
    'WS=/work/.zmk-workspace'
    'cd "$WS/zmk"'
    'mkdir -p /work/firmware'
    "echo '==> Building DIAGNOSTIC $name'"
    # Fresh local build dir each run (full rebuild — this image is built only
    # occasionally, and /tmp is ephemeral inside the --rm container anyway).
    "rm -rf $buildDir"
    "west build -s app -b $board -d $buildDir -- -DZMK_CONFIG=/work/config -DSHIELD=$shield -DKEYMAP_FILE=$keymap"
    "cp $buildDir/zephyr/zmk.uf2 /work/firmware/$name.uf2"
    "echo '==> Wrote firmware/$name.uf2'"
)
$runScript = ($lines -join "`n") + "`n"

$buildLocal = Join-Path $Root '.build'
New-Item -ItemType Directory -Force -Path $buildLocal | Out-Null
$runScriptPath = Join-Path $buildLocal 'run-diag.sh'
[IO.File]::WriteAllText($runScriptPath, $runScript)  # WriteAllText keeps LF endings

# --- Run the build in the container -----------------------------------------
Write-Host "Using image: $Image" -ForegroundColor Cyan
Write-Host "Repo mounted at /work (host: $Root)`n" -ForegroundColor DarkGray

docker run --rm -v "${Root}:/work" -w /work $Image bash /work/.build/run-diag.sh
$exit = $LASTEXITCODE

if ($exit -eq 0) {
    Write-Host "`nDiagnostic firmware built:" -ForegroundColor Green
    Write-Host "  firmware\crabulik_console-nice_nano-diag.uf2"
    Write-Host "`nFlash it, then in a key tester press each button:" -ForegroundColor Cyan
    Write-Host "  Pin 2  (US)           -> types A"
    Write-Host "  Pin 3  (UA)           -> types B"
    Write-Host "  Pin 6  (Clear-BT)     -> types C"
    Write-Host "  Pin 9  (EC11 click)   -> types D"
    Write-Host "  Pin 18 (Button 5)     -> types I"
    Write-Host "  Pin 19 (Button 6)     -> types J"
    Write-Host "  EC11 rotation         -> types E / F"
    Write-Host "  Mouse wheel rotation  -> types G / H"
    Write-Host "  (a dead/unwired input types nothing)"
    Write-Host "`nFlash with: .\scripts\flash.ps1 -Firmware crabulik_console-nice_nano-diag.uf2" -ForegroundColor Cyan
    Write-Host "When done, reflash normal firmware: .\scripts\build.ps1 ; .\scripts\flash.ps1" -ForegroundColor Cyan
} else {
    Write-Host "`nDiagnostic build FAILED (exit $exit). See the west output above." -ForegroundColor Red
}
exit $exit
