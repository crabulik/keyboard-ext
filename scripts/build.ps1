<#
.SYNOPSIS
    Build ZMK firmware locally on Windows using the official ZMK Docker image.

.DESCRIPTION
    Reads build targets from build.yaml (board + shield combos), spins up the
    zmkfirmware/zmk-build-arm container, and runs `west build` for each target.

    On the first run it clones the ZMK source and initializes the Zephyr west
    workspace into a gitignored .zmk-workspace/ folder. Later runs reuse it and
    build incrementally.

    Resulting .uf2 files are copied into firmware/<name>.uf2 where <name> is
    "<shield>-<board>" (or just "<board>" when no shield is set).

.PARAMETER Pristine
    Force a clean (pristine) build instead of letting west decide (--pristine=auto).

.PARAMETER Update
    Run `west update` before building (pull latest Zephyr / modules).

.PARAMETER Logging
    Build a separate image with USB serial logging enabled, via ZMK's
    `zmk-usb-logging` snippet (it adds both the Kconfig and the required CDC-ACM
    devicetree node). The output is suffixed "-logging.uf2" and built in its own
    directory, so it never overwrites your normal firmware. Logging raises power
    draw — flash it only while debugging, not for daily battery use.

.PARAMETER Image
    Override the Docker image tag. Default: zmkfirmware/zmk-build-arm:stable

.EXAMPLE
    .\scripts\build.ps1 -Logging
    Build firmware\crabulik_console-nice_nano-logging.uf2 with USB logging on.

.EXAMPLE
    .\scripts\build.ps1
    Build every target listed in build.yaml.

.EXAMPLE
    .\scripts\build.ps1 -Pristine
    Force a full clean rebuild.
#>
[CmdletBinding()]
param(
    [switch]$Pristine,
    [switch]$Update,
    [switch]$Logging,
    [string]$Image = 'zmkfirmware/zmk-build-arm:stable'
)

$ErrorActionPreference = 'Stop'

# --- Resolve repo root (parent of this scripts/ folder) ---------------------
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$BuildYaml = Join-Path $Root 'build.yaml'

# --- Prerequisite checks ----------------------------------------------------
if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Host "ERROR: 'docker' was not found on PATH." -ForegroundColor Red
    Write-Host "Install Docker Desktop and ensure it is running:" -ForegroundColor Yellow
    Write-Host "  https://www.docker.com/products/docker-desktop/"
    exit 1
}

try {
    docker info *> $null
    if ($LASTEXITCODE -ne 0) { throw }
} catch {
    Write-Host "ERROR: Docker is installed but the engine is not responding." -ForegroundColor Red
    Write-Host "Start Docker Desktop and wait for it to finish initializing, then retry." -ForegroundColor Yellow
    exit 1
}

if (-not (Test-Path $BuildYaml)) {
    Write-Host "ERROR: build.yaml not found at $BuildYaml" -ForegroundColor Red
    exit 1
}

# --- Parse build.yaml into board/shield targets -----------------------------
function Get-BuildTargets {
    param([string]$Path)
    $targets = @()
    $current = $null
    foreach ($line in Get-Content $Path) {
        if ($line -match '^\s*-\s*board:\s*([^\s#]+)') {
            if ($current) { $targets += [pscustomobject]$current }
            $current = @{ board = $Matches[1]; shield = $null }
        }
        elseif ($line -match '^\s*-\s*shield:\s*([^\s#]+)') {
            if ($current) { $targets += [pscustomobject]$current }
            $current = @{ board = $null; shield = $Matches[1] }
        }
        elseif ($line -match '^\s*board:\s*([^\s#]+)' -and $current) {
            $current.board = $Matches[1]
        }
        elseif ($line -match '^\s*shield:\s*([^\s#]+)' -and $current) {
            $current.shield = $Matches[1]
        }
    }
    if ($current) { $targets += [pscustomobject]$current }
    return $targets
}

$targets = @(Get-BuildTargets -Path $BuildYaml | Where-Object { $_.board })
if ($targets.Count -eq 0) {
    Write-Host "ERROR: No 'board:' entries found in build.yaml" -ForegroundColor Red
    exit 1
}

