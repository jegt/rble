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
            "On Linux: ensure user is in 'bluetooth' group or has appropriate polkit permissions. " \
            "On macOS: grant Bluetooth access in System Preferences > Privacy & Security.")
    end
  end

  # Raised when subprocess communication fails (macOS backend)
  class SubprocessError < Error
    def initialize(msg = 'Subprocess communication failed. The helper process may have crashed.')
      super
    end
  end

  # Raised when Bluetooth is not powered on
  class BluetoothOffError < Error
    def initialize
      super('Bluetooth is not powered on. Enable Bluetooth in system settings.')
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

  # Base class for connection-related errors
  class ConnectionError < Error; end

  # Raised when connection attempt times out
  class ConnectionTimeoutError < ConnectionError
    def initialize(timeout = 30)
      super("Connection timed out after #{timeout} seconds. " \
            'Ensure device is in range and advertising.')
    end
  end

  # Raised when operation requires an active connection
  class NotConnectedError < ConnectionError
    def initialize(msg = nil)
      super(msg || 'Connection lost. Create a new connection with RBLE.connect()')
    end
  end

  # Raised when attempting to connect to an already-connected device
  class AlreadyConnectedError < ConnectionError
    def initialize
      super('Device is already connected. Disconnect first if you need to reconnect.')
    end
  end

  # Base class for service discovery errors
  class ServiceDiscoveryError < Error; end

  # Raised when a requested service UUID is not found on the device
  class ServiceNotFoundError < ServiceDiscoveryError
    def initialize(uuid = nil)
      msg = uuid ? "Service with UUID '#{uuid}' not found on device." : 'Service not found on device.'
      msg += ' Ensure the device supports this service and discovery has completed.'
      super(msg)
    end
  end

  # Raised when a requested characteristic UUID is not found
  class CharacteristicNotFoundError < ServiceDiscoveryError
    def initialize(uuid = nil)
      msg = uuid ? "Characteristic with UUID '#{uuid}' not found." : 'Characteristic not found.'
      msg += ' Ensure the service contains this characteristic.'
      super(msg)
    end
  end

  # Base class for GATT operation errors
  class GATTError < Error; end

  # Raised when a read operation fails
  class ReadError < GATTError
    def initialize(msg = 'Failed to read characteristic value.')
      super
    end
  end

  # Raised when a write operation fails
  class WriteError < GATTError
    def initialize(msg = 'Failed to write characteristic value.')
      super
    end
  end

  # Raised when notification subscription fails
  class NotifyError < GATTError
    def initialize(msg = 'Failed to enable notifications on characteristic.')
      super
    end
  end

  # Raised when operation is not permitted by the characteristic
  class NotPermittedError < GATTError
    def initialize(operation = 'operation')
      super("#{operation.capitalize} not permitted on this characteristic. " \
            'Check characteristic flags for supported operations.')
    end
  end

  # Raised when operation requires pairing or authorization
  class NotAuthorizedError < GATTError
    def initialize(operation = 'operation')
      super("#{operation.capitalize} requires authorization. " \
            'Device may need to be paired first.')
    end
  end

  # Raised when characteristic does not support the requested operation
  class NotSupportedError < GATTError
    def initialize(operation = 'operation')
      super("#{operation.capitalize} not supported by this characteristic. " \
            'Check the Flags property for supported operations.')
    end
  end

  # Base class for backend selection errors
  class BackendUnavailableError < Error
    attr_reader :backend

    def initialize(backend:, reason:, suggestion: nil)
      @backend = backend
      message = "Backend :#{backend} unavailable: #{reason}"
      message = "#{message}\n\n#{suggestion}" if suggestion
      super(message)
    end
  end

  # Raised when attempting to change backend after BLE operations have started
  class BackendAlreadySelectedError < Error
    def initialize(msg = 'Cannot change backend after BLE operations have started.')
      super
    end
  end

  # Raised when Linux Swift helper binary is not found
  class HelperNotFoundError < BackendUnavailableError
    def initialize(path)
      super(
        backend: :bluetooth_linux,
        reason: "Helper binary not found at #{path}",
        suggestion: <<~SUGGESTION.chomp
          Build the helper manually:
            cd ext/linux_ble && swift build -c release

          Or use BlueZ backend instead:
            RBLE.backend = :bluez
        SUGGESTION
      )
    end
  end

  # Raised when BlueZ daemon conflicts with direct HCI access
  class DaemonConflictError < BackendUnavailableError
    def initialize(adapter = nil)
      adapter_info = adapter ? " on #{adapter}" : ''
      super(
        backend: :bluetooth_linux,
        reason: "BlueZ Bluetooth daemon is running#{adapter_info}",
        suggestion: <<~SUGGESTION.chomp
          Stop the daemon temporarily:
            sudo systemctl stop bluetooth

          Or use BlueZ backend instead (works with daemon):
            RBLE.backend = :bluez
        SUGGESTION
      )
    end
  end
end
