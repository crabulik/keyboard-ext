# Hardware Setup & Wiring

## Bill of Materials (BOM)

| Component | Specification | Quantity |
| :--- | :--- | :--- |
| **Microcontroller** | Supermini nRF52840 (Pro Micro clone) | 1 |
| **Switches** | Kailh Choc V1 (Brown or White) | 3 |
| **Keycaps** | MBK profile Choc keycaps (1u size) | 2 (+1 optional) |
| **Status LEDs** | 3mm LEDs (e.g., Blue, Green) | 2 |
| **Resistors** | 220Ω Resistors | 2 |
| **Power** | Li-Po Battery 301230 (110mAh, 3.7V) | 1 |
| **Wire** | 30 AWG flexible silicone wire | 1 roll |

*Note: Two rotary encoders — an **EC11** (rotation + push-click) and a **TTC
mouse-wheel** encoder (rotation only) — are an **optional add-on**. The firmware
already supports them; see [Rotary encoders](#rotary-encoders-optional) below.
The console works fine without them.*

## Wiring Guide (Initial Prototype)

The Supermini uses its internal pull-up resistors for the switches. All components share a common Ground (`GND`).

| Component | Pin on Supermini | Connection Path |
| :--- | :--- | :--- |
| **Button 1 (US Layout)** | **Pin 2 (017)** | Pin 2 -> Switch Pin A <br> Switch Pin B -> GND |
| **Button 2 (UA Layout)** | **Pin 3 (020)** | Pin 3 -> Switch Pin A <br> Switch Pin B -> GND |
| **Button 3 (Clear Bluetooth)** | **Pin 6 (1.00)** | Pin 6 -> Switch Pin A <br> Switch Pin B -> GND |
| **LED 1 (US Indicator)** | **Pin 4 (022)** | Pin 4 -> 220Ω Resistor -> LED Positive (+) <br> LED Negative (-) -> GND |
| **LED 2 (UA Indicator)** | **Pin 5 (024)** | Pin 5 -> 220Ω Resistor -> LED Positive (+) <br> LED Negative (-) -> GND |

> **Button 3 — host switch (hold)** is wired exactly like the layout buttons
> (switch between **Pin 6** and **GND**, using the MCU's internal pull-up). In
> firmware it's a **hold layer for Bluetooth host switching** (Logitech
> Easy-Switch style):
> - **Hold Button 3 + tap Button 1/2** → connect to host (BLE profile) 0 / 1.
> - **Press all three buttons together** → clear the current Bluetooth bond
>   (`&bt BT_CLR`), to re-pair a host.
>
> Pair each host on its own profile first (hold Btn3 + tap the button for an empty
> profile, then pair from that computer). A plain momentary tact switch is fine and
> a keycap is optional (hence "+1 optional" in the BOM). Pin 6 is silkscreened
> **`D6`/`A7`** on the Supermini and maps to nRF GPIO **P1.00**.

### Rotary encoders (optional)

Two incremental quadrature encoders are supported in firmware: an **EC11**
(rotation **and** a push-click) and a **TTC mouse-wheel** encoder (rotation
only). Both share the common Ground and use the MCU's internal pull-ups — **no
external resistors**. Each encoder's **common (C)** pin is the **middle** of its
three pins; confirm with a multimeter continuity test (the common is the pin
that makes/breaks against *both* of the other two as you slowly rotate).

| Component | Pin on Supermini | Connection Path |
| :--- | :--- | :--- |
| **EC11 — rotation A** | **Pin 7 (011)** | Pin 7 -> Encoder Pin A |
| **EC11 — rotation B** | **Pin 8 (1.04)** | Pin 8 -> Encoder Pin B |
| **EC11 — common (C)** | **GND** | Middle encoder pin -> GND |
| **EC11 — push-click** | **Pin 9 (1.06)** | Pin 9 -> Switch Pin A <br> Switch Pin B -> GND |
| **Mouse wheel — A** | **Pin 14 (1.11)** | Pin 14 -> Encoder Pin A |
| **Mouse wheel — B** | **Pin 15 (1.13)** | Pin 15 -> Encoder Pin B |
| **Mouse wheel — common (C)** | **GND** | Middle encoder pin -> GND |

> **Default behavior** (set in
> [`crabulik_console.keymap`](../config/boards/shields/crabulik_console/crabulik_console.keymap)):
> the **EC11 knob is a volume control** — turn for volume up/down, **click to
> mute** — and the **mouse wheel switches tabs** (Ctrl+Tab / Ctrl+Shift+Tab).
> The EC11 push-click is added to `kscan0` as **Button 4**, so the
> all-three-buttons bond-clear combo (positions 0–2) is unaffected.
>
> **Pin choice:** Pins 7/8/9/14/15 map to nRF **P0.11 / P1.04 / P1.06 / P1.11 /
> P1.13**. We deliberately avoid pins 10 and 16 (**P0.09 / P0.10**) — those are
> the nRF52840 **NFC** pins and need extra firmware config to act as plain GPIO.
>
> **Tuning** (in
> [`crabulik_console.overlay`](../config/boards/shields/crabulik_console/crabulik_console.overlay)):
> if one detent skips or double-fires, adjust that encoder's `steps` — **double**
> it if one detent triggers twice, **halve** it if a detent does nothing. To flip
> direction, swap the encoder's A/B pins (or its two keymap bindings).

### Additional buttons (optional)

Two spare momentary switches, wired exactly like Buttons 1–3 (direct GPIO to
GND, internal pull-up — no resistor). In firmware they're **media transport**
keys.

| Component | Pin on Supermini | Connection Path |
| :--- | :--- | :--- |
| **Button 5 (Prev track)** | **Pin 18 (1.15)** | Pin 18 -> Switch Pin A <br> Switch Pin B -> GND |
| **Button 6 (Next track)** | **Pin 19 (0.02)** | Pin 19 -> Switch Pin A <br> Switch Pin B -> GND |

> Want different actions? Change the `&kp C_PREV` / `&kp C_NEXT` bindings (key
> positions 4 and 5) in
> [`crabulik_console.keymap`](../config/boards/shields/crabulik_console/crabulik_console.keymap).
> More pins remain free for further buttons — **D20, D21, D0, D1** as-is, plus
> **D10/D16** if you add `CONFIG_NFCT_PINS_AS_GPIO=y` (those two are NFC pins).
> Each extra button is one more `input-gpios` entry plus a matching binding on
> every keymap layer.

### Battery Connection
1. Solder the red wire of the 3.7V Li-Po battery to the **B+** pad on the back of the Supermini.
2. Solder the black wire to the **B-** pad.
3. **CRITICAL:** Do NOT solder the `BOOST` jumper. The default 100mA charge rate is perfect for a 110mAh battery.

### Entering the UF2 Bootloader (flashing)

To flash firmware the board must be in its **UF2 bootloader**, where it mounts as
a small removable USB drive (`NICENANO`). The bootloader is entered by a **quick
double reset** — briefly connecting the **RST** line to **GND** twice in fast
succession (same rhythm as a mouse double-click).

| Your board has... | How to enter the bootloader |
| :--- | :--- |
| A reset button | **Double-tap** it quickly. |
| **No reset button** (this build) | **Tap `RST` to `GND` twice, quickly** with a wire or tweezers. The `RST` and `GND` pins are exposed on the Pro Micro header. |

Notes:
* A **single** tap just reboots the board (normal reset); a **fast double** tap
  enters the bootloader. If it only reboots, tap a little faster.
* A **brand-new** board often ships already in bootloader mode — just plugging in
  USB may mount the `NICENANO` drive with no reset needed.
* **Optional mod:** solder a small momentary push button across **`RST` ↔ `GND`**
  to get a proper double-tap reset button. Recommended if you expect to reflash
  often.

Once the `NICENANO` drive appears, flash from the repo root with
`.\scripts\flash.ps1` (see [BUILD.md](BUILD.md)).
