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

## How it works

1. Daemon reads the active layout (Windows `GetKeyboardLayout`).
2. Maps it to one byte: `0`=US, `1`=UA, `2`=off/unknown.
3. On every change, writes that byte to the keyboard's custom GATT characteristic.
4. Firmware drives `led_us` / `led_ua` accordingly.

**It uses WinRT, not a scan.** A keyboard that's paired *and connected* stops
advertising, so `bleak`'s scan-based connect can't find it. WinRT's
`BluetoothLEDevice.FromBluetoothAddressAsync` reaches the connected device
directly by address — which is why the app always needs `--address`. (WinRT
ships as a dependency of `bleak`, so installing `bleak` is enough.)

GATT IDs (must match the firmware):
- Service: `6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d`
- Characteristic (write): `6b1a0002-7a3c-4b9e-9c2d-1f5e8a0b1c2d`

## Prerequisites

- The keyboard runs firmware that includes the `zmk-layout-indicators` module
  (built in by default — see [docs/BUILD.md](../docs/BUILD.md)).
- The keyboard is **paired** with this host (the GATT write needs an encrypted
  link) and **connected over Bluetooth** — i.e. running on battery, *not* on a
  USB data port (on USB it talks HID over USB and the BLE link drops).
- Python 3.10+.

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

## Run automatically at login (Windows)

Register a Scheduled Task ("At log on") that runs:

```
<path-to-venv>\Scripts\pythonw.exe  <repo>\companion\crabulik_indicator.py --address <addr>
```

`pythonw.exe` runs it without a console window.

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

## macOS

Not implemented yet. Two pieces are needed: layout detection
(`TISCopyCurrentKeyboardInputSource`) and a CoreBluetooth writer (the WinRT class
here is Windows-only).
