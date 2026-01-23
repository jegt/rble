# frozen_string_literal: true

namespace :test do
  desc 'Run integration test with real BLE hardware'
  task :integration do
    require_relative '../../rble'

    test = RBLE::IntegrationTest.new
    test.run
    exit(test.success? ? 0 : 1)
  end
end

module RBLE
  # Dynamic integration test for BLE hardware
  #
  # Scans for devices, connects to one with readable characteristics,
  # discovers services, and reads a characteristic value.
  #
  # Prefers devices with Device Information Service (0x180A) for reliability,
  # falls back to any connectable device if no ideal device found.
  #
  # @api private
  class IntegrationTest
    DEVICE_INFO_SERVICE = '180a'
    MANUFACTURER_NAME = '2a29'
    MODEL_NUMBER = '2a24'
    SCAN_TIMEOUT = 15
    CONNECTION_TIMEOUT = 15

    def initialize
      @success = false
      @connection = nil
      @results = []
      @device = nil
      @services = nil
    end

    # Run the integration test
    def run
      scan_for_devices
      return unless @device

      connect_to_device
      return unless @connection

      discover_services
      read_characteristic

      @success = true
    rescue StandardError => e
      puts "Error: #{e.message}"
      @results << "Error: #{e.class} - #{e.message}"
    ensure
      cleanup
      print_summary
    end

    # Check if test passed
    # @return [Boolean]
    def success?
      @success
    end

    private

    def scan_for_devices
      puts "Scanning for BLE devices (#{SCAN_TIMEOUT}s timeout)..."
      devices = []
      preferred = nil

      scanner = Scanner.new(timeout: SCAN_TIMEOUT)
      scanner.start do |device|
        # Deduplicate by address
        unless devices.any? { |d| d.address == device.address }
          devices << device
        end

        # Check if this device advertises Device Information Service
        if device.service_uuids.any? { |uuid| uuid.downcase.include?(DEVICE_INFO_SERVICE) }
          preferred = device
          scanner.stop
        end
      end

      if devices.empty?
        puts
        puts "No BLE devices found."
        puts "Suggestions:"
        puts "  - Ensure BLE devices are nearby and advertising"
        puts "  - Check that Bluetooth adapter is enabled (rake rble:check)"
        puts "  - Try increasing scan time or moving closer to devices"
        @results << "No devices found"
        return
      end

      puts "Found #{devices.length} device(s)"

      @device = preferred || devices.first
      device_name = @device.name || 'unnamed'

      if preferred
        puts "Selected: #{device_name} (#{@device.address}) - has Device Information Service"
      else
        puts "Selected: #{device_name} (#{@device.address}) - fallback (no Device Info Service found)"
      end
      @results << "Scanned and found #{devices.length} device(s)"
    end

    def connect_to_device
      puts
      puts "Connecting..."
      @connection = RBLE.connect(@device.address, timeout: CONNECTION_TIMEOUT)
      puts "Connected!"
      @results << "Connected to device"
    rescue ConnectionTimeoutError
      puts "Connection timed out. Device may have moved out of range."
      @results << "Connection timeout"
    rescue ConnectionError => e
      puts "Connection failed: #{e.message}"
      @results << "Connection failed"
    end

    def discover_services
      puts
      puts "Discovering services..."
      @services = @connection.discover_services
      char_count = @services.sum { |s| s.characteristics.length }
      puts "Found #{@services.length} services, #{char_count} characteristics"
      @results << "Discovered #{@services.length} services"
    end

    def read_characteristic
      # Find a readable characteristic, preferring Device Info characteristics
      char = find_readable_characteristic

      unless char
        puts
        puts "No readable characteristics found"
        @results << "No readable characteristics (still passing)"
        return
      end

      puts
      puts "Reading #{char_name(char)} (#{char.short_uuid})..."
      value = char.read

      # Try to display as string if it looks like printable text
      display = if value.bytes.all? { |b| (b >= 32 && b < 127) || b == 0 }
        # Remove null terminators and clean up
        value.force_encoding('UTF-8').gsub("\x00", '')
      else
        # Display as hex for binary data
        value.bytes.map { |b| format('%02x', b) }.join(' ')
      end
      puts "Value: #{display.inspect}"

      # Truncate for results if too long
      truncated = display.length > 50 ? "#{display[0..47]}..." : display
      @results << "Read characteristic #{char.short_uuid}: #{truncated}"
    end

    def find_readable_characteristic
      # First try Device Information Service
      device_info = @services.find { |s| s.short_uuid == DEVICE_INFO_SERVICE }

      if device_info
        # Prefer Manufacturer Name, then Model Number
        [MANUFACTURER_NAME, MODEL_NUMBER].each do |uuid|
          char = device_info.characteristics.find { |c| c.short_uuid == uuid && c.readable? }
          return char if char
        end

        # Try any readable char in Device Info service
        char = device_info.characteristics.find(&:readable?)
        return char if char
      end

      # Fallback: any readable characteristic from any service
      @services.each do |service|
        char = service.characteristics.find(&:readable?)
        return char if char
      end

      nil
    end

    def char_name(char)
      case char.short_uuid
      when MANUFACTURER_NAME then 'Manufacturer Name'
      when MODEL_NUMBER then 'Model Number'
      when '2a25' then 'Serial Number'
      when '2a27' then 'Hardware Revision'
      when '2a26' then 'Firmware Revision'
      when '2a28' then 'Software Revision'
      else 'Characteristic'
      end
    end

    def cleanup
      return unless @connection

      begin
        if @connection.connected?
          puts
          puts "Disconnecting..."
          @connection.disconnect
          puts "Disconnected"
        end
      rescue StandardError => e
        # Suppress disconnect errors during cleanup
        puts "Disconnect warning: #{e.message}"
      end
    end

    def print_summary
      puts
      puts '=' * 40
      if @success
        puts 'Integration test PASSED'
      else
        puts 'Integration test FAILED'
      end
      @results.each { |r| puts "  - #{r}" }
    end
  end
end
