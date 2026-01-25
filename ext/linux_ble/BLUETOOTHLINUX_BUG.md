# BluetoothLinux Bug: HCI Event Filter Does Not Support Events >= 32

## Summary

The `setEvent()` method in `CInterop.HCIFilterSocketOption` incorrectly handles HCI events with codes >= 32, causing LE Meta Events (code 0x3E = 62) to be filtered out. This makes BLE scanning non-functional.

## Affected Version

- Commit: `077f9d36afdae57e12c436842db56ef318e2fd23` (master as of 2026-01-24)
- Also affects all tagged releases including 5.0.5

## Environment

- Linux kernel 6.8.0-90-generic (Ubuntu 24.04)
- Swift 6.0
- Realtek USB Bluetooth adapter (hci0)

## Symptoms

- `lowEnergyScan()` returns a valid `AsyncLowEnergyScanStream`
- The stream never yields any scan results
- No errors are thrown
- `btmon` shows LE Advertising Reports ARE being received by the kernel
- HCI commands (LE Set Scan Parameters, LE Set Scan Enable) succeed

## Root Cause

In `Sources/BluetoothLinux/Internal/CInterop.swift`, lines 591-594:

```swift
@usableFromInline
mutating func setEvent(_ event: UInt8) {
    let bit = (CInt(event) & 63)
    HCISetBit(bit, &eventMask.0)  // BUG: Always uses eventMask.0
}
```

The HCI filter structure has two 32-bit event mask words:
- `eventMask.0` for events 0-31
- `eventMask.1` for events 32-63

The current code always sets the bit in `eventMask.0`, even for events >= 32. For LE Meta Event (code 62):
- `bit = 62 & 63 = 62`
- `HCISetBit(62, &eventMask.0)` - attempts to set bit 62 in a 32-bit integer

This results in undefined behavior (likely no bit being set) and the LE Meta events are filtered out by the kernel.

## Proof via strace

The HCI filter being set shows:
```
setsockopt(9, SOL_HCI, HCI_FILTER, "\20\0\0\0\0\0\0@\0\0\0\0\0\0\0\0", 16)
```

Decoded:
- `type_mask` = 0x10 (allow event packets) ✓
- `event_mask[0]` = 0x40000000 (bit 30 set - wrong location)
- `event_mask[1]` = 0x00000000 (should have bit 30 set for event 62)

## Fix

```swift
@usableFromInline
mutating func setEvent(_ event: UInt8) {
    // Events 0-31 use eventMask.0, events 32-63 use eventMask.1
    if event >= 32 {
        let bit = CInt(event) - 32
        HCISetBit(bit, &eventMask.1)
    } else {
        let bit = CInt(event)
        HCISetBit(bit, &eventMask.0)
    }
}
```

## Verification

After applying the fix, `lowEnergyScan()` correctly yields BLE advertisements:

```
device_discovered: A8:03:2A:B9:FE:FA (ShellyPlus1-A8032AB9FEF8)
device_discovered: C4:82:E1:06:93:C7 (TY)
device_discovered: 4A:F4:13:64:66:50 (Quest 3)
device_discovered: DD:DF:30:71:BB:06 (Ruuvi BB06)
... (many more devices)
```

## Related Issues

This may be related to or the root cause of:
- Issue #40: "Scan error Invalid HCI Command Parameters"

While #40 reports a different error, the underlying cause (improper HCI filter configuration) is similar. Some adapters may fail with an error while others silently filter out the events.

## Impact

- **All BLE scanning is broken** on Linux
- Affects any code using `lowEnergyScan()` or `GATTCentral.scan()`
- The library appears to work (no errors) but never discovers any devices

## Suggested PR

A one-line conceptual fix in `CInterop.swift`:

```diff
 @usableFromInline
 mutating func setEvent(_ event: UInt8) {
-    let bit = (CInt(event) & 63)
-    HCISetBit(bit, &eventMask.0)
+    if event >= 32 {
+        HCISetBit(CInt(event) - 32, &eventMask.1)
+    } else {
+        HCISetBit(CInt(event), &eventMask.0)
+    }
 }
```

---

*Discovered while developing rble (Ruby BLE gem) BluetoothLinux backend*
*2026-01-24*
