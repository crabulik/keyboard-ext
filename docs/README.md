# Custom Wireless Macro Console

This repository contains the ZMK firmware configuration and hardware documentation for a custom-built, wireless macro console.

## Features
* **Brain:** Supermini nRF52840 (Pro Micro footprint) with built-in Li-Po charging.
* **Firmware:** ZMK (Zephyr RTOS) for native multi-device Bluetooth support.
* **Switches:** 2x Kailh Choc V1 (Low-Profile) for explicit layout switching.
* **Indicators:** 2x 3mm Status LEDs for visual feedback on the active layout.
* **Enclosure:** Designed to be printed on a Bambu Lab P2S using matte PLA or PETG for a professional, non-reflective finish.

## Folder Structure
* `/config`: ZMK shield definitions, device tree overlays (`.overlay`), and keymaps (`.keymap`).
* `/scripts`: PowerShell scripts to build, flash, and clean firmware locally.
* `/docs`: Hardware BOM, wiring schematics, build guide, and project overview.

## Building & Flashing
Firmware is built **locally on Windows** with Docker — no GitHub Actions. See
[BUILD.md](BUILD.md) for the full guide. Quick version (from the repo root):

```powershell
.\scripts\build.ps1   # build -> firmware\crabulik_console-nice_nano.uf2
.\scripts\flash.ps1   # double-tap reset on the board, then flash
```
