# frozen_string_literal: true

require 'thor'
require 'rble'
require_relative 'cli/formatters/text'
require_relative 'cli/formatters/json'
require_relative 'cli/adapter'

module RBLE
  module CLI
    class Main < Thor
      def self.exit_on_failure?
        true
      end

      check_unknown_options!

      class_option :json, type: :boolean, default: false,
                          desc: "Output as JSON (NDJSON for streaming)"
      class_option :verbose, type: :boolean, aliases: "-v", default: false,
                             desc: "Show detailed error information"

      desc "scan", "Discover nearby BLE devices"
      method_option :timeout, type: :numeric, aliases: "-t",
                              desc: "Stop after N seconds (default: continuous)"
      method_option :name, type: :string, aliases: "-n",
                           desc: "Filter by device name (case-insensitive substring)"
      method_option :rssi, type: :numeric, aliases: "-r",
                           desc: "Minimum RSSI threshold (e.g., -70)"
      method_option :passive, type: :boolean, default: false,
                              desc: "Use passive scanning (no scan requests sent)"
      def scan
        require_relative 'cli/scan'
        Scan.new(options).execute
      end

      desc "show ADDRESS", "Display GATT services and characteristics"
      method_option :timeout, type: :numeric, aliases: "-t", default: 10,
                              desc: "Connection timeout in seconds"
      def show(address)
        require_relative 'cli/show'
        merged = options.merge("address" => address)
        Show.new(merged).execute
      end

      desc "pair ADDRESS", "Pair with a BLE device"
      method_option :timeout, type: :numeric, aliases: "-t", default: 30,
                              desc: "Pairing timeout in seconds"
      method_option :security, type: :string, aliases: "-s",
                               desc: "Security level (low, medium, high)"
      method_option :force, type: :boolean, default: false,
                            desc: "Auto-accept pairing prompts"
      def pair(address)
        require_relative 'cli/pair'
        merged = options.merge("address" => address)
        Pair.new(merged).execute
      end

      desc "unpair ADDRESS", "Remove pairing bond from a device"
      def unpair(address)
        require_relative 'cli/unpair'
        merged = options.merge("address" => address)
        Unpair.new(merged).execute
      end

      desc "paired", "List bonded devices"
      def paired
        require_relative 'cli/paired'
        Paired.new(options).execute
      end

      desc "read ADDRESS CHARACTERISTIC", "Read a characteristic value"
      method_option :timeout, type: :numeric, aliases: "-t", default: 10,
                              desc: "Connection timeout in seconds"
      def read(address, characteristic)
        require_relative 'cli/read'
        merged = options.merge("address" => address, "characteristic" => characteristic)
        Read.new(merged).execute
      end

      desc "write ADDRESS CHARACTERISTIC VALUE", "Write a value to a characteristic"
      method_option :timeout, type: :numeric, aliases: "-t", default: 10,
                              desc: "Connection timeout in seconds"
      method_option :hex, type: :boolean, default: false,
                          desc: "Value is hex bytes (e.g., '0A1BFF')"
      method_option :string, type: :boolean, default: false,
                             desc: "Value is UTF-8 string"
      method_option :uint8, type: :boolean, default: false,
                            desc: "Value is unsigned 8-bit integer"
      method_option :uint16, type: :boolean, default: false,
                             desc: "Value is unsigned 16-bit integer (LE)"
      method_option :uint32, type: :boolean, default: false,
                             desc: "Value is unsigned 32-bit integer (LE)"
      method_option :int8, type: :boolean, default: false,
                           desc: "Value is signed 8-bit integer"
      method_option :int16, type: :boolean, default: false,
                            desc: "Value is signed 16-bit integer (LE)"
      method_option :int32, type: :boolean, default: false,
                            desc: "Value is signed 32-bit integer (LE)"
      method_option :verify, type: :boolean, default: false,
                             desc: "Read back after writing to confirm"
      def write(address, characteristic, value)
        require_relative 'cli/write'
        merged = options.merge("address" => address, "characteristic" => characteristic, "value" => value)
        Write.new(merged).execute
      end

      desc "monitor ADDRESS CHARACTERISTIC", "Subscribe to characteristic notifications"
      method_option :timeout, type: :numeric, aliases: "-t", default: 10,
                              desc: "Connection timeout in seconds"
      method_option :reconnect, type: :boolean, default: false,
                                desc: "Auto-reconnect on disconnect"
      def monitor(address, characteristic)
        require_relative 'cli/monitor'
        merged = options.merge("address" => address, "characteristic" => characteristic)
        Monitor.new(merged).execute
      end

      desc "status", "Show Bluetooth adapter status"
      method_option :adapter, type: :string, desc: "Adapter name (default: auto)"
      def status
        require_relative 'cli/status'
        Status.new(options).execute
      end

      desc "doctor", "Diagnose Bluetooth problems"
      def doctor
        require_relative 'cli/doctor'
        Doctor.new(options).execute
      end

      desc "adapter SUBCOMMAND", "Manage Bluetooth adapters"
      subcommand "adapter", AdapterCli

      desc "version", "Show rble version"
      def version
        puts "rble #{RBLE::VERSION}"
      end

      map "--version" => :version
      map "-V" => :version
    end
  end
end
