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
