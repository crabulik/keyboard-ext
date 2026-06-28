<#
.SYNOPSIS
  Install (or uninstall) the CrabulikConsole layout-indicator companion as a
  Windows background task that runs continuously and starts automatically at
  login.

.DESCRIPTION
  Mirrors install-macos.sh for Windows. It:
    - creates a Python virtualenv in companion\.venv (reused if present)
    - installs the Windows dependencies (requirements.txt -> bleak/WinRT)
    - auto-detects the keyboard's BLE address from the Bluetooth registry
      (override with -Address) -- Windows can't scan a connected device, so the
      daemon connects by address
    - registers a Scheduled Task ("At log on") that runs the daemon with
      pythonw.exe (no console window), restarts it if it dies, and logs to
      %LOCALAPPDATA%\CrabulikConsole\crabulik-indicator.log

  No administrator rights are required: the task runs as the current user with
  limited privileges.

  The keyboard must be PAIRED with this PC and connected over Bluetooth (running
  on battery, not plugged into a USB *data* port -- on USB it talks HID over USB
  and the BLE link drops). The daemon retries forever, so it's fine if the
  keyboard isn't connected at the moment you log in.

.PARAMETER Address
  BLE MAC address of the keyboard, e.g. F8:6B:7D:5C:15:A4. If omitted, it's
  auto-detected by matching the paired-device name (Crabulik* / Custom Console).

.PARAMETER Interval
  Layout poll interval in seconds (default 0.4).

.PARAMETER Uninstall
  Stop and remove the Scheduled Task.

.PARAMETER Help
  Show this help.

.EXAMPLE
  .\install-windows.ps1
  Auto-detect the address, set everything up, and start the companion.

.EXAMPLE
  .\install-windows.ps1 -Address F8:6B:7D:5C:15:A4

.EXAMPLE
  .\install-windows.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$Address,
    [double]$Interval = 0.4,
    [switch]$Uninstall,
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# --------------------------------------------------------------------------- #
# Constants
# --------------------------------------------------------------------------- #
$TaskName     = 'CrabulikConsoleIndicator'
$CompanionDir = $PSScriptRoot
$VenvDir      = Join-Path $CompanionDir '.venv'
$VenvPython   = Join-Path $VenvDir 'Scripts\python.exe'
$VenvPythonW  = Join-Path $VenvDir 'Scripts\pythonw.exe'
$Script       = Join-Path $CompanionDir 'crabulik_indicator.py'
$LogDir       = Join-Path $env:LOCALAPPDATA 'CrabulikConsole'
$Log          = Join-Path $LogDir 'crabulik-indicator.log'
$CurrentUser  = "$env:USERDOMAIN\$env:USERNAME"

# --------------------------------------------------------------------------- #
# Pretty output (mirrors the macOS installer)
# --------------------------------------------------------------------------- #
function Info($msg) { Write-Host '==> ' -ForegroundColor Blue   -NoNewline; Write-Host $msg }
function Warn($msg) { Write-Host 'warn: ' -ForegroundColor Yellow -NoNewline; Write-Host $msg }
function Err($msg)  { Write-Host 'error: ' -ForegroundColor Red    -NoNewline; Write-Host $msg }

function Show-Usage {
    Get-Help $PSCommandPath -Detailed
}

# --------------------------------------------------------------------------- #
# Find paired BLE devices and their MAC addresses from the registry.
# (A connected device can't be scanned, so we connect by address.)
# --------------------------------------------------------------------------- #
function Find-PairedBleDevices {
    $root = 'HKLM:\SYSTEM\CurrentControlSet\Enum\BTHLE'
    if (-not (Test-Path $root)) { return @() }
    $out = @()
    Get-ChildItem $root -ErrorAction SilentlyContinue | ForEach-Object {
        $hex = $_.PSChildName -replace '(?i)^Dev_', ''
        if ($hex.Length -ne 12) { return }
        $name = $null
        Get-ChildItem $_.PSPath -ErrorAction SilentlyContinue | ForEach-Object {
            $p = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
            if ($p.FriendlyName) { $name = $p.FriendlyName }
        }
        $mac = (($hex -split '(..)' | Where-Object { $_ }) -join ':').ToUpper()
        $out += [pscustomobject]@{ Name = $name; Address = $mac }
    }
    return $out
}

