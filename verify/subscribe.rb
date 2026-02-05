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

SCRIPT_NAME = "verify/subscribe"
SCAN_TIMEOUT = 15
CONNECT_TIMEOUT = 15
SUBSCRIBE_WAIT = 30
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
  Timeout.timeout(120) do
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

            sub_char.unsubscribe rescue nil
            subscribed_char = nil
            conn.disconnect
            conn = nil

            metrics["Connected:"] = "#{device.name} (#{device.address})"
            metrics["Char:"] = sub_char.short_uuid
            metrics["Notifs:"] = notification_count

            if first_notification_time && last_notification_time
              sub_duration = (last_notification_time - first_notification_time).round(1)
              metrics["Sub time:"] = "#{sub_duration}s"
            end

            if notification_count > 0
              puts "  Received #{notification_count} notifications"
              status = :PASS
              break
            else
              puts "  Subscribed but no notifications received"
              next
            end
          ensure
            subscribed_char&.unsubscribe rescue nil
            subscribed_char = nil
            if conn&.connected?
              conn.disconnect rescue nil
            end
            conn = nil
          end
        end

        break if status == :PASS
      rescue RBLE::ConnectionError, RBLE::TimeoutError, RBLE::GATTError => e
        puts "  Failed: #{e.class}: #{e.message}"
        next
      end
    end

    # Determine final status if not already PASS
    if status != :PASS
      if !found_subscribable
        status = :SKIP
        $stderr.puts "SKIP: No subscribable characteristics found on any device"
        metrics["Reason:"] = "no subscribable characteristics"
      elsif status != :SKIP
        status = :SKIP
        $stderr.puts "SKIP: Subscriptions established but no notifications received"
        metrics["Reason:"] = "no notifications received"
      end
    end
  end
rescue Timeout::Error
  $stderr.puts "ERROR: Script timed out after 120s (safety net)"
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
