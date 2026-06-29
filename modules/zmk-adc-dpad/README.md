# zmk-adc-dpad — resistor-ladder 5-way on one ADC pin

Reads a passive **resistor-ladder 5-way control** (center + up/down/left/right)
on a single analog pin and sends one key per direction. Built for a **CaddxFPV
OSD menu board** (the 2-pin one: signal + GND), but works with any OSD/joystick
board that switches a different resistor onto one signal wire.

Each direction divides the signal line to a distinct voltage; the driver
thresholds the ADC reading and sends the mapped key **directly into ZMK's HID
pipeline**, so it needs no kscan/keymap entry and fires on any layer. Default
mapping is **arrows + Enter** (center = Enter).

> Experimental and **off by default**. Until you enable it (Kconfig) *and* add
> the `dpad_chan` overlay node, this module compiles to nothing and your normal
> firmware is unaffected.

## 1. Wire it

The board is passive (no VCC), so the MCU must supply the reference:

```
 board signal ──┬────────────────  nRF analog pin (e.g. P0.29 / AIN5)
                │
               [R] 10 kΩ pull-up
                │
              3.3V
 board GND  ─────────────────────  GND
```

- **Signal** → a free **analog-capable** pin. nRF52840 ADC inputs:
  `AIN0=P0.02, AIN1=P0.03, AIN2=P0.04, AIN3=P0.05, AIN4=P0.28, AIN5=P0.29,
  AIN6=P0.30, AIN7=P0.31`. Pick one not already used in the overlay and note the
  `AINx` number.
- **Pull-up:** ~10 kΩ from signal to 3.3V. (10 kΩ spreads the bands well if the
  board's internal resistors are in the low-kΩ range; you'll confirm by reading
  the actual voltages below.)
- **GND** → GND.

## 2. Add the ADC channel to the overlay

In [config/boards/shields/crabulik_console/crabulik_console.overlay](../../config/boards/shields/crabulik_console/crabulik_console.overlay),
add (set `zephyr,input-positive` to the `AINx` you wired):

```dts
#include <zephyr/dt-bindings/adc/adc.h>
#include <zephyr/dt-bindings/adc/nrf-saadc.h>

&adc {
    status = "okay";
    #address-cells = <1>;
    #size-cells = <0>;

    dpad_chan: channel@4 {
        reg = <4>;
        zephyr,gain = "ADC_GAIN_1_6";
        zephyr,reference = "ADC_REF_INTERNAL";
        zephyr,acquisition-time = <ADC_ACQ_TIME(ADC_ACQ_TIME_MICROSECONDS, 40)>;
        zephyr,input-positive = <NRF_SAADC_AIN5>;  /* <-- your wired pin */
    };
};
```

The `gain 1/6 + internal 0.6V reference` pair gives a clean 0–3.6V range, which
is why the driver converts raw counts to millivolts with `adc_ref_internal()`.

## 3. Enable it

In [config/crabulik_console.conf](../../config/crabulik_console.conf):

```
CONFIG_CRABULIK_ADC_DPAD=y
# turn on only while calibrating (needs a logging build):
# CONFIG_CRABULIK_ADC_DPAD_LOG_MV=y
```

(The module is already on `ZMK_EXTRA_MODULES` via `scripts/build.ps1`.)

## 4. Calibrate

The thresholds and key order live at the top of
[src/adc_dpad.c](src/adc_dpad.c) (`thresholds_mv` / `keycodes`). Two ways to get
the numbers:

- **Multimeter (no firmware):** measure resistance signal→GND for each direction
  and idle, tell me the values, and I'll compute thresholds for your pull-up.
- **In-firmware (recommended):** set `CONFIG_CRABULIK_ADC_DPAD_LOG_MV=y`, build a
  **logging** firmware (`./scripts/build.ps1 -Logging`), flash, open the USB
  serial log (see [docs/BUILD.md](../../docs/BUILD.md)), and press each direction.
  Note the `mv=` for each one and for idle. Then:
  - set each `thresholds_mv[i]` to the midpoint between neighbouring readings
    (ascending), `DPAD_KEYUP_MV` just below idle, and
  - order `keycodes[]` so each band sends the arrow you want.

Rebuild without the log option once it's dialed in.

## Notes / limits

- One direction at a time. A resistor ladder can't encode two simultaneous
  presses, so diagonals aren't supported (it's a center+4 control anyway).
- Keys are sent directly, bypassing the keymap — handy (works on every layer),
  but it means the d-pad isn't remapped by your layers. To change what it sends,
  edit `keycodes[]` (any `dt-bindings/zmk/keys.h` code, e.g. `C_VOL_UP`, `TAB`).
- Reads the ADC every `DPAD_POLL_MS` (30 ms). Bump it up to trade latency for a
  little battery.
- I can't compile/flash this from macOS — build on your Windows/Docker side. If
  it errors, paste the log and I'll fix it.