function Resolve-Address {
    $cands = Find-PairedBleDevices
    $match = @($cands | Where-Object { $_.Name -match '(?i)crabulik|custom console' })

    if ($match.Count -eq 1) {
        Info "Auto-detected keyboard: '$($match[0].Name)' at $($match[0].Address)"
        return $match[0].Address
    }
    if ($match.Count -gt 1) {
        Err 'Found more than one keyboard-like device. Re-run with -Address <one of these>:'
        $match | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Address, $_.Name) }
        exit 1
    }

    Err 'Could not find the keyboard among paired Bluetooth LE devices.'
    if ($cands.Count) {
        Write-Host 'Paired BLE devices seen:'
        $cands | ForEach-Object { Write-Host ("    {0,-22} {1}" -f $_.Address, $_.Name) }
        Write-Host ''
        Write-Host 'If one of these is the keyboard (it may show a cached/old name),'
        Write-Host 're-run with:  .\install-windows.ps1 -Address <AA:BB:CC:DD:EE:FF>'
    } else {
        Write-Host 'No paired BLE devices found at all. Pair the keyboard first, and make'
        Write-Host 'sure it is on BLE (battery) rather than USB, then re-run.'
    }
    exit 1
}

# --------------------------------------------------------------------------- #
# Uninstall
# --------------------------------------------------------------------------- #
function Invoke-Uninstall {
    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -eq $task) {
        Info "No Scheduled Task named '$TaskName' is registered. Nothing to do."
    } else {
        Info "Stopping and removing the Scheduled Task ($TaskName)..."
        Stop-ScheduledTask    -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Info 'Removed.'
    }
    Info "The virtualenv ($VenvDir) and log ($Log) were left in place."
}

# --------------------------------------------------------------------------- #
# Install
# --------------------------------------------------------------------------- #
function Invoke-Install {
    # 1. virtualenv
    if (-not (Test-Path $VenvPython)) {
        Info "Creating virtualenv at $VenvDir ..."
        if (Get-Command py -ErrorAction SilentlyContinue) {
            & py -3 -m venv $VenvDir
        } elseif (Get-Command python -ErrorAction SilentlyContinue) {
            & python -m venv $VenvDir
        } else {
            Err 'python not found. Install Python 3.10+ (python.org) and retry.'
            exit 1
        }
    } else {
        Info "Reusing existing virtualenv at $VenvDir"
    }

    if (-not (Test-Path $VenvPythonW)) {
        Err "pythonw.exe missing from the venv ($VenvPythonW). Recreate the venv (delete .venv) and retry."
        exit 1
    }

    # 2. dependencies
    Info 'Installing dependencies (requirements.txt) ...'
    & $VenvPython -m pip install --quiet --upgrade pip
    & $VenvPython -m pip install --quiet -r (Join-Path $CompanionDir 'requirements.txt')

    # 3. address
    if (-not $Address) {
        $Address = Resolve-Address
    } else {
        $Address = $Address.ToUpper()
        Info "Using provided address: $Address"
    }

    # 4. log dir
    if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

    # 5. Scheduled Task. Format the interval with an invariant decimal point so a
    #    comma-locale doesn't produce "0,4" (which argparse can't parse as float).
    $intervalStr = $Interval.ToString([System.Globalization.CultureInfo]::InvariantCulture)
    $argStr = '"{0}" --address {1} --interval {2} --log "{3}"' -f $Script, $Address, $intervalStr, $Log

    $action = New-ScheduledTaskAction -Execute $VenvPythonW -Argument $argStr -WorkingDirectory $CompanionDir
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $CurrentUser
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
        -StartWhenAvailable `
        -ExecutionTimeLimit ([TimeSpan]::Zero) `
        -RestartInterval (New-TimeSpan -Minutes 1) -RestartCount 3 `
        -MultipleInstances IgnoreNew
    $principal = New-ScheduledTaskPrincipal -UserId $CurrentUser -LogonType Interactive -RunLevel Limited
    $desc = 'CrabulikConsole layout-indicator companion: pushes the active OS keyboard layout to the keyboard over BLE so its LEDs match.'

    Info "Registering Scheduled Task '$TaskName' (starts at log on)..."
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Description $desc -Force | Out-Null

    Info 'Starting it now...'
    Start-ScheduledTask -TaskName $TaskName

    Write-Host ''
    Info 'Installed. The companion runs in the background and starts at every login.'
    Write-Host ''
    Write-Host "  Address:  $Address"
    Write-Host "  Log:      $Log"
    Write-Host "  Watch:    Get-Content -Wait '$Log'"
    Write-Host "  Status:   Get-ScheduledTask -TaskName $TaskName | Get-ScheduledTaskInfo"
    Write-Host "  Remove:   .\install-windows.ps1 -Uninstall"
    Write-Host ''
    Warn 'The keyboard must be connected over Bluetooth (on battery, not a USB data port).'
    Warn 'Switch layout (US <-> UA) and the LED should follow within ~1s.'
}

# --------------------------------------------------------------------------- #
# Dispatch
# --------------------------------------------------------------------------- #
if ($Help)      { Show-Usage; return }
if ($Uninstall) { Invoke-Uninstall; return }
Invoke-Install
