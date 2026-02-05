# frozen_string_literal: true

module RBLE
  module CLI
    class Status
      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
      end

      def execute
        backend = Backend.for_platform
        adapter_name = @options["adapter"] || backend.default_adapter_name
        info = backend.adapter_info(adapter_name)
        @formatter.status(info)
      rescue RBLE::AdapterNotFoundError
        $stderr.puts "No Bluetooth adapter found. Run `rble doctor` to diagnose."
        exit 1
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end
    end
  end
end
