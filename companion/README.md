# CrabulikConsole — Layout Indicator Companion

A small user-space background app that makes the keyboard's **indicator LEDs
reflect the host's *real* keyboard layout**.

The keyboard can't read the OS layout on its own, so this daemon watches the
active layout and pushes it to the keyboard over BLE. The firmware
([modules/zmk-layout-indicators](../modules/zmk-layout-indicators)) lights the
matching LED.

> **No drivers, nothing system-level.** This is an ordinary app using the OS's
> standard layout and Bluetooth APIs. It does not change input drivers, lock
> keys, or system settings.

One script, [`crabulik_indicator.py`](crabulik_indicator.py), supports **Windows
and macOS** — run it with the same command on either (jump to
[Windows](#windows) or [macOS](#macos) below).

## How it works

1. Daemon reads the active layout — Windows `GetKeyboardLayout`, macOS
   `TISCopyCurrentKeyboardInputSource` (Carbon).
2. Maps it to one byte: `0`=US, `1`=UA, `2`=off/unknown.
3. On every change, writes that byte to the keyboard's custom GATT characteristic.
4. Firmware drives `led_us` / `led_ua` accordingly.

**A connected keyboard can't be scanned.** A device that's paired *and connected*
stops advertising, so the usual scan-based connect can't find it. Each OS has a
way to reach the already-connected device directly:

- **Windows** — `bleak`'s scan fails, so we use WinRT's
  `BluetoothLEDevice.FromBluetoothAddressAsync`, which reaches the device by
  address. That's why Windows needs `--address`. (WinRT ships as a dependency of
  `bleak`, so installing `bleak` is enough.)
- **macOS** — CoreBluetooth hides the BLE MAC address, so there's no address to
  pass. We find the keyboard by our unique custom **service UUID** via
  `retrieveConnectedPeripherals(withServices:)` (no scan), falling back to a
  scan-by-service. macOS needs **no `--address`**.

GATT IDs (must match the firmware):
- Service: `6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d`
- Characteristic (write): `6b1a0002-7a3c-4b9e-9c2d-1f5e8a0b1c2d`

## Prerequisites (both platforms)

- The keyboard runs firmware that includes the `zmk-layout-indicators` module
  (built in by default — see [docs/BUILD.md](../docs/BUILD.md)).
- The keyboard is **paired** with this host (the GATT write needs an encrypted
  link) and **connected over Bluetooth** — i.e. running on battery, *not* on a
  USB data port (on USB it talks HID over USB and the BLE link drops).
- Python 3.10+.

The byte→LED mapping lives at the top of
[`crabulik_indicator.py`](crabulik_indicator.py) (`WIN_LANG_*` for Windows,
`_layout_code_macos` for macOS) — adjust there to add or re-map layouts.

---

# Windows

## Setup

```powershell
cd companion
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
```

## Find the keyboard's BLE address

A connected device can't be scanned, so you connect by address. Print it (run
while the keyboard is paired):

```powershell
Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Enum\BTHLE' | ForEach-Object {
  $hex = $_.PSChildName -replace '(?i)^Dev_',''
  $name = $null
  Get-ChildItem $_.PSPath | ForEach-Object { $p = Get-ItemProperty $_.PSPath -EA SilentlyContinue; if ($p.FriendlyName) { $name = $p.FriendlyName } }
  if ($hex.Length -eq 12) { '{0,-20} {1}' -f $name, (($hex -split '(..)' | ? {$_}) -join ':').ToUpper() }
}
```

Look for your keyboard (it may still show a cached/old name). If it isn't listed,
it's currently on **USB** rather than Bluetooth — unplug USB so it connects over
BLE, then re-run.

## Run

```powershell
python crabulik_indicator.py --address F8:6B:7D:5C:15:A4
```

Switch layout (US ↔ UA) and you should see `layout -> US/UA` printed and the LED
follow. Options:

```powershell
python crabulik_indicator.py --address <addr> --interval 0.5   # poll every 0.5s
```

## Install as a background service (recommended)

[`install-windows.ps1`](install-windows.ps1) does the whole setup in one step —
creates the venv, installs the dependencies, **auto-detects the keyboard's BLE
address**, and registers a **Scheduled Task** ("At log on") that runs the daemon
with `pythonw.exe` (no console window), restarts it if it dies, and logs to
`%LOCALAPPDATA%\CrabulikConsole\crabulik-indicator.log`. No admin rights needed.
After this you can skip the manual *Setup* / *Find the address* / *Run* above.

```powershell
cd companion
.\install-windows.ps1
```

It then runs continuously and **starts automatically at login**. Useful
follow-ups:

```powershell
.\install-windows.ps1 -Uninstall                  # stop and remove the task
.\install-windows.ps1 -Address F8:6B:7D:5C:15:A4  # if auto-detect can't find it
Get-Content -Wait "$env:LOCALAPPDATA\CrabulikConsole\crabulik-indicator.log"
Get-ScheduledTask -TaskName CrabulikConsoleIndicator | Get-ScheduledTaskInfo
```

> If PowerShell blocks the script (`running scripts is disabled`), allow it for
> this one process: `powershell -ExecutionPolicy Bypass -File .\install-windows.ps1`.

### Manual alternative

If you'd rather not use the installer, register a Scheduled Task ("At log on")
that runs `pythonw.exe` (no console window) yourself:

```
<path-to-venv>\Scripts\pythonw.exe  <repo>\companion\crabulik_indicator.py --address <addr> --log <logfile>
```

## One-shot test / debug

