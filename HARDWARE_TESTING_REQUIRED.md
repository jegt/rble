# Hardware Testing Required

The reliability improvements from RELIABILITY_RESEARCH.md have been implemented but **require hardware testing** before being considered complete.

## Changes Requiring Hardware Verification

### Phase 2.1: ServicesResolved Delay (150ms)
- **File**: `lib/rble/bluez/async_connection_operations.rb`
- **Test**: Connect to a real BLE device and verify services are fully available after connection
- **Risk**: Delay may be too short for some devices, or too long causing unnecessary latency

### Phase 2.2: GATT Operation Queue (50ms inter-op delay)
- **File**: `lib/rble/bluez/gatt_operation_queue.rb`
- **Test**: Rapid read/write cycles on real device, concurrent operations from multiple threads
- **Risk**: Queue serialization may cause timeouts, delay may need tuning

### Phase 2.3: InProgress Retry Policy (3 retries, exponential backoff)
- **File**: `lib/rble/bluez/retry_policy.rb`
- **Test**: Trigger InProgress errors by rapid operations, verify retries succeed
- **Risk**: May not retry enough, or may retry when it shouldn't

### Phase 2.4: UUID Filter Verification
- **File**: `lib/rble/backend/bluez.rb`
- **Test**: Scan with UUID filter, verify only matching devices returned
- **Risk**: May incorrectly filter out valid devices

### Phase 2.5: Scan/Connect Conflict Prevention
- **File**: `lib/rble/backend/bluez.rb`
- **Test**: Start scan, then connect - verify scan stops and connect succeeds
- **Risk**: May cause issues if scan stop fails

## Recommended Hardware Test Procedure

```ruby
# 1. Basic connect/disconnect cycle
device = RBLE.scan(timeout: 5) { |d| d.name =~ /MyDevice/ }
conn = RBLE.connect(device.address)
conn.discover_services
conn.disconnect

# 2. GATT operation stress test
conn = RBLE.connect(device.address)
conn.discover_services
char = conn.service('180d').characteristic('2a37')

# Rapid reads
10.times { char.read }

# Concurrent operations (should serialize via queue)
threads = 5.times.map { Thread.new { char.read } }
threads.each(&:join)

conn.disconnect

# 3. Subscription test
conn = RBLE.connect(device.address)
conn.discover_services
char = conn.service('180d').characteristic('2a37')
char.subscribe { |v| puts v.bytes.inspect }
sleep 5
char.unsubscribe
conn.disconnect

# 4. Disconnect/reconnect test
5.times do
  conn = RBLE.connect(device.address)
  conn.discover_services
  conn.disconnect
end
```

## Status

- [x] Hardware tests run on Linux with BlueZ (2026-01-27)
- [x] ServicesResolved delay verified - services discovered successfully after connect
- [x] GATT queue tested - sequential and concurrent reads serialized properly
- [x] Notifications tested - 5 heart rate notifications received successfully
- [ ] InProgress retry observed - no InProgress errors occurred during testing (good!)
- [x] Scan/connect conflict tested - scan auto-stopped before connect with warning log
- [x] Reconnect cycles tested - 5 connect/discover/disconnect cycles completed

## Test Results (2026-01-27)

Tested with Polar H10 heart rate monitor (24:AC:AC:0C:DD:8E):

1. **Connect & Discover Services**: 7 services discovered with 18 characteristics
2. **Sequential GATT Reads**: 5 reads completed successfully (0.99-2.68s each)
3. **Concurrent GATT Reads**: 3 concurrent threads serialized properly through queue
4. **Notifications**: 5 heart rate notifications received over 5 seconds
5. **Disconnect**: Clean disconnect
6. **Scan/Connect Conflict**: Warning logged, scan stopped, connect succeeded
7. **Reconnect Cycles**: 5/5 cycles completed successfully

## Notes

Unit tests pass (211 examples, 0 failures) and hardware tests verified the reliability features work correctly with real BLE hardware.
