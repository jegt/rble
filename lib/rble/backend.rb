# frozen_string_literal: true

require_relative "backend/base"

module RBLE
  module Backend
    # Returns the appropriate backend for the current platform
    # @return [Backend::Base] Platform-specific backend instance
    # @raise [Error] if platform is not supported
    def self.for_platform
      case RUBY_PLATFORM
      when /linux/
        require_relative "backend/bluez"
        BlueZ.new
      when /darwin/
        raise Error, "macOS support not yet implemented"
      else
        raise Error, "Unsupported platform: #{RUBY_PLATFORM}"
      end
    end
  end
end
