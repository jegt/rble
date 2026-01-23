# frozen_string_literal: true

module RBLE
  module BlueZ
    # Manages D-Bus system bus connection to BlueZ
    class DBusConnection
      attr_reader :bus, :service

      def initialize
        @bus = nil
        @service = nil
      end

      # Connect to D-Bus system bus
      # Uses ASystemBus (non-singleton) to avoid state issues when switching between
      # event loop processing (DBus::Main) and synchronous calls (send_sync)
      # @raise [PermissionError] if permission denied
      # @raise [Error] if BlueZ service not available
      def connect
        @bus = DBus::ASystemBus.new
        @service = @bus.service(BLUEZ_SERVICE)
      rescue DBus::Error => e
        if e.message.include?('AccessDenied') || e.message.include?('Permission')
          raise PermissionError.new('connect to D-Bus')
        end
        raise Error, "Failed to connect to BlueZ D-Bus service: #{e.message}"
      end

      # Get the root object for ObjectManager interface
      # @return [DBus::ProxyObject]
      def root_object
        obj = @service.object('/')
        obj.introspect
        obj
      end

      # Get object manager interface
      # @return [DBus::ProxyObjectInterface]
      def object_manager
        root_object[OBJECT_MANAGER_INTERFACE]
      end

      # Get a D-Bus object by path
      # @param path [String] D-Bus object path
      # @return [DBus::ProxyObject]
      def object(path)
        obj = @service.object(path)
        obj.introspect
        obj
      end

      # Check if connected
      # @return [Boolean]
      def connected?
        !@bus.nil? && !@service.nil?
      end

      # Disconnect (cleanup)
      def disconnect
        @service = nil
        @bus = nil
      end
    end
  end
end
