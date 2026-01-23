# frozen_string_literal: true

module RBLE
  # Represents a connection to a BLE device
  #
  # Provides access to GATT services and characteristics for reading,
  # writing, and subscribing to values.
  #
  # @example Connect and read a characteristic
  #   connection = RBLE.connect(device.address)
  #   connection.discover_services
  #   hr_service = connection.service('180d')
  #   measurement = hr_service.characteristic('2a37')
  #   # Future: value = measurement.read (Plan 04)
  #   connection.disconnect
  #
  class Connection
    attr_reader :address, :device_path

    # Create a connection (internal - use RBLE.connect)
    # @param address [String] Device MAC address
    # @param device_path [String] D-Bus device path
    # @param backend [Backend::Base] Platform backend instance
    def initialize(address:, device_path:, backend:)
      @address = address
      @device_path = device_path
      @backend = backend
      @services = nil
      @connected = true
    end

    # Check if still connected
    # @return [Boolean]
    def connected?
      @connected
    end

    # Discover GATT services on the connected device
    # Must be called before accessing services
    #
    # @param timeout [Numeric] Discovery timeout in seconds (default: 30)
    # @return [Array<Service>] Discovered services
    # @raise [NotConnectedError] if not connected
    # @raise [ServiceDiscoveryError] if discovery fails
    def discover_services(timeout: 30)
      raise NotConnectedError unless @connected

      @services = @backend.discover_services(@device_path, timeout: timeout)
    end

    # Get all discovered services
    # @return [Array<Service>]
    # @raise [ServiceDiscoveryError] if discover_services not called
    def services
      raise ServiceDiscoveryError, 'Call discover_services first' if @services.nil?

      @services
    end

    # Find a service by UUID
    # Supports both full UUID and short UUID (e.g., "180d")
    #
    # @param uuid [String] Service UUID to find
    # @return [Service]
    # @raise [ServiceNotFoundError] if service not found
    # @raise [ServiceDiscoveryError] if discover_services not called
    def service(uuid)
      normalized = normalize_uuid(uuid)
      found = services.find { |s| s.uuid.downcase == normalized || s.short_uuid == uuid.downcase }
      raise ServiceNotFoundError, uuid unless found

      found
    end

    # Disconnect from the device
    # @return [void]
    def disconnect
      return unless @connected

      @backend.disconnect_device(@device_path)
      @connected = false
      @services = nil
    end

    private

    # Normalize a short UUID to full 128-bit format
    # @param short_uuid [String] Short or full UUID
    # @return [String] Full 128-bit UUID in lowercase
    def normalize_uuid(short_uuid)
      if short_uuid.length == 4
        "0000#{short_uuid.downcase}-0000-1000-8000-00805f9b34fb"
      else
        short_uuid.downcase
      end
    end
  end

  class << self
    # Connect to a BLE device by address
    #
    # @param address [String] Device MAC address (e.g., "AA:BB:CC:DD:EE:FF")
    # @param timeout [Numeric] Connection timeout in seconds (default: 30)
    # @param adapter [String, nil] Bluetooth adapter name (e.g., "hci0")
    # @return [Connection] Connected device handle
    # @raise [ConnectionTimeoutError] if connection times out
    # @raise [ConnectionError] if connection fails
    #
    # @example
    #   conn = RBLE.connect("AA:BB:CC:DD:EE:FF", timeout: 10)
    #   conn.discover_services
    #   # ... use services ...
    #   conn.disconnect
    #
    def connect(address, timeout: 30, adapter: nil)
      backend = Backend.for_platform

      # Convert address to D-Bus path
      device_path = backend.device_path_for_address(address, adapter: adapter)
      raise ConnectionError, "Device '#{address}' not found. Scan for devices first." unless device_path

      # Connect via backend
      backend.connect_device(device_path, timeout: timeout)

      Connection.new(
        address: address,
        device_path: device_path,
        backend: backend
      )
    end
  end
end