Write-Host "Targets from build.yaml:" -ForegroundColor Cyan
foreach ($t in $targets) {
    $s = if ($t.shield) { $t.shield } else { '(none)' }
    Write-Host ("  board={0,-16} shield={1}" -f $t.board, $s)
}

# --- Generate the in-container build script (LF line endings) ---------------
$pristineMode = if ($Pristine) { 'always' } else { 'auto' }
$snippetArg   = if ($Logging)  { ' -S zmk-usb-logging' } else { '' }
$logSuffix    = if ($Logging)  { '-logging' } else { '' }

$lines = @(
    'set -euo pipefail'
    'WS=/work/.zmk-workspace'
    'if [ ! -d "$WS/zmk/zephyr" ]; then'
    '  echo "==> First-time setup: cloning ZMK + initializing west workspace (this can take a few minutes)"'
    '  mkdir -p "$WS"'
    '  cd "$WS"'
    '  if [ ! -d zmk ]; then git clone --depth 1 https://github.com/zmkfirmware/zmk.git; fi'
    '  cd zmk'
    '  west init -l app'
    '  west update'
    '  west zephyr-export'
)
if ($Update) {
    $lines += '  :'
    $lines += 'else'
    $lines += '  echo "==> Updating west workspace"'
    $lines += '  cd "$WS/zmk" && west update'
}
$lines += 'fi'
$lines += 'cd "$WS/zmk"'
$lines += 'mkdir -p /work/firmware'

foreach ($t in $targets) {
    # HWMv2 board strings can carry qualifiers/revisions (e.g. "nice_nano//zmk").
    # Keep the full string for `-b`, but use just the base board name for file
    # paths so artifacts/build dirs don't contain '/' or '@'.
    $boardName = (($t.board -split '[\\/@]') | Where-Object { $_ })[0]
    $name = if ($t.shield) { "$($t.shield)-$boardName" } else { $boardName }
    $artifact = "$name$logSuffix"
    $buildDir = "/work/.build/$artifact"
    $shieldArg = if ($t.shield) { " -DSHIELD=$($t.shield)" } else { '' }
    $lines += "echo '==> Building $artifact'"
    $lines += "west build --pristine=$pristineMode$snippetArg -s app -b $($t.board) -d $buildDir -- -DZMK_CONFIG=/work/config -DZMK_EXTRA_MODULES=/work/modules/zmk-layout-indicators$shieldArg"
    $lines += "cp $buildDir/zephyr/zmk.uf2 /work/firmware/$artifact.uf2"
    $lines += "echo '==> Wrote firmware/$artifact.uf2'"
}

$runScript = ($lines -join "`n") + "`n"

# Write the script where the container can read it (.build is gitignored)
$buildLocal = Join-Path $Root '.build'
New-Item -ItemType Directory -Force -Path $buildLocal | Out-Null
$runScriptPath = Join-Path $buildLocal 'run.sh'
[IO.File]::WriteAllText($runScriptPath, $runScript)  # WriteAllText keeps the LF endings as-is

# --- Run the build in the container -----------------------------------------
Write-Host "`nUsing image: $Image" -ForegroundColor Cyan
Write-Host "Repo mounted at /work (host: $Root)`n" -ForegroundColor DarkGray

docker run --rm -v "${Root}:/work" -w /work $Image bash /work/.build/run.sh
$exit = $LASTEXITCODE

if ($exit -eq 0) {
    Write-Host "`nBuild complete. Firmware in:" -ForegroundColor Green
    Get-ChildItem (Join-Path $Root 'firmware') -Filter *.uf2 -ErrorAction SilentlyContinue |
        ForEach-Object { Write-Host ("  {0}  ({1:N0} bytes)" -f $_.Name, $_.Length) }
    Write-Host "`nFlash by double-tapping reset on the Supermini, then run: .\scripts\flash.ps1" -ForegroundColor Cyan
} else {
    Write-Host "`nBuild FAILED (exit $exit). See the west output above." -ForegroundColor Red
}
exit $exit
