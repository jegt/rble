#!/usr/bin/env ruby
# frozen_string_literal: true

# Test script for disconnect detection
# Usage: ruby tools/disconnect_test.rb [device_address]

require_relative '../lib/rble'

# Get device address from argument or prompt
address = ARGV[0]
unless address
  puts "Scanning for BLE devices..."
  puts "(Press Ctrl+C after finding your test device)"
  puts

  RBLE.scan(timeout: 10) do |device|
    puts "  #{device.address} - #{device.name || '(no name)'} (RSSI: #{device.rssi})"
  end

  puts
  print "Enter device address to test: "
  address = gets&.chomp
  exit 1 if address.nil? || address.empty?
end

puts
puts "=" * 60
puts "Disconnect Detection Test"
puts "=" * 60
puts
puts "Connecting to #{address}..."

begin
  conn = RBLE.connect(address, timeout: 30)
  puts "Connected! State: #{conn.state}"
  puts

  # Register callbacks
  conn.on_state_change do |old_state, new_state|
    puts "[STATE CHANGE] #{old_state} -> #{new_state}"
  end

  conn.on_disconnect do |reason|
    puts
    puts "=" * 60
    puts "[DISCONNECT] Reason: #{reason}"
    puts "=" * 60
    puts
    puts "SUCCESS: Disconnect detected!"
    puts
  end

  puts "Callbacks registered."
  puts
  puts "Now do ONE of the following to test disconnect:"
  puts "  1. Power off the BLE device"
  puts "  2. Move the device out of Bluetooth range"
  puts "  3. Press Enter to disconnect gracefully"
  puts
  puts "Waiting for disconnect event..."
  puts "(Press Enter to disconnect manually, Ctrl+C to abort)"
  puts

  # Wait for user input or disconnect
  input = gets

  if conn.connected?
    puts "Disconnecting gracefully..."
    conn.disconnect
    puts "Disconnected. Final state: #{conn.state}"
  else
    puts "Already disconnected. Final state: #{conn.state}"
  end

  # Test that operations fail after disconnect
  puts
  puts "Testing operations after disconnect..."
  begin
    conn.discover_services
    puts "ERROR: discover_services should have raised NotConnectedError!"
  rescue RBLE::NotConnectedError => e
    puts "PASS: discover_services raised NotConnectedError: #{e.message}"
  end

rescue RBLE::ConnectionError => e
  puts "Connection failed: #{e.message}"
  exit 1
rescue Interrupt
  puts
  puts "Aborted by user."
  conn&.disconnect
  exit 0
end

puts
puts "Test complete."
