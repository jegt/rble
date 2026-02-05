# Changelog

All notable changes to this project will be documented in this file.

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
