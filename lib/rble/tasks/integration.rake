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
  # Scans for devices, then tries each device until finding one with
  # a readable characteristic. Prioritizes devices advertising Device
  # Information Service (0x180A) for reliability.
  #
  # @api private
  class IntegrationTest
    DEVICE_INFO_SERVICE = '180a'
    MANUFACTURER_NAME = '2a29'
    MODEL_NUMBER = '2a24'
    SCAN_TIMEOUT = 15
    CONNECTION_TIMEOUT = 10

    def initialize
      @success = false
      @connection = nil
      @results = []
      @devices = []
    end

    # Run the integration test
    def run
      scan_for_devices
      return if @devices.empty?

      try_devices_until_success
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

      scanner = Scanner.new(timeout: SCAN_TIMEOUT)
      scanner.start do |device|
        # Deduplicate by address
        unless @devices.any? { |d| d.address == device.address }
          @devices << device
        end
      end

      if @devices.empty?
        puts
        puts "No BLE devices found."
        puts "Suggestions:"
        puts "  - Ensure BLE devices are nearby and advertising"
        puts "  - Check that Bluetooth adapter is enabled (rake rble:check)"
        puts "  - Try increasing scan time or moving closer to devices"
        @results << "No devices found"
        return
      end

      puts "Found #{@devices.length} device(s)"
      @results << "Scanned and found #{@devices.length} device(s)"

      # Sort: prefer devices with Device Information Service
      @devices.sort_by! do |d|
        has_device_info = d.service_uuids.any? { |uuid| uuid.downcase.include?(DEVICE_INFO_SERVICE) }
        has_device_info ? 0 : 1
      end
    end

    def try_devices_until_success
      @devices.each_with_index do |device, index|
        device_name = device.name || 'unnamed'
        puts
        puts "Trying device #{index + 1}/#{@devices.length}: #{device_name} (#{device.address})"

        result = try_device(device)
        if result == :success
          @success = true
          return
        end
        # Continue to next device on :no_readable or :connection_failed
      end

      puts
      puts "Tried all #{@devices.length} device(s), none had readable characteristics"
      @results << "No device with readable characteristics found"
    end

    # Try a single device: connect, discover, read
    # Returns :success, :no_readable, or :connection_failed
    def try_device(device)
      # Connect
      puts "  Connecting..."
      begin
        @connection = RBLE.connect(device.address, timeout: CONNECTION_TIMEOUT)
        puts "  Connected!"
      rescue ConnectionTimeoutError
        puts "  Connection timed out, skipping..."
        return :connection_failed
      rescue ConnectionError => e
        puts "  Connection failed: #{e.message}, skipping..."
        return :connection_failed
      end

      # Discover services
      puts "  Discovering services..."
      services = @connection.discover_services
      char_count = services.sum { |s| s.characteristics.length }
      puts "  Found #{services.length} services, #{char_count} characteristics"

      # Find and read a characteristic
      char = find_readable_characteristic(services)
      unless char
        puts "  No readable characteristics, trying next device..."
        disconnect_quietly
        return :no_readable
      end

      # Read the characteristic
      puts "  Reading #{char_name(char)} (#{char.short_uuid})..."
      value = char.read
      display = format_value(value)
      puts "  Value: #{display.inspect}"

      # Record success
      device_name = device.name || 'unnamed'
      @results << "Connected to #{device_name}"
      @results << "Discovered #{services.length} services"
      truncated = display.length > 50 ? "#{display[0..47]}..." : display
      @results << "Read characteristic #{char.short_uuid}: #{truncated}"

      :success
    rescue StandardError => e
      puts "  Error: #{e.message}, trying next device..."
      disconnect_quietly
      :connection_failed
    end

    def find_readable_characteristic(services)
      # First try Device Information Service
      device_info = services.find { |s| s.short_uuid == DEVICE_INFO_SERVICE }

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
      services.each do |service|
        char = service.characteristics.find(&:readable?)
        return char if char
      end

      nil
    end

    def format_value(value)
      if value.bytes.all? { |b| (b >= 32 && b < 127) || b == 0 }
        # Remove null terminators and clean up
        value.force_encoding('UTF-8').gsub("\x00", '')
      else
        # Display as hex for binary data
        value.bytes.map { |b| format('%02x', b) }.join(' ')
      end
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

    def disconnect_quietly
      return unless @connection

      @connection.disconnect if @connection.connected?
    rescue StandardError
      # Ignore disconnect errors
    ensure
      @connection = nil
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
