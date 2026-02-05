# frozen_string_literal: true

require_relative 'characteristic_helpers'

module RBLE
  module CLI
    class Read
      include CharacteristicHelpers

      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
        @characteristic_uuid = options["characteristic"]
        @timeout = options["timeout"] || 10
      end

      def execute
        connection = connect_and_discover(@address, timeout: @timeout)

        begin
          char = find_characteristic(connection, @characteristic_uuid)

          unless char.readable?
            $stderr.puts "Error: Characteristic #{@characteristic_uuid} does not support read."
            $stderr.puts "Supported: #{char.flags.join(', ')}"
            exit 1
          end

          name = resolve_char_name(char.uuid)
          $stderr.puts "Reading #{name}..."
          raw_value = char.read
          formatted = format_value(char.uuid, raw_value)

          @formatter.read_value(
            address: @address,
            uuid: char.uuid,
            name: RBLE::GATT::UUIDDatabase.resolve(char.uuid, type: :characteristic),
            raw: raw_value,
            formatted: formatted
          )
        ensure
          connection.disconnect if connection.connected?
        end
      rescue RBLE::DeviceNotFoundError => e
        $stderr.puts "Error: #{e.message}"
        $stderr.puts "Run `rble scan` first to discover nearby devices."
        exit 1
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end
    end
  end
end
