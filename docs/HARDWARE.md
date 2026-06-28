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

*Note: Rotary encoders (EC11 and TTC mouse wheel) are planned for a future hardware revision.*

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
