# frozen_string_literal: true

require_relative 'rble/version'
require_relative 'rble/errors'
require_relative 'rble/device'
require_relative 'rble/service'
require_relative 'rble/characteristic'
require_relative 'rble/backend'
require_relative 'rble/scanner'
require_relative 'rble/connection'

module RBLE
  class << self
    # Logger for debug output
    # Set to a Logger instance with debug level to see notification flow
    # @example
    #   RBLE.logger = Logger.new(STDOUT)
    #   RBLE.logger.level = Logger::DEBUG
    attr_accessor :logger

    # Enable trace-level output for connection timing and D-Bus call flow
    # @example
    #   RBLE.trace = true
    attr_accessor :trace

    # Global warning flag. Defaults to true.
    # Set to false to suppress feature-level warnings from RBLE.
    # @example
    #   RBLE.warnings = false
    attr_writer :warnings

    def warnings
      @warnings.nil? ? true : @warnings
    end

    # Output a warning with [RBLE] prefix, respecting RBLE.warnings flag.
    # @param message [String] Warning message
    def rble_warn(message)
      return unless warnings

      warn "[RBLE] #{message}"
    end
  end

  # Backend selection API - delegates to RBLE::Backend

  def self.backend
    Backend.backend
  end

  def self.backend=(value)
    Backend.backend = value
  end

  def self.available_backends
    Backend.available_backends
  end

  def self.backend_info
    Backend.backend_info
  end
end
