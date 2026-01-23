# frozen_string_literal: true

require_relative 'backend/base'

module RBLE
  module Backend
    @instance_mutex = Mutex.new
    @instance = nil

    # Returns the appropriate backend for the current platform (singleton)
    # @return [Backend::Base] Platform-specific backend instance
    # @raise [Error] if platform is not supported
    def self.for_platform
      @instance_mutex.synchronize do
        @instance ||= create_backend
      end
    end

    # Reset the singleton instance (for testing)
    # @api private
    def self.reset!
      @instance_mutex.synchronize do
        @instance&.shutdown if @instance.respond_to?(:shutdown)
        @instance = nil
      end
    end

    class << self
      private

      def create_backend
        case RUBY_PLATFORM
        when /linux/
          require_relative 'backend/bluez'
          BlueZ.new
        when /darwin/
          require_relative 'backend/corebluetooth'
          CoreBluetooth.new
        else
          raise Error, "Unsupported platform: #{RUBY_PLATFORM}"
        end
      end
    end
  end
end
