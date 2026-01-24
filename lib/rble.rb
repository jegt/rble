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
