#!/usr/bin/env python3
"""
CrabulikConsole layout-indicator companion daemon (Windows + macOS).

The keyboard cannot read the host's active keyboard layout on its own, so this
small user-space app does it: it watches the OS layout and, on every change,
writes one byte over BLE to the keyboard's custom GATT characteristic. The
firmware lights the matching indicator LED.

Protocol (1 byte, must match modules/zmk-layout-indicators):
    0 = US   (led_us on,  led_ua off)
    1 = UA   (led_ua on,  led_us off)
    2 = off / unknown (both off)

The keyboard must be PAIRED (the characteristic requires an encrypted link) and
connected over Bluetooth (typing works, i.e. running on battery — not on a USB
data port, where it talks HID over USB and the BLE link drops).

How each platform reaches the (already-connected) keyboard:

  Windows  bleak finds devices by *scanning*, which fails for a device that's
           already connected (it stops advertising). So we use WinRT's
           BluetoothLEDevice.FromBluetoothAddressAsync, which reaches the
           connected/paired device directly by address — hence --address is
           required. (WinRT ships as a dependency of bleak; `pip install bleak`
           is enough.) Find the address with the registry one-liner in README.md.

  macOS    CoreBluetooth hides the BLE MAC address, so there is no address to
           pass. Instead we identify the keyboard by our unique custom SERVICE
           UUID via retrieveConnectedPeripheralsWithServices_ (no scan needed for
           a connected device), falling back to a scan-by-service. --address is
           ignored on macOS.

Usage:
    Windows:  python  crabulik_indicator.py --address F8:6B:7D:5C:15:A4
    macOS:    python3 crabulik_indicator.py
    (both):   ... --interval 0.5     # layout poll interval, seconds
    (both):   ... --log <path>       # append output to a file (for background runs)

To run it continuously in the background and start it at login, use the
installers: install-windows.ps1 (Windows) or install-macos.sh (macOS).
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


# =========================================================================== #
# Windows: layout detection (GetKeyboardLayout) + BLE writer (WinRT)
# =========================================================================== #
# Windows language identifiers (low word of the HKL). Extend as needed.
WIN_LANG_US = 0x0409  # English (United States)
WIN_LANG_UA = 0x0422  # Ukrainian


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


async def run_windows(address: str, interval: float) -> None:
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


# =========================================================================== #
# macOS: layout detection (Carbon TIS) + BLE writer (CoreBluetooth)
# =========================================================================== #
# Defined only on macOS so the module imports cleanly on Windows (importing
# CoreBluetooth/Carbon elsewhere would fail).
if sys.platform == "darwin":
    import ctypes
    import ctypes.util
    import time

    import objc
    from CoreBluetooth import (
        CBCentralManager,
        CBCharacteristicWriteWithResponse,
        CBUUID,
    )
    from Foundation import NSData, NSDate, NSObject, NSRunLoop

    CB_POWERED_ON = 5  # CBManagerStatePoweredOn
    RECONNECT_BACKOFF = 3.0  # seconds between connection attempts when offline

    SVC_CBUUID = CBUUID.UUIDWithString_(str(SVC_UUID).upper())
    CHR_CBUUID = CBUUID.UUIDWithString_(str(CHR_UUID).upper())

    # Human-readable CBManagerState / CBManagerAuthorization values.
    CB_STATE_NAMES = {
        0: "unknown",
        1: "resetting",
        2: "unsupported",
        3: "unauthorized",
        4: "poweredOff",
        5: "poweredOn",
    }
    CB_AUTH_NAMES = {0: "notDetermined", 1: "restricted", 2: "denied", 3: "allowedAlways"}

    def _bluetooth_authorization():
        """CBManagerAuthorization int, or None if the API isn't available."""
        try:
            return int(CBCentralManager.authorization())
        except Exception:  # noqa: BLE001 - older macOS without the class method
            return None

    def _bluetooth_permission_hint():
        """Print one-time guidance for the common 'state never resolves' trap.

        On macOS, Bluetooth access is attributed to the *responsible app* — the
        terminal/editor that launched Python. Launched from an IDE's integrated
        terminal (VS Code/Electron), CoreBluetooth often can't resolve the
        permission: no prompt appears and the manager sits in 'unknown' forever.
        Running from the standalone Terminal.app / iTerm fixes it."""
        auth = _bluetooth_authorization()
        print(
            "  Bluetooth isn't reporting 'poweredOn' "
            f"(permission: {CB_AUTH_NAMES.get(auth, auth)})."
        )
        print("  If it hangs here with no prompt, the app running Python lacks Bluetooth")
        print("  permission (common in IDE integrated terminals). Fix: run from the")
        print("  standalone Terminal.app or iTerm and allow Bluetooth when prompted, or")
        print("  enable it under System Settings > Privacy & Security > Bluetooth, then")
        print("  fully quit and reopen the terminal.")

    # --- Carbon Text Input Source API (via ctypes; no extra package) -------- #
    _carbon = ctypes.CDLL(ctypes.util.find_library("Carbon"))
    _cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
    _carbon.TISCopyCurrentKeyboardInputSource.restype = ctypes.c_void_p
    _carbon.TISGetInputSourceProperty.restype = ctypes.c_void_p
    _carbon.TISGetInputSourceProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
    _cf.CFStringGetCString.restype = ctypes.c_bool
    _cf.CFStringGetCString.argtypes = [
        ctypes.c_void_p,
        ctypes.c_char_p,
        ctypes.c_long,
        ctypes.c_uint32,
    ]
    _cf.CFRelease.argtypes = [ctypes.c_void_p]
    _kTISPropertyInputSourceID = ctypes.c_void_p.in_dll(
        _carbon, "kTISPropertyInputSourceID"
    )
    _CF_UTF8 = 0x08000100

    def _current_input_source_id():
        src = _carbon.TISCopyCurrentKeyboardInputSource()
        if not src:
            return None
        try:
            cfstr = _carbon.TISGetInputSourceProperty(
                src, _kTISPropertyInputSourceID
            )  # not owned, don't release
            if not cfstr:
                return None
            buf = ctypes.create_string_buffer(256)
            if _cf.CFStringGetCString(cfstr, buf, 256, _CF_UTF8):
                return buf.value.decode("utf-8")
            return None
        finally:
            _cf.CFRelease(src)

    def _layout_code_macos() -> int:
        sid = _current_input_source_id() or ""
        if "Ukrainian" in sid:
            return CODE_UA
        if sid.endswith(".US") or "ABC" in sid:
            return CODE_US
        return CODE_OFF

    # --- CoreBluetooth link ------------------------------------------------- #
    class CoreBluetoothLink(NSObject):
        """Maintains a persistent connection to the keyboard and writes the
        layout byte whenever the target changes.

        macOS hides BLE addresses, so the keyboard is found by our unique custom
        SERVICE UUID (retrieveConnectedPeripheralsWithServices_, no scan), with a
        scan-by-service fallback. The connection is kept open and the
        characteristic cached; on disconnect it re-acquires and re-syncs the LED.

        The daemon loop only declares intent via updateTarget_(); this object
        handles delivery, retries, and re-sync. Callbacks are delivered on the
        run loop the daemon pumps in run_macos()."""

        def init(self):
            self = objc.super(CoreBluetoothLink, self).init()
            if self is None:
                return None
            self.central = CBCentralManager.alloc().initWithDelegate_queue_(self, None)
            self.peripheral = None
            self.char = None
            self.target = None  # desired layout code (None until first set)
            self.last_written = None  # last code confirmed written
            self.powered = False
            self.acquiring = False
            self.next_attempt = 0.0  # monotonic time gate for connection attempts
            return self

        # ---- public API (called from the daemon loop) ---------------------- #
        def updateTarget_(self, code):
            """Set the desired layout code; write it now if the link is ready."""
            self.target = code
            self._flush()

        def ensureConnected(self):
            """Kick off a connection attempt if offline (rate-limited)."""
            if not self.powered or self.peripheral is not None or self.acquiring:
                return
            now = time.monotonic()
            if now < self.next_attempt:
                return
            self.next_attempt = now + RECONNECT_BACKOFF
            self._acquire()

        # ---- internals ----------------------------------------------------- #
        def _acquire(self):
            self.acquiring = True
            conn = self.central.retrieveConnectedPeripheralsWithServices_([SVC_CBUUID])
            if conn and len(conn):
                self.peripheral = conn[0]
                print(f"  found connected keyboard: {self.peripheral.name()}")
                self.central.connectPeripheral_options_(self.peripheral, None)
            else:
                print("  keyboard not in connected list; scanning by service UUID...")
                self.central.scanForPeripheralsWithServices_options_(
                    [SVC_CBUUID], None
                )

        def _flush(self):
            if (
                self.peripheral is not None
                and self.char is not None
                and self.target is not None
                and self.target != self.last_written
            ):
                data = NSData.dataWithBytes_length_(bytes([self.target]), 1)
                self.peripheral.writeValue_forCharacteristic_type_(
                    data, self.char, CBCharacteristicWriteWithResponse
                )

        def _drop(self):
            self.peripheral = None
            self.char = None
            self.acquiring = False
            self.last_written = None  # force a re-sync once reconnected

        # ---- CBCentralManagerDelegate -------------------------------------- #
        def centralManagerDidUpdateState_(self, central):
            self.powered = central.state() == CB_POWERED_ON
            if self.powered:
                self.ensureConnected()
            else:
                print(f"  Bluetooth not powered on (state={central.state()})")
                self._drop()

        def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
            self, central, peripheral, adv, rssi
        ):
            print(f"  discovered: {peripheral.name()}")
            central.stopScan()
            self.peripheral = peripheral
            central.connectPeripheral_options_(peripheral, None)

        def centralManager_didConnectPeripheral_(self, central, peripheral):
            peripheral.setDelegate_(self)
            peripheral.discoverServices_([SVC_CBUUID])

        def centralManager_didFailToConnectPeripheral_error_(
            self, central, peripheral, error
        ):
            print(f"  connect failed ({error}); will retry")
            self._drop()

        def centralManager_didDisconnectPeripheral_error_(
            self, central, peripheral, error
        ):
            print("  keyboard disconnected; will re-acquire")
            self._drop()

        # ---- CBPeripheralDelegate ------------------------------------------ #
        def peripheral_didDiscoverServices_(self, peripheral, error):
            if error:
                print(f"  service discovery error: {error}")
                self._drop()
                return
            for s in peripheral.services():
                if s.UUID().isEqual_(SVC_CBUUID):
                    peripheral.discoverCharacteristics_forService_([CHR_CBUUID], s)
                    return
            # Connected but no custom service: stay connected and quiet (no spin).
            print(
                "  custom service not found — old firmware without the layout "
                "module, or a stale GATT cache (remove + re-pair to refresh)."
            )
            self.acquiring = False

        def peripheral_didDiscoverCharacteristicsForService_error_(
            self, peripheral, service, error
        ):
            if error:
                print(f"  characteristic discovery error: {error}")
                self._drop()
                return
            for c in service.characteristics():
                if c.UUID().isEqual_(CHR_CBUUID):
                    self.char = c
                    self.acquiring = False
                    print("  link ready.")
                    self._flush()  # push the current target so the LED syncs
                    return
            print("  characteristic not found.")
            self.acquiring = False

        def peripheral_didWriteValueForCharacteristic_error_(
            self, peripheral, characteristic, error
        ):
            if error:
                print(f"  write failed: {error}")
            else:
                self.last_written = self.target

    def run_macos(interval: float) -> None:
        link = CoreBluetoothLink.alloc().init()
        last = None  # None forces a write on startup so the LED syncs immediately
        print("Watching layout; pushing to the keyboard over BLE on change (Ctrl+C to stop).")
        print("(macOS finds the keyboard by its custom service UUID — no address needed.)")
        rl = NSRunLoop.currentRunLoop()
        waited = 0.0  # seconds Bluetooth has failed to reach poweredOn
        warned = False  # one-time permission hint
        while True:
            # Pump the run loop so CoreBluetooth callbacks fire; this also paces
            # the poll. KeyboardInterrupt surfaces between iterations.
            rl.runMode_beforeDate_(
                "NSDefaultRunLoopMode", NSDate.dateWithTimeIntervalSinceNow_(interval)
            )
            # Watchdog: if Bluetooth never reaches poweredOn, it's almost always a
            # permission / responsible-app issue (see _bluetooth_permission_hint).
            if not link.powered:
                waited += interval
                if not warned and waited >= 5.0:
                    _bluetooth_permission_hint()
                    warned = True
            else:
                waited = 0.0
                warned = False
            link.ensureConnected()
            code = get_layout_code()
            if code != last:
                print(f"  layout -> {LABELS.get(code, '?')} ({code})")
                link.updateTarget_(code)
                last = code


