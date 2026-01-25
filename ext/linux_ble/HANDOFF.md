# Handoff: BluetoothLinux BLE Backend

## Current Status

**Scanning: WORKING**
- Devices are discovered correctly
- Names, service UUIDs, manufacturer data all parsed properly
- Device address type (public/random) correctly detected

**Connecting: BLOCKED**
- L2CAP non-blocking connect times out (poll doesn't return write event)
- BlueZ (bluetoothctl) CAN connect to same devices
- Issue is in BluetoothLinux library's L2CAP handling

## What Was Done This Session

### L2CAPSocket Fixes Applied (in checkout)

The following changes were made to `.build/checkouts/BluetoothLinux/Sources/BluetoothLinux/L2CAP/L2CAPSocket.swift`:

1. **PSM Configuration**: Changed destination PSM from `.att` (0x1F) to `nil` for LE fixed channels
2. **Local Address Type**: Set to `.lowEnergyPublic` to match HCI adapter
3. **Local CID**: Changed from `.att` (4) to `0` (kernel assigns)

```swift
// Current configuration:
let localSocketAddress = L2CAPSocketAddress(
    address: localAddress,
    addressType: .lowEnergyPublic,  // LE public address for local bind
    protocolServiceMultiplexer: nil,  // No PSM for LE connections
    channel: 0  // Let kernel assign local CID
)
let destinationSocketAddress = L2CAPSocketAddress(
    address: destinationAddress,
    addressType: AddressType(lowEnergy: destinationAddressType),
    protocolServiceMultiplexer: nil,  // No PSM for LE fixed channels
    channel: .att  // CID 4 for ATT
)
```

### BLEManager.swift Fixes

1. Added `cachedLocalAddress` property to pre-cache address during initialization
2. Avoids HCI blocking issue (can't read address while scanning)

## Remaining Issues

### L2CAP Connection Timeout

**Symptoms:**
- `connect()` returns EINPROGRESS (expected for non-blocking)
- `poll()` for write event times out after 30 seconds
- Same devices connect fine with BlueZ/bluetoothctl

**Possible Causes:**
1. BlueZ uses btmgmt interface rather than raw L2CAP
2. BlueZ handles pairing/bonding negotiation automatically
3. BluetoothLinux may be missing LE connection initiation steps

**Investigation Ideas:**
1. Compare strace of BlueZ connection vs BluetoothLinux
2. Check if LE connection requires specific HCI commands first
3. Look at BlueZ source code for LE connection flow

## Previous Session: HCI Event Filter Bug

Found and documented bug where LE Meta Events weren't being received:
- `setEvent()` in CInterop.swift always used `eventMask.0` even for events >= 32
- LE Meta Event (code 62) needs bit 30 in `eventMask.1`
- PR created: https://github.com/jegt/BluetoothLinux/pull/51

## Files Modified

- `ext/linux_ble/Sources/RBLELinuxHelper/BLEManager.swift` - cachedLocalAddress property
- `.build/checkouts/BluetoothLinux/Sources/BluetoothLinux/L2CAP/L2CAPSocket.swift` - PSM/CID fixes (checkout only)

## Test Commands

```bash
# Reset adapter and run helper
sudo hciconfig hci0 reset
sudo setcap 'cap_net_raw,cap_net_admin=eip' ./.build/debug/RBLELinuxHelper

# Test scan
echo '{"id":1,"method":"start_scan","params":{"timeout":5}}' | \
  timeout 10 ./.build/debug/RBLELinuxHelper

# Test with BlueZ (this works)
sudo systemctl start bluetooth
bluetoothctl
> scan on
> connect A8:03:2A:B9:FE:FA
```

## Next Steps

1. Debug L2CAP connection flow - may need to trace system calls
2. Consider if LE connection requires HCI_LE_Create_Connection command first
3. Look at GATT library's connection code for any missing steps
4. Or: use DBus interface to BlueZ instead of direct HCI/L2CAP
