# frozen_string_literal: true

module RBLE
  module BlueZ
    # Manages D-Bus system bus connection to BlueZ
    class DBusConnection
      attr_reader :bus, :service, :root_object

      def initialize
        @bus = nil
        @service = nil
        @root_object = nil
      end

      # Connect to D-Bus system bus
      # Uses ASystemBus (non-singleton) to avoid state issues when switching between
      # event loop processing (DBus::Main) and synchronous calls (send_sync)
      # @raise [PermissionError] if permission denied
      # @raise [Error] if BlueZ service not available
      def connect
        @bus = DBus::ASystemBus.new
        @service = @bus.service(BLUEZ_SERVICE)

        # Pre-introspect root for ObjectManager (REL-01: before async context)
        # This ensures ObjectManager is available without async introspection
        @root_object = @service.object('/')
        @root_object.introspect
      rescue DBus::Error => e
        if e.message.include?('AccessDenied') || e.message.include?('Permission')
          raise PermissionError.new('connect to D-Bus')
        end
        raise Error, "Failed to connect to BlueZ D-Bus service: #{e.message}"
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
        @root_object = nil
        @service = nil
        @bus = nil
      end
    end
  end
end
