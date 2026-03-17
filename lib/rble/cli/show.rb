# frozen_string_literal: true

require 'rble/gatt/uuid_database'
require_relative 'characteristic_helpers'

module RBLE
  module CLI
    class Show
      include CharacteristicHelpers

      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
        @timeout = options["timeout"] || 10
      end

      def execute
        backend = RBLE::Backend.for_platform
        connection = connect_with_retry(@address, timeout: @timeout)

        begin
          $stderr.puts "Discovering services..."
          connection.discover_services
          services = connection.services

          $stderr.puts "Found #{services.size} service#{'s' unless services.size == 1}"

          tree_data = build_tree_data(@address, connection, services, backend)
          @formatter.show_tree(tree_data)
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

      private

      def build_tree_data(address, connection, services, backend)
        device_name = begin
          backend.device_name(connection.device_path)
        rescue StandardError
          nil
        end

        service_data = services.map do |service|
          resolved_service = RBLE::GATT::UUIDDatabase.resolve(service.uuid, type: :service)

          chars = service.characteristics.map do |char|
            resolved_char = RBLE::GATT::UUIDDatabase.resolve(char.uuid, type: :characteristic)

            descriptors = extract_descriptors(char)

            {
              uuid: char.uuid,
              resolved_name: resolved_char,
              properties: char.flags,
              handle: extract_handle(char.path),
              descriptors: descriptors
            }
          end

          {
            uuid: service.uuid,
            resolved_name: resolved_service,
            primary: service.primary,
            characteristics: chars
          }
        end

        total_chars = service_data.sum { |s| s[:characteristics].size }

        {
          address: address,
          name: device_name,
          services: service_data,
          total_characteristics: total_chars
        }
      end

      def extract_descriptors(char)
        return [] unless char.respond_to?(:descriptors) && char.descriptors

        char.descriptors.map do |desc|
          resolved_desc = RBLE::GATT::UUIDDatabase.resolve(desc[:uuid], type: :descriptor)
          {
            uuid: desc[:uuid],
            resolved_name: resolved_desc,
            handle: extract_handle(desc[:path])
          }
        end
      end

      def extract_handle(path)
        return nil unless path

        if path =~ /([0-9a-fA-F]{4})\z/
          "0x#{Regexp.last_match(1).upcase}"
        end
      end
    end
  end
end
