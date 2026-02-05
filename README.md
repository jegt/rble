# RBLE

Reliable BLE communication for Ruby — scanning, connections, and GATT operations on Linux and macOS. Includes a standalone `rble` CLI tool.

## Features

- **CLI Tool** - `rble` command for scanning, inspecting, reading, writing, and monitoring BLE devices from the terminal
- **Device Scanning** - Discover BLE devices with filtering by service UUID, name, RSSI
- **GATT Connections** - Connect to devices and discover services/characteristics
- **Read/Write** - Read and write characteristic values with timeout support
- **Notifications** - Subscribe to characteristic value changes with smart formatting
- **Cross-Platform** - Works on Linux (BlueZ/D-Bus) and macOS (CoreBluetooth)
- **Disconnect Detection** - Callbacks for connection state changes and disconnections
- **GATT UUID Database** - 175 human-readable names for standard BLE services and characteristics

## Requirements

- **Ruby** 3.2 or higher
- **Linux**: BlueZ 5.50+ with D-Bus
- **macOS**: macOS 12 (Monterey) or higher, Xcode command-line tools

## Installation

Add to your Gemfile:

```ruby
gem 'rble'
```

Then run:

```bash
bundle install
```

### macOS

On macOS, a Swift helper binary is automatically compiled during gem installation. This requires Xcode Command Line Tools:

```bash
xcode-select --install
```

If the automatic build fails, you can build manually:

```bash
cd $(bundle info rble --path)/ext/macos_ble
swift build -c release
```

### Linux Permissions

On Linux, ensure your user has permission to access Bluetooth. Either:

1. Add your user to the `bluetooth` group:
   ```bash
   sudo usermod -aG bluetooth $USER
   # Log out and back in for changes to take effect
   ```

2. Or run with appropriate permissions via polkit.

## Quick Start

Verify your setup works by scanning for nearby devices:

```ruby
require 'rble'

RBLE.scan(timeout: 5) do |device|
  puts "Found: #{device.name || 'Unknown'} (#{device.address})"
end
```

## CLI Tool

RBLE includes a standalone command-line tool for BLE operations without writing Ruby code:

```bash
# Discover nearby devices
rble scan
rble scan --timeout 30 --name Polar --rssi -70

# Check Bluetooth health
rble status
rble doctor

# Inspect a device's GATT services
rble show AA:BB:CC:DD:EE:FF

# Read/write characteristics
rble read AA:BB:CC:DD:EE:FF 2a19        # Battery Level → "95%"
rble write AA:BB:CC:DD:EE:FF 2a00 "MyDevice"

# Stream notifications
rble monitor AA:BB:CC:DD:EE:FF 2a37      # Heart Rate → "72 bpm"

# Manage adapter
rble adapter list
rble adapter power on

# Pairing
rble pair AA:BB:CC:DD:EE:FF
rble paired
rble unpair AA:BB:CC:DD:EE:FF
```

All commands support `--json` for structured NDJSON output and `--help` for usage details.

## Rake Tasks

RBLE provides rake tasks for system checks and integration testing. Add to your Rakefile:

```ruby
require 'rble/tasks'
```

Then run:

```bash
# Check system BLE readiness (permissions, adapter, helper binary)
rake rble:check

# Run integration test with real BLE hardware
rake test:integration
```

The `rble:check` task verifies your system is correctly configured for BLE operations and provides actionable suggestions for any issues found.

## Usage Examples

### Scanning for Devices

Basic scan with timeout:

```ruby
require 'rble'

# Scan for 10 seconds, callback for each unique device
RBLE.scan(timeout: 10) do |device|
  puts "#{device.name || 'Unknown'} - #{device.address}"
  puts "  RSSI: #{device.rssi} dBm"
  puts "  Services: #{device.service_uuids.join(', ')}" unless device.service_uuids.empty?
end
```

Filter by service UUID (e.g., Heart Rate service):

```ruby
RBLE.scan(timeout: 10, service_uuids: ['180d']) do |device|
  puts "Heart rate monitor: #{device.name}"
end
```

Continuous RSSI monitoring (for beacon-style applications):

```ruby
RBLE.scan(timeout: 60, allow_duplicates: true) do |device|
  puts "#{device.address}: RSSI #{device.rssi} dBm"
end
```

Manual stop control:

```ruby
scanner = RBLE.scan do |device|
  puts device.name
  scanner.stop if device.name == "MyDevice"
end
```

