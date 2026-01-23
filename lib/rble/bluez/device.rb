# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wrapper for BlueZ Device1 D-Bus interface
    # Provides connection lifecycle management
    class Device
      attr_reader :path, :address

      # @param connection [DBusConnection] D-Bus connection instance
      # @param device_path [String] D-Bus object path (e.g., /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX)
      def initialize(connection, device_path)
        @connection = connection
        @path = device_path
        @address = extract_address_from_path(device_path)

        # Get D-Bus object and interfaces
        @object = connection.object(device_path)
        @device_iface = @object[DEVICE_INTERFACE]
        @props_iface = @object[PROPERTIES_INTERFACE]
      end

      # Check if device is currently connected
      # @return [Boolean] true if connected
      def connected?
        get_property('Connected')
      end

      # Check if GATT services have been resolved
      # @return [Boolean] true if services are resolved
      def services_resolved?
        get_property('ServicesResolved')
      end

      # Get device name from adapter cache
      # @return [String, nil] device name or nil if not known
      def name
        get_property('Name')
      rescue DBus::Error
        nil
      end

      # Connect to device (calls D-Bus Connect method)
      # Note: This is async - returns immediately, watch Connected property for completion
      # @raise [ConnectionError] if connection initiation fails
      def connect
        @device_iface.Connect
      rescue DBus::Error => e
        raise ConnectionError, "Failed to initiate connection: #{e.message}"
      end

      # Disconnect from device
      # @raise [ConnectionError] if disconnect fails
      def disconnect
        @device_iface.Disconnect
      rescue DBus::Error => e
        raise ConnectionError, "Failed to disconnect: #{e.message}"
      end

      # Read a property value from the Device1 interface
      # @param name [String] property name
      # @return [Object] property value
      def get_property(name)
        @props_iface.Get(DEVICE_INTERFACE, name).first
      end

      private

      # Extract MAC address from D-Bus object path
      # @param path [String] e.g., /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      # @return [String] MAC address (e.g., AA:BB:CC:DD:EE:FF) or 'UNKNOWN'
      def extract_address_from_path(path)
        if path =~ /dev_([0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2})/i
          Regexp.last_match(1).tr('_', ':').upcase
        else
          'UNKNOWN'
        end
      end
    end
  end
end
