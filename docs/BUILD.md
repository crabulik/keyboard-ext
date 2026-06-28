# Local Build (Windows + PowerShell + Docker)

Firmware is built **locally** using the official ZMK Docker image — no GitHub
Actions required. The build runs inside `zmkfirmware/zmk-build-arm`, so the only
thing you install on Windows is Docker Desktop.

## Prerequisites

1. **Docker Desktop** — <https://www.docker.com/products/docker-desktop/>
   Install it, launch it, and wait until the whale icon shows "running".
2. **Git** is provided inside the container; you don't need it on the host for
   the build itself (though you'll want it to manage this repo).

> The build scripts check that Docker is installed and the engine is responding,
> and stop with a clear message if not.

## Build

From the repo root, in PowerShell:

```powershell
.\scripts\build.ps1
```

- **First run** clones the ZMK source + Zephyr into a gitignored
  `.zmk-workspace/` folder and runs `west update`. This takes a few minutes and
  downloads a few hundred MB. Subsequent runs reuse it and build incrementally.
- Output `.uf2` files are written to `firmware/<shield>-<board>.uf2`,
  e.g. `firmware/crabulik_console-nice_nano.uf2`.

### Options

| Command | Effect |
| :--- | :--- |
| `.\scripts\build.ps1` | Build every target in `build.yaml` (incremental). |
| `.\scripts\build.ps1 -Pristine` | Force a clean rebuild (`--pristine=always`). |
| `.\scripts\build.ps1 -Update` | Run `west update` first (pull latest Zephyr/modules). |
| `.\scripts\build.ps1 -Logging` | Build a separate `*-logging.uf2` with USB serial logging enabled (see [Reading logs](#reading-logs-usb-serial)). |

The script reads targets straight from [`build.yaml`](../build.yaml), so adding a
board/shield combo there is enough — no script edits needed.

## Flash

1. Plug the Supermini in via USB.
2. Enter the UF2 bootloader so it mounts as a small removable drive (label
   `NICENANO`):
   - **If your board has a reset button:** double-tap it quickly.
   - **If it has no reset button** (this build): tap the **`RST` pin to `GND`
     twice, quickly** with a wire or tweezers (a single tap only reboots). See
     [HARDWARE.md → Entering the UF2 Bootloader](HARDWARE.md#entering-the-uf2-bootloader-flashing)
     for details and an optional reset-button mod.
3. Run:

```powershell
.\scripts\flash.ps1
```

The script waits for the bootloader drive, copies the `.uf2` onto it, and the
board reboots into the new firmware. If you have more than one `.uf2`, it lets
you pick; or pass one explicitly:

```powershell
.\scripts\flash.ps1 -Firmware crabulik_console-nice_nano.uf2
```

You can also just drag-and-drop the `.uf2` onto the `NICENANO` drive in Explorer.

## Reading logs (USB serial)

This board has no SWD debug probe (none is in the BOM), so you can't step-debug
the firmware. The practical alternative is **USB serial logging**: ZMK routes its
`LOG_INF` / `LOG_DBG` / `LOG_ERR` output to a USB CDC-ACM serial port that you can
read on the host.

On current ZMK this is enabled by the **`zmk-usb-logging` snippet**, which adds
both the Kconfig *and* the CDC-ACM devicetree node it needs. (Setting
`CONFIG_ZMK_USB_LOGGING=y` on its own no longer builds on `nice_nano` — the node
would be missing.) The build script wires the snippet in behind a `-Logging`
switch:

```powershell
.\scripts\build.ps1 -Logging   # -> firmware\crabulik_console-nice_nano-logging.uf2
.\scripts\flash.ps1 -Firmware crabulik_console-nice_nano-logging.uf2
```

The logging image is built in its own directory with a `-logging` suffix, so it
never overwrites your normal firmware — keep the regular `.uf2` for daily use and
flash the logging one only while debugging.

Then read the logs:

1. Keep the Supermini plugged in via USB **after** flashing (USB stays active
   with logging on). It enumerates as a new **COM port**.
2. Find the port:

   ```powershell
   Get-CimInstance Win32_SerialPort | Select-Object DeviceID, Description
   ```

3. Open it in any serial terminal. The baud rate is irrelevant for USB CDC-ACM —
   pick anything. Options:
   - **VS Code:** install the *Serial Monitor* extension
     (`ms-vscode.vscode-serial-monitor`), pick the COM port, click *Start Monitoring*.
   - **PuTTY / Tera Term:** open a Serial session on the COM port.

> **Turn it off for battery use.** USB logging keeps USB active and raises power
> draw. Just reflash the normal (non-`-logging`) firmware before running the
> console untethered on the Li-Po.

## Clean

```powershell
.\scripts\clean.ps1        # remove .build/ and firmware/
.\scripts\clean.ps1 -All   # also remove .zmk-workspace/ (forces full re-setup)
```

## Layout

| Path | Purpose | Tracked in git? |
| :--- | :--- | :--- |
| `scripts/` | PowerShell build/flash/clean scripts | yes |
| `.zmk-workspace/` | Cloned ZMK + Zephyr (west workspace) | no (gitignored) |
| `.build/` | Per-target CMake/Zephyr build trees | no (gitignored) |
| `firmware/` | Final `.uf2` outputs | no (gitignored) |