### Finding a Specific Device

Find a device by address (stops scanning when found):

```ruby
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)

if device
  puts "Found: #{device.name}"
else
  puts "Device not found"
end
```

### Connecting and Discovering Services

```ruby
# First, find the device to ensure it's advertising
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)
raise "Device not found" unless device

# Connect to the device
connection = RBLE.connect(device.address, timeout: 30)
puts "Connected!"

# Discover GATT services
services = connection.discover_services
puts "Found #{services.length} services:"

services.each do |service|
  puts "  Service: #{service.short_uuid}"
  service.characteristics.each do |char|
    puts "    Characteristic: #{char.short_uuid} [#{char.flags.join(', ')}]"
  end
end

# Always disconnect when done
connection.disconnect
```

### Reading a Characteristic

```ruby
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)
raise "Device not found" unless device

connection = RBLE.connect(device.address)
connection.discover_services

# Get Device Information service (standard UUID: 0x180a)
device_info = connection.service('180a')

# Read Model Number characteristic (standard UUID: 0x2a24)
model_char = device_info.characteristic('2a24')
model_number = model_char.read
puts "Model: #{model_number}"

# Read as byte array instead
bytes = model_char.read_bytes
puts "Bytes: #{bytes.inspect}"

connection.disconnect
```

### Writing a Characteristic

```ruby
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)
raise "Device not found" unless device

connection = RBLE.connect(device.address)
connection.discover_services

# Find your service and characteristic
service = connection.service('your-service-uuid')
char = service.characteristic('your-characteristic-uuid')

# Write with response (waits for acknowledgment)
char.write([0x01, 0x02, 0x03])

# Write without response (faster, no acknowledgment)
char.write([0x01, 0x02, 0x03], response: false)

# Write a string (converted to bytes)
char.write("hello".bytes)

connection.disconnect
```

### Subscribing to Notifications

```ruby
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)
raise "Device not found" unless device

connection = RBLE.connect(device.address)
connection.discover_services

# Subscribe to Heart Rate Measurement notifications
hr_service = connection.service('180d')
hr_measurement = hr_service.characteristic('2a37')

hr_measurement.subscribe do |value|
  # Heart Rate Measurement format: first byte contains flags,
  # heart rate value follows (8-bit or 16-bit based on flags)
  bytes = value.bytes
  flags = bytes[0]
  hr_value = (flags & 0x01) == 0 ? bytes[1] : (bytes[1] | (bytes[2] << 8))
  puts "Heart Rate: #{hr_value} BPM"
end

# Keep the connection open to receive notifications
puts "Listening for heart rate updates... Press Ctrl+C to stop"
sleep(60)

# Clean up
hr_measurement.unsubscribe
connection.disconnect
```

### Handling Disconnection Events

```ruby
device = RBLE.find_device("AA:BB:CC:DD:EE:FF", timeout: 10)
raise "Device not found" unless device

connection = RBLE.connect(device.address)

# Register disconnect callback before doing other operations
connection.on_disconnect do |reason|
  puts "Disconnected! Reason: #{reason}"
  # reason is a symbol: :user_requested, :link_loss, :timeout, :remote_disconnect, etc.
end

# Optional: track all state changes
connection.on_state_change do |old_state, new_state|
  puts "Connection state: #{old_state} -> #{new_state}"
end

connection.discover_services
# ... use the connection ...

# When you disconnect intentionally, callback receives :user_requested
connection.disconnect
```

## API Overview

### RBLE Module Methods

- `RBLE.scan(timeout:, service_uuids:, allow_duplicates:, adapter:) { |device| }` - Scan for devices
- `RBLE.find_device(address, timeout:, adapter:)` - Find a specific device by address
- `RBLE.connect(address, timeout:, adapter:)` - Connect to a device
- `RBLE.adapters` - List available Bluetooth adapters

### Device

Immutable snapshot of a discovered device:
- `address` - MAC address (Linux) or UUID (macOS)
- `name` - Device name from advertisement
- `rssi` - Signal strength in dBm
- `service_uuids` - Advertised service UUIDs
- `manufacturer_data` - Company ID to byte array mapping
- `tx_power` - Transmit power level

### Connection

