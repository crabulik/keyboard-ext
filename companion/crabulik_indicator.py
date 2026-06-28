#!/usr/bin/env python3
"""
CrabulikConsole layout-indicator companion daemon (Windows / WinRT).

The keyboard cannot read the host's active keyboard layout on its own, so this
small user-space app does it: it watches the OS layout and, on every change,
writes one byte over BLE to the keyboard's custom GATT characteristic. The
firmware lights the matching indicator LED.

Why WinRT instead of bleak: bleak finds devices by *scanning*, which fails for a
keyboard that's already connected (a connected BLE device stops advertising).
WinRT's BluetoothLEDevice.FromBluetoothAddressAsync reaches the connected/paired
device directly, with no scan. (WinRT ships as a dependency of bleak, so
`pip install bleak` is enough.)

Protocol (1 byte, must match modules/zmk-layout-indicators):
    0 = US   (led_us on,  led_ua off)
    1 = UA   (led_ua on,  led_us off)
    2 = off / unknown (both off)

The keyboard must be PAIRED (the characteristic requires an encrypted link) and
connected over Bluetooth (typing works). Find its address with the registry
one-liner in README.md.

Usage:
    python crabulik_indicator.py --address F8:6B:7D:5C:15:A4
    python crabulik_indicator.py --address F8:6B:7D:5C:15:A4 --interval 0.5
"""

import argparse
import asyncio
import sys
import uuid

# Must match the firmware (modules/zmk-layout-indicators/src/layout_indicators.c)
SVC_UUID = uuid.UUID("6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d")
CHR_UUID = uuid.UUID("6b1a0002-7a3c-4b9e-9c2d-1f5e8a0b1c2d")

CODE_US = 0
CODE_UA = 1
CODE_OFF = 2
LABELS = {CODE_US: "US", CODE_UA: "UA", CODE_OFF: "off"}

# Windows language identifiers (low word of the HKL). Extend as needed.
WIN_LANG_US = 0x0409  # English (United States)
WIN_LANG_UA = 0x0422  # Ukrainian


# --------------------------------------------------------------------------- #
# Layout detection (per-OS)
# --------------------------------------------------------------------------- #
def _layout_code_windows() -> int:
    import ctypes

    user32 = ctypes.windll.user32
    hwnd = user32.GetForegroundWindow()
    thread_id = user32.GetWindowThreadProcessId(hwnd, None)
    hkl = user32.GetKeyboardLayout(thread_id)
    lang_id = hkl & 0xFFFF  # low word = language identifier
    if lang_id == WIN_LANG_US:
        return CODE_US
    if lang_id == WIN_LANG_UA:
        return CODE_UA
    return CODE_OFF


def get_layout_code() -> int:
    if sys.platform == "win32":
        return _layout_code_windows()
    # macOS support (TISCopyCurrentKeyboardInputSource + a CoreBluetooth writer)
    # is not implemented yet — Windows is the first target.
    raise RuntimeError(f"Unsupported platform: {sys.platform}")


# --------------------------------------------------------------------------- #
# BLE link (WinRT — reaches the already-connected device, no scan)
# --------------------------------------------------------------------------- #
class WinRTLink:
    """Holds the BLE device + characteristic and writes the layout byte.

    The handle is cached and re-acquired automatically if a write fails (e.g.
    after the keyboard disconnects/reconnects)."""

    def __init__(self, address: str) -> None:
        self._addr = int(address.replace(":", "").replace("-", ""), 16)
        self._device = None
        self._char = None

    async def _acquire(self) -> None:
        from winrt.windows.devices.bluetooth import BluetoothLEDevice
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattCommunicationStatus,
        )

        device = await BluetoothLEDevice.from_bluetooth_address_async(self._addr)
        if device is None:
            raise RuntimeError(
                "device not reachable (is it powered and connected over Bluetooth?)"
            )

        sres = await device.get_gatt_services_for_uuid_async(SVC_UUID)
        if sres.status != GattCommunicationStatus.SUCCESS or sres.services.size == 0:
            raise RuntimeError(
                "custom service not found (old firmware without the module, or the "
                "GATT cache is stale — remove + re-pair in Windows to refresh it)"
            )
        service = sres.services.get_at(0)

        cres = await service.get_characteristics_for_uuid_async(CHR_UUID)
        if cres.status != GattCommunicationStatus.SUCCESS or cres.characteristics.size == 0:
            raise RuntimeError("characteristic not found")

        self._device = device  # keep a reference so the connection isn't dropped
        self._char = cres.characteristics.get_at(0)

    async def write(self, code: int) -> None:
        from winrt.windows.devices.bluetooth.genericattributeprofile import (
            GattCommunicationStatus,
        )
        from winrt.windows.storage.streams import DataWriter

        if self._char is None:
            await self._acquire()

        writer = DataWriter()
        writer.write_byte(code)
        result = await self._char.write_value_with_result_async(writer.detach_buffer())
        if result.status != GattCommunicationStatus.SUCCESS:
            self.reset()
            raise RuntimeError(
                f"write rejected (status={result.status}) — likely the bond/encryption; "
                "remove + re-pair in Windows"
            )

    def reset(self) -> None:
        self._device = None
        self._char = None


# --------------------------------------------------------------------------- #
# Main loop
# --------------------------------------------------------------------------- #
async def run(address: str, interval: float) -> None:
    link = WinRTLink(address)
    last = None  # None forces a write on startup so the LED syncs immediately
    print(f"Watching layout; writing to {address} on change (Ctrl+C to stop).")
    while True:
        code = get_layout_code()
        if code != last:
            try:
                await link.write(code)
                print(f"  layout -> {LABELS.get(code, '?')} ({code})")
                last = code
            except Exception as exc:  # noqa: BLE001 - report and re-acquire
                print(f"  write failed: {exc}")
                print("  re-acquiring in 3s...")
                link.reset()
                last = None
                await asyncio.sleep(3.0)
                continue
        await asyncio.sleep(interval)


def main() -> None:
    parser = argparse.ArgumentParser(description="CrabulikConsole layout indicator daemon")
    parser.add_argument(
        "--address",
        default=None,
        help="BLE address of the keyboard, e.g. F8:6B:7D:5C:15:A4 (required). "
        "Find it with the registry one-liner in README.md.",
    )
    parser.add_argument(
        "--interval", type=float, default=0.4, help="layout poll interval (seconds)"
    )
    args = parser.parse_args()

    if not args.address:
        print("ERROR: --address is required (a connected BLE device can't be scanned).")
        print("Find the keyboard's address with the registry one-liner in README.md,")
        print("then run:  python crabulik_indicator.py --address <AA:BB:CC:DD:EE:FF>")
        sys.exit(1)

    try:
        asyncio.run(run(args.address, args.interval))
    except KeyboardInterrupt:
        print("\nStopped.")


if __name__ == "__main__":
    main()
