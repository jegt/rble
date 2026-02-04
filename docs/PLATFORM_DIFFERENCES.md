# Platform Differences

RBLE works on both Linux (BlueZ) and macOS (CoreBluetooth). The API is the same on both platforms, but some behaviors differ due to platform limitations. This document covers what you need to know.

## Device Identification

Devices are identified differently on each platform:

- **Linux:** MAC addresses (e.g., `"AA:BB:CC:DD:EE:FF"`)
- **macOS:** UUID strings assigned by CoreBluetooth (e.g., `"12345678-1234-1234-1234-123456789ABC"`)

Device addresses are **not portable** between platforms. A device scanned on Linux will have a different identifier than the same device scanned on macOS.

The `address_type` field on `Device` is available on Linux (from BlueZ, typically `"public"` or `"random"`) and is `nil` on macOS.

```ruby
RBLE.scan(timeout: 5) do |device|
  puts device.address       # MAC on Linux, UUID on macOS
  puts device.address_type  # "public"/"random" on Linux, nil on macOS
end
```

## Scanning

### Passive Scanning

The `active:` parameter controls active vs. passive scanning:

- **Linux:** Fully supported. `active: false` performs passive scanning (no scan requests sent).
- **macOS:** CoreBluetooth does not expose scan mode control. The library warns and proceeds with a normal scan.

```ruby
# Works on Linux; warns and continues on macOS
RBLE.scan(active: false, timeout: 10) do |device|
  puts device.name
end
```

### Adapter Selection

The `adapter:` parameter selects which Bluetooth adapter to use:

- **Linux:** Supported. Pass an adapter name like `"hci0"`.
- **macOS:** Not available. The library warns and uses the default adapter.

```ruby
# Works on Linux; warns and continues on macOS
RBLE.scan(adapter: "hci0", timeout: 10) do |device|
  puts device.name
end
```

## Connections

Connection behavior is consistent across platforms. `RBLE.connect` takes a device address (MAC on Linux, UUID on macOS) and returns a `Connection` object with the same API on both platforms.

Disconnect reasons are mapped to the same symbols on both platforms:
`:user_requested`, `:timeout`, `:remote_disconnect`, `:connection_failed`, `:link_loss`, `:unknown`.

## GATT Operations

Read, write, subscribe, and unsubscribe have identical APIs on both platforms:

```ruby
conn = RBLE.connect(device.address)
conn.discover_services

service = conn.service("180d")
char = service.characteristic("2a37")

value = char.read
char.write("\x01")
char.subscribe { |data| puts data.bytes.inspect }
char.unsubscribe

conn.disconnect
```

The `connection:` keyword parameter used internally by the BlueZ backend for D-Bus session routing is handled transparently -- you do not need to pass it.

## Error Handling

Both backends raise the same RBLE exception classes. You can write rescue patterns that work on both platforms:

```ruby
begin
  conn = RBLE.connect(device.address, timeout: 10)
  conn.discover_services
  value = conn.service("180d").characteristic("2a37").read
rescue RBLE::ConnectionTimeoutError
  # Connection timed out
rescue RBLE::DeviceNotFoundError
  # Device disappeared between scan and connect
rescue RBLE::NotConnectedError
  # Connection lost during operation
rescue RBLE::ReadError, RBLE::WriteError
  # GATT read or write failed
rescue RBLE::ServiceDiscoveryError
  # Service discovery failed or timed out
rescue RBLE::ConnectionError
  # Any connection-related error (parent of timeout, not-connected, etc.)
rescue RBLE::Error
  # Catch-all for any RBLE error
end
```

Use `exception.cause` to access the original platform-specific error for debugging:

```ruby
rescue RBLE::ReadError => e
  puts e.message        # RBLE error message
  puts e.cause&.message # Original platform error (if any)
end
```

### Error Class Hierarchy

```
RBLE::Error
  RBLE::ConnectionError
    RBLE::ConnectionTimeoutError
    RBLE::DeviceNotFoundError
    RBLE::NotConnectedError
    RBLE::AlreadyConnectedError
    RBLE::ConnectionFailed
  RBLE::ServiceDiscoveryError
    RBLE::CharacteristicNotFoundError
  RBLE::GATTError
    RBLE::ReadError
    RBLE::WriteError
    RBLE::NotifyError
  RBLE::BluetoothOffError
  RBLE::PermissionError
  RBLE::AdapterNotFoundError
```

## Adapter Information

`RBLE.adapters` returns adapter details, but the content differs:

- **Linux:** Returns MAC address, adapter name (e.g., `"hci0"`), and powered status.
- **macOS:** Returns name (`"default"`), `nil` for address, and powered status.

```ruby
RBLE.adapters
# Linux:  [{name: "hci0", address: "AA:BB:CC:DD:EE:FF", powered: true}]
# macOS:  [{name: "default", address: nil, powered: true}]
```

## Warning Suppression

Set `RBLE.warnings = false` to suppress platform-capability warnings (e.g., passive scan not supported, adapter selection not available):

```ruby
RBLE.warnings = false
```

This suppresses feature-level warnings only. Error-level messages (subprocess crashes, JSON parse errors) always print regardless of this setting.
