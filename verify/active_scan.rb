#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification: Active BLE scan for device discovery
#
# Verifies that RBLE.scan (active mode, default) discovers BLE devices
# with names and RSSI values. No user interaction required.
#
# Pass criteria:
#   - At least 1 device found
#   - At least 1 device has a name
#   - No resource leaks (thread delta <= 1, FD delta <= 2)
#
# Usage: ruby verify/active_scan.rb

require_relative '../lib/rble'
require 'timeout'

SCRIPT_NAME = "verify/active_scan"
DURATION = 15

def thread_count
  Thread.list.count
end

def fd_count
  Dir.glob('/proc/self/fd/*').count
end

# Capture baseline AFTER requiring rble
start_time = Time.now
baseline_threads = thread_count
baseline_fds = fd_count
status = :FAIL
metrics = {}

begin
  Timeout.timeout(DURATION * 2) do
    devices = {}

    RBLE.scan(timeout: DURATION, allow_duplicates: false) do |device|
      devices[device.address] = { name: device.name, rssi: device.rssi }
      puts "  #{device.address}  #{(device.name || '(unnamed)').ljust(30)}  RSSI: #{device.rssi || 'n/a'}"
    end

    # Evaluate pass criteria
    total = devices.size
    named_count = devices.count { |_, info| info[:name] }
    rssi_count = devices.count { |_, info| info[:rssi] }

    strongest = devices.max_by { |_, info| info[:rssi] || -999 }

    metrics["Devices:"] = total
    metrics["Named:"] = named_count
    metrics["With RSSI:"] = rssi_count

    if strongest
      addr, info = strongest
      label = info[:name] || addr
      metrics["Strongest:"] = "#{label} (#{info[:rssi]} dBm)"
    end

    passed_found = total > 0
    passed_named = named_count > 0

    unless passed_found
      $stderr.puts "FAIL: No devices found in #{DURATION}s"
    end

    unless passed_named
      $stderr.puts "FAIL: No devices with names found"
    end

    status = :PASS if passed_found && passed_named
  end
rescue Timeout::Error
  $stderr.puts "ERROR: Script timed out after #{DURATION * 2}s (safety net)"
rescue => e
  $stderr.puts "ERROR: #{e.class}: #{e.message}"
ensure
  # Allow GC to finalize D-Bus socket objects before measuring FDs
  GC.start
  sleep 0.5

  elapsed = (Time.now - start_time).round(1)
  final_threads = thread_count
  final_fds = fd_count
  thread_delta = final_threads - baseline_threads
  fd_delta = final_fds - baseline_fds

  # Check for resource leaks
  if thread_delta > 1
    $stderr.puts "LEAK: #{thread_delta} threads not cleaned up"
    status = :FAIL
  end
  if fd_delta > 2
    $stderr.puts "LEAK: #{fd_delta} file descriptors not closed"
    status = :FAIL
  end

  # Print structured summary
  puts
  puts "=" * 60
  puts "VERIFICATION: #{SCRIPT_NAME}"
  puts "-" * 60
  puts "Status:       #{status}"
  puts "Duration:     #{elapsed}s"
  metrics.each { |k, v| puts "#{k.ljust(14)}#{v}" }
  puts "-" * 60
  puts "Resources:"
  puts "  Threads:    #{baseline_threads} -> #{final_threads} (delta: #{thread_delta})"
  puts "  FDs:        #{baseline_fds} -> #{final_fds} (delta: #{fd_delta})"
  puts "=" * 60

  exit(status == :PASS ? 0 : 1)
end
