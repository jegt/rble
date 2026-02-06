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

  # Raised when device is no longer available (disappeared between scan and connect)
  class DeviceNotFoundError < ConnectionError
    attr_reader :address, :device_name

    def initialize(address, device_name: nil)
      @address = address
      @device_name = device_name

      msg = if device_name
              "Device '#{device_name}' (#{address}) was seen during scan but is no longer available"
            else
              "Device #{address} was seen during scan but is no longer available"
            end
      super(msg)
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

  # Raised when connection attempt fails (out of range, device unavailable, etc.)
  class ConnectionFailed < ConnectionError
    attr_reader :address, :reason

    def initialize(address, reason = nil)
      @address = address
      @reason = reason
      msg = "Connection to #{address} failed"
      msg = "#{msg}: #{reason}" if reason
      super(msg)
    end
  end

  # Raised when device disconnects during an operation
  class DeviceDisconnected < ConnectionError
    attr_reader :address, :operation

    def initialize(address = nil, operation = nil)
      @address = address
      @operation = operation
      msg = 'Device disconnected'
      msg = "#{msg} (#{address})" if address
      msg = "#{msg} during #{operation}" if operation
      super(msg)
    end
  end

  # Raised when an async operation is pending and the session is closed
  class SessionClosedError < ConnectionError
    def initialize
      super('Session closed while operation was pending')
    end
  end

  # Raised when BlueZ returns org.bluez.Error.InProgress after retries exhausted
  class OperationInProgressError < ConnectionError
    def initialize(operation = nil)
      msg = operation ? "Operation '#{operation}' still in progress after retries." : 'Operation still in progress after retries.'
      super(msg)
    end

    def recovery_hint
      'Wait a moment and retry the operation. If persists, disconnect and reconnect.'
    end
  end

  # Raised when adapter is not ready (e.g., not powered, not initialized)
  class AdapterNotReadyError < Error
    def initialize(adapter = nil)
      msg = adapter ? "Adapter '#{adapter}' is not ready." : 'Bluetooth adapter is not ready.'
      super(msg)
    end

    def recovery_hint
      "Run 'bluetoothctl power on' to enable the adapter, or wait for initialization to complete."
    end
  end

  # Raised when authentication/pairing fails during connection
  class AuthenticationError < ConnectionError
    attr_reader :address

    def initialize(address = nil)
      @address = address
      msg = address ? "Authentication failed for device #{address}." : 'Authentication failed.'
      super(msg)
    end

    def recovery_hint
      'Remove the device pairing and re-pair: bluetoothctl remove <address>, then bluetoothctl pair <address>'
    end
  end

  # Raised when connection is aborted (often due to RF interference or device busy)
  class ConnectionAbortedError < ConnectionError
    attr_reader :address

    def initialize(address = nil, reason = nil)
      @address = address
      msg = address ? "Connection to #{address} was aborted" : 'Connection was aborted'
      msg = "#{msg}: #{reason}" if reason
      super(msg)
    end

    def recovery_hint
      'This may be caused by RF interference, device busy, or distance. Move closer to the device and retry.'
    end
  end

  # Raised when connection is lost unexpectedly during an operation
  class ConnectionLostError < ConnectionError
    attr_reader :address, :operation

    def initialize(address = nil, operation = nil)
      @address = address
      @operation = operation
      msg = 'Connection lost'
      msg = "#{msg} to #{address}" if address
      msg = "#{msg} during #{operation}" if operation
      super(msg)
    end

    def recovery_hint
      'Reconnect with RBLE.connect(). Check device is still in range and powered.'
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

  # Raised when subscribing to a characteristic that doesn't support notifications
  class NotifyNotSupported < GATTError
    attr_reader :uuid, :flags

    def initialize(uuid, flags)
      @uuid = uuid
      @flags = flags
      super("Characteristic #{uuid} does not support notifications. " \
            "Flags: [#{flags.join(', ')}]. " \
            "Characteristic must have 'notify' or 'indicate' flag.")
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

  # Raised when a D-Bus operation times out
  class TimeoutError < Error
    attr_reader :operation, :timeout_value

    def initialize(operation, timeout_value)
      @operation = operation
      @timeout_value = timeout_value
      super("#{operation} timed out after #{timeout_value}s")
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

end