Active connection to a device:
- `discover_services` - Discover GATT services
- `services` - Get discovered services
- `service(uuid)` - Find a service by UUID
- `connected?` - Check connection state
- `on_disconnect { |reason| }` - Register disconnect callback
- `on_state_change { |old, new| }` - Register state change callback
- `disconnect` - Close the connection

### Service

GATT service with characteristics:
- `uuid` - Full 128-bit UUID
- `short_uuid` - Short UUID for standard services (e.g., "180d")
- `characteristic(uuid)` - Find a characteristic by UUID
- `characteristics` - All characteristics in this service

### ActiveCharacteristic

Characteristic with read/write/subscribe operations:
- `uuid` / `short_uuid` - Characteristic UUID
- `flags` - Capability flags ("read", "write", "notify", etc.)
- `readable?` / `writable?` / `subscribable?` - Check capabilities
- `read` - Read value as binary string
- `read_bytes` - Read value as byte array
- `write(data, response:)` - Write value
- `subscribe { |value| }` - Subscribe to notifications
- `unsubscribe` - Stop receiving notifications

## Platform Notes

### Linux (BlueZ)

**Requirements:**
- BlueZ 5.50 or higher
- D-Bus system bus access

**Adapter Selection:**

On systems with multiple Bluetooth adapters, specify which to use:

```ruby
RBLE.scan(adapter: 'hci1') { |d| puts d.name }
RBLE.connect(address, adapter: 'hci1')
```

List available adapters:

```ruby
RBLE.adapters.each do |adapter|
  puts "#{adapter[:name]}: #{adapter[:address]} (powered: #{adapter[:powered]})"
end
```

**Permissions:**

If you see permission errors, ensure your user is in the `bluetooth` group:

```bash
sudo usermod -aG bluetooth $USER
# Log out and log back in
```

Or configure polkit for your application.

### macOS (CoreBluetooth)

**Requirements:**
- macOS 12 (Monterey) or higher
- Xcode command-line tools (`xcode-select --install`)

**Build the Helper:**

The macOS backend uses a Swift helper binary. Build it with:

```bash
bundle exec rake build:macos
```

**Device Addresses:**

On macOS, CoreBluetooth does not expose actual MAC addresses. Instead, devices are identified by a system-assigned UUID that may change:

```ruby
# macOS device addresses look like UUIDs
RBLE.find_device("E621E1F8-C36C-495A-93FC-0C247A3E6E5F")
```

**Bluetooth Permissions:**

The first time your application uses Bluetooth, macOS will prompt for permission. Grant access in System Preferences > Privacy & Security > Bluetooth.

## Error Handling

RBLE raises specific exceptions for different error conditions:

```ruby
begin
  connection = RBLE.connect(address, timeout: 10)
  connection.discover_services
  # ...
rescue RBLE::AdapterNotFoundError
  puts "No Bluetooth adapter found"
rescue RBLE::AdapterDisabledError
  puts "Bluetooth is turned off"
rescue RBLE::ConnectionTimeoutError
  puts "Could not connect - device may be out of range"
rescue RBLE::NotConnectedError
  puts "Connection lost during operation"
rescue RBLE::ServiceNotFoundError => e
  puts "Service not available: #{e.message}"
rescue RBLE::CharacteristicNotFoundError => e
  puts "Characteristic not available: #{e.message}"
rescue RBLE::NotSupportedError => e
  puts "Operation not supported: #{e.message}"
rescue RBLE::ReadError, RBLE::WriteError => e
  puts "GATT operation failed: #{e.message}"
end
```

### Common Errors

| Error | Meaning |
|-------|---------|
| `AdapterNotFoundError` | No Bluetooth hardware detected |
| `AdapterDisabledError` | Bluetooth is turned off |
| `PermissionError` | Missing Bluetooth permissions |
| `ConnectionTimeoutError` | Device not responding (out of range, not advertising) |
| `NotConnectedError` | Connection was lost |
| `ServiceNotFoundError` | Requested service UUID not on device |
| `CharacteristicNotFoundError` | Requested characteristic not in service |
| `NotSupportedError` | Characteristic doesn't support the operation |
| `ReadError` / `WriteError` | GATT operation failed |

## Development

### Running Tests

```bash
bundle install
bundle exec rspec
```

### Building the macOS Helper

```bash
bundle exec rake build:macos
```

This compiles the Swift helper from `ext/macos_ble/`.

### Code Style

```bash
bundle exec rubocop
```

## License

MIT License. See [LICENSE.txt](LICENSE.txt) for details.
