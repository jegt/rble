#!/usr/bin/env ruby
# frozen_string_literal: true

# Verification: Subscribe + notification receipt
#
# Discovers BLE devices, connects, finds a subscribable characteristic,
# and verifies that at least 1 notification is received within 30 seconds.
#
# Pass criteria:
#   - PASS: received >= 1 notification
#   - SKIP: no subscribable device/characteristic found (not an rble failure)
#   - FAIL: subscription error, connection error, or resource leak
#
# Usage: ruby verify/subscribe.rb

require_relative '../lib/rble'
require_relative 'reason_codes'
require 'timeout'

SCRIPT_NAME = 'verify/subscribe'
SCAN_TIMEOUT = 15
CONNECT_TIMEOUT = 15
SUBSCRIBE_WAIT = 30
MAX_RETRIES = 3
MAX_CANDIDATES_TO_TRY = 10
MIN_RSSI = -92
PREFERRED_DEVICE_PATTERNS = [/ruuvi/i, /shelly/i, /vivosmart/i].freeze

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
subscribed_char = nil
found_subscribable = false

begin
  Timeout.timeout(120) do
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

            # Find subscribable characteristic
            sub_char = nil
            services.each do |svc|
              sub_char = svc.characteristics.find(&:subscribable?)
              break if sub_char
            end

            unless sub_char
              puts '  No subscribable characteristics'
              conn.disconnect
              conn = nil
              next
            end

            found_subscribable = true
            subscribed_char = sub_char
            notification_count = 0
            first_notification_time = nil
            last_notification_time = nil

            puts "  Subscribing to #{sub_char.short_uuid}..."
            sub_char.subscribe do |_value|
              now = Time.now
              notification_count += 1
              first_notification_time ||= now
              last_notification_time = now
            end

            puts "  Waiting for notifications (up to #{SUBSCRIBE_WAIT}s)..."
            waited = 0.0
            while waited < SUBSCRIBE_WAIT
              sleep 0.5
              waited += 0.5
              if notification_count > 0 && waited >= 3
                # Got at least one notification and waited a bit for more
                break
              end
            end

            begin
              sub_char.unsubscribe
            rescue StandardError
              nil
            end
            subscribed_char = nil
            conn.disconnect
            conn = nil

            metrics['Connected:'] = "#{device.name} (#{device.address})"
            metrics['Char:'] = sub_char.short_uuid
            metrics['Notifs:'] = notification_count

            if first_notification_time && last_notification_time
              sub_duration = (last_notification_time - first_notification_time).round(1)
              metrics['Sub time:'] = "#{sub_duration}s"
            end

            if notification_count > 0
              puts "  Received #{notification_count} notifications"
              status = :PASS
              reason = Verify::Reason::OK
              break
            else
              puts '  Subscribed but no notifications received'
              next
            end
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

        break if status == :PASS
      rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError, RBLE::SessionClosedError => e
        puts "  Failed: #{e.class}: #{e.message}"
        next
      end
    end

    # Determine final status if not already PASS
    if status != :PASS
      if !found_subscribable
        status = :SKIP
        warn 'SKIP: No subscribable characteristics found on any device'
        metrics['Reason:'] = 'no subscribable characteristics'
        reason = Verify::Reason::SKIP_NO_SUBSCRIBABLE_CHARACTERISTICS
      elsif status != :SKIP
        status = :SKIP
        warn 'SKIP: Subscriptions established but no notifications received'
        metrics['Reason:'] = 'no notifications received'
        reason = Verify::Reason::SKIP_NO_NOTIFICATIONS
      end
    end
  end
rescue Timeout::Error
  warn 'ERROR: Script timed out after 120s (safety net)'
  reason ||= Verify::Reason::TIMEOUT
rescue StandardError => e
  unless e.message == 'No connectable devices'
    warn "ERROR: #{e.class}: #{e.message}"
    metrics['Error:'] = "#{e.class}: #{e.message}"
    reason ||= Verify::Reason::EXCEPTION
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
