# frozen_string_literal: true

require_relative 'characteristic_helpers'

module RBLE
  module CLI
    class Monitor
      include CharacteristicHelpers

      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
        @characteristic_uuid = options["characteristic"]
        @timeout = options["timeout"] || 10
        @reconnect = options["reconnect"] || false
        @stop = false
      end

      def execute
        if @reconnect
          reconnect_loop
        else
          single_session
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

      # Run a single monitor session: connect, subscribe, stream until stop or disconnect.
      def single_session
        connection = connect_and_discover(@address, timeout: @timeout)

        begin
          char = find_characteristic(connection, @characteristic_uuid)

          unless char.subscribable?
            $stderr.puts "Error: Characteristic #{@characteristic_uuid} does not support notifications."
            $stderr.puts "Supported: #{char.flags.join(', ')}"
            exit 1
          end

          stream_notifications(connection, char)
        ensure
          connection.disconnect if connection.connected?
        end
      end

      # Reconnect loop: retry single_session on connection errors until @stop is set.
      def reconnect_loop
        loop do
          begin
            single_session
          rescue RBLE::DeviceNotFoundError
            raise # No retry for device not found
          rescue RBLE::ConnectionTimeoutError, RBLE::ConnectionFailed, RBLE::Error => e
            break if @stop

            $stderr.puts "Error: #{e.message}"
            $stderr.puts "Reconnecting in 2s..."
            interruptible_sleep(2)
            next
          end

          break if @stop

          $stderr.puts "Device disconnected."
          $stderr.puts "Reconnecting in 2s..."
          interruptible_sleep(2)
        end
      end

      # Sleep in short intervals, checking @stop flag for responsiveness
      # @param seconds [Numeric] Total sleep duration
      def interruptible_sleep(seconds)
        intervals = (seconds / 0.1).ceil
        intervals.times do
          break if @stop
          sleep 0.1
        end
      end

      # Subscribe and stream notifications until @stop flag or disconnect.
      def stream_notifications(connection, char)
        name = resolve_char_name(char.uuid)
        char_display_name = RBLE::GATT::UUIDDatabase.resolve(char.uuid, type: :characteristic)

        $stderr.puts "Subscribing to #{name}..."

        char.subscribe do |value|
          timestamp = Time.now
          formatted = format_value(char.uuid, value)
          @formatter.monitor_value(
            address: @address,
            uuid: char.uuid,
            name: char_display_name,
            raw: value,
            formatted: formatted,
            timestamp: timestamp
          )
        end

        $stderr.puts "Subscribed, waiting for notifications..."

        prev_handler = trap("INT") { @stop = true }

        begin
          while !@stop && connection.connected?
            sleep 0.1
          end

          unless connection.connected?
            $stderr.puts "Device disconnected." unless @stop
          end
        ensure
          trap("INT", prev_handler || "DEFAULT")
          char.unsubscribe if connection.connected?
        end
      end
    end
  end
end
