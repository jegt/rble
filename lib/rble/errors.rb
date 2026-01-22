# frozen_string_literal: true

module RBLE
  # Base error class for all RBLE errors
  class Error < StandardError; end

  # Raised when no Bluetooth adapter is found
  class AdapterNotFoundError < Error
    def initialize(msg = 'No Bluetooth adapter found. Ensure Bluetooth hardware is present and enabled.')
      super
    end
  end

  # Raised when adapter exists but is powered off or disabled
  class AdapterDisabledError < Error
    def initialize(adapter = nil)
      msg = adapter ? "Bluetooth adapter '#{adapter}' is disabled." : 'Bluetooth adapter is disabled.'
      msg += " Run 'bluetoothctl power on' to enable."
      super(msg)
    end
  end

  # Raised when operation fails due to insufficient permissions
  class PermissionError < Error
    def initialize(operation = 'access Bluetooth')
      super("Permission denied to #{operation}. " \
            "Ensure user is in 'bluetooth' group or has appropriate polkit permissions.")
    end
  end

  # Raised when scan operation fails
  class ScanError < Error; end

  # Raised when a scan is already in progress
  class ScanInProgressError < ScanError
    def initialize
      super('A scan is already in progress. Stop the current scan before starting a new one.')
    end
  end
end
