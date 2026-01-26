# frozen_string_literal: true

require 'dbus'
require_relative 'async_call'
require_relative 'async_introspection'

module RBLE
  module BlueZ
    # Provides async connection operations using AsyncCall + AsyncIntrospection patterns.
    # Use this to perform device connection lifecycle operations without blocking the event loop.
    #
    # This module is part of the v0.4.0 async architecture. It builds on AsyncCall
    # and AsyncIntrospection to provide non-blocking connection operations.
    #
    # Including class must:
    # - Include AsyncCall module (provides async_call method)
    # - Include AsyncIntrospection module (provides async_introspect method)
    # - Have @service attribute pointing to D-Bus service
    #
    # @example
    #   include AsyncCall
    #   include AsyncIntrospection
    #   include AsyncConnectionOperations
    #
    #   async_connect("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
    #   async_disconnect("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
    #   async_start_discovery("/org/bluez/hci0", filter: { transport: 'le' })
    #   async_stop_discovery("/org/bluez/hci0")
    #   value = async_get_property("/org/bluez/hci0", "org.bluez.Adapter1", "Powered")
    #   async_set_property("/org/bluez/hci0", "org.bluez.Adapter1", "Powered", true)
    #
    module AsyncConnectionOperations
      DEVICE_INTERFACE = 'org.bluez.Device1'
      ADAPTER_INTERFACE = 'org.bluez.Adapter1'
      PROPERTIES_INTERFACE = 'org.freedesktop.DBus.Properties'

      # Timeouts from CONTEXT.md
      DEFAULT_CONNECT_TIMEOUT = 30
      DEFAULT_DISCONNECT_TIMEOUT = 5
      DEFAULT_DISCOVERY_TIMEOUT = 10
      DEFAULT_PROPERTY_TIMEOUT = 5

      # Async connect to a BLE device
      #
      # @param device_path [String] D-Bus device path
      # @param wait_for_services [Boolean] Wait for GATT services to be discovered (default: true)
      # @param timeout [Numeric] Timeout in seconds (default: 30)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if connection times out
      # @raise [ConnectionFailed] if connection fails
      # @raise [AdapterNotFoundError] if adapter not ready
      def async_connect(device_path, wait_for_services: true, timeout: DEFAULT_CONNECT_TIMEOUT)
        address = extract_address_from_path(device_path)

        proxy = async_introspect(device_path, timeout: timeout)
        device_iface = proxy[DEVICE_INTERFACE]
        props_iface = proxy[PROPERTIES_INTERFACE]

        # Idempotent: check if already connected
        connected = props_iface.Get(DEVICE_INTERFACE, 'Connected').first
        if connected
          # If waiting for services and not resolved, wait
          if wait_for_services
            services_resolved = props_iface.Get(DEVICE_INTERFACE, 'ServicesResolved').first
            unless services_resolved
              wait_for_services_resolved(props_iface, timeout: timeout)
            end
          end
          return true
        end

        # Setup ServicesResolved watcher BEFORE calling Connect (avoid race per RESEARCH.md)
        services_queue = nil
        if wait_for_services
          services_queue = Thread::Queue.new
          props_iface.on_signal('PropertiesChanged') do |interface, changed, _invalidated|
            next unless interface == DEVICE_INTERFACE
            if changed.key?('ServicesResolved') && changed['ServicesResolved'] == true
              services_queue.push(true)
            end
          end
        end

        begin
          # Call Connect asynchronously
          async_call("Connect(#{address})", timeout: timeout) do |queue, _request_id|
            device_iface.Connect do |reply|
              if reply.is_a?(DBus::Error)
                queue.push([reply, nil])
              else
                queue.push([nil, :ok])
              end
            end
          end

          # Wait for ServicesResolved if requested
          if wait_for_services && services_queue
            # Check if already resolved (race condition protection)
            services_resolved = props_iface.Get(DEVICE_INTERFACE, 'ServicesResolved').first
            unless services_resolved
              result = services_queue.pop(timeout: timeout)
              raise TimeoutError.new('ServicesResolved', timeout) if result.nil?
            end
          end

          true
        ensure
          # Unsubscribe signal handler
          props_iface.on_signal('PropertiesChanged') if wait_for_services
        end
      rescue DBus::Error => e
        translate_connection_error(e, device_path)
      end

      # Async disconnect from a BLE device
      #
      # @param device_path [String] D-Bus device path
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if disconnect times out
      def async_disconnect(device_path, timeout: DEFAULT_DISCONNECT_TIMEOUT)
        address = extract_address_from_path(device_path)

        proxy = async_introspect(device_path, timeout: timeout)
        device_iface = proxy[DEVICE_INTERFACE]
        props_iface = proxy[PROPERTIES_INTERFACE]

        # Idempotent: check if not connected
        connected = props_iface.Get(DEVICE_INTERFACE, 'Connected').first
        return true unless connected

        async_call("Disconnect(#{address})", timeout: timeout) do |queue, _request_id|
          device_iface.Disconnect do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_connection_error(e, device_path)
      end

      # Async start discovery on an adapter
      #
      # @param adapter_path [String] D-Bus adapter path
      # @param filter [Hash] Discovery filter options
      # @option filter [String] :transport Transport type ('auto', 'bredr', 'le')
      # @option filter [Array<String>] :uuids Service UUIDs to filter
      # @option filter [Integer] :rssi Minimum RSSI value
      # @option filter [Integer] :pathloss Maximum path loss
      # @option filter [Boolean] :duplicate_data Report duplicate advertisements
      # @param timeout [Numeric] Timeout in seconds (default: 10)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if operation times out
      # @raise [ScanError] if discovery fails
      # @raise [AdapterNotFoundError] if adapter not ready
      def async_start_discovery(adapter_path, filter: {}, timeout: DEFAULT_DISCOVERY_TIMEOUT)
        proxy = async_introspect(adapter_path, timeout: timeout)
        adapter_iface = proxy[ADAPTER_INTERFACE]
        props_iface = proxy[PROPERTIES_INTERFACE]

        # Idempotent: check if already discovering
        discovering = props_iface.Get(ADAPTER_INTERFACE, 'Discovering').first
        return true if discovering

        # Set discovery filter first if any options provided
        unless filter.empty?
          async_set_discovery_filter(adapter_path, adapter_iface, filter, timeout: timeout)
        end

        async_call("StartDiscovery(#{adapter_path})", timeout: timeout) do |queue, _request_id|
          adapter_iface.StartDiscovery do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_discovery_error(e, adapter_path)
      end

      # Async stop discovery on an adapter
      #
      # @param adapter_path [String] D-Bus adapter path
      # @param timeout [Numeric] Timeout in seconds (default: 10)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if operation times out
      def async_stop_discovery(adapter_path, timeout: DEFAULT_DISCOVERY_TIMEOUT)
        proxy = async_introspect(adapter_path, timeout: timeout)
        adapter_iface = proxy[ADAPTER_INTERFACE]
        props_iface = proxy[PROPERTIES_INTERFACE]

        # Idempotent: check if not discovering
        discovering = props_iface.Get(ADAPTER_INTERFACE, 'Discovering').first
        return true unless discovering

        async_call("StopDiscovery(#{adapter_path})", timeout: timeout) do |queue, _request_id|
          adapter_iface.StopDiscovery do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_discovery_error(e, adapter_path)
      end

      # Async get any D-Bus property value
      #
      # @param object_path [String] D-Bus object path
      # @param interface [String] D-Bus interface name
      # @param property [String] Property name
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [Object] Property value (unwrapped from variant)
      # @raise [TimeoutError] if operation times out
      def async_get_property(object_path, interface, property, timeout: DEFAULT_PROPERTY_TIMEOUT)
        proxy = async_introspect(object_path, timeout: timeout)
        props_iface = proxy[PROPERTIES_INTERFACE]

        result = async_call("Get(#{interface}.#{property})", timeout: timeout) do |queue, _request_id|
          props_iface.Get(interface, property) do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, reply])
            end
          end
        end

        # D-Bus Properties.Get returns [value]
        result&.first
      rescue DBus::Error => e
        raise TimeoutError.new("Get #{interface}.#{property}", timeout) if e.message.include?('timeout')
        raise e
      end

      # Async set any writable D-Bus property
      #
      # @param object_path [String] D-Bus object path
      # @param interface [String] D-Bus interface name
      # @param property [String] Property name
      # @param value [Object] Value to set
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if operation times out
      def async_set_property(object_path, interface, property, value, timeout: DEFAULT_PROPERTY_TIMEOUT)
        proxy = async_introspect(object_path, timeout: timeout)
        props_iface = proxy[PROPERTIES_INTERFACE]

        # Wrap value in DBus::Data::Variant with inferred type
        variant_value = create_variant(value)

        async_call("Set(#{interface}.#{property})", timeout: timeout) do |queue, _request_id|
          props_iface.Set(interface, property, variant_value) do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        true
      rescue DBus::Error => e
        raise TimeoutError.new("Set #{interface}.#{property}", timeout) if e.message.include?('timeout')
        raise e
      end

      private

      # Wait for ServicesResolved property to become true
      def wait_for_services_resolved(props_iface, timeout:)
        queue = Thread::Queue.new

        props_iface.on_signal('PropertiesChanged') do |interface, changed, _invalidated|
          next unless interface == DEVICE_INTERFACE
          if changed.key?('ServicesResolved') && changed['ServicesResolved'] == true
            queue.push(true)
          end
        end

        begin
          result = queue.pop(timeout: timeout)
          raise TimeoutError.new('ServicesResolved', timeout) if result.nil?
        ensure
          props_iface.on_signal('PropertiesChanged')
        end
      end

      # Set discovery filter with correct D-Bus variant types
      def async_set_discovery_filter(adapter_path, adapter_iface, options, timeout:)
        filter = {}

        # Transport: STRING
        if options[:transport]
          filter['Transport'] = DBus::Data::Variant.new(
            options[:transport].to_s,
            member_type: DBus::Type::STRING
          )
        end

        # UUIDs: Array[STRING]
        if options[:uuids] && !options[:uuids].empty?
          filter['UUIDs'] = DBus::Data::Variant.new(
            options[:uuids],
            member_type: DBus::Type::Array[DBus::Type::STRING]
          )
        end

        # RSSI: INT16
        if options[:rssi]
          filter['RSSI'] = DBus::Data::Variant.new(
            options[:rssi].to_i,
            member_type: DBus::Type::INT16
          )
        end

        # Pathloss: UINT16
        if options[:pathloss]
          filter['Pathloss'] = DBus::Data::Variant.new(
            options[:pathloss].to_i,
            member_type: DBus::Type::UINT16
          )
        end

        # DuplicateData: BOOLEAN
        if options.key?(:duplicate_data)
          filter['DuplicateData'] = DBus::Data::Variant.new(
            !!options[:duplicate_data],
            member_type: DBus::Type::BOOLEAN
          )
        end

        async_call("SetDiscoveryFilter(#{adapter_path})", timeout: timeout) do |queue, _request_id|
          adapter_iface.SetDiscoveryFilter(filter) do |reply|
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end
      end

      # Create DBus::Data::Variant with inferred type
      def create_variant(value)
        type = case value
               when TrueClass, FalseClass then DBus::Type::BOOLEAN
               when Integer then DBus::Type::INT32
               when Float then DBus::Type::DOUBLE
               when String then DBus::Type::STRING
               when Array then DBus::Type::Array[DBus::Type::STRING]
               else DBus::Type::VARIANT
               end

        DBus::Data::Variant.new(value, member_type: type)
      end

      # Translate D-Bus errors to RBLE errors for connection operations
      def translate_connection_error(error, device_path)
        address = extract_address_from_path(device_path)

        case error.name
        when 'org.bluez.Error.AlreadyConnected'
          raise AlreadyConnectedError
        when 'org.bluez.Error.NotConnected'
          raise NotConnectedError
        when 'org.bluez.Error.Failed'
          # Parse message for more context
          if error.message.include?('le-connection-abort') ||
             error.message.include?('Software caused connection abort') ||
             error.message.include?('br-connection-abort')
            raise ConnectionFailed.new(address, 'connection aborted')
          elsif error.message.include?('Host is down')
            raise ConnectionFailed.new(address, 'device not reachable (out of range?)')
          else
            raise ConnectionFailed.new(address, error.message)
          end
        when 'org.bluez.Error.NotReady'
          raise AdapterNotFoundError, 'Bluetooth adapter not ready'
        when 'org.bluez.Error.InProgress'
          raise ConnectionError, "Connection already in progress for #{address}"
        when 'org.freedesktop.DBus.Error.UnknownObject'
          raise DeviceNotFoundError.new(address)
        else
          raise ConnectionError, "Connection failed: #{error.message} (#{error.name})"
        end
      end

      # Translate D-Bus errors to RBLE errors for discovery operations
      def translate_discovery_error(error, adapter_path)
        adapter_name = adapter_path.split('/').last

        case error.name
        when 'org.bluez.Error.NotReady'
          raise AdapterNotFoundError, "Adapter #{adapter_name} not ready"
        when 'org.bluez.Error.Failed'
          raise ScanError, "Discovery failed on #{adapter_name}: #{error.message}"
        when 'org.bluez.Error.InProgress'
          raise ScanInProgressError
        when 'org.bluez.Error.NotAuthorized'
          raise PermissionError, "Discovery on #{adapter_name}"
        when 'org.bluez.Error.NotSupported'
          raise ScanError, "Discovery filter not supported: #{error.message}"
        else
          raise ScanError, "Discovery error: #{error.message} (#{error.name})"
        end
      end

      # Extract MAC address from device path
      # Path format: /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      def extract_address_from_path(path)
        segments = path.split('/')
        dev_segment = segments.find { |s| s.start_with?('dev_') }
        return path unless dev_segment

        # Convert dev_AA_BB_CC_DD_EE_FF to AA:BB:CC:DD:EE:FF
        dev_segment.sub('dev_', '').tr('_', ':')
      end
    end
  end
end
