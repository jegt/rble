# frozen_string_literal: true

require 'rble/gatt/uuid_database'
require_relative 'value_parser'
require_relative 'hex_dump'

module RBLE
  module CLI
    # Shared helpers for GATT commands (read, write, monitor).
    #
    # Provides UUID normalization, characteristic discovery, connection
    # management, and value formatting used by all three commands.
    #
    # @example Including in a command class
    #   class Read
    #     include CharacteristicHelpers
    #
    #     def execute
    #       connection = connect_and_discover(@address, timeout: @timeout)
    #       char = find_characteristic(connection, "2a37")
    #       puts format_value(char.uuid, char.read)
    #     end
    #   end
    module CharacteristicHelpers
      # Bluetooth Base UUID suffix for short UUID expansion
      BLUETOOTH_BASE_SUFFIX = "-0000-1000-8000-00805f9b34fb"

      # Normalize user UUID input to full 128-bit lowercase UUID.
      #
      # Handles:
      # - Short 4-char UUIDs: "2a37" -> "00002a37-0000-1000-8000-00805f9b34fb"
      # - "0x" prefix: "0x2a37" -> expanded
      # - Case-insensitive: "2A37" -> lowercase
      # - Full 128-bit UUIDs: passed through lowercase
      #
      # @param input [String] UUID from user input
      # @return [String] Full 128-bit UUID in lowercase
      def normalize_char_uuid(input)
        stripped = input.sub(/\A0x/i, '').downcase
        if stripped.length == 4
          "0000#{stripped}#{BLUETOOTH_BASE_SUFFIX}"
        else
          stripped
        end
      end

      # Find an ActiveCharacteristic across all services on a connection.
      #
      # Searches all services and their characteristics for a match by UUID.
      # First match wins (per design decision -- no disambiguation).
      #
      # @param connection [Connection] Connected device with discovered services
      # @param uuid_input [String] UUID from user (short, full, or with 0x prefix)
      # @return [ActiveCharacteristic] The found characteristic
      # @raise [RBLE::Error] if characteristic not found
      def find_characteristic(connection, uuid_input)
        normalized = normalize_char_uuid(uuid_input)
        short_input = uuid_input.sub(/\A0x/i, '').downcase

        connection.services.each do |service|
          service.characteristics.each do |char|
            return char if char.uuid.downcase == normalized || char.short_uuid == short_input
          end
        end

        raise RBLE::Error,
              "Characteristic #{uuid_input} not found on device. " \
              "Run `rble show <address>` to see available characteristics."
      end

      # Connect to a device, discover services, and return the connection.
      #
      # Reuses Show's connect_with_retry pattern: one retry for
      # ConnectionTimeout/ConnectionFailed, no retry for DeviceNotFound.
      # Status messages are written to stderr.
      #
      # @param address [String] Device MAC address
      # @param timeout [Numeric] Connection timeout in seconds
      # @return [Connection] Connected device with services discovered
      # @raise [SystemExit] on unrecoverable connection errors
      def connect_and_discover(address, timeout:)
        connection = connect_with_retry(address, timeout: timeout)
        $stderr.puts "Discovering services..."
        connection.discover_services
        connection
      end

      # Format a characteristic value for display.
      #
      # Known UUIDs are parsed with smart parsers (e.g., "72 bpm").
      # Unknown UUIDs are displayed as hex+ASCII dump.
      #
      # @param uuid [String] Characteristic UUID
      # @param raw_bytes [String] Binary string of raw characteristic data
      # @return [String] Formatted value string
      def format_value(uuid, raw_bytes)
        if ValueParser.known?(uuid)
          ValueParser.parse(uuid, raw_bytes)
        else
          HexDump.format(raw_bytes)
        end
      end

      # Get human-readable name + UUID display for a characteristic.
      #
      # Standard UUIDs: "Heart Rate Measurement (2a37)"
      # Vendor UUIDs: "12345678-1234-1234-1234-123456789abd"
      #
      # @param uuid [String] Characteristic UUID (full 128-bit)
      # @return [String] Display name
      def resolve_char_name(uuid)
        name = RBLE::GATT::UUIDDatabase.resolve(uuid, type: :characteristic)
        short = RBLE::GATT::UUIDDatabase.extract_short_uuid(uuid)

        if name
          if RBLE::GATT::UUIDDatabase.standard_uuid?(uuid)
            "#{name} (#{short})"
          else
            "#{name} (#{uuid})"
          end
        else
          short == uuid.downcase ? uuid : short
        end
      end

      private

      # Connect with one retry on timeout/connection failure.
      # No retry for DeviceNotFoundError.
      #
      # @param address [String] Device MAC address
      # @param timeout [Numeric] Connection timeout in seconds
      # @return [Connection] Connected device
      # @raise [SystemExit] on unrecoverable errors
      def connect_with_retry(address, timeout:)
        $stderr.puts "Connecting to #{address}..."
        RBLE.connect(address, timeout: timeout)
      rescue RBLE::DeviceNotFoundError
        raise # No retry for device not found
      rescue RBLE::ConnectionTimeoutError, RBLE::ConnectionFailed
        $stderr.puts "Connection failed, retrying..."
        begin
          RBLE.connect(address, timeout: timeout)
        rescue RBLE::ConnectionTimeoutError, RBLE::ConnectionFailed => e
          $stderr.puts "Error: #{e.message}"
          exit 1
        end
      end
    end
  end
end
