# frozen_string_literal: true

module RBLE
  module CLI
    class Unpair
      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
      end

      def execute
        backend = RBLE::Backend.for_platform
        device_path = backend.device_path_for_address(@address)

        if device_path.nil?
          $stderr.puts "Device not paired"
          @formatter.pair_result(success: true, address: @address, message: "Not paired")
          return
        end

        $stderr.puts "Removing pairing for #{@address}..."
        result = backend.unpair_device(device_path)

        case result
        when :unpaired
          $stderr.puts "Pairing removed"
          @formatter.pair_result(success: true, address: @address, message: "Pairing removed")
        when :not_paired
          $stderr.puts "Device not paired"
          @formatter.pair_result(success: true, address: @address, message: "Not paired")
        end
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end
    end
  end
end
