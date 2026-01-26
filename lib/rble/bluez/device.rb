# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wrapper for BlueZ Device1 D-Bus interface
    # Provides connection lifecycle management
    class Device
      attr_reader :path, :address

      # @param connection [DBusConnection] D-Bus connection instance
      # @param device_path [String] D-Bus object path (e.g., /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX)
      # @deprecated Use new_from_session instead for async operations
      def initialize(connection, device_path)
        @connection = connection
        @session = nil
        @path = device_path
        @address = extract_address_from_path(device_path)

        # Get D-Bus object and interfaces
        @object = connection.object(device_path)
        @device_iface = @object[DEVICE_INTERFACE]
        @props_iface = @object[PROPERTIES_INTERFACE]
      end

      # Create a Device from a DBusSession
      # This is the preferred constructor for async operations
      # @param session [DBusSession] Active D-Bus session
      # @param device_path [String] D-Bus object path (e.g., /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX)
      # @return [Device]
      def self.new_from_session(session, device_path)
        device = allocate
        device.instance_variable_set(:@session, session)
        device.instance_variable_set(:@path, device_path)
        device.instance_variable_set(:@address, device.send(:extract_address_from_path, device_path))
        # Async introspect for non-blocking setup
        proxy = session.async_introspect(device_path, timeout: 5)
        device.instance_variable_set(:@object, proxy)
        device.instance_variable_set(:@device_iface, proxy[DEVICE_INTERFACE])
        device.instance_variable_set(:@props_iface, proxy[PROPERTIES_INTERFACE])
        device
      end

      # Check if device is currently connected
      # @return [Boolean] true if connected
      def connected?
        if @session
          @session.async_get_property(@path, DEVICE_INTERFACE, 'Connected', timeout: 5)
        else
          get_property('Connected')
        end
      end

      # Check if GATT services have been resolved
      # @return [Boolean] true if services are resolved
      def services_resolved?
        if @session
          @session.async_get_property(@path, DEVICE_INTERFACE, 'ServicesResolved', timeout: 5)
        else
          get_property('ServicesResolved')
        end
      end

      # Get device name from adapter cache
      # @return [String, nil] device name or nil if not known
      def name
        if @session
          @session.async_get_property(@path, DEVICE_INTERFACE, 'Name', timeout: 5)
        else
          get_property('Name')
        end
      rescue DBus::Error
        nil
      end

      # Connect to device
      # When using session, waits for connection and optionally for services to resolve
      # @param wait_for_services [Boolean] Wait for GATT services to be discovered (default: true)
      # @param timeout [Numeric] Connection timeout in seconds (default: 30)
      # @return [Boolean] true on success
      # @raise [ConnectionError] if connection fails
      # @raise [TimeoutError] if connection times out
      def connect(wait_for_services: true, timeout: 30)
        if @session
          # Async path: handles waiting for connection and services
          @session.async_connect(@path, wait_for_services: wait_for_services, timeout: timeout)
        else
          # Legacy synchronous path: just initiates connection
          @device_iface.Connect
          true
        end
      rescue DBus::Error => e
        raise ConnectionError, "Failed to initiate connection: #{e.message}"
      end

      # Disconnect from device
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [Boolean] true on success
      # @raise [ConnectionError] if disconnect fails
      def disconnect(timeout: 5)
        if @session
          # Async path: idempotent disconnect
          @session.async_disconnect(@path, timeout: timeout)
        else
          # Legacy synchronous path
          @device_iface.Disconnect
          true
        end
      rescue DBus::Error => e
        raise ConnectionError, "Failed to disconnect: #{e.message}"
      end

      # Read a property value from the Device1 interface
      # Used by legacy synchronous path only
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
