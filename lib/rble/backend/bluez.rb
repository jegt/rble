# frozen_string_literal: true

require_relative '../bluez'

module RBLE
  module Backend
    # BlueZ D-Bus backend for Linux BLE operations
    class BlueZ < Base
      def initialize
        # Scan session (temporary D-Bus session for scanning only)
        @scan_session = nil
        @scan_adapter_path = nil # Store adapter path for filtering
        @scanning = false
        @scan_callback = nil
        @known_devices = {} # path => Device
        @allow_duplicates = false
        @signal_handlers = []

        # Connection tracking
        @connected_devices = {}  # device_path => BlueZ::Device
        @device_sessions = {}    # device_path => DBusSession (for async operations)
        @device_services = {}    # device_path => [Service, ...]

        # Subscription tracking for notifications
        @subscriptions = {} # char_path => { callback:, wrapper:, connection: }

        # Connection object tracking for disconnect notifications
        @connection_objects = {} # device_path => Connection instance

        # Thread safety: protects shared state accessed from multiple threads
        # (D-Bus signal handlers run on rble-dbus-loop thread, user code on main thread)
        @state_mutex = Mutex.new

        # Best-effort cleanup on process exit
        at_exit { cleanup_all_connections }
      end

      # Start scanning for BLE devices
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs
      # @param allow_duplicates [Boolean] Callback on every advertisement
      # @param adapter [String, nil] Adapter name (e.g., "hci0")
      # @yield [Device] Called when device discovered/updated
      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, active: true, &block)
        @state_mutex.synchronize do
          raise ScanInProgressError if @scanning
          @scanning = true
        end
        raise ArgumentError, 'Block required for scan callback' unless block_given?

        @scan_callback = block
        @allow_duplicates = allow_duplicates
        # Store normalized service UUIDs for secondary filtering (BlueZ may ignore filter)
        @service_uuid_filter = service_uuids&.map { |uuid| normalize_uuid_for_filter(uuid) }
        @state_mutex.synchronize { @known_devices.clear }

        begin
          # Create temporary D-Bus session for scanning
          # This session will be destroyed when scan stops
          @scan_session = RBLE::BlueZ::DBusSession.new
          @scan_session.connect

          # Setup signal handlers BEFORE starting event loop to avoid blocking
          # on_signal does synchronous AddMatch which blocks if event loop is running
          setup_scan_signal_handlers(@scan_session)

          # Start event loop - async operations need it running to process D-Bus callbacks
          @scan_session.start_event_loop

          # Setup adapter (uses async introspection which needs event loop)
          @scan_adapter_path = setup_adapter_for_scan(@scan_session, adapter)
          start_discovery_on_session(@scan_session, service_uuids: service_uuids, allow_duplicates: allow_duplicates)

          # Process existing devices (already discovered before scan started)
          process_existing_devices_from_session(@scan_session)
        rescue StandardError
          stop_scan_cleanup
          raise
        end
      end

      # Stop current scan
      def stop_scan
        @state_mutex.synchronize { return unless @scanning }

        begin
          # Stop discovery on the scan session's adapter
          if @scan_session && @scan_adapter_path
            adapter = RBLE::BlueZ::Adapter.new_from_session(@scan_session, @scan_adapter_path)
            adapter.stop_discovery
          end
        rescue StandardError => e
          RBLE.logger&.debug("[RBLE] Error during stop_scan cleanup: #{e.class}: #{e.message}")
        end

        # Destroy the temporary scan session - this connection is never reused
        stop_scan_cleanup
      end

      # Check if scanning
      # @return [Boolean]
      def scanning?
        @state_mutex.synchronize { @scanning }
      end

      # Get the scan session's event queue for signal-safe direct push
      # @return [Thread::Queue, nil]
      def scan_event_queue
        @scan_session&.event_loop_queue
      end

      # List available adapters
      # @return [Array<Hash>]
      def adapters
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect

        om = conn.object_manager
        managed = om.GetManagedObjects.first

        adapters = managed.select { |_path, ifaces| ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
        adapters.map do |path, ifaces|
          props = ifaces[RBLE::BlueZ::ADAPTER_INTERFACE]
          {
            name: path.split('/').last,
            address: props['Address'],
            powered: props['Powered'],
            discoverable: props['Discoverable'],
            pairable: props['Pairable'],
            alias: props['Alias'],
            discovering: props['Discovering']
          }
        end
      rescue StandardError => e
        raise Error, "Failed to list adapters: #{e.message}"
      ensure
        conn&.disconnect
      end

      # Get the default adapter name
      # @return [String] Adapter name (e.g., "hci0")
      # @raise [AdapterNotFoundError] if no adapter found
      def default_adapter_name
        adapter_list = adapters
        raise AdapterNotFoundError if adapter_list.empty?

        adapter_list.first[:name]
      end

      # Get full info for a single adapter
      # @param adapter_name [String] Adapter name (e.g., "hci0")
      # @return [Hash] Adapter properties
      # @raise [AdapterNotFoundError] if adapter not found
      def adapter_info(adapter_name)
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect

        om = conn.object_manager
        managed = om.GetManagedObjects.first

        adapter_path = "/org/bluez/#{adapter_name}"
        entry = managed.find { |path, ifaces| path == adapter_path && ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
        raise AdapterNotFoundError unless entry

        _path, ifaces = entry
        props = ifaces[RBLE::BlueZ::ADAPTER_INTERFACE]
        {
          name: adapter_name,
          address: props['Address'],
          powered: props['Powered'],
          discoverable: props['Discoverable'],
          pairable: props['Pairable'],
          alias: props['Alias'],
          discovering: props['Discovering']
        }
      rescue AdapterNotFoundError
        raise
      rescue StandardError => e
        raise Error, "Failed to get adapter info: #{e.message}"
      ensure
        conn&.disconnect
      end

      # Set a property on an adapter
      # @param adapter_name [String] Adapter name (e.g., "hci0")
      # @param property [Symbol] Property to set (:powered, :discoverable, :pairable, :alias)
      # @param value [Object] Value to set
      # @return [true]
      # @raise [RBLE::Error] on failure
      def adapter_set_property(adapter_name, property, value)
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        session.start_event_loop

        begin
          adapter_path = "/org/bluez/#{adapter_name}"
          adapter = RBLE::BlueZ::Adapter.new_from_session(session, adapter_path)

          case property
          when :powered
            adapter.set_powered(value)
          when :discoverable
            adapter.set_discoverable(value)
          when :pairable
            adapter.set_pairable(value)
          when :alias
            adapter.set_alias(value)
          else
            raise Error, "Unknown adapter property: #{property}"
          end

          true
        ensure
          session.close
        end
      rescue RBLE::Error
        raise
      rescue StandardError => e
        raise Error, "Failed to set adapter property: #{e.message}"
      end

      # Process events (blocking) - call this to receive callbacks
      # @param timeout [Numeric, nil] Timeout in seconds
      # @return [Boolean] true if shutdown, false if timeout
      def process_events(timeout: nil)
        return false unless @scanning
        return false unless @scan_session

        @scan_session.process_events(timeout: timeout) do |event|
          handle_event(event)
        end
      end

      # Connect to a BLE device
      # Uses a temporary D-Bus connection for the connect operation
      # @param device_path [String] D-Bus device path
      # @param timeout [Numeric] Connection timeout in seconds (default: 30)
      # @return [Boolean] true on successful connection
      # @raise [AlreadyConnectedError] if device is already connected
      # @raise [ConnectionTimeoutError] if connection times out
      # @raise [ConnectionError] on other connection failures
      def connect_device(device_path, timeout: 30)
        # Check if already connected (thread-safe)
        @state_mutex.synchronize do
          raise AlreadyConnectedError if @connected_devices.key?(device_path)
        end

        # Auto-stop scan before connect - BlueZ doesn't handle scan+connect well
        if scanning?
          RBLE.logger&.warn('[RBLE] Stopping scan before connect (BlueZ limitation)')
          stop_scan
        end

        # Create DBusSession for async operations
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        session.start_event_loop

        begin
          # Use async_connect which handles everything without deadlock
          session.async_connect(device_path, wait_for_services: true, timeout: timeout)

          # Create Device from session for later operations
          device = RBLE::BlueZ::Device.new_from_session(session, device_path)

          # Store connected device (thread-safe)
          @state_mutex.synchronize do
            @connected_devices[device_path] = device
            @device_sessions[device_path] = session
          end
          true
        rescue RBLE::TimeoutError => e
          session.stop_event_loop
          session.disconnect
          raise ConnectionTimeoutError.new(timeout)
        rescue DBus::Error => e
          session.stop_event_loop
          session.disconnect
          if e.name == 'org.freedesktop.DBus.Error.UnknownObject'
            address = extract_address_from_path(device_path)
            raise DeviceNotFoundError.new(address)
          end
          raise ConnectionError, "Failed to connect: #{e.message}"
        rescue => e
          session.stop_event_loop
          session.disconnect
          raise
        end
      end

      # Disconnect from a BLE device
      # @param device_path [String] D-Bus device path
      # @return [void]
      def disconnect_device(device_path)
        device, session = @state_mutex.synchronize do
          dev = @connected_devices.delete(device_path)
          sess = @device_sessions.delete(device_path)
          @device_services.delete(device_path)
          @subscriptions.delete_if { |char_path, _| char_path.start_with?(device_path) }
          [dev, sess]
        end
        return unless device

        # Unregister connection for disconnect monitoring
        unregister_connection(device_path)

        begin
          # Use async disconnect if session available
          if session
            session.async_disconnect(device_path, timeout: 5) rescue nil
            session.stop_event_loop rescue nil
            session.disconnect rescue nil
          else
            # Fallback to sync disconnect (legacy path)
            device.disconnect rescue nil
          end
        rescue DBus::Error
          # Ignore errors during cleanup - device may already be disconnected
        end
      end

      # Register a Connection for disconnect monitoring
      # @param device_path [String] D-Bus device path
      # @param connection [Connection] Connection instance to notify on disconnect
      # @return [void]
      def register_connection(device_path, connection)
        @state_mutex.synchronize { @connection_objects[device_path] = connection }
        # Disconnect monitoring is now set up in Connection#setup_dbus_session
        # BEFORE the event loop starts, to avoid blocking on_signal calls
      end

      # Unregister a Connection from disconnect monitoring
      # @param device_path [String] D-Bus device path
      # @return [void]
      def unregister_connection(device_path)
        @state_mutex.synchronize { @connection_objects.delete(device_path) }
        # Signal handler cleanup happens automatically when device object is GC'd
      end

      # Discover GATT services on a connected device
      # Uses the Connection's DBusSession for D-Bus operations
      # @param device_path [String] D-Bus device path
      # @param connection [Connection] Connection instance
      # @param timeout [Numeric] Discovery timeout in seconds (default: 30)
      # @return [Array<Service>] Discovered services with characteristics
      # @raise [NotConnectedError] if device is not connected
      # @raise [ServiceDiscoveryError] if discovery fails
      def discover_services(device_path, connection:, timeout: 30)
        device, cached_services = @state_mutex.synchronize do
          [@connected_devices[device_path], @device_services[device_path]]
        end
        raise NotConnectedError unless device

        # Return cached services if available
        return cached_services if cached_services

        # Use Connection's D-Bus session
        session = connection.dbus_session
        raise NotConnectedError, 'No active D-Bus session' unless session

        # Check if services already resolved
        unless device.services_resolved?
          # Wait for ServicesResolved using the Connection's event loop
          begin
            wait_for_property_on_session(session, device_path, 'ServicesResolved', true, timeout)
          rescue ConnectionTimeoutError
            raise ServiceDiscoveryError, "Service discovery timed out after #{timeout} seconds"
          end
        end

        # Enumerate services and characteristics using Connection's session
        services = enumerate_services_from_session(session, device_path)
        @state_mutex.synchronize { @device_services[device_path] = services }
        services
      end

      # Get the device D-Bus path for a given MAC address
      # Uses a temporary D-Bus connection for the lookup
      # @param address [String] Device MAC address (e.g., "AA:BB:CC:DD:EE:FF")
      # @param adapter [String, nil] Specific adapter name (e.g., "hci0")
      # @return [String, nil] Device path or nil if not found
      def device_path_for_address(address, adapter: nil)
        conn = create_temporary_connection
        om = conn.object_manager
        managed = om.GetManagedObjects.first

        # Normalize address for comparison
        normalized = address.upcase

        # Find device by address
        managed.each do |path, interfaces|
          next unless interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)

          # Filter by adapter if specified
          if adapter
            adapter_path = "/org/bluez/#{adapter}"
            next unless path.start_with?(adapter_path)
          end

          device_props = interfaces[RBLE::BlueZ::DEVICE_INTERFACE]
          device_address = device_props['Address']&.upcase

          return path if device_address == normalized
        end

        nil
      ensure
        conn&.disconnect
      end

      # Read the device name from BlueZ Device1 properties
      # @param device_path [String] D-Bus device path
      # @return [String, nil] Device name or alias, nil if not found
      def device_name(device_path)
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect
        begin
          managed = conn.object_manager.GetManagedObjects.first
          device_ifaces = managed[device_path]
          return nil unless device_ifaces
          device_props = device_ifaces[RBLE::BlueZ::DEVICE_INTERFACE]
          return nil unless device_props
          device_props['Name'] || device_props['Alias']
        ensure
          conn.disconnect
        end
      end

      # Read a characteristic value
      # Uses the Connection's DBusSession for D-Bus operations
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection] Connection that owns this characteristic
      # @param timeout [Numeric] Read timeout in seconds (default: 5)
      # @return [String] Binary string (ASCII-8BIT encoding)
      # @raise [NotConnectedError] if device is not connected
      # @raise [ReadError] if read fails
      # @raise [TimeoutError] if operation times out
      def read_characteristic(char_path, connection:, timeout: 5)
        # Check connection before attempting read (thread-safe)
        device_path = extract_device_path(char_path)
        connected = @state_mutex.synchronize { device_path && @connected_devices.key?(device_path) }
        raise NotConnectedError unless connected

        # Use Connection's D-Bus session with async GATT operation
        session = connection.dbus_session
        raise NotConnectedError, 'No active D-Bus session' unless session

        # Async read - does not block event loop, handles timeout internally
        session.async_read_value(char_path, timeout: timeout)
      rescue NotConnectedError
        # Handle unexpected disconnect
        handle_unexpected_disconnect(device_path) if device_path
        raise
      end

      # Write a value to a characteristic
      # Uses the Connection's DBusSession for D-Bus operations
      # @param char_path [String] D-Bus characteristic path
      # @param data [String, Array<Integer>] Data to write
      # @param connection [Connection] Connection that owns this characteristic
      # @param response [Boolean] Wait for write response (true = 'request', false = 'command')
      # @param timeout [Numeric] Write timeout in seconds (default: 5)
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      # @raise [WriteError] if write fails
      # @raise [TimeoutError] if operation times out
      def write_characteristic(char_path, data, connection:, response: true, timeout: 5)
        # Check connection before attempting write (thread-safe)
        device_path = extract_device_path(char_path)
        connected = @state_mutex.synchronize { device_path && @connected_devices.key?(device_path) }
        raise NotConnectedError unless connected

        # Use Connection's D-Bus session with async GATT operation
        session = connection.dbus_session
        raise NotConnectedError, 'No active D-Bus session' unless session

        # Convert string to bytes array if needed
        bytes = data.is_a?(String) ? data.bytes : data

        # Async write - does not block event loop, handles timeout internally
        session.async_write_value(char_path, bytes, response: response, timeout: timeout)
      rescue NotConnectedError
        # Handle unexpected disconnect
        handle_unexpected_disconnect(device_path) if device_path
        raise
      end

      # Subscribe to characteristic notifications
      # Uses the Connection's DBusSession for D-Bus operations and event delivery
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection] Connection that owns this characteristic
      # @param timeout [Numeric] Timeout for StartNotify call in seconds (default: 5)
      # @yield [String] Called with value (binary string) on each notification
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      # @raise [NotifyError] if subscription fails
      # @raise [TimeoutError] if operation times out
      def subscribe_characteristic(char_path, connection:, timeout: 5, &callback)
        # Check connection and subscription state (thread-safe)
        device_path = extract_device_path(char_path)
        already_subscribed, connected = @state_mutex.synchronize do
          [@subscriptions.key?(char_path), device_path && @connected_devices.key?(device_path)]
        end

        # Already subscribed - return early
        return true if already_subscribed

        raise NotConnectedError unless connected

        # Use Connection's D-Bus session for both GATT operations and event delivery
        session = connection.dbus_session
        raise NotConnectedError, 'No active D-Bus session' unless session

        RBLE.logger&.debug("[RBLE] Subscribing to #{char_path}")

        # Async start notifications - does not block event loop
        # Idempotent: returns true if already notifying (handled by async module)
        session.async_start_notify(char_path, timeout: timeout)

        RBLE.logger&.debug("[RBLE] StartNotify called for #{char_path}")

        # Get introspected proxy for PropertiesChanged signal handler
        # Uses cached introspection from async_start_notify call
        proxy = session.async_introspect(char_path, timeout: timeout)
        props_iface = proxy[RBLE::BlueZ::PROPERTIES_INTERFACE]

        # Validate introspection succeeded - Properties interface must have Get method
        unless props_iface.respond_to?(:Get)
          raise RBLE::Error, "Introspection incomplete for #{char_path}: Properties interface has no Get method. " \
                             "This may indicate corrupted D-Bus introspection data."
        end

        # Get UUID from characteristic properties - use async call to avoid deadlock
        char_uuid = session.async_get_property(
          char_path, RBLE::BlueZ::GATT_CHARACTERISTIC_INTERFACE, 'UUID', timeout: timeout
        )

        # Subscribe to PropertiesChanged signal for value updates
        # Events are enqueued to the Connection's event loop
        # Use async registration to avoid deadlock — on_signal does synchronous
        # AddMatch which blocks if event loop is running on the same connection.
        session.async_register_signal_handler(props_iface, 'PropertiesChanged') do |interface, changed, _invalidated|
          next unless interface == RBLE::BlueZ::GATT_CHARACTERISTIC_INTERFACE
          next unless changed.key?('Value')

          # Convert value bytes to binary string
          value = changed['Value'].map(&:to_i).pack('C*')

          RBLE.logger&.debug("[RBLE] Notification received: #{char_path} (#{value.bytesize} bytes)")
          RBLE.logger&.debug("[RBLE]   Data: #{value.bytes.map { |b| format('%02x', b) }.join(' ')}")

          # Enqueue to Connection's event loop for thread-safe callback dispatch
          # Using Connection's dbus_session ensures notifications are delivered
          # even when scan session is destroyed
          session.enqueue(:notification, char_path, { value: value, callback: callback })
        end

        # Store subscription for tracking (thread-safe)
        # Include connection reference, UUID, and proxy for cleanup
        @state_mutex.synchronize do
          @subscriptions[char_path] = {
            callback: callback,
            proxy: proxy,
            connection: connection,
            uuid: char_uuid
          }
        end

        # Start background notification processing on first subscribe
        connection.ensure_notification_processing

        true
      rescue NotConnectedError
        # Handle unexpected disconnect
        handle_unexpected_disconnect(device_path) if device_path
        raise
      end

      # Get active subscriptions for a connection
      # @param connection [Connection] Connection to query
      # @return [Array<Hash>] Subscription info hashes with :uuid and :path
      def subscriptions_for_connection(connection)
        @state_mutex.synchronize do
          @subscriptions.select { |_path, sub| sub[:connection] == connection }
                        .map do |path, sub|
                          { path: path, uuid: sub[:uuid] }
                        end
        end
      end

      # Unsubscribe from characteristic notifications
      # @param char_path [String] D-Bus characteristic path
      # @param connection [Connection] Connection that owns this subscription
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      def unsubscribe_characteristic(char_path, connection: nil)
        RBLE.logger&.debug("[RBLE] Unsubscribing from #{char_path}")

        device_path = extract_device_path(char_path)
        subscription, connected = @state_mutex.synchronize do
          sub = @subscriptions.delete(char_path)
          conn = device_path && @connected_devices.key?(device_path)
          [sub, conn]
        end
        return true unless subscription

        # Check connection before attempting unsubscribe
        raise NotConnectedError unless connected

        # Use provided connection or fall back to stored one
        conn = connection || subscription[:connection]
        session = conn&.dbus_session
        return true unless session

        begin
          # Async stop notify - does not block event loop
          session.async_stop_notify(char_path, timeout: 5)
          RBLE.logger&.debug("[RBLE] StopNotify called for #{char_path}")
        rescue NotConnectedError
          # Handle unexpected disconnect
          handle_unexpected_disconnect(device_path) if device_path
          raise
        rescue StandardError => e
          RBLE.logger&.debug("[RBLE] Error during unsubscribe cleanup: #{e.class}: #{e.message}")
        end

        true
      end

      # Pair with a BLE device
      #
      # Creates a PairingSession with a dedicated D-Bus bus, exports a PairingAgent,
      # and drives the Pair() call with agent callback processing.
      #
      # @param device_path [String] D-Bus device path
      # @param io_handler [#display, #prompt, #confirm] IO handler for user interaction
      # @param force [Boolean] Skip interactive prompts (auto-accept)
      # @param capability [String, nil] Security capability level ("low", "medium", "high")
      # @param timeout [Numeric] Pairing timeout in seconds
      # @return [Symbol] :paired on success, :already_paired if already paired
      # @raise [RBLE::AuthenticationError] if authentication fails
      # @raise [RBLE::ConnectionFailed] if connection to device fails
      # @raise [RBLE::Error] on other failures
      def pair_device(device_path, io_handler:, force: false, capability: nil, timeout: 30)
        # Check if already paired via D-Bus properties
        if device_already_paired?(device_path)
          return :already_paired
        end

        mapped_capability = RBLE::BlueZ::PairingSession::CAPABILITY_MAP.fetch(
          capability,
          RBLE::BlueZ::PairingSession::CAPABILITY_MAP[nil]
        )

        session = RBLE::BlueZ::PairingSession.new(
          io_handler: io_handler,
          force: force,
          capability: mapped_capability
        )
        session.pair(device_path, timeout: timeout)
      end

      # Remove pairing bond from a device
      #
      # If the device is connected, disconnects first. Uses Adapter1.RemoveDevice
      # to remove the pairing bond. Idempotent: returns :not_paired if device is
      # not known to BlueZ.
      #
      # @param device_path [String] D-Bus device path
      # @return [Symbol] :unpaired on success, :not_paired if not paired
      # @raise [RBLE::Error] on failure
      def unpair_device(device_path)
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect

        begin
          managed = conn.object_manager.GetManagedObjects.first

          # Check if device exists in BlueZ
          device_ifaces = managed[device_path]
          unless device_ifaces && device_ifaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)
            return :not_paired
          end

          # If connected, disconnect first
          device_props = device_ifaces[RBLE::BlueZ::DEVICE_INTERFACE]
          if device_props['Connected']
            begin
              session = RBLE::BlueZ::DBusSession.new
              session.connect
              session.start_event_loop
              session.async_disconnect(device_path, timeout: 5)
            rescue StandardError => e
              RBLE.logger&.debug("[RBLE] Error disconnecting before unpair: #{e.message}")
            ensure
              session&.close
            end
          end

          # Extract adapter path from device path
          # Device path: /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX
          # Adapter path: /org/bluez/hci0
          parts = device_path.split('/')
          dev_index = parts.index { |p| p.start_with?('dev_') }
          adapter_path = parts[0...dev_index].join('/')

          # Call Adapter1.RemoveDevice
          adapter_obj = conn.object(adapter_path)
          adapter_iface = adapter_obj[RBLE::BlueZ::ADAPTER_INTERFACE]
          adapter_iface.RemoveDevice(device_path)

          :unpaired
        ensure
          conn.disconnect
        end
      rescue DBus::Error => e
        if e.name == 'org.bluez.Error.DoesNotExist'
          :not_paired
        else
          raise RBLE::Error, "Failed to unpair device: #{e.message}"
        end
      end

      # List all bonded/paired devices
      #
      # Queries BlueZ via GetManagedObjects and filters for devices that have
      # Bonded == true or Paired == true.
      #
      # @return [Array<Hash>] Sorted array of device info hashes with:
      #   :address, :name, :paired, :bonded, :connected, :trusted, :address_type, :rssi, :icon, :adapter
      # @raise [RBLE::Error] on failure
      def bonded_devices
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect

        begin
          managed = conn.object_manager.GetManagedObjects.first

          devices = []
          managed.each do |path, ifaces|
            next unless ifaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)

            props = ifaces[RBLE::BlueZ::DEVICE_INTERFACE]
            paired = props['Paired'] == true
            bonded = props['Bonded'] == true

            next unless paired || bonded

            # Extract adapter name from path
            parts = path.split('/')
            dev_index = parts.index { |p| p.start_with?('dev_') }
            adapter_name = dev_index ? parts[dev_index - 1] : nil

            devices << {
              address: props['Address'],
              name: props['Name'] || props['Alias'],
              paired: paired,
              bonded: bonded,
              connected: props['Connected'] == true,
              trusted: props['Trusted'] == true,
              address_type: props['AddressType'] || 'public',
              rssi: props['RSSI'],
              icon: props['Icon'],
              adapter: adapter_name
            }
          end

          devices.sort_by { |d| d[:address].to_s }
        ensure
          conn.disconnect
        end
      rescue StandardError => e
        raise RBLE::Error, "Failed to list bonded devices: #{e.message}"
      end

      private

      # Best-effort disconnect of all tracked connections during process exit
      # @return [void]
      def cleanup_all_connections
        connections = @state_mutex.synchronize { @connection_objects.values.dup }
        connections.each do |conn|
          conn.disconnect if conn.connected?
        rescue StandardError
          # best-effort cleanup during exit
        end
      end

      # Check if a device is already paired via D-Bus properties
      # @param device_path [String] D-Bus device path
      # @return [Boolean] true if device is paired
      def device_already_paired?(device_path)
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect
        begin
          managed = conn.object_manager.GetManagedObjects.first
          device_ifaces = managed[device_path]
          return false unless device_ifaces

          props = device_ifaces[RBLE::BlueZ::DEVICE_INTERFACE]
          return false unless props

          props['Paired'] == true
        ensure
          conn.disconnect
        end
      rescue StandardError
        false
      end

      # Extract device path from characteristic path
      # @param char_path [String] Characteristic path
      #   Format: /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX/serviceXXXX/charXXXX
      # @return [String, nil] Device path or nil if not extractable
      def extract_device_path(char_path)
        return nil unless char_path

        # Find the device portion (ends at /service)
        parts = char_path.split('/')
        device_index = parts.index { |p| p.start_with?('dev_') }
        return nil unless device_index

        parts[0..device_index].join('/')
      end

      # Handle unexpected disconnect detected via PropertiesChanged signal
      # @param device_path [String] D-Bus device path
      def handle_unexpected_disconnect(device_path)
        # Get connection and clean up state atomically (thread-safe)
        connection = @state_mutex.synchronize do
          conn = @connection_objects.delete(device_path)
          return unless conn

          # Clean up tracking state
          @connected_devices.delete(device_path)
          @device_services.delete(device_path)

          # Clear any active subscriptions for this device's characteristics
          # Use delete_if to avoid modifying hash during iteration
          @subscriptions.delete_if { |char_path, _| char_path.start_with?(device_path) }

          conn
        end

        # Notify the Connection object with link_loss reason
        # Called OUTSIDE mutex to prevent deadlock if callback accesses backend
        connection.handle_disconnect(:link_loss)
      end

      # Setup adapter for scanning using the given session
      # @param session [DBusSession] D-Bus session to use
      # @param adapter_name [String, nil] Adapter name (e.g., "hci0")
      # @return [String] Adapter path
      def setup_adapter_for_scan(session, adapter_name)
        adapter_path = if adapter_name
                         "/org/bluez/#{adapter_name}"
                       else
                         # Find first available adapter using async call (avoids deadlock)
                         managed = session.async_get_managed_objects(timeout: 10)
                         adapter_entry = managed.find { |_path, ifaces| ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
                         raise AdapterNotFoundError unless adapter_entry

                         adapter_entry.first
                       end

        adapter = RBLE::BlueZ::Adapter.new_from_session(session, adapter_path)
        raise AdapterDisabledError, adapter.name unless adapter.powered?

        adapter_path
      end

      # Setup signal handlers for scanning using the scan session
      # All handlers are registered BEFORE the event loop starts to avoid
      # synchronous AddMatch deadlock with the event loop reading the same socket.
      # @param session [DBusSession] D-Bus session to use
      def setup_scan_signal_handlers(session)
        # Subscribe to InterfacesAdded for new device discovery
        # Use object_manager which returns pre-introspected root (no sync call)
        object_manager = session.object_manager

        object_manager.on_signal('InterfacesAdded') do |path, interfaces|
          # Capture session to prevent race with cleanup setting it to nil
          scan_session = @scan_session
          if interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE) && scan_session
            scan_session.enqueue(:device_found, path, interfaces[RBLE::BlueZ::DEVICE_INTERFACE])
          end
        end
        @signal_handlers << [:interfaces_added, object_manager]

        object_manager.on_signal('InterfacesRemoved') do |path, interfaces|
          # Capture session to prevent race with cleanup setting it to nil
          scan_session = @scan_session
          if interfaces.include?(RBLE::BlueZ::DEVICE_INTERFACE) && scan_session
            scan_session.enqueue(:device_removed, path, nil)
          end
        end
        @signal_handlers << [:interfaces_removed, object_manager]

        # Broad PropertiesChanged for ALL device property updates during scan.
        # A pathless MatchRule matches signals from any BlueZ object path.
        # The handler filters by @scan_adapter_path at dispatch time.
        # Replaces per-device subscribe_to_device_properties_for_scan which called
        # on_signal after the event loop started, causing deadlock.
        mr = DBus::MatchRule.new
        mr.type = 'signal'
        mr.interface = 'org.freedesktop.DBus.Properties'
        mr.member = 'PropertiesChanged'
        bus = session.bus
        bus.add_match(mr) do |msg|
          scan_session = @scan_session
          next unless scan_session
          next unless @scan_adapter_path && msg.path&.start_with?(@scan_adapter_path)

          interface_name = msg.params[0]
          changed = msg.params[1]
          next unless interface_name == RBLE::BlueZ::DEVICE_INTERFACE

          scan_session.enqueue(:properties_changed, msg.path, changed)
        end
        @signal_handlers << [:properties_changed_broad, mr]
      end

      # Start discovery on the scan session's adapter
      # @param session [DBusSession] D-Bus session to use
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs
      # @param allow_duplicates [Boolean] Callback on every advertisement
      def start_discovery_on_session(session, service_uuids:, allow_duplicates:)
        adapter = RBLE::BlueZ::Adapter.new_from_session(session, @scan_adapter_path)
        adapter.set_discovery_filter(
          service_uuids: service_uuids,
          allow_duplicates: allow_duplicates
        )
        adapter.start_discovery
      end

      # Process existing devices from a D-Bus session
      # @param session [DBusSession] D-Bus session to use
      def process_existing_devices_from_session(session)
        # Use async call to avoid deadlock with event loop
        managed = session.async_get_managed_objects(timeout: 10)

        managed.each do |path, interfaces|
          next unless interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)
          next unless path.start_with?(@scan_adapter_path)

          device_props = interfaces[RBLE::BlueZ::DEVICE_INTERFACE]
          handle_device_found(path, device_props)
        end
      end

      def handle_event(event)
        case event.type
        when :device_found
          handle_device_found(event.path, event.data)
        when :device_removed
          handle_device_removed(event.path)
        when :properties_changed
          handle_properties_changed(event.path, event.data)
        when :notification
          handle_notification(event.data)
        when :error
          raise event.data[:exception] if event.data&.key?(:exception)
        end
      end

      def handle_notification(data)
        return unless data.is_a?(Hash)

        callback = data[:callback]
        value = data[:value]
        callback&.call(value)
      end

      def handle_device_found(path, properties)
        return unless @scan_adapter_path && path.start_with?(@scan_adapter_path)

        # Secondary UUID filter verification - BlueZ may ignore the filter in some cases
        # Check if device advertises any of the requested service UUIDs
        if @service_uuid_filter && !@service_uuid_filter.empty?
          device_uuids = (properties['UUIDs'] || []).map { |u| normalize_uuid_for_filter(u) }
          return unless @service_uuid_filter.any? { |filter_uuid| device_uuids.include?(filter_uuid) }
        end

        device = build_device(path, properties)

        # Thread-safe check-then-act for known_devices
        is_new = @state_mutex.synchronize do
          new_device = !@known_devices.key?(path)
          @known_devices[path] = device
          new_device
        end

        # Callback if new device or allow_duplicates
        return unless is_new || @allow_duplicates

        @scan_callback&.call(device)
      end

      def handle_device_removed(path)
        @state_mutex.synchronize { @known_devices.delete(path) }
      end

      def handle_properties_changed(path, changed)
        updates = parse_property_updates(changed)
        return if updates.empty?

        # Thread-safe update of known_devices
        new_device = @state_mutex.synchronize do
          old_device = @known_devices[path]
          return unless old_device

          updated = old_device.update(**updates)
          @known_devices[path] = updated
          updated
        end

        # Callback if allow_duplicates (for RSSI monitoring)
        @scan_callback&.call(new_device) if @allow_duplicates
      end

      def build_device(path, properties)
        Device.new(
          address: properties['Address']&.upcase || extract_address_from_path(path),
          name: properties['Name'],
          rssi: properties['RSSI'],
          manufacturer_data: parse_manufacturer_data(properties['ManufacturerData']),
          manufacturer_data_raw: parse_manufacturer_data_raw(properties['ManufacturerData']),
          service_data: parse_service_data(properties['ServiceData']),
          service_uuids: properties['UUIDs'] || [],
          tx_power: properties['TxPower'],
          address_type: properties['AddressType'] || 'public'
        )
      end

      def parse_property_updates(changed)
        updates = {}
        updates[:name] = changed['Name'] if changed.key?('Name')
        updates[:rssi] = changed['RSSI'] if changed.key?('RSSI')
        updates[:tx_power] = changed['TxPower'] if changed.key?('TxPower')

        if changed.key?('ManufacturerData')
          updates[:manufacturer_data] = parse_manufacturer_data(changed['ManufacturerData'])
          updates[:manufacturer_data_raw] = parse_manufacturer_data_raw(changed['ManufacturerData'])
        end

        updates[:service_data] = parse_service_data(changed['ServiceData']) if changed.key?('ServiceData')

        updates[:service_uuids] = changed['UUIDs'] || [] if changed.key?('UUIDs')

        updates
      end

      # Parse ManufacturerData D-Bus dict (a{qay}) to Hash of byte arrays
      def parse_manufacturer_data(data)
        return {} if data.nil?

        result = {}
        data.each do |company_id, bytes|
          # company_id is uint16, bytes is array of uint8
          result[company_id.to_i] = bytes.map(&:to_i)
        end
        result
      end

      # Parse ManufacturerData to raw binary strings
      def parse_manufacturer_data_raw(data)
        return {} if data.nil?

        result = {}
        data.each do |company_id, bytes|
          result[company_id.to_i] = bytes.map(&:to_i).pack('C*')
        end
        result
      end

      # Parse ServiceData D-Bus dict (a{say}) to Hash of byte arrays
      def parse_service_data(data)
        return {} if data.nil?

        result = {}
        data.each do |uuid, bytes|
          result[uuid.to_s] = bytes.map(&:to_i)
        end
        result
      end

      # Extract MAC address from D-Bus path like /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      def extract_address_from_path(path)
        if path =~ /dev_([0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2})/i
          ::Regexp.last_match(1).tr('_', ':').upcase
        else
          'UNKNOWN'
        end
      end

      # Normalize UUID for filter comparison
      # Converts short UUIDs (e.g., "180d") to full 128-bit format
      # @param uuid [String] UUID in any format
      # @return [String] Lowercase 128-bit UUID
      def normalize_uuid_for_filter(uuid)
        uuid = uuid.to_s.downcase.delete('-')
        if uuid.length == 4
          # Short 16-bit UUID - expand to full 128-bit Bluetooth Base UUID
          "0000#{uuid}-0000-1000-8000-00805f9b34fb"
        elsif uuid.length == 8
          # 32-bit UUID - expand to full 128-bit Bluetooth Base UUID
          "#{uuid}-0000-1000-8000-00805f9b34fb"
        elsif uuid.length == 32
          # Full UUID without hyphens - add hyphens
          "#{uuid[0..7]}-#{uuid[8..11]}-#{uuid[12..15]}-#{uuid[16..19]}-#{uuid[20..31]}"
        else
          # Already formatted
          uuid.downcase
        end
      end

      # Clean up scan-specific state by destroying the temporary scan session
      # After this, the scan D-Bus connection is never reused (fresh session per scan)
      def stop_scan_cleanup
        # Destroy the temporary scan session (stops event loop and closes D-Bus connection)
        # Signal handlers are automatically dropped when the D-Bus connection closes.
        # We don't call unsubscribe_signal_handlers here because remove_match is a
        # synchronous D-Bus call that deadlocks when the event loop is still running.
        @scan_session&.disconnect
        @scan_session = nil
        @scan_adapter_path = nil

        # Clear signal handler tracking (handlers already invalidated by connection close)
        @signal_handlers.clear

        # Clear scan-specific state only
        @state_mutex.synchronize do
          @scanning = false
          @known_devices.clear
        end

        @scan_callback = nil
        @service_uuid_filter = nil
      end

      # Full cleanup - resets all backend state
      # Called on errors or when backend needs to be completely reset
      def cleanup
        # Stop scan session if active
        # Signal handlers are automatically dropped when connection closes
        @scan_session&.disconnect
        @scan_session = nil
        @scan_adapter_path = nil

        # Clear signal handler tracking (handlers already invalidated by connection close)
        @signal_handlers.clear

        # Clear all shared state atomically
        @state_mutex.synchronize do
          @scanning = false
          @known_devices.clear
          @connection_objects.clear
          @connected_devices.clear
          @device_services.clear
          @subscriptions.clear
        end

        @scan_callback = nil
      end

      # Create a temporary D-Bus connection for one-shot operations
      # Used for operations that don't have a Connection context (e.g., connect_device, device_path_for_address)
      # The connection must be disconnected after use
      # @return [DBusConnection] New D-Bus connection
      def create_temporary_connection
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect
        conn
      end

      # Wait for a property to change using a DBusSession
      # @param session [DBusSession] D-Bus session to use
      # @param device_path [String] Device path to watch
      # @param property [String] Property name (e.g., 'Connected', 'ServicesResolved')
      # @param expected_value [Object] Expected property value
      # @param timeout [Numeric] Timeout in seconds
      # @raise [ConnectionTimeoutError] if timeout exceeded
      def wait_for_property_on_session(session, device_path, property, expected_value, timeout)
        # Subscribe to PropertiesChanged on the device
        # Use async_introspect to avoid deadlock (Connection's event loop is running)
        device_obj = session.async_introspect(device_path, timeout: 5)
        props_iface = device_obj[RBLE::BlueZ::PROPERTIES_INTERFACE]

        # Use async registration to avoid deadlock with running event loop
        session.async_register_signal_handler(props_iface, 'PropertiesChanged') do |interface, changed, _invalidated|
          session.enqueue(:properties_changed, device_path, changed) if interface == RBLE::BlueZ::DEVICE_INTERFACE
        end

        deadline = Time.now + timeout

        loop do
          remaining = deadline - Time.now
          raise ConnectionTimeoutError, timeout if remaining <= 0

          # Process events with timeout
          shutdown = session.process_events(timeout: [remaining, 0.5].min) do |event|
            next unless event.type == :properties_changed
            next unless event.path == device_path
            next unless event.data.is_a?(Hash) && event.data.key?(property)

            return true if event.data[property] == expected_value
          end

          # Check if we received shutdown
          break if shutdown
        end

        raise ConnectionTimeoutError, timeout
      end

      # Enumerate GATT services and characteristics for a device using a DBusSession
      # @param session [DBusSession] D-Bus session to use
      # @param device_path [String] Device path
      # @return [Array<Hash>] Service data with characteristics and their paths
      #   Each hash contains: :uuid, :primary, :characteristics (array of {data:, path:})
      def enumerate_services_from_session(session, device_path)
        # Use async call to avoid deadlock with event loop
        managed = session.async_get_managed_objects(timeout: 10)

        # Find all services under this device
        services = []
        service_paths = managed.select do |path, ifaces|
          path.start_with?("#{device_path}/") && ifaces.key?(RBLE::BlueZ::GATT_SERVICE_INTERFACE)
        end

        service_paths.each do |service_path, service_ifaces|
          service_props = service_ifaces[RBLE::BlueZ::GATT_SERVICE_INTERFACE]
          service_uuid = service_props['UUID']
          service_primary = service_props['Primary'] != false

          # Find characteristics for this service
          characteristics = []
          char_paths = managed.select do |path, ifaces|
            path.start_with?("#{service_path}/") && ifaces.key?(RBLE::BlueZ::GATT_CHARACTERISTIC_INTERFACE)
          end

          char_paths.each do |char_path, char_ifaces|
            char_props = char_ifaces[RBLE::BlueZ::GATT_CHARACTERISTIC_INTERFACE]
            char_uuid = char_props['UUID']
            char_flags = char_props['Flags'] || []

            # Enumerate descriptors under this characteristic
            desc_entries = managed.select do |path, ifaces|
              path.start_with?("#{char_path}/") && ifaces.key?(RBLE::BlueZ::GATT_DESCRIPTOR_INTERFACE)
            end

            descriptors = desc_entries.map do |desc_path, desc_ifaces|
              desc_props = desc_ifaces[RBLE::BlueZ::GATT_DESCRIPTOR_INTERFACE]
              { uuid: desc_props['UUID'], path: desc_path }
            end

            characteristics << {
              data: Characteristic.new(
                uuid: char_uuid,
                flags: char_flags,
                service_uuid: service_uuid
              ),
              path: char_path,
              descriptors: descriptors
            }
          end

          services << {
            uuid: service_uuid,
            primary: service_primary,
            characteristics: characteristics
          }
        end

        services
      end

    end
  end
end
