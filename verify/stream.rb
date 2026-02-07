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
require_relative 'reason_codes'
require 'timeout'

SCRIPT_NAME = 'verify/stream'
SCAN_TIMEOUT = 15
CONNECT_TIMEOUT = 15
STREAM_DURATION = 300
MAX_GAP_SECONDS = 30
MAX_RETRIES = 3
MAX_CANDIDATES_TO_TRY = 10
MIN_RSSI = -92
NO_DATA_FALLBACK_SECONDS = 45
TARGET_DEVICE_PATTERNS = [/ruuvi/i].freeze
PREFERRED_DEVICE_PATTERNS = [/ruuvi/i, /shelly/i, /vivosmart/i].freeze
PREFERRED_STREAM_CHARS = %w[
  6e400003-b5a3-f393-e0a9-e50e24dcca9e
  da2e7828-fbce-4e01-ae9e-261174997c48
].freeze

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

  prioritized = candidates.sort_by do |d|
    name = d.name.to_s
    preferred_idx = PREFERRED_DEVICE_PATTERNS.find_index { |rx| name.match?(rx) } || 999
    [preferred_idx, -(d.rssi || -127)]
  end

  targeted = prioritized.select { |d| TARGET_DEVICE_PATTERNS.any? { |rx| d.name.to_s.match?(rx) } }
  if targeted.empty?
    puts "  No target stream devices found (patterns: #{TARGET_DEVICE_PATTERNS.map(&:source).join(', ')})"
    []
  else
    targeted
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

def normalized_uuid(value)
  value.to_s.downcase.delete('-')
end

def preferred_char_index(char)
  uuid = normalized_uuid(char.short_uuid)
  PREFERRED_STREAM_CHARS.each_with_index do |preferred, idx|
    return idx if uuid == normalized_uuid(preferred)
  end
  nil
end

def ordered_subscribable_chars(services)
  chars = services.flat_map(&:characteristics).select(&:subscribable?)
  unique = {}
  chars.each { |char| unique[normalized_uuid(char.short_uuid)] ||= char }

  unique.values.sort_by do |char|
    idx = preferred_char_index(char)
    [idx.nil? ? 999 : idx, char.short_uuid.to_s]
  end
end

# --- Main ---

start_time = Time.now
baseline = resource_snapshot
status = :FAIL
reason = nil
metrics = {}
conn = nil
subscribed_char = nil
found_subscribable = false
saw_session_closed = false

