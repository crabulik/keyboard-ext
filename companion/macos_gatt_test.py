"""
One-shot CoreBluetooth GATT write test for macOS (analog of win_gatt_test.py).

macOS hides BLE MAC addresses, so we identify the keyboard by our unique custom
SERVICE UUID and reach the already-connected device via
retrieveConnectedPeripheralsWithServices_ (no scan needed); it falls back to a
scan-by-service if it isn't currently connected.

It also prints the current keyboard layout (via the Carbon TIS API) so we can
validate layout detection at the same time.

Requires:
    pip install pyobjc-framework-CoreBluetooth

Usage (keyboard powered + connected over Bluetooth, i.e. typing works):
    python3 macos_gatt_test.py 1     # write UA   (led_ua)
    python3 macos_gatt_test.py 0     # write US   (led_us)
    python3 macos_gatt_test.py 2     # both off
    python3 macos_gatt_test.py       # just print detected layout, write nothing
"""

import ctypes
import ctypes.util
import sys

import objc
from CoreBluetooth import (
    CBCentralManager,
    CBCharacteristicWriteWithResponse,
    CBUUID,
)
from Foundation import NSData, NSDate, NSObject, NSRunLoop

SVC_UUID = CBUUID.UUIDWithString_("6B1A0001-7A3C-4B9E-9C2D-1F5E8A0B1C2D")
CHR_UUID = CBUUID.UUIDWithString_("6B1A0002-7A3C-4B9E-9C2D-1F5E8A0B1C2D")
CB_POWERED_ON = 5  # CBManagerStatePoweredOn

CODE_US, CODE_UA, CODE_OFF = 0, 1, 2


# --------------------------------------------------------------------------- #
# Layout detection (Carbon Text Input Source API via ctypes)
# --------------------------------------------------------------------------- #
_carbon = ctypes.CDLL(ctypes.util.find_library("Carbon"))
_cf = ctypes.CDLL(ctypes.util.find_library("CoreFoundation"))
_carbon.TISCopyCurrentKeyboardInputSource.restype = ctypes.c_void_p
_carbon.TISGetInputSourceProperty.restype = ctypes.c_void_p
_carbon.TISGetInputSourceProperty.argtypes = [ctypes.c_void_p, ctypes.c_void_p]
_cf.CFStringGetCString.restype = ctypes.c_bool
_cf.CFStringGetCString.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_long, ctypes.c_uint32]
_cf.CFRelease.argtypes = [ctypes.c_void_p]
_kID = ctypes.c_void_p.in_dll(_carbon, "kTISPropertyInputSourceID")
_UTF8 = 0x08000100


def current_input_source_id():
    src = _carbon.TISCopyCurrentKeyboardInputSource()
    if not src:
        return None
    try:
        cfstr = _carbon.TISGetInputSourceProperty(src, _kID)  # not owned, don't release
        if not cfstr:
            return None
        buf = ctypes.create_string_buffer(256)
        if _cf.CFStringGetCString(cfstr, buf, 256, _UTF8):
            return buf.value.decode("utf-8")
        return None
    finally:
        _cf.CFRelease(src)


def get_layout_code():
    sid = current_input_source_id() or ""
    if "Ukrainian" in sid:
        return CODE_UA
    if sid.endswith(".US") or "ABC" in sid:
        return CODE_US
    return CODE_OFF


# --------------------------------------------------------------------------- #
# CoreBluetooth one-shot
# --------------------------------------------------------------------------- #
class Tester(NSObject):
    def initWithCode_(self, code):
        self = objc.super(Tester, self).init()
        self.code = code
        self.done = False
        self.peripheral = None
        return self

    def centralManagerDidUpdateState_(self, central):
        if central.state() != CB_POWERED_ON:
            print(f"Bluetooth not powered on (state={central.state()})")
            self.done = True
            return
        conn = central.retrieveConnectedPeripheralsWithServices_([SVC_UUID])
        if conn and len(conn):
            self.peripheral = conn[0]
            print(f"found connected peripheral: {self.peripheral.name()}")
            central.connectPeripheral_options_(self.peripheral, None)
        else:
            print("not in connected list; scanning by service UUID...")
            central.scanForPeripheralsWithServices_options_([SVC_UUID], None)

    def centralManager_didDiscoverPeripheral_advertisementData_RSSI_(
        self, central, peripheral, adv, rssi
    ):
        print(f"discovered: {peripheral.name()}")
        central.stopScan()
        self.peripheral = peripheral
        central.connectPeripheral_options_(peripheral, None)

    def centralManager_didConnectPeripheral_(self, central, peripheral):
        print("connected; discovering services...")
        peripheral.setDelegate_(self)
        peripheral.discoverServices_([SVC_UUID])

    def peripheral_didDiscoverServices_(self, peripheral, error):
        if error:
            print(f"service discovery error: {error}")
            self.done = True
            return
        for s in peripheral.services():
            if s.UUID().isEqual_(SVC_UUID):
                print("found custom service; discovering characteristics...")
                peripheral.discoverCharacteristics_forService_([CHR_UUID], s)
                return
        print("FAIL: custom service not found (old firmware without the module?)")
        self.done = True

    def peripheral_didDiscoverCharacteristicsForService_error_(self, peripheral, service, error):
        if error:
            print(f"characteristic discovery error: {error}")
            self.done = True
            return
        for c in service.characteristics():
            if c.UUID().isEqual_(CHR_UUID):
                if self.code is None:
                    print("characteristic found; no code given, nothing written.")
                    self.done = True
                    return
                data = NSData.dataWithBytes_length_(bytes([self.code]), 1)
                print(f"writing code {self.code} ...")
                peripheral.writeValue_forCharacteristic_type_(
                    data, c, CBCharacteristicWriteWithResponse
                )
                return
        print("FAIL: characteristic not found")
        self.done = True

    def peripheral_didWriteValueForCharacteristic_error_(self, peripheral, characteristic, error):
        if error:
            print(f"FAIL: write error: {error}")
        else:
            print("SUCCESS — wrote the layout code; the matching LED should be on now.")
        self.done = True


def main():
    code = int(sys.argv[1]) if len(sys.argv) > 1 else None
    print(f"current layout id: {current_input_source_id()}  -> code {get_layout_code()}")
    if code is None:
        print("(no code arg; pass 0/1/2 to also write)")

    tester = Tester.alloc().initWithCode_(code)
    CBCentralManager.alloc().initWithDelegate_queue_(tester, None)

    rl = NSRunLoop.currentRunLoop()
    deadline = NSDate.dateWithTimeIntervalSinceNow_(20.0)
    while not tester.done and NSDate.date().compare_(deadline) < 0:
        rl.runMode_beforeDate_("NSDefaultRunLoopMode", NSDate.dateWithTimeIntervalSinceNow_(0.1))
    if not tester.done:
        print("timed out (no Bluetooth callback within 20s).")


if __name__ == "__main__":
    main()
