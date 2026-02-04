#!/usr/bin/env ruby
# frozen_string_literal: true

# Passive scanning example for RuuviTag sensors
#
# RuuviTags broadcast non-connectable advertisements containing sensor data
# (temperature, humidity, pressure, etc.) in their manufacturer-specific data.
# Passive scanning receives these advertisements without sending scan requests,
# which is more power-efficient and works with non-connectable advertisements.
#
# Usage:
#   ruby examples/passive_scan.rb
#
# Requires a RuuviTag sensor in range.

require "rble"

RUUVI_COMPANY_ID = 0x0499

puts "Scanning for RuuviTag advertisements (30s)..."
puts

RBLE.scan(active: false, timeout: 30) do |device|
  payload = device.manufacturer_data_bytes(RUUVI_COMPANY_ID)
  next unless payload

  format = payload.getbyte(0)
  next unless format == 5 # RAWv2

  temp_raw = payload.unpack1("@1s>")   # signed 16-bit big-endian at offset 1
  temperature = temp_raw * 0.005

  humidity_raw = payload.unpack1("@3S>") # unsigned 16-bit big-endian at offset 3
  humidity = humidity_raw * 0.0025

  puts "#{device.address}: #{temperature.round(2)} C, #{humidity.round(2)}%"
end
