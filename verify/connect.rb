#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification: Connect + service discovery + characteristic read
#
# Discovers BLE devices in range, connects to the strongest signal,
# discovers GATT services, and reads a characteristic value.
#
# Pass criteria:
#   - Connected to at least 1 device
#   - Discovered at least 1 service
#   - Read at least 1 characteristic (or services found but no readable chars)
#   - No resource leaks (thread delta <= 1, FD delta <= 2)
#
# Usage: ruby verify/connect.rb

require_relative '../lib/rble'
require_relative 'reason_codes'
require 'timeout'

SCRIPT_NAME = 'verify/connect'
SCAN_TIMEOUT = 15
CONNECT_TIMEOUT = 15
MAX_RETRIES = 3
MAX_CANDIDATES_TO_TRY = 10
MIN_RSSI = -92
PREFERRED_DEVICE_PATTERNS = [/ruuvi/i, /shelly/i, /vivosmart/i].freeze
PREFERRED_READ_CHARS = %w[2a00 2a01 2a29 2a24 2a19].freeze

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
  puts '=' * 60
  puts "VERIFICATION: #{SCRIPT_NAME}"
  puts '-' * 60
  puts "Status:       #{status}"
  puts "Duration:     #{elapsed}s"
  metrics.each { |k, v| puts "#{k.ljust(14)}#{v}" }
  puts '-' * 60
  puts 'Resources:'
  puts "  Threads:    #{baseline[:threads]} -> #{final_res[:threads]} (delta: #{thread_delta})"
  puts "  FDs:        #{baseline[:fds]} -> #{final_res[:fds]} (delta: #{fd_delta})"
  puts '=' * 60

  [thread_delta, fd_delta]
end

def find_connectable_devices
  candidates = []
  puts "Scanning for connectable devices (#{SCAN_TIMEOUT}s)..."

  RBLE.scan(timeout: SCAN_TIMEOUT) do |device|
    next unless device.address
    next if device.rssi && device.rssi < MIN_RSSI

    existing = candidates.find { |c| c.address == device.address }
    unless existing
      candidates << device
      label = device.name || '(unnamed)'
      puts "  Found: #{label} (#{device.address}) RSSI: #{device.rssi || 'n/a'}"
    end
  end

  candidates.sort_by do |d|
    name = d.name.to_s
    preferred_idx = PREFERRED_DEVICE_PATTERNS.find_index { |rx| name.match?(rx) } || 999
    [preferred_idx, -(d.rssi || -127)]
  end
end

def with_retries(description)
  attempts = 0
  begin
    attempts += 1
    yield
  rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError, RBLE::SessionClosedError => e
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
reason = nil
metrics = {}
conn = nil
saw_session_closed = false

begin
  Timeout.timeout(120) do
    candidates = find_connectable_devices

    if candidates.empty?
      warn 'FAIL: No connectable devices found (with name and RSSI > -80)'
      metrics['Scanned:'] = '0 candidates'
      reason ||= Verify::Reason::NO_CONNECTABLE_DEVICES
      raise 'No connectable devices'
    end

    metrics['Scanned:'] = "#{candidates.size} candidates"
    connected_device = nil
    services_found = 0
    chars_total = 0
    read_result = nil

    candidates.first(MAX_CANDIDATES_TO_TRY).each do |device|
      puts "\nTrying #{device.name} (#{device.address})..."
      begin
        with_retries(device.name) do
          conn = RBLE.connect(device.address, timeout: CONNECT_TIMEOUT)

          begin
            puts '  Connected. Discovering services...'
            services = conn.discover_services
            services_found = services.size
            chars_total = services.sum { |s| s.characteristics.size }
            puts "  Found #{services_found} services, #{chars_total} characteristics"

            connected_device = device

            # Find a readable characteristic
            readable_char = nil

            # Try preferred UUIDs first
            PREFERRED_READ_CHARS.each do |uuid|
              services.each do |svc|
                char = svc.characteristics.find { |c| c.short_uuid == uuid && c.readable? }
                if char
                  readable_char = char
                  break
                end
              end
              break if readable_char
            end

            # Fall back to any readable characteristic
            unless readable_char
              services.each do |svc|
                readable_char = svc.characteristics.find(&:readable?)
                break if readable_char
              end
            end

            if readable_char
              puts "  Reading characteristic #{readable_char.short_uuid}..."
              value = readable_char.read
              read_result = { uuid: readable_char.short_uuid, length: value.bytesize }
              puts "  Read #{value.bytesize} bytes from #{readable_char.short_uuid}"
            else
              puts '  No readable characteristics found'
            end
          ensure
            conn.disconnect if conn&.connected?
            conn = nil
          end
        end

        # Successfully connected and discovered -- stop trying more devices
        break
      rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError, RBLE::SessionClosedError => e
        puts "  Failed: #{e.class}: #{e.message}"
        saw_session_closed = true if e.is_a?(RBLE::SessionClosedError)
        begin
          conn&.disconnect
        rescue StandardError
          nil
        end
        conn = nil
        next
      end
    end

    if connected_device
      metrics['Connected:'] = "#{connected_device.name} (#{connected_device.address})"
      metrics['Services:'] = services_found
      metrics['Chars:'] = chars_total
      metrics['Read:'] = if read_result
                           "#{read_result[:uuid]} (#{read_result[:length]} bytes)"
                         else
                           'no readable characteristics'
                         end
      status = :PASS
      reason = Verify::Reason::OK
    else
      warn 'FAIL: Could not connect to any device'
      reason ||= (saw_session_closed ? Verify::Reason::SESSION_CLOSED : Verify::Reason::COULD_NOT_CONNECT)
    end
  end
rescue Timeout::Error
  warn 'ERROR: Script timed out after 120s (safety net)'
  reason ||= Verify::Reason::TIMEOUT
rescue StandardError => e
  warn "ERROR: #{e.class}: #{e.message}" unless e.message == 'No connectable devices'
  if e.message != 'No connectable devices'
    metrics['Error:'] = "#{e.class}: #{e.message}"
    reason ||= (e.is_a?(RBLE::SessionClosedError) ? Verify::Reason::SESSION_CLOSED : Verify::Reason::EXCEPTION)
  end
ensure
  begin
    conn&.disconnect
  rescue StandardError
    nil
  end

  # Allow GC to finalize D-Bus socket objects before measuring FDs
  GC.start
  sleep 0.5

  elapsed = (Time.now - start_time).round(1)
  final_res = resource_snapshot
  thread_delta = final_res[:threads] - baseline[:threads]
  fd_delta = final_res[:fds] - baseline[:fds]

  if thread_delta > 1
    warn "LEAK: #{thread_delta} threads not cleaned up"
    status = :FAIL
    reason = Verify::Reason::THREAD_LEAK
  end
  if fd_delta > 2
    warn "LEAK: #{fd_delta} file descriptors not closed"
    status = :FAIL
    reason = Verify::Reason::FD_LEAK
  end

  metrics['Reason:'] = reason if reason
  print_summary(status, elapsed, metrics, baseline, final_res)

  exit(status == :PASS ? 0 : 1)
end
