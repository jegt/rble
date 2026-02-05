# frozen_string_literal: true

require 'thor'
require 'rble'
require_relative 'cli/formatters/text'
require_relative 'cli/formatters/json'

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

      desc "version", "Show rble version"
      def version
        puts "rble #{RBLE::VERSION}"
      end

      map "--version" => :version
      map "-V" => :version
    end
  end
end
