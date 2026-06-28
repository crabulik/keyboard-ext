"""
One-shot WinRT GATT write test for Windows.

bleak finds devices by *scanning*, which fails for a device that's already
connected (it stops advertising). This bypasses bleak and uses the WinRT API
that can reach a *connected/paired* device directly:
    BluetoothLEDevice.FromBluetoothAddressAsync(addr)  -> no scan needed
and forces an UNCACHED service lookup (Windows may have cached the old GATT
table from a previous pairing that predates our custom service).

Usage (keyboard powered + connected, i.e. typing works):
    python win_gatt_test.py 1     # write UA  (led_ua)
    python win_gatt_test.py 0     # write US  (led_us)
    python win_gatt_test.py 2     # both off
"""

import asyncio
import sys
import uuid

from winrt.windows.devices.bluetooth import BluetoothLEDevice
from winrt.windows.devices.bluetooth.genericattributeprofile import (
    GattCommunicationStatus,
    GattWriteOption,
)
from winrt.windows.storage.streams import DataWriter

ADDRESS = "F8:6B:7D:5C:15:A4"
SVC_UUID = uuid.UUID("6b1a0001-7a3c-4b9e-9c2d-1f5e8a0b1c2d")
CHR_UUID = uuid.UUID("6b1a0002-7a3c-4b9e-9c2d-1f5e8a0b1c2d")


def addr_to_int(addr: str) -> int:
    return int(addr.replace(":", ""), 16)


async def main() -> None:
    code = int(sys.argv[1]) if len(sys.argv) > 1 else 1
    print(f"Connecting to {ADDRESS}, writing layout code {code} ...")

    dev = await BluetoothLEDevice.from_bluetooth_address_async(addr_to_int(ADDRESS))
    if dev is None:
        print("FAIL: FromBluetoothAddressAsync returned None.")
        print("  -> Windows has no live handle for this device. Make sure it is")
        print("     powered, connected (typing works), and bonded.")
        return
    print(f"OK device: name='{dev.name}'  connection={dev.connection_status}")

    sres = await dev.get_gatt_services_for_uuid_async(SVC_UUID)
    print(f"service lookup: status={sres.status}  count={sres.services.size}")
    if sres.status != GattCommunicationStatus.SUCCESS or sres.services.size == 0:
        print("Custom service not found by UUID. Listing ALL services for debugging:")
        allres = await dev.get_gatt_services_async()
        if allres.status == GattCommunicationStatus.SUCCESS:
            for i in range(allres.services.size):
                print("   service:", allres.services.get_at(i).uuid)
        else:
            print("   (could not enumerate services:", allres.status, ")")
        print("  -> If 6b1a0001-... is ABSENT above, the board has OLDER firmware")
        print("     without the layout module. Reflash crabulik_console-nice_nano.uf2,")
        print("     remove+re-pair in Windows (refreshes the GATT cache), then retry.")
        return

    svc = sres.services.get_at(0)
    cres = await svc.get_characteristics_for_uuid_async(CHR_UUID)
    print(f"characteristic lookup: status={cres.status}  count={cres.characteristics.size}")
    if cres.status != GattCommunicationStatus.SUCCESS or cres.characteristics.size == 0:
        print("FAIL: characteristic not found.")
        return

    ch = cres.characteristics.get_at(0)
    writer = DataWriter()
    writer.write_byte(code)
    st = await ch.write_value_with_result_async(writer.detach_buffer())
    print(f"write: status={st.status}")
    if st.status == GattCommunicationStatus.SUCCESS:
        print("SUCCESS — wrote the layout code. The corresponding LED should be on now.")
    else:
        print(f"FAIL: write rejected (likely encryption/bond). protocol_error={st.protocol_error}")
        print("  -> Remove the device in Windows Bluetooth, re-pair, retry.")


if __name__ == "__main__":
    asyncio.run(main())
