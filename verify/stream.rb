#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification: Sustained 5-minute BLE subscription stream
#
# Discovers BLE devices, connects, finds a subscribable characteristic,
# and sustains a subscription for 5 minutes monitoring for data continuity.
#
# Pass criteria:
#   - PASS: >= 10 data points over 5 minutes, max_gap < 30s, still connected at end
#   - SKIP: no subscribable device/characteristic found (not an rble failure)
#   - FAIL: connection dropped, max_gap exceeded, or resource leak
#
# Usage: ruby verify/stream.rb

require_relative '../lib/rble'

SCRIPT_NAME = "verify/stream"
SCAN_TIMEOUT = 15
CONNECT_TIMEOUT = 15
STREAM_DURATION = 300
MAX_GAP_SECONDS = 30
MAX_RETRIES = 3

def thread_count
  Thread.list.count
end

def fd_count
  Dir.glob('/proc/self/fd/*').count
rescue Errno::ENOENT, Errno::EACCES
  0
end

def resource_snapshot
  { threads: thread_count, fds: fd_count }
end

def print_summary(status, elapsed, metrics, baseline, final_res)
  thread_delta = final_res[:threads] - baseline[:threads]
  fd_delta = final_res[:fds] - baseline[:fds]

  puts
  puts "=" * 60
  puts "VERIFICATION: #{SCRIPT_NAME}"
  puts "-" * 60
  puts "Status:       #{status}"
  puts "Duration:     #{elapsed}s"
  metrics.each { |k, v| puts "#{k.ljust(14)}#{v}" }
  puts "-" * 60
  puts "Resources:"
  puts "  Threads:    #{baseline[:threads]} -> #{final_res[:threads]} (delta: #{thread_delta})"
  puts "  FDs:        #{baseline[:fds]} -> #{final_res[:fds]} (delta: #{fd_delta})"
  puts "=" * 60

  [thread_delta, fd_delta]
end

def find_connectable_devices
  candidates = []
  puts "Scanning for connectable devices (#{SCAN_TIMEOUT}s)..."

  RBLE.scan(timeout: SCAN_TIMEOUT) do |device|
    next unless device.name && device.rssi && device.rssi > -80

    existing = candidates.find { |c| c.address == device.address }
    unless existing
      candidates << device
      puts "  Found: #{device.name} (#{device.address}) RSSI: #{device.rssi}"
    end
  end

  candidates.sort_by { |d| -(d.rssi || -100) }
end

def with_retries(description)
  attempts = 0
  begin
    attempts += 1
    yield
  rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError => e
    if attempts < MAX_RETRIES
      puts "  Retry #{attempts}/#{MAX_RETRIES} for #{description}: #{e.class}: #{e.message}"
      sleep 1
      retry
    end
    raise
  end
end

# --- Main ---

start_time = Time.now
baseline = resource_snapshot
status = :FAIL
metrics = {}
conn = nil
subscribed_char = nil
found_subscribable = false

