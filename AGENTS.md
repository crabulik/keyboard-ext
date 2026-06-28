# AGENTS.md

Guidance for AI coding agents (and humans) working in this repository.

## What this project is

ZMK firmware configuration and hardware documentation for a **custom wireless
2-key macro console**. It is a "Zephyr config repo" — it contains a ZMK *shield*
definition plus keymap/overlay, not the ZMK source itself. ZMK and Zephyr are
fetched at build time into a gitignored `.zmk-workspace/`.

- **Board (MCU):** Supermini nRF52840 (Pro Micro footprint) — built as
  `nice_nano//zmk` in ZMK. Zephyr 4.1+ (hardware model v2) dropped `nice_nano_v2`
  and requires the board's **`zmk` variant**: the bare `nice_nano` base board has
  **no `CONFIG_ZMK_BLE`/`CONFIG_ZMK_USB`** (no Bluetooth, no USB HID) — only the
  `//zmk` variant enables them. Revision defaults to 2.0.0 (nice!nano v2 hardware).
- **Shield:** `crabulik_console` — 2x Kailh Choc V1 direct-wired switches and 2x
  status LEDs.
- **Function:** Each switch sends a macro shortcut to switch keyboard layout on
  the host (US / UA). LEDs indicate the active layout.
- **Connectivity:** Bluetooth LE (ZMK on Zephyr RTOS).

See [docs/README.md](docs/README.md), [docs/HARDWARE.md](docs/HARDWARE.md), and
[docs/BUILD.md](docs/BUILD.md) for the human-facing docs.

## Repository layout

| Path | Purpose | Tracked? |
| :--- | :--- | :--- |
| [build.yaml](build.yaml) | Build matrix: board + shield combos to build | yes |
| [config/crabulik_console.conf](config/crabulik_console.conf) | User Kconfig overrides (auto-merged by shield name); currently no overrides | yes |
| [config/boards/shields/crabulik_console/](config/boards/shields/crabulik_console/) | The ZMK shield definition | yes |
| [modules/zmk-layout-indicators/](modules/zmk-layout-indicators/) | Custom ZMK module: BLE GATT service driving the layout LEDs (Option A) | yes |
| [companion/](companion/) | Host-side daemon (Python + bleak) that pushes the active OS layout to the keyboard | yes |
| [scripts/](scripts/) | PowerShell build / flash / clean scripts | yes |
| [docs/](docs/) | BOM, wiring, build guide, overview | yes |
| `.zmk-workspace/` | Cloned ZMK + Zephyr (west workspace) | no (gitignored) |
| `.build/` | Per-target CMake/Zephyr build trees + generated `run.sh` | no (gitignored) |
| `firmware/` | Final `.uf2` outputs | no (gitignored) |

### Shield files (the heart of the config)

- [crabulik_console.keymap](config/boards/shields/crabulik_console/crabulik_console.keymap)
  — key bindings. Currently two keys: `Ctrl+Shift+1` (US) and `Ctrl+Shift+2` (UA).
- [crabulik_console.overlay](config/boards/shields/crabulik_console/crabulik_console.overlay)
  — devicetree: a `zmk,kscan-gpio-direct` kscan with two GPIOs, plus two
  `gpio-leds`. GPIO numbers are **`pro_micro` connector pins** (2, 3 = switches;
  4, 5 = LEDs), not raw nRF52840 pins.
- [Kconfig.shield](config/boards/shields/crabulik_console/Kconfig.shield) — declares
  `SHIELD_CRABULIK_CONSOLE`.
- [Kconfig.defconfig](config/boards/shields/crabulik_console/Kconfig.defconfig) — sets
  the keyboard name when the shield is selected.

## Environment

- **Platform:** Windows 11, PowerShell. Build runs inside Docker (the ZMK
  toolchain image), so no Zephyr SDK install is needed on the host.
- **Required:** Docker Desktop running. The build scripts verify Docker is
  installed and the engine responds, and exit with a clear message otherwise.

## Build / flash / clean

All commands run from the repo root in PowerShell.

```powershell
.\scripts\build.ps1            # build every target in build.yaml (incremental)
.\scripts\build.ps1 -Pristine  # force a clean rebuild (--pristine=always)
.\scripts\build.ps1 -Update    # west update first (pull latest Zephyr/modules)

.\scripts\flash.ps1            # wait for UF2 bootloader drive, copy .uf2, board reboots
.\scripts\flash.ps1 -Firmware crabulik_console-nice_nano.uf2

.\scripts\clean.ps1            # remove .build/ and firmware/
.\scripts\clean.ps1 -All       # also remove .zmk-workspace/ (forces full re-setup)
```

- **First build** clones ZMK and runs `west update` into `.zmk-workspace/`
  (several minutes, a few hundred MB). Later builds reuse it and are incremental.
- Output is written to `firmware/<shield>-<board>.uf2`, e.g.
  `firmware/crabulik_console-nice_nano.uf2`.
- **How the build works:** [build.ps1](scripts/build.ps1) parses
  [build.yaml](build.yaml), generates a bash script at `.build/run.sh` (LF line
  endings — important), then runs it in `zmkfirmware/zmk-build-arm:stable` with
  the repo mounted at `/work`. Inside the container it runs
  `west build -s app -b <board> -- -DZMK_CONFIG=/work/config -DSHIELD=<shield>`.

**To flash:** plug in the Supermini, **double-tap reset** to enter the UF2
bootloader (mounts as removable drive labeled `NICENANO`), then run
`flash.ps1`. Drag-and-drop of the `.uf2` onto the drive also works.

## Conventions & gotchas for agents

- **Adding a build target:** edit [build.yaml](build.yaml) only — the scripts read
  targets from it, no script edits needed. Format is the standard ZMK
  `include:` list of `{ board, shield }` entries.
- **Changing keys:** edit the `bindings` in the keymap. Order maps positionally to
  the `input-gpios` order in the overlay (first binding = first GPIO = Button 1).
- **Changing wiring/pins:** edit `input-gpios` / `gpios` in the overlay. Keep the
  keymap binding count in sync with the GPIO count, and keep
  [docs/HARDWARE.md](docs/HARDWARE.md) wiring table consistent.
- **Pin numbering:** overlay GPIOs reference the `pro_micro` nodelabel
  (connector-relative), matching the wiring table in HARDWARE.md. Don't substitute
  raw `P0.xx` nRF pin numbers.
- **Don't edit or commit** `.zmk-workspace/`, `.build/`, or `firmware/` — all
  gitignored, all regenerable.
- **`run.sh` line endings:** the generated `.build/run.sh` must use LF. The script
  uses `[IO.File]::WriteAllText` deliberately to avoid CRLF, which would break
  bash in the Linux container. Preserve this if touching build.ps1.
- **Validation:** there is no host-side test suite. "Does it compile" = a
  successful `build.ps1` run producing the `.uf2`. Real validation is flashing to
  hardware.

## Roadmap notes

Rotary encoders (EC11 and a TTC mouse wheel) are planned for a future hardware
revision (see [docs/HARDWARE.md](docs/HARDWARE.md)). Not yet wired or in the keymap.
