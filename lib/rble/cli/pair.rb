# frozen_string_literal: true

module RBLE
  module CLI
    # IO handler for interactive terminal prompts during pairing
    class TerminalIOHandler
      def display(msg)
        $stderr.puts msg
      end

      def prompt(msg)
        $stderr.print msg
        $stdin.gets&.strip
      end

      def confirm(msg)
        $stderr.print msg
        response = $stdin.gets&.strip&.downcase
        response == 'y' || response == 'yes'
      end
    end

    # Null IO handler for JSON mode (no interactive prompts on stdout)
    class NullIOHandler
      def display(_msg); end

      def prompt(_msg)
        nil
      end

      def confirm(_msg)
        false
      end
    end

    class Pair
      SECURITY_CAPABILITY_MAP = {
        "low" => "NoInputNoOutput",
        "medium" => "DisplayYesNo",
        "high" => "KeyboardDisplay"
      }.freeze

      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
        @timeout = options["timeout"] || 30
        @security = options["security"]
        @force = options["force"] || false
      end

      def execute
        backend = RBLE::Backend.for_platform
        device_path = backend.device_path_for_address(@address)

        if device_path.nil?
          $stderr.puts "Error: Device #{@address} not found."
          $stderr.puts "Run `rble scan` first to discover nearby devices."
          exit 1
        end

        io_handler = @options["json"] ? NullIOHandler.new : TerminalIOHandler.new
        capability = SECURITY_CAPABILITY_MAP[@security]

        $stderr.puts "Pairing with #{@address}..."
        result = backend.pair_device(
          device_path,
          io_handler: io_handler,
          force: @force,
          capability: capability,
          timeout: @timeout
        )

        case result
        when :paired
          $stderr.puts "Bonded successfully"
          @formatter.pair_result(success: true, address: @address, message: "Bonded successfully")
        when :already_paired
          $stderr.puts "Device already paired"
        end
      rescue RBLE::DeviceNotFoundError => e
        $stderr.puts "Error: #{e.message}"
        $stderr.puts "Run `rble scan` first to discover nearby devices."
        exit 1
      rescue RBLE::AuthenticationError
        $stderr.puts "Error: Pairing rejected by device. Ensure device is in pairing mode and try again."
        exit 1
      rescue RBLE::ConnectionFailed
        $stderr.puts "Error: Connection failed. Device may be out of range."
        exit 1
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end
    end
  end
end