begin
  Timeout.timeout((STREAM_DURATION * 2) + 60) do
    candidates = find_connectable_devices

    if candidates.empty?
      warn 'SKIP: No connectable devices found'
      status = :SKIP
      reason = Verify::Reason::SKIP_NO_CONNECTABLE_DEVICES
      metrics['Scanned:'] = '0 candidates'
      raise 'No connectable devices'
    end

    metrics['Scanned:'] = "#{candidates.size} candidates"

    candidates.first(MAX_CANDIDATES_TO_TRY).each do |device|
      puts "\nTrying #{device.name} (#{device.address})..."
      begin
        with_retries(device.name) do
          conn = RBLE.connect(device.address, timeout: CONNECT_TIMEOUT)

          begin
            puts '  Connected. Discovering services...'
            services = conn.discover_services
            puts "  Found #{services.size} services"

            subscribable_chars = ordered_subscribable_chars(services)

            if subscribable_chars.empty?
              puts '  No subscribable characteristics'
              conn.disconnect
              conn = nil
              next
            end

            found_subscribable = true
            metrics['Sub chars:'] = subscribable_chars.size

            stream_outcome = nil
            subscribable_chars.each_with_index do |sub_char, idx|
              preferred_idx = preferred_char_index(sub_char)
              pref_label = preferred_idx ? "preferred ##{preferred_idx + 1}" : 'fallback'
              puts "  Trying #{sub_char.short_uuid} (#{pref_label}) [#{idx + 1}/#{subscribable_chars.size}]"

              subscribed_char = sub_char
              data_points = 0
              last_data_time = Time.now
              max_gap = 0.0
              stream_start = Time.now
              connection_lost = false
              switched_for_no_data = false

              sub_char.subscribe do |_value|
                now = Time.now
                gap = now - last_data_time
                max_gap = gap if gap > max_gap
                last_data_time = now
                data_points += 1
              end

              puts '  Streaming...'
              last_progress = Time.now
              stream_elapsed = 0.0

              while stream_elapsed < STREAM_DURATION
                sleep 0.5
                stream_elapsed = Time.now - stream_start

                if Time.now - last_progress >= 30
                  puts "  [#{stream_elapsed.round(0)}s] #{data_points} data points, max gap: #{max_gap.round(1)}s"
                  last_progress = Time.now
                end

                unless conn.connected?
                  puts "  Connection lost after #{stream_elapsed.round(0)}s"
                  connection_lost = true
                  break
                end

                unless data_points.zero? && stream_elapsed >= NO_DATA_FALLBACK_SECONDS && idx < (subscribable_chars.size - 1)
                  next
                end

                puts "  No data for #{NO_DATA_FALLBACK_SECONDS}s, switching characteristic"
                switched_for_no_data = true
                break
              end

              begin
                sub_char.unsubscribe
              rescue StandardError
                nil
              end
              subscribed_char = nil

              next if switched_for_no_data

              actual_duration = (Time.now - stream_start).round(1)
              still_connected = conn.connected?

              metrics['Connected:'] = "#{device.name} (#{device.address})"
              metrics['Char:'] = sub_char.short_uuid
              metrics['Points:'] = data_points
              metrics['Max gap:'] = "#{max_gap.round(1)}s"
              metrics['Drops:'] = connection_lost ? 1 : 0
              metrics['Duration:'] = "#{actual_duration}s"
              metrics['Chars tried:'] = idx + 1

              passed_points = data_points >= 10
              passed_gap = max_gap < MAX_GAP_SECONDS
              passed_connected = still_connected && !connection_lost

              unless passed_points
                warn "FAIL: Only #{data_points} data points (need >= 10)"
                reason ||= Verify::Reason::NO_DATA_POINTS
              end
              unless passed_gap
                warn "FAIL: Max gap #{max_gap.round(1)}s exceeds #{MAX_GAP_SECONDS}s"
                reason ||= Verify::Reason::STREAM_GAP_EXCEEDED
              end
              unless passed_connected
                warn 'FAIL: Connection dropped during stream'
                reason ||= Verify::Reason::CONNECTION_DROPPED
              end

              if passed_points && passed_gap && passed_connected
                status = :PASS
                reason = Verify::Reason::OK
              end

              stream_outcome = :done
              break
            end

            if stream_outcome.nil?
              chosen_char = subscribable_chars.last
              metrics['Connected:'] = "#{device.name} (#{device.address})"
              metrics['Char:'] = chosen_char.short_uuid
              metrics['Points:'] = 0
              metrics['Max gap:'] = '0.0s'
              metrics['Drops:'] = 0
              metrics['Duration:'] = "#{NO_DATA_FALLBACK_SECONDS}s"
              metrics['Chars tried:'] = subscribable_chars.size
              warn 'FAIL: Only 0 data points (need >= 10)'
              reason ||= Verify::Reason::NO_DATA_POINTS
            end

            if conn.connected?
              begin
                conn.disconnect
              rescue StandardError
                nil
              end
            end
            conn = nil

            break
          ensure
            begin
              subscribed_char&.unsubscribe
            rescue StandardError
              nil
            end
            subscribed_char = nil
            if conn&.connected?
              begin
                conn.disconnect
              rescue StandardError
                nil
              end
            end
            conn = nil
          end
        end

        break if status == :PASS || found_subscribable
      rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError, RBLE::SessionClosedError => e
        puts "  Failed: #{e.class}: #{e.message}"
        saw_session_closed = true if e.is_a?(RBLE::SessionClosedError)
        reason ||= Verify::Reason::SESSION_CLOSED if e.is_a?(RBLE::SessionClosedError)
        next
      end
    end

    # Determine final status if not already set
    if status != :PASS && !found_subscribable
      status = :SKIP
      warn 'SKIP: No subscribable characteristics found on any device'
      metrics['Reason:'] = 'no subscribable characteristics'
      reason = Verify::Reason::SKIP_NO_SUBSCRIBABLE_CHARACTERISTICS
    elsif status != :PASS && reason.nil?
      reason = saw_session_closed ? Verify::Reason::SESSION_CLOSED : Verify::Reason::EXCEPTION
    end
  end
rescue Timeout::Error
  warn "ERROR: Script timed out after #{(STREAM_DURATION * 2) + 60}s (safety net)"
  reason ||= Verify::Reason::TIMEOUT
rescue StandardError => e
  unless e.message == 'No connectable devices'
    warn "ERROR: #{e.class}: #{e.message}"
    metrics['Error:'] = "#{e.class}: #{e.message}"
    reason ||= (e.is_a?(RBLE::SessionClosedError) ? Verify::Reason::SESSION_CLOSED : Verify::Reason::EXCEPTION)
  end
ensure
  begin
    subscribed_char&.unsubscribe
  rescue StandardError
    nil
  end
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

  exit(if status == :SKIP
         0
       else
         (status == :PASS ? 0 : 1)
       end)
end
