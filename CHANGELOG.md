# Changelog

All notable changes to this project will be documented in this file.

## [0.6.0] - 2026-02-05

### Added

- **CLI Tool** — `rble` command-line executable for BLE operations from the terminal
- `rble scan` — discover BLE devices with `--timeout`, `--continuous`, `--passive`, `--name`, `--rssi` filters
- `rble show <mac>` — connect and display GATT service/characteristic tree with human-readable names
- `rble status` — show Bluetooth adapter info and powered state
- `rble doctor` — diagnose 8 common Bluetooth problems with actionable fix commands
- `rble adapter list/power/discoverable/pairable/name` — manage adapter settings
- `rble pair <mac>` / `rble unpair <mac>` / `rble paired` — BLE device pairing management
- `rble read <mac> <char>` — read characteristic values with smart formatting
- `rble write <mac> <char> <value>` — write to characteristics with 8 type encoders (hex, string, uint8/16/32, int8/16/32)
- `rble monitor <mac> <char>` — subscribe and stream notifications with reconnect support
- `--json` flag on all commands for structured NDJSON output
- GATT UUID database with 175 entries (70 services, 90 characteristics, 15 descriptors) at `RBLE::GATT::UUIDDatabase`
- 15 smart value parsers for known BLE characteristic types (heart rate, battery, temperature, blood pressure, etc.)
- IEEE 11073 FLOAT/SFLOAT decoding for medical device data
- Hex dump formatter for unknown characteristic types
- PairingAgent and PairingSession infrastructure for BlueZ pairing operations
- Thor ~> 1.3 as CLI framework dependency

## [0.5.0] - 2026-02-05

### Added

- Passive scanning mode via `RBLE.scan(active: false)` on both backends
- `Device#manufacturer_data_bytes(company_id)` convenience method for parsing advertisement data
- RuuviTag passive scanning example script (`examples/passive_scan.rb`)
- `RBLE.warnings` flag to suppress user-facing warnings (`RBLE.warnings = false`)
- `RBLE.rble_warn` centralized warning helper with consistent `[RBLE]` prefix
- `Backend::Base#subscriptions_for_connection` method on both backends
- `connection:` parameter on all GATT methods for both backends
- CoreBluetooth error mapping expanded from 2 to 8 specific RBLE exception classes
- Platform differences documentation (`docs/PLATFORM_DIFFERENCES.md`)
- Hardware verification scripts for BLE workflows (`verify/`)
- Thread safety audit confirming all 15 shared variables are properly protected

### Fixed

- Untracked D-Bus signal handlers causing FD leaks on session close
- CoreBluetooth `address_type` changed from hardcoded `'random'` to `nil` (accurate)
- CoreBluetooth `discover` regex now handles reversed word order in error messages

### Removed

- Dead code: `setup_disconnect_monitoring` and `translate_dbus_error` (63 lines)

### Changed

- All `[rble]` prefixes normalized to uppercase `[RBLE]` across all backends and trace output
- `allow_duplicates:` default changed to `nil` sentinel with conditional resolution based on `active:` parameter

## [0.1.0] - 2026-01-23

Initial release.

### Added

- BLE device scanning with service UUID filtering
- GATT connections with service/characteristic discovery
- Read and write characteristic values
- Subscribe to characteristic notifications
- Disconnect detection with callbacks
- Linux support via BlueZ D-Bus API
- macOS support via CoreBluetooth (Swift helper)
- Automatic macOS helper build during gem install