[`win_gatt_test.py`](win_gatt_test.py) does a single connect + write with verbose
output — handy to confirm the link without the polling loop:

```powershell
python win_gatt_test.py 1   # write UA
python win_gatt_test.py 0   # write US
```

## Troubleshooting

| Symptom | Likely cause / fix |
| :--- | :--- |
| `device not reachable` | Keyboard isn't connected over BLE. Make sure it's on battery (not USB) and connected; press a key to wake/reconnect it. |
| `custom service not found` | Board has older firmware without the module, **or** Windows cached an old GATT table. Reflash `crabulik_console-nice_nano.uf2`, then remove + re-pair in Windows to refresh the cache. |
| `write rejected` / encryption | Bond is stale. Remove the device in Windows Bluetooth, re-pair, retry. |
| Not in the address list | It's on USB, not Bluetooth. Unplug USB (run on battery) and re-run the address query. |
| Wrong LED for a layout | Adjust the `WIN_LANG_*` codes / mapping at the top of `crabulik_indicator.py`. |

---

# macOS

No BLE address is needed — the daemon finds the keyboard by its custom service
UUID.

## Setup

```bash
cd companion
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-macos.txt
```

This pulls in `pyobjc-framework-CoreBluetooth` (and its Cocoa/Foundation deps).
Layout detection uses the Carbon Text Input Source API via `ctypes` — no extra
package.

## Run

```bash
python3 crabulik_indicator.py
```

Switch layout (US/ABC ↔ Ukrainian) and you should see `layout -> US/UA` printed
and the LED follow. Options:

```bash
python3 crabulik_indicator.py --interval 0.5   # poll every 0.5s
```

## Grant Bluetooth permission

macOS gates Bluetooth behind privacy permissions, attributed to the **app that
launched Python** (the "responsible process"). The **first run** should pop a
prompt to allow Bluetooth for that app (e.g. **Terminal** or **iTerm**) — click
**Allow**. If you missed it, grant it manually under **System Settings → Privacy
& Security → Bluetooth**, then **fully quit and reopen** the terminal app.

> **Run from a standalone terminal — not an IDE's integrated terminal.** If you
> launch the daemon from the **VS Code / Cursor integrated terminal**, Bluetooth
> access is attributed to the editor (an Electron app), which often can't resolve
> it: **no prompt appears** and the daemon hangs in the `unknown` state with no
> keyboard found (`macos_gatt_test.py` shows "timed out … no Bluetooth callback").
> Use **Terminal.app** or **iTerm** instead. The daemon prints a hint after ~5s
> if Bluetooth never powers on.

## Install as a login service (recommended)

[`install-macos.sh`](install-macos.sh) does the whole setup in one step — creates
the venv, installs the dependencies, builds a small **app wrapper**, registers a
**LaunchAgent**, and starts the daemon. After this you can skip the manual
*Setup* and *Run* above.

```bash
cd companion
./install-macos.sh
```

It then runs continuously and **starts automatically at login**. Useful follow-ups:

```bash
./install-macos.sh --uninstall                 # stop and remove the service + app
tail -f ~/Library/Logs/crabulik-indicator.log  # watch its output
launchctl print gui/$(id -u)/com.crabulik.indicator | grep -E 'state|pid'
```

**On first start, macOS prompts to allow Bluetooth for "CrabulikIndicator" —
click Allow.** If you see no prompt and the LEDs don't update, enable
**CrabulikIndicator** under **System Settings → Privacy & Security → Bluetooth**,
then `launchctl kickstart -k gui/$(id -u)/com.crabulik.indicator`.

> **Why an app wrapper, not just a plist?** macOS attributes Bluetooth permission
> to the *running executable's app bundle*. A bare framework `python3` has no
> `NSBluetoothAlwaysUsageDescription` in its Info.plist, so under launchd the OS
> **hard-crashes** the process (TCC) the moment it touches CoreBluetooth — it
> only "works" from Terminal because it borrows Terminal's permission. So the
> installer builds `~/Library/Application Support/CrabulikConsole/CrabulikIndicator.app`
> (a copy of the framework python stub + an Info.plist that declares the Bluetooth
> usage, ad-hoc signed) and points the LaunchAgent at it. The plist passes
> `PYTHONHOME`/`PYTHONPATH` so that interpreter still uses this venv.

## One-shot test / debug

[`macos_gatt_test.py`](macos_gatt_test.py) does a single connect + write (and
prints the detected layout) — handy to confirm the link without the polling loop:

```bash
python3 macos_gatt_test.py 1   # write UA
python3 macos_gatt_test.py 0   # write US
python3 macos_gatt_test.py     # just print the detected layout, write nothing
```

## Troubleshooting

| Symptom | Likely cause / fix |
| :--- | :--- |
| `Bluetooth not powered on` | Turn Bluetooth on, **or** Python lacks Bluetooth permission — see *Grant Bluetooth permission* above. |
| Sits on `scanning by service UUID...` forever | Keyboard isn't connected over BLE. Make sure it's on battery (not USB) and connected; press a key to wake/reconnect it. |
| `custom service not found` | Board has older firmware without the module, **or** a stale GATT cache. Reflash `crabulik_console-nice_nano.uf2`, then remove the device in **System Settings → Bluetooth** and re-pair. |
| `write failed` / encryption | Bond is stale. Remove the device in System Settings → Bluetooth, re-pair, retry. |
| Wrong LED for a layout | Adjust `_layout_code_macos` at the top of `crabulik_indicator.py`. Run `python3 macos_gatt_test.py` (no arg) to see the input-source id your layout reports. |
