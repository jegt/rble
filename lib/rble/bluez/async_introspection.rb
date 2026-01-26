# frozen_string_literal: true

require 'dbus'
require 'securerandom'
require_relative 'async_call'

module RBLE
  module BlueZ
    # Provides async D-Bus introspection with caching.
    # Use this to introspect D-Bus objects without blocking the event loop.
    #
    # This module builds on AsyncCall to provide async introspection and
    # GetManagedObjects calls. Results are cached for session lifetime.
    #
    # Including class must:
    # - Include AsyncCall module (provides async_call method)
    # - Provide a `service` method returning the D-Bus service
    #
    # @example
    #   include AsyncCall
    #   include AsyncIntrospection
    #
    #   proxy = async_introspect("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
    #   managed = async_get_managed_objects
    #
    module AsyncIntrospection
      INTROSPECTABLE_INTERFACE = 'org.freedesktop.DBus.Introspectable'
      OBJECT_MANAGER_INTERFACE = 'org.freedesktop.DBus.ObjectManager'
      ROOT_PATH = '/'

      # Asynchronously introspect a D-Bus object by path
      #
      # Returns cached ProxyObject if available, otherwise performs async
      # introspection and caches the result.
      #
      # @param path [String] D-Bus object path to introspect
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [DBus::ProxyObject] Introspected proxy object
      # @raise [TimeoutError] if introspection times out
      # @raise [DBus::Error] if D-Bus call fails
      def async_introspect(path, timeout: 5)
        @introspection_cache ||= {}

        # Return cached result if present
        return @introspection_cache[path] if @introspection_cache.key?(path)

        # Perform async introspection
        proxy = perform_async_introspect(path, timeout: timeout)

        # Cache and return
        @introspection_cache[path] = proxy
        proxy
      end

      # Asynchronously get all managed objects from ObjectManager
      #
      # Creates the D-Bus message directly to avoid triggering synchronous
      # introspection when accessing proxy interfaces.
      #
      # @param timeout [Numeric] Timeout in seconds (default: 10)
      # @return [Hash] path => { interface_name => { property => value } }
      # @raise [TimeoutError] if call times out
      # @raise [DBus::Error] if D-Bus call fails
      def async_get_managed_objects(timeout: 10)
        result = async_call('GetManagedObjects', timeout: timeout) do |queue, _request_id, cancelled|
          # Create message directly to avoid sync introspection
          msg = DBus::Message.new(DBus::Message::METHOD_CALL)
          msg.path = ROOT_PATH
          msg.interface = OBJECT_MANAGER_INTERFACE
          msg.destination = service.name
          msg.member = 'GetManagedObjects'
          msg.sender = service.connection.unique_name

          service.connection.send_sync_or_async(msg) do |reply, *params|
            next if cancelled[0]  # Discard late callback
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              # params contains the method return values (first is the Hash)
              queue.push([nil, params.first])
            end
          end
        end

        result
      end

      # Clear cache and re-introspect a path
      #
      # Forces a fresh introspection even if the path is cached.
      #
      # @param path [String] D-Bus object path to refresh
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [DBus::ProxyObject] Fresh introspected proxy object
      # @raise [TimeoutError] if introspection times out
      # @raise [DBus::Error] if D-Bus call fails
      def refresh_introspection(path, timeout: 5)
        @introspection_cache ||= {}

        # Clear cache entry
        @introspection_cache.delete(path)

        # Perform fresh introspection (will be cached by async_introspect)
        async_introspect(path, timeout: timeout)
      end

      # Remove a path from the introspection cache
      #
      # Call this when a device is removed to clean up stale cache entries.
      #
      # @param path [String] D-Bus object path to remove from cache
      # @return [void]
      def clear_introspection(path)
        @introspection_cache ||= {}
        @introspection_cache.delete(path)
      end

      private

      # Perform the actual async introspection
      #
      # Uses connection.introspect_data with a block to avoid triggering
      # synchronous introspection when accessing proxy interfaces.
      #
      # @param path [String] D-Bus object path
      # @param timeout [Numeric] Timeout in seconds
      # @return [DBus::ProxyObject] Introspected proxy object
      def perform_async_introspect(path, timeout:)
        # Create proxy without triggering auto-introspection
        proxy = service.object(path)

        # Use async_call with direct introspect_data call (supports async via block)
        xml = async_call('Introspect', timeout: timeout) do |queue, _request_id, cancelled|
          service.connection.introspect_data(service.name, path) do |xml_result|
            next if cancelled[0]  # Discard late callback
            if xml_result.is_a?(DBus::Error)
              queue.push([xml_result, nil])
            else
              queue.push([nil, xml_result])
            end
          end
        end

        # Parse introspection XML into proxy object
        DBus::ProxyObjectFactory.introspect_into(proxy, xml)

        proxy
      end
    end
  end
end
