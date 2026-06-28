# Custom Wireless Macro Console

A custom-built, wireless 2-key macro console for **switching keyboard layouts**
with a single dedicated keypress. Built on the [ZMK firmware](https://zmk.dev/)
(Zephyr RTOS) for native Bluetooth LE support.

Press one button to switch to your **US** layout, the other for your **Ukrainian
(UA)** layout — no more cycling through input sources and landing on the wrong one.

## How it works

Each button sends a fixed keyboard shortcut over Bluetooth that your computer
maps to a specific layout:

| Button | Sends | Intended layout |
| :--- | :--- | :--- |
| **Button 1** | `Ctrl + Shift + 1` | US (ABC) |
| **Button 2** | `Ctrl + Shift + 2` | Ukrainian |

The keyboard always sends the *same* shortcut; it's your **operating system** that
decides what that shortcut does. So you configure the mapping once per computer
(see **Host configuration** below). The firmware works on Windows and macOS
without changes.

## Features

* **Brain:** Supermini nRF52840 (Pro Micro footprint) with built-in Li-Po charging.
* **Firmware:** ZMK for native multi-device Bluetooth support.
* **Switches:** 2× Kailh Choc V1 (low-profile) for explicit layout switching.
* **Indicators:** 2× 3mm status LEDs for visual feedback on the active layout.
* **Enclosure:** 3D-printable (designed for Bambu Lab P2S, matte PLA/PETG).

## Getting started

1. **Build the hardware** — see [docs/HARDWARE.md](docs/HARDWARE.md) for the bill
   of materials and wiring guide.
2. **Build & flash the firmware** — see [docs/BUILD.md](docs/BUILD.md). Quick
   version (from the repo root, on Windows with Docker):

   ```powershell
   .\scripts\build.ps1   # build  -> firmware\crabulik_console-nice_nano.uf2
   .\scripts\flash.ps1   # double-tap reset on the board, then flash
   ```

3. **Pair over Bluetooth** — the device advertises as **"CrabulikConsole"**.
4. **Configure your OS** so the shortcuts switch layouts — see below.

## Host configuration

The buttons send `Ctrl+Shift+1` and `Ctrl+Shift+2`. You need to tell your computer
to treat those as "switch to a specific layout."

### Windows

Windows has this built in:

1. **Settings → Time & Language → Language & region → Typing → Advanced keyboard
   settings → Input language hot keys.**
2. In the **Text Services and Input Languages** dialog, select a language and click
   **Change Key Sequence**, then assign `Ctrl+Shift+1` to US and `Ctrl+Shift+2` to
   Ukrainian.

### ⌨️ Setting Specific Keyboard Layout Hotkeys (macOS)

macOS natively **cycles** through keyboard inputs, which can occasionally lead to
the wrong language being selected. You can force your Mac to switch to a
**specific** layout using **Raycast Script Commands** and the **keyboardSwitcher**
CLI utility.

#### Prerequisites

* [Raycast](https://www.raycast.com/) installed.
* **keyboardSwitcher** installed (available at
  <https://github.com/Lutzifer/keyboardSwitcher>).

#### Step 1: Create the Script Commands

You need to create a separate Raycast Script Command for each language you want to
map. Open Raycast, type **Create Script Command**, set the template to **Bash**,
and use the scripts below.

**Switch to Ukrainian Layout** — create a script titled *"Set Ukr"* with the mode
set to `silent`. Paste the following code:

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Set Ukr
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🤖

# Documentation:
# @raycast.author Pavlo Shylan

keyboardSwitcher select Ukrainian
```

**Switch to US (ABC) Layout** — create a second script titled *"Set US"* with the
mode set to `silent`. Paste the following code:

```bash
#!/bin/bash

# Required parameters:
# @raycast.schemaVersion 1
# @raycast.title Set US
# @raycast.mode silent

# Optional parameters:
# @raycast.icon 🤖

# Documentation:
# @raycast.author Pavlo Shylan

keyboardSwitcher select ABC
```

#### Step 2: Assign Your Hotkeys

1. Open your **Raycast Settings** (`Cmd + ,`) and navigate to the **Extensions**
   tab.
2. Scroll down the left sidebar to the **Script Commands** section.
3. Locate your newly created **Set Ukr** and **Set US** scripts.
4. Click the empty box in the **Hotkey** column next to each script and record your
   preferred keyboard shortcut — use `Ctrl + Shift + 2` for **Set Ukr** and
   `Ctrl + Shift + 1` for **Set US** to match the console's buttons.

## Layout indicator LEDs (optional)

The two status LEDs can show the **real active OS layout**, so you notice at a
glance when the wrong one is selected. Since the keyboard can't read the host's
layout by itself, a tiny companion app pushes it over Bluetooth:

- Firmware: the [`zmk-layout-indicators`](modules/zmk-layout-indicators) module
  exposes a custom BLE characteristic that drives `led_us` / `led_ua` (built in by
  default).
- Host: a small user-space daemon ([`companion/`](companion/), Python + `bleak`)
  watches the active layout and writes it to that characteristic — **no drivers,
  nothing system-level**.

See [companion/README.md](companion/README.md) to set it up.

## Documentation

* [docs/HARDWARE.md](docs/HARDWARE.md) — bill of materials & wiring guide.
* [docs/BUILD.md](docs/BUILD.md) — build, flash, clean, and reading USB logs.
* [docs/README.md](docs/README.md) — project overview & folder structure.
* [companion/README.md](companion/README.md) — layout-indicator companion app.

## Repository layout

* `/config` — ZMK shield definition, devicetree overlay (`.overlay`), keymap
  (`.keymap`), and Kconfig (`.conf`).
* `/modules` — custom ZMK module(s), incl. the BLE layout-indicator service.
* `/companion` — host-side layout-indicator daemon (Python + bleak).
* `/scripts` — PowerShell scripts to build, flash, and clean firmware locally.
* `/docs` — hardware BOM, wiring, build guide, and project overview.

## License

See [LICENSE](LICENSE).