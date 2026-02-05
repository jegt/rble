# frozen_string_literal: true

module RBLE
  module CLI
    class Paired
      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
      end

      def execute
        backend = RBLE::Backend.for_platform
        devices = backend.bonded_devices

        @formatter.paired_list(devices)
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end
    end
  end
end
