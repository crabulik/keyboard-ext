<#
.SYNOPSIS
    Flash a built .uf2 onto the Supermini nRF52840 (UF2 bootloader).

.DESCRIPTION
    Put the board into bootloader mode (double-tap the reset button). It mounts
    as a small removable USB drive (volume label typically "NICENANO"). This
    script finds that drive and copies the chosen .uf2 onto it. The board
    reboots into the new firmware automatically once the copy finishes.

.PARAMETER Firmware
    Name (or path) of the .uf2 to flash. If omitted and only one exists in
    firmware/, that one is used; otherwise you'll be prompted to choose.

.PARAMETER DriveLabel
    Volume label of the bootloader drive. Default: NICENANO

.EXAMPLE
    .\scripts\flash.ps1
    Flash the single firmware in firmware/ (or pick from a list).

.EXAMPLE
    .\scripts\flash.ps1 -Firmware crabulik_console-nice_nano.uf2
#>
[CmdletBinding()]
param(
    [string]$Firmware,
    [string]$DriveLabel = 'NICENANO'
)

$ErrorActionPreference = 'Stop'

$Root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fwDir = Join-Path $Root 'firmware'

# --- Resolve which .uf2 to flash --------------------------------------------
if ($Firmware) {
    $uf2 = if (Test-Path $Firmware) { (Resolve-Path $Firmware).Path }
           else { Join-Path $fwDir $Firmware }
    if (-not (Test-Path $uf2)) {
        Write-Host "ERROR: firmware not found: $uf2" -ForegroundColor Red
        exit 1
    }
} else {
    $candidates = @(Get-ChildItem $fwDir -Filter *.uf2 -ErrorAction SilentlyContinue)
    if ($candidates.Count -eq 0) {
        Write-Host "ERROR: no .uf2 found in $fwDir. Run .\scripts\build.ps1 first." -ForegroundColor Red
        exit 1
    } elseif ($candidates.Count -eq 1) {
        $uf2 = $candidates[0].FullName
    } else {
        Write-Host "Multiple firmware files found:" -ForegroundColor Cyan
        for ($i = 0; $i -lt $candidates.Count; $i++) {
            Write-Host ("  [{0}] {1}" -f $i, $candidates[$i].Name)
        }
        $sel = Read-Host "Choose one by number"
        $uf2 = $candidates[[int]$sel].FullName
    }
}

Write-Host "Firmware to flash: $uf2" -ForegroundColor Cyan

# --- Find the bootloader drive ----------------------------------------------
function Find-BootloaderDrive {
    param([string]$Label)
    # Prefer matching by volume label; fall back to any small removable FAT drive.
    $vols = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter }
    $byLabel = $vols | Where-Object { $_.FileSystemLabel -eq $Label }
    if ($byLabel) { return ($byLabel | Select-Object -First 1) }
    # UF2 bootloaders present as a tiny removable FAT volume (a few MB).
    return $vols | Where-Object {
        $_.DriveType -eq 'Removable' -and $_.Size -lt 64MB
    } | Select-Object -First 1
}

Write-Host "Waiting for bootloader drive '$DriveLabel' (double-tap reset on the board)..." -ForegroundColor Yellow
$drive = $null
for ($i = 0; $i -lt 60; $i++) {
    $drive = Find-BootloaderDrive -Label $DriveLabel
    if ($drive) { break }
    Start-Sleep -Milliseconds 500
}

if (-not $drive) {
    Write-Host "ERROR: bootloader drive not found after 30s." -ForegroundColor Red
    Write-Host "Double-tap the reset button quickly to enter the UF2 bootloader, then retry." -ForegroundColor Yellow
    exit 1
}

$target = "$($drive.DriveLetter):\"
$labelText = if ($drive.FileSystemLabel) { $drive.FileSystemLabel } else { '(no label)' }
Write-Host ("Found bootloader at {0} [{1}]" -f $target, $labelText) -ForegroundColor Green

# --- Copy and let the board reboot ------------------------------------------
Copy-Item -Path $uf2 -Destination $target -Force
Write-Host "Copied firmware. The board will reboot into the new firmware now." -ForegroundColor Green
