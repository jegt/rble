# Changelog

All notable changes to this project will be documented in this file.

## [0.7.1] - 2026-03-18

### Fixed

- **`at_exit` hook hangs CI** — Per-instance `at_exit { cleanup_all_connections }` in backend initializers caused process hang at exit when the singleton was reset during test teardown. Moved to a single class-level hook in `Backend` that reads the current singleton at exit time (no-op after `Backend.reset!`) with a 5-second thread timeout.
- **CI timeout** — Added `timeout-minutes: 10` to CI workflow as a safety net.

## [0.7.0] - 2026-03-17

### Fixed (Critical)

- **GATT queue was dead code** (R1) — `gatt_queue` was a private method, so `respond_to?(:gatt_queue)` always returned false and all GATT operations bypassed the serialization queue. Made `gatt_queue` public.
- **Stale subscriptions on normal disconnect** (R2) — `disconnect_device` did not clear `@subscriptions` for the device on either BlueZ or CoreBluetooth backends. This broke reconnect-resubscribe flows.

### Fixed (High)

- **GATT queue stop stranded callers** (R3) — `GattOperationQueue#stop` cleared the queue without notifying threads blocked on `enqueue`. Now drains pending operations and unblocks callers with a `RuntimeError`.
- **GATT queue race condition** (R5) — `gatt_queue` accessor could create duplicate queues under concurrent access. Now protected by mutex.
- **`@services` thread safety** (R6) — `@services` reads/writes in `Connection` are now synchronized with `@state_mutex`.
- **CoreBluetooth busy-poll** (R8) — Replaced `sleep 0.001`/`sleep 0.01` busy-poll in `send_request` with blocking `Queue#pop(timeout:)`.
- **Value parser bounds checking** (R4) — All binary characteristic parsers now return `"malformed"` for truncated input instead of crashing.
- **`remaining_timeout` error messages** (R7) — Timeout errors now report the correct operation name instead of always saying "Connect".

### Fixed (Medium)

- **`at_exit` connection cleanup** (R9) — Both backends now register `at_exit` hooks to disconnect all tracked connections on process exit, preventing 30s device unreachability.
- **CoreBluetooth scan state poisoning** (R12) — `start_scan` failure now resets `@scanning` to false, preventing permanent `ScanInProgressError`.
- **CLI pair security validation** (R13) — Invalid `--security` values are now rejected with a clear error message.
- **CLI write octal/hex rejection** (R14) — Integer parsing now enforces decimal (base 10) to prevent `010` being treated as octal `8`.
- **Monitor reconnect sleep** (R15) — Reconnect delay is now interruptible, responding to Ctrl+C within 100ms instead of up to 2s.

### Fixed (Low)

- **Text formatter nil RSSI** (R17) — Shows "N/A" instead of fabricating "0 dBm" when RSSI is unknown.
- **JSON raw bytes format** (R20) — `read_value` now uses `raw_hex` (hex string) matching `monitor_value` format. **Breaking change** for JSON consumers: `raw` (integer array) is now `raw_hex` (hex string).
- **JSON write verified key** (R24) — `write_result` only includes `verified` key when verify was actually requested.
- **JSON pair/unpair edge states** (R18) — `already_paired` and `not_paired` states now produce JSON output.
- **Doctor platform guard** (R19) — Linux-specific checks are skipped on non-Linux platforms. Added `check_ruby_dbus` diagnostic.
- **32-bit UUID handling** (R21) — `normalize_char_uuid` and `normalize_key` now handle 8-character UUID inputs.
- **Deduplicated `connect_with_retry`** (R22) — `Show` now uses the shared `CharacteristicHelpers` version.
- **CoreBluetooth `subscriptions_for_connection`** (R25) — Now correctly filters by the connection's device UUID instead of returning all subscriptions.

### Removed

- Dead `GattService` class (R23) — unused code removed.

### Documentation

- README: Added Linux section documenting `ruby-dbus` dependency.

### Known Issues (deferred)

- R10: `@stop_requested` in Scanner is not thread-safe under JRuby (no current impact under MRI).
- R11: Post-unsubscribe notification callbacks may still fire due to async D-Bus signal delivery.
- R16: Each connection creates two D-Bus sessions (connect-session + Connection-session). Architectural change deferred.

## [0.6.3] - 2026-02-06

### Fixed

- Eliminate D-Bus `on_signal` deadlock across all call sites — `on_signal` calls synchronous `AddMatch` which blocks forever when an event loop is reading the same socket
- Scan: replace per-device `subscribe_to_device_properties_for_scan` (called after event loop starts) with a single broad pathless `PropertiesChanged` match rule registered before event loop
- Connect: replace synchronous `on_signal`/`remove_match` in `async_connect` and `wait_for_services_resolved` with new `async_register_signal_handler` / `async_unregister_signal_handler` methods
- Subscribe: replace `Thread.new` + `register_signal_handler` workaround in `subscribe_characteristic` with `async_register_signal_handler` (eliminates orphaned threads)
- Cache invalidation: reorder `setup_cache_invalidation_handler` to run before event loop starts in `start_event_loop`

### Added

- `DBusSession#async_register_signal_handler` — splits `on_signal` into local handler registration + async D-Bus `AddMatch` call, safe to call while event loop is running
- `DBusSession#async_unregister_signal_handler` — same pattern for `RemoveMatch`

### Removed

- `subscribe_to_device_properties_for_scan` method (replaced by broad match rule)

## [0.6.2] - 2026-02-06

### Fixed

- `Time#iso8601` error on Ruby 3.2/3.3 in JSON monitor output (added missing `require 'time'`)
- BlueZ adapter test no longer fails in CI when D-Bus socket exists but BlueZ service is not running
- `rble doctor` no longer crashes on macOS due to unconditional `ruby-dbus` require
- macOS CI bundle install failure caused by frozen lockfile mismatch (use `install_if` for `ruby-dbus`)
- `rble adapter` help showed doubled namespace (`rble rble adapter`)
- Disabled ANSI color in CLI help output for consistent readability

## [0.6.1] - 2026-02-06

### Fixed

- `rble doctor` no longer crashes with `uninitialized constant RBLE::BlueZ` (added missing require)
- `rble doctor` output redesigned: compact OK/FAIL/WARN checklist with detailed errors at bottom
- `rble help` and `rble tree` show clean command names (`rble scan`, `rble adapter`) instead of internal class paths
- `rble scan` Ctrl+C reliably stops within 1 second using flag-and-wake pattern (no more potential deadlock)

### Changed

- `ruby-dbus` is no longer a hard gemspec dependency; only required at runtime on Linux for BlueZ backend
- Gemspec metadata completed (documentation_uri, bug_tracker_uri)
- Gem description updated to be more precise and technical

### Added

- GitHub Actions CI workflow (Ruby 3.2/3.3/3.4 on Ubuntu, Ruby 3.4 on macOS)

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