# =========================================================================== #
# Dispatch
# =========================================================================== #
def get_layout_code() -> int:
    if sys.platform == "win32":
        return _layout_code_windows()
    if sys.platform == "darwin":
        return _layout_code_macos()
    raise RuntimeError(f"Unsupported platform: {sys.platform}")


def main() -> None:
    # Line-buffer stdout so progress shows promptly even when redirected to a file
    # or captured by launchd; block buffering would otherwise hide it until exit.
    try:
        sys.stdout.reconfigure(line_buffering=True)
    except Exception:  # noqa: BLE001 - reconfigure is best-effort (Python 3.7+)
        pass

    parser = argparse.ArgumentParser(description="CrabulikConsole layout indicator daemon")
    parser.add_argument(
        "--address",
        default=None,
        help="BLE address of the keyboard, e.g. F8:6B:7D:5C:15:A4 (Windows only; "
        "required there — find it with the registry one-liner in README.md). "
        "Ignored on macOS, which finds the keyboard by its service UUID.",
    )
    parser.add_argument(
        "--interval", type=float, default=0.4, help="layout poll interval (seconds)"
    )
    parser.add_argument(
        "--log",
        default=None,
        help="append stdout/stderr to this file. Used when run in the background "
        "(e.g. via install-windows.ps1 / pythonw), where there is no console to "
        "print to.",
    )
    args = parser.parse_args()

    # Background runners (pythonw.exe on Windows) have no console: sys.stdout is
    # None and prints would fail. Redirect to a log file so output is preserved.
    if args.log:
        try:
            logfile = open(args.log, "a", buffering=1, encoding="utf-8")
            sys.stdout = logfile
            sys.stderr = logfile
        except Exception:  # noqa: BLE001 - logging is best-effort
            pass

    if sys.platform == "win32":
        if not args.address:
            print("ERROR: --address is required on Windows (a connected BLE device can't be scanned).")
            print("Find the keyboard's address with the registry one-liner in README.md,")
            print("then run:  python crabulik_indicator.py --address <AA:BB:CC:DD:EE:FF>")
            sys.exit(1)
        try:
            asyncio.run(run_windows(args.address, args.interval))
        except KeyboardInterrupt:
            print("\nStopped.")
    elif sys.platform == "darwin":
        try:
            run_macos(args.interval)
        except KeyboardInterrupt:
            print("\nStopped.")
    else:
        print(f"ERROR: unsupported platform: {sys.platform}")
        sys.exit(1)


if __name__ == "__main__":
    main()
