# frozen_string_literal: true

module RBLE
  module Backend
    # Abstract base class for platform-specific BLE backends.
    # Subclasses must implement all public methods.
    class Base
      # Start scanning for BLE devices
      #
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs (nil = all devices)
      # @param allow_duplicates [Boolean] If true, callback fires on every advertisement
      # @param adapter [String, nil] Specific adapter to use (nil = default)
      # @yield [Device] Called when a device is discovered
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, active: true, &block)
        raise NotImplementedError, "#{self.class}#start_scan must be implemented"
      end

      # Stop the current scan
      #
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def stop_scan
        raise NotImplementedError, "#{self.class}#stop_scan must be implemented"
      end

      # Check if a scan is currently running
      #
      # @return [Boolean]
      # @raise [NotImplementedError] if not implemented by subclass
      def scanning?
        raise NotImplementedError, "#{self.class}#scanning? must be implemented"
      end

      # List available Bluetooth adapters
      #
      # @return [Array<Hash>] Array of adapter info hashes with :name, :address, :powered keys
      # @raise [NotImplementedError] if not implemented by subclass
      def adapters
        raise NotImplementedError, "#{self.class}#adapters must be implemented"
      end

      # Get the default adapter name
      #
      # @return [String, nil] Default adapter name or nil if none available
      def default_adapter
        adapters.first&.dig(:name)
      end

      # Connection methods (implement in subclass)

      # Connect to a BLE device
      #
      # @param device_path [String] D-Bus device path
      # @param timeout [Numeric] Connection timeout in seconds
      # @return [Boolean] true on successful connection
      # @raise [NotImplementedError] if not implemented by subclass
      def connect_device(device_path, timeout: 30)
        raise NotImplementedError, "#{self.class}#connect_device must be implemented"
      end

      # Disconnect from a BLE device
      #
      # @param device_path [String] D-Bus device path
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def disconnect_device(device_path)
        raise NotImplementedError, "#{self.class}#disconnect_device must be implemented"
      end

      # Discover GATT services on a connected device
      #
      # @param device_path [String] D-Bus device path
      # @param connection [Connection, nil] Connection for D-Bus session routing (BlueZ only)
      # @param timeout [Numeric] Discovery timeout in seconds
      # @return [Array<Service>] Discovered services
      # @raise [NotImplementedError] if not implemented by subclass
      def discover_services(device_path, connection: nil, timeout: 30)
        raise NotImplementedError, "#{self.class}#discover_services must be implemented"
      end

      # Get the device D-Bus path for a given MAC address
      #
      # @param address [String] Device MAC address
      # @param adapter [String, nil] Specific adapter to use
      # @return [String, nil] Device path or nil if not found
      # @raise [NotImplementedError] if not implemented by subclass
      def device_path_for_address(address, adapter: nil)
        raise NotImplementedError, "#{self.class}#device_path_for_address must be implemented"
      end

      # GATT operations (implement in subclass)

      # Read a characteristic value
      #
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection, nil] Connection for D-Bus session routing (BlueZ only)
      # @param timeout [Numeric] Read timeout in seconds
      # @return [String] Binary string (ASCII-8BIT encoding)
      # @raise [NotImplementedError] if not implemented by subclass
      def read_characteristic(char_path, connection: nil, timeout: 30)
        raise NotImplementedError, "#{self.class}#read_characteristic must be implemented"
      end

      # Write a value to a characteristic
      #
      # @param char_path [String] D-Bus characteristic path
      # @param data [String, Array<Integer>] Data to write
      # @param connection [Connection, nil] Connection for D-Bus session routing (BlueZ only)
      # @param response [Boolean] Wait for write response (true = write with response)
      # @param timeout [Numeric] Write timeout in seconds
      # @return [Boolean] true on success
      # @raise [NotImplementedError] if not implemented by subclass
      def write_characteristic(char_path, data, connection: nil, response: true, timeout: 30)
        raise NotImplementedError, "#{self.class}#write_characteristic must be implemented"
      end

      # Subscribe to characteristic notifications
      #
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection, nil] Connection for D-Bus session routing (BlueZ only)
      # @yield [String] Called with value (binary string) on each notification
      # @return [Boolean] true on success
      # @raise [NotImplementedError] if not implemented by subclass
      def subscribe_characteristic(char_path, connection: nil, &)
        raise NotImplementedError, "#{self.class}#subscribe_characteristic must be implemented"
      end

      # Unsubscribe from characteristic notifications
      #
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection, nil] Connection for D-Bus session routing (BlueZ only)
      # @return [Boolean] true on success
      # @raise [NotImplementedError] if not implemented by subclass
      def unsubscribe_characteristic(char_path, connection: nil)
        raise NotImplementedError, "#{self.class}#unsubscribe_characteristic must be implemented"
      end

      # Get active subscriptions for a connection
      #
      # @param connection [Connection] Connection to query
      # @return [Array<Hash>] Subscription info hashes with :uuid and :path
      def subscriptions_for_connection(connection)
        []
      end
    end
  end
end
