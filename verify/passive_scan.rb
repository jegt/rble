#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification: Passive BLE scan for 60 seconds
#
# Verifies that RBLE.scan(active: false) receives continuous BLE advertisements
# without user interaction. Checks for resource leaks after completion.
#
# Pass criteria:
#   - At least 1 advertisement received
#   - Maximum gap between advertisements < 10 seconds
#   - No resource leaks (thread delta <= 1, FD delta <= 2)
#
# Usage: ruby verify/passive_scan.rb

require_relative '../lib/rble'
require 'timeout'

SCRIPT_NAME = "verify/passive_scan"
DURATION = 60
MAX_GAP_SECONDS = 10

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
    devices_seen = {}
    total_advertisements = 0
    last_event_time = Time.now
    max_gap_observed = 0.0
    last_progress_time = Time.now

    RBLE.scan(active: false, timeout: DURATION, allow_duplicates: true) do |device|
      now = Time.now
      total_advertisements += 1

      gap = now - last_event_time
      max_gap_observed = gap if gap > max_gap_observed
      last_event_time = now

      entry = devices_seen[device.address] ||= { name: device.name, count: 0, first_seen: now }
      entry[:count] += 1
      entry[:last_seen] = now
      entry[:name] ||= device.name

      # Progress every 10 seconds
      if now - last_progress_time >= 10
        puts "[#{(now - start_time).round(0)}s] #{devices_seen.size} devices, #{total_advertisements} advertisements"
        last_progress_time = now
      end
    end

    # Evaluate pass criteria
    passed_adverts = total_advertisements > 0
    passed_gap = max_gap_observed < MAX_GAP_SECONDS

    metrics["Devices:"] = devices_seen.size
    metrics["Adverts:"] = total_advertisements
    metrics["Max gap:"] = "#{max_gap_observed.round(1)}s"

    if devices_seen.size <= 5
      addrs = devices_seen.map { |addr, info| "#{addr} (#{info[:name] || 'unnamed'})" }.join(", ")
      metrics["Addresses:"] = addrs
    else
      metrics["Addresses:"] = "#{devices_seen.size} unique"
    end

    unless passed_adverts
      $stderr.puts "FAIL: No advertisements received in #{DURATION}s"
    end

    unless passed_gap
      $stderr.puts "FAIL: Max gap #{max_gap_observed.round(1)}s exceeds #{MAX_GAP_SECONDS}s threshold"
    end

    status = :PASS if passed_adverts && passed_gap
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
