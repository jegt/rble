# frozen_string_literal: true

module RBLE
  module BlueZ
    # @deprecated Use AsyncGattOperations methods on DBusSession instead.
    #   This class uses synchronous D-Bus calls which block the event loop.
    #   In v0.4.0+, use session.async_read_value, session.async_write_value,
    #   session.async_start_notify, and session.async_stop_notify.
    #
    # Wrapper for BlueZ GattCharacteristic1 D-Bus interface (DEPRECATED)
    class GattCharacteristic
      attr_reader :path, :uuid

      def initialize(connection, char_path)
        @connection = connection
        @path = char_path

        @object = connection.object(char_path)
        @char_iface = @object[GATT_CHARACTERISTIC_INTERFACE]
        @props_iface = @object[PROPERTIES_INTERFACE]

        # Cache UUID since it doesn't change
        @uuid = get_property('UUID')
      end

      # @deprecated Use AsyncGattOperations methods on DBusSession instead.
      # Create a GattCharacteristic from a DBusSession
      # @param session [DBusSession] Active D-Bus session
      # @param char_path [String] D-Bus characteristic path
      # @return [GattCharacteristic]
      def self.new_from_session(session, char_path)
        char = allocate
        char.instance_variable_set(:@path, char_path)
        object = session.object(char_path)
        object.introspect
        char.instance_variable_set(:@object, object)
        char.instance_variable_set(:@char_iface, object[GATT_CHARACTERISTIC_INTERFACE])
        char.instance_variable_set(:@props_iface, object[PROPERTIES_INTERFACE])
        char.instance_variable_set(:@uuid, char.send(:get_property, 'UUID'))
        char
      end

      # Get characteristic flags (read, write, notify, etc.)
      def flags
        get_property('Flags')
      end

      # Get service path this characteristic belongs to
      def service_path
        get_property('Service')
      end

      # Check if currently notifying
      def notifying?
        get_property('Notifying')
      end

      # Read the characteristic value
      # @param options [Hash] D-Bus options (e.g., offset)
      # @return [Array<Integer>] byte array
      def read_value(options = {})
        @char_iface.ReadValue(options).first
      end

      # Write a value to the characteristic
      # @param bytes [Array<Integer>] byte array to write
      # @param options [Hash] D-Bus options (type: 'request' or 'command')
      def write_value(bytes, options = {})
        @char_iface.WriteValue(bytes, options)
      end

      # Start notifications (BlueZ handles CCCD automatically)
      def start_notify
        @char_iface.StartNotify
      end

      # Stop notifications
      def stop_notify
        @char_iface.StopNotify
      end

      # Subscribe to property changes (for notification values)
      # @yield [Hash] changed properties
      def on_properties_changed(&)
        @props_iface.on_signal('PropertiesChanged', &)
      end

      def get_property(name)
        @props_iface.Get(GATT_CHARACTERISTIC_INTERFACE, name).first
      end
    end
  end
end