begin
  Timeout.timeout(STREAM_DURATION * 2 + 60) do
    candidates = find_connectable_devices

    if candidates.empty?
      $stderr.puts "SKIP: No connectable devices found"
      status = :SKIP
      metrics["Scanned:"] = "0 candidates"
      raise "No connectable devices"
    end

    metrics["Scanned:"] = "#{candidates.size} candidates"

    candidates.first(5).each do |device|
      puts "\nTrying #{device.name} (#{device.address})..."
      begin
        with_retries(device.name) do
          conn = RBLE.connect(device.address, timeout: CONNECT_TIMEOUT)

          begin
            puts "  Connected. Discovering services..."
            services = conn.discover_services
            puts "  Found #{services.size} services"

            # Find subscribable characteristic
            sub_char = nil
            services.each do |svc|
              sub_char = svc.characteristics.find(&:subscribable?)
              break if sub_char
            end

            unless sub_char
              puts "  No subscribable characteristics"
              conn.disconnect
              conn = nil
              next
            end

            found_subscribable = true
            subscribed_char = sub_char

            # Stream tracking state
            data_points = 0
            last_data_time = Time.now
            max_gap = 0.0
            stream_start = Time.now
            disconnect_count = 0

            conn.on_disconnect do |_reason|
              disconnect_count += 1
            end

            puts "  Subscribing to #{sub_char.short_uuid} for #{STREAM_DURATION}s..."
            sub_char.subscribe do |_value|
              now = Time.now
              gap = now - last_data_time
              max_gap = gap if gap > max_gap
              last_data_time = now
              data_points += 1
            end

            puts "  Streaming..."
            last_progress = Time.now
            stream_elapsed = 0.0

            while stream_elapsed < STREAM_DURATION
              sleep 0.5
              stream_elapsed = Time.now - stream_start

              # Progress every 30 seconds
              if Time.now - last_progress >= 30
                puts "  [#{stream_elapsed.round(0)}s] #{data_points} data points, max gap: #{max_gap.round(1)}s"
                last_progress = Time.now
              end

              # Early exit if connection lost
              unless conn.connected?
                puts "  Connection lost after #{stream_elapsed.round(0)}s"
                break
              end
            end

            sub_char.unsubscribe rescue nil
            subscribed_char = nil
            still_connected = conn.connected?
            conn.disconnect if still_connected
            conn = nil

            actual_duration = (Time.now - stream_start).round(1)

            metrics["Connected:"] = "#{device.name} (#{device.address})"
            metrics["Char:"] = sub_char.short_uuid
            metrics["Points:"] = data_points
            metrics["Max gap:"] = "#{max_gap.round(1)}s"
            metrics["Drops:"] = disconnect_count
            metrics["Duration:"] = "#{actual_duration}s"

            passed_points = data_points >= 10
            passed_gap = max_gap < MAX_GAP_SECONDS
            passed_connected = still_connected

            unless passed_points
              $stderr.puts "FAIL: Only #{data_points} data points (need >= 10)"
            end
            unless passed_gap
              $stderr.puts "FAIL: Max gap #{max_gap.round(1)}s exceeds #{MAX_GAP_SECONDS}s"
            end
            unless passed_connected
              $stderr.puts "FAIL: Connection dropped during stream"
            end

            if passed_points && passed_gap && passed_connected
              status = :PASS
            end

            break
          ensure
            subscribed_char&.unsubscribe rescue nil
            subscribed_char = nil
            if conn&.connected?
              conn.disconnect rescue nil
            end
            conn = nil
          end
        end

        break if status == :PASS || found_subscribable
      rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError => e
        puts "  Failed: #{e.class}: #{e.message}"
        next
      end
    end

    # Determine final status if not already set
    if status != :PASS && status != :FAIL
      unless found_subscribable
        status = :SKIP
        $stderr.puts "SKIP: No subscribable characteristics found on any device"
        metrics["Reason:"] = "no subscribable characteristics"
      end
    end
  end
rescue Timeout::Error
  $stderr.puts "ERROR: Script timed out after #{STREAM_DURATION * 2 + 60}s (safety net)"
rescue => e
  unless e.message == "No connectable devices"
    $stderr.puts "ERROR: #{e.class}: #{e.message}"
  end
ensure
  subscribed_char&.unsubscribe rescue nil
  conn&.disconnect rescue nil

  elapsed = (Time.now - start_time).round(1)
  final_res = resource_snapshot
  thread_delta, fd_delta = print_summary(status, elapsed, metrics, baseline, final_res)

  if thread_delta > 1
    $stderr.puts "LEAK: #{thread_delta} threads not cleaned up"
    status = :FAIL
  end
  if fd_delta > 2
    $stderr.puts "LEAK: #{fd_delta} file descriptors not closed"
    status = :FAIL
  end

  exit(status == :SKIP ? 0 : (status == :PASS ? 0 : 1))
end
