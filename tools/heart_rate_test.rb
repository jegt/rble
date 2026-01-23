#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for Heart Rate subscription with Polar H10
# Usage: ruby tools/heart_rate_test.rb [device_address]
#
# Standard BLE Heart Rate Service:
#   Service UUID: 180D
#   Heart Rate Measurement characteristic UUID: 2A37 (notify)

require_relative '../lib/rble'

HEART_RATE_SERVICE_UUID = '180d'
HEART_RATE_MEASUREMENT_UUID = '2a37'

def parse_heart_rate(data)
  # Heart Rate Measurement format (BLE spec):
  # Byte 0: Flags
  #   Bit 0: 0 = HR is 1 byte, 1 = HR is 2 bytes (UINT16)
  #   Bit 1-2: Sensor contact status
  #   Bit 3: Energy expended present
  #   Bit 4: RR-Interval present
  # Byte 1+: Heart rate value (1 or 2 bytes depending on flag)

  bytes = data.bytes
  flags = bytes[0]
  hr_16bit = (flags & 0x01) == 1

  if hr_16bit
    hr = bytes[1] | (bytes[2] << 8)
  else
    hr = bytes[1]
  end

  hr
end

# Get device address from argument or scan for Polar
address = ARGV[0]

if address
  # Address provided - still need to find device first (required for CoreBluetooth)
  puts "Scanning for device #{address}..."
  device = RBLE.find_device(address, timeout: 15)

  unless device
    puts "Device not found. Make sure it's powered on and advertising."
    exit 1
  end

  puts "Found: #{device.name || '(unnamed)'}"
else
  puts "Scanning for Polar H10..."
  puts "(Will auto-select first Polar device found)"
  puts

  found_device = nil
  RBLE.scan(timeout: 15) do |device|
    name = device.name || ''
    puts "  #{device.address} - #{name} (RSSI: #{device.rssi})"

    if name.downcase.include?('polar')
      found_device = device
      break
    end
  end

  if found_device
    address = found_device.address
    puts
    puts "Found Polar device: #{found_device.name} (#{address})"
  else
    puts
    puts "No Polar device found. Enter address manually:"
    print "> "
    address = gets&.chomp
    exit 1 if address.nil? || address.empty?

    # Still need to find it
    puts "Scanning for #{address}..."
    device = RBLE.find_device(address, timeout: 15)
    unless device
      puts "Device not found."
      exit 1
    end
  end
end

puts
puts "=" * 60
puts "Heart Rate Monitor Test"
puts "=" * 60
puts
puts "Connecting to #{address}..."

begin
  conn = RBLE.connect(address, timeout: 30)
  puts "Connected! State: #{conn.state}"
  puts

  # Register disconnect callback
  conn.on_disconnect do |reason|
    puts
    puts "[DISCONNECT] Reason: #{reason}"
    puts
  end

  # Discover services
  puts "Discovering services..."
  services = conn.discover_services
  puts "Found #{services.length} services"
  puts

  # Find Heart Rate Service
  hr_service = services.find { |s| s.short_uuid.downcase == HEART_RATE_SERVICE_UUID }

  unless hr_service
    puts "Heart Rate Service (180D) not found!"
    puts "Available services:"
    services.each { |s| puts "  #{s.short_uuid}" }
    conn.disconnect
    exit 1
  end

  puts "Found Heart Rate Service (180D)"

  # Find Heart Rate Measurement characteristic
  hr_char = hr_service.characteristics.find { |c| c.short_uuid.downcase == HEART_RATE_MEASUREMENT_UUID }

  unless hr_char
    puts "Heart Rate Measurement characteristic (2A37) not found!"
    puts "Available characteristics:"
    hr_service.characteristics.each { |c| puts "  #{c.short_uuid} [#{c.flags.join(', ')}]" }
    conn.disconnect
    exit 1
  end

  puts "Found Heart Rate Measurement characteristic (2A37)"
  puts "Flags: #{hr_char.flags.join(', ')}"
  puts

  unless hr_char.subscribable?
    puts "ERROR: Characteristic is not subscribable!"
    conn.disconnect
    exit 1
  end

  # Subscribe to heart rate notifications
  puts "Subscribing to heart rate notifications..."
  puts "(Press Ctrl+C to stop)"
  puts
  puts "-" * 40

  sample_count = 0
  start_time = Time.now

  hr_char.subscribe do |data|
    sample_count += 1
    hr = parse_heart_rate(data)
    elapsed = (Time.now - start_time).round(1)

    # Simple ASCII heart rate visualization
    bar_length = [hr - 40, 0].max / 2
    bar = '#' * [bar_length, 50].min

    puts "#{elapsed}s | HR: #{hr.to_s.rjust(3)} bpm | #{bar}"
  end

  puts "Subscribed! Waiting for heart rate data..."
  puts "(Make sure the sensor has skin contact)"
  puts

  # Wait for user interrupt
  loop do
    sleep 1
    # Process events (important for macOS)
    Thread.pass
  end

rescue RBLE::ConnectionError => e
  puts "Connection failed: #{e.message}"
  exit 1
rescue RBLE::NotSupportedError => e
  puts "Operation not supported: #{e.message}"
  conn&.disconnect
  exit 1
rescue Interrupt
  puts
  puts "-" * 40
  puts
  puts "Stopping..."

  if conn&.connected?
    puts "Unsubscribing..."
    hr_char&.unsubscribe rescue nil

    puts "Disconnecting..."
    conn.disconnect
  end

  elapsed = (Time.now - start_time).round(1) if start_time
  puts
  puts "Session summary:"
  puts "  Duration: #{elapsed}s"
  puts "  Samples received: #{sample_count}"
  puts
  puts "Done."
end
