# frozen_string_literal: true

require 'set'

module RBLE
  module CLI
    class Scan
      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @advertisement_count = 0
        @seen_addresses = Set.new
        @start_time = nil
      end

      def execute
        scanner = RBLE::Scanner.new(
          timeout: @options["timeout"],
          active: !@options["passive"],
          allow_duplicates: true
        )

        prev_handler = trap("INT") { scanner.stop }

        @advertisement_count = 0
        @seen_addresses = Set.new
        @start_time = Time.now

        begin
          scanner.start do |device|
            next unless matches_filters?(device)

            @advertisement_count += 1
            @seen_addresses.add(device.address)
            @formatter.device(device)
          end
        rescue RBLE::Error => e
          handle_error(e)
        ensure
          trap("INT", prev_handler || "DEFAULT")
        end

        duration = (Time.now - @start_time).round(1)
        device_count = @seen_addresses.size
        $stderr.puts "Discovered #{device_count} device#{'s' unless device_count == 1} " \
                     "(#{@advertisement_count} advertisement#{'s' unless @advertisement_count == 1}) " \
                     "in #{duration}s"

        if @options["timeout"] && @advertisement_count.zero? && has_filters?
          $stderr.puts "No devices found matching filters"
        end
      end

      private

      def matches_filters?(device)
        if @options["name"]
          return false unless device.name
          return false unless device.name.downcase.include?(@options["name"].downcase)
        end

        if @options["rssi"]
          return false unless device.rssi
          return false unless device.rssi >= @options["rssi"]
        end

        true
      end

      def has_filters?
        @options["name"] || @options["rssi"]
      end

      def handle_error(error)
        $stderr.puts "Error: #{error.message}"

        if @options["verbose"]
          $stderr.puts error.recovery_hint if error.respond_to?(:recovery_hint)
          $stderr.puts error.backtrace.join("\n") if error.backtrace
        end

        exit 1
      end
    end
  end
end
