# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wrapper for BlueZ GattService1 D-Bus interface
    class GattService
      attr_reader :path, :uuid

      def initialize(connection, service_path)
        @connection = connection
        @path = service_path

        @object = connection.object(service_path)
        @service_iface = @object[GATT_SERVICE_INTERFACE]
        @props_iface = @object[PROPERTIES_INTERFACE]

        # Cache UUID since it doesn't change
        @uuid = get_property('UUID')
      end

      # Is this a primary service?
      def primary?
        get_property('Primary')
      end

      # Get the device path this service belongs to
      def device_path
        get_property('Device')
      end

      def get_property(name)
        @props_iface.Get(GATT_SERVICE_INTERFACE, name).first
      end
    end
  end
end
