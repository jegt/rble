# frozen_string_literal: true

require_relative '../bluez'

module RBLE
  module Backend
    # BlueZ D-Bus backend for Linux BLE operations
    class BlueZ < Base
      def initialize
        @connection = nil
        @adapter = nil
        @event_loop = nil
        @scanning = false
        @scan_callback = nil
        @known_devices = {} # path => Device
        @allow_duplicates = false
        @signal_handlers = []

        # Connection tracking
        @connected_devices = {}  # device_path => BlueZ::Device
        @device_services = {}    # device_path => [Service, ...]

        # Subscription tracking for notifications
        @subscriptions = {} # char_path => { callback:, wrapper: }

        # Connection object tracking for disconnect notifications
        @connection_objects = {} # device_path => Connection instance

        # Monitoring infrastructure for disconnect detection
        @monitoring_loop = nil
        @monitoring_mutex = Mutex.new

        # Thread safety: protects shared state accessed from multiple threads
        # (D-Bus signal handlers run on rble-dbus-loop thread, user code on main thread)
        @state_mutex = Mutex.new
      end

      # Start scanning for BLE devices
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs
      # @param allow_duplicates [Boolean] Callback on every advertisement
      # @param adapter [String, nil] Adapter name (e.g., "hci0")
      # @yield [Device] Called when device discovered/updated
      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, &block)
        @state_mutex.synchronize do
          raise ScanInProgressError if @scanning
          @scanning = true
        end
        raise ArgumentError, 'Block required for scan callback' unless block_given?

        @scan_callback = block
        @allow_duplicates = allow_duplicates
        @state_mutex.synchronize { @known_devices.clear }

        begin
          setup_connection
          setup_adapter(adapter)
          setup_signal_handlers
          start_discovery(service_uuids: service_uuids, allow_duplicates: allow_duplicates)

          # Process existing devices (already discovered before scan started)
          process_existing_devices

          # Start event processing
          @event_loop.start(@connection.bus)
        rescue StandardError
          cleanup
          raise
        end
      end

      # Stop current scan
      def stop_scan
        @state_mutex.synchronize { return unless @scanning }

        begin
          @adapter&.stop_discovery
        rescue StandardError
          # Ignore errors during cleanup
        end

        cleanup
      end

      # Check if scanning
      # @return [Boolean]
      def scanning?
        @state_mutex.synchronize { @scanning }
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
            powered: props['Powered']
          }
        end
      rescue StandardError => e
        raise Error, "Failed to list adapters: #{e.message}"
      ensure
        conn&.disconnect
      end

      # Process events (blocking) - call this to receive callbacks
      # @param timeout [Numeric, nil] Timeout in seconds
      # @return [Boolean] true if shutdown, false if timeout
      def process_events(timeout: nil)
        return false unless @scanning

        @event_loop.process_events(timeout: timeout) do |event|
          handle_event(event)
        end
      end

      # Connect to a BLE device
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

        # Create BlueZ::Device wrapper
        conn = ensure_connection
        device = RBLE::BlueZ::Device.new(conn, device_path)

        # Check if already connected at BlueZ level
        if device.connected?
          @state_mutex.synchronize { @connected_devices[device_path] = device }
          return true
        end

        # Setup event loop for connection state tracking
        event_loop = setup_connection_event_loop(conn, device_path)

        begin
          # Initiate connection (async D-Bus call)
          device.connect

          # Wait for Connected = true via PropertiesChanged
          wait_for_property(event_loop, device_path, 'Connected', true, timeout)

          # Store connected device (thread-safe)
          @state_mutex.synchronize { @connected_devices[device_path] = device }
          true
        rescue ConnectionTimeoutError
          # Cleanup on timeout
          cleanup_connection_event_loop(event_loop)
          raise
        rescue DBus::Error => e
          cleanup_connection_event_loop(event_loop)
          raise ConnectionError, "Failed to connect: #{e.message}"
        ensure
          # Stop the event loop if still running
          cleanup_connection_event_loop(event_loop)
        end
      end

      # Disconnect from a BLE device
      # @param device_path [String] D-Bus device path
      # @return [void]
      def disconnect_device(device_path)
        device = @state_mutex.synchronize do
          dev = @connected_devices.delete(device_path)
          @device_services.delete(device_path)
          dev
        end
        return unless device

        # Unregister connection for disconnect monitoring
        unregister_connection(device_path)

        begin
          # Disconnect (no need to wait for confirmation - fire and forget)
          device.disconnect
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
        setup_disconnect_monitoring(device_path, connection)
      end

      # Unregister a Connection from disconnect monitoring
      # @param device_path [String] D-Bus device path
      # @return [void]
      def unregister_connection(device_path)
        @state_mutex.synchronize { @connection_objects.delete(device_path) }
        # Signal handler cleanup happens automatically when device object is GC'd
      end

      # Discover GATT services on a connected device
      # @param device_path [String] D-Bus device path
      # @param timeout [Numeric] Discovery timeout in seconds (default: 30)
      # @return [Array<Service>] Discovered services with characteristics
      # @raise [NotConnectedError] if device is not connected
      # @raise [ServiceDiscoveryError] if discovery fails
      def discover_services(device_path, timeout: 30)
        device, cached_services = @state_mutex.synchronize do
          [@connected_devices[device_path], @device_services[device_path]]
        end
        raise NotConnectedError unless device

        # Return cached services if available
        return cached_services if cached_services

        # Check if services already resolved
        unless device.services_resolved?
          # Setup event loop for waiting on ServicesResolved
          conn = ensure_connection
          event_loop = setup_connection_event_loop(conn, device_path)

          begin
            wait_for_property(event_loop, device_path, 'ServicesResolved', true, timeout)
          rescue ConnectionTimeoutError
            cleanup_connection_event_loop(event_loop)
            raise ServiceDiscoveryError, "Service discovery timed out after #{timeout} seconds"
          ensure
            cleanup_connection_event_loop(event_loop)
          end
        end

        # Enumerate services and characteristics
        services = enumerate_services(device_path)
        @state_mutex.synchronize { @device_services[device_path] = services }
        services
      end

      # Get the device D-Bus path for a given MAC address
      # @param address [String] Device MAC address (e.g., "AA:BB:CC:DD:EE:FF")
      # @param adapter [String, nil] Specific adapter name (e.g., "hci0")
      # @return [String, nil] Device path or nil if not found
      def device_path_for_address(address, adapter: nil)
        conn = ensure_connection
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
      end

      # Read a characteristic value
      # @param char_path [String] D-Bus characteristic path
      # @param timeout [Numeric] Read timeout in seconds (currently unused - D-Bus handles timeout)
      # @return [String] Binary string (ASCII-8BIT encoding)
      # @raise [NotConnectedError] if device is not connected
      # @raise [ReadError] if read fails
      def read_characteristic(char_path, timeout: 30) # rubocop:disable Lint/UnusedMethodArgument
        # Check connection before attempting read (thread-safe)
        device_path = extract_device_path(char_path)
        connected = @state_mutex.synchronize { device_path && @connected_devices.key?(device_path) }
        raise NotConnectedError unless connected

        conn = ensure_connection
        wrapper = RBLE::BlueZ::GattCharacteristic.new(conn, char_path)

        # Read value with empty options
        result = wrapper.read_value({})

        # Convert byte array to binary string
        result.map(&:to_i).pack('C*')
      rescue DBus::Error => e
        # Check if disconnect related - handle unexpected disconnect
        if e.name == 'org.bluez.Error.NotConnected'
          handle_unexpected_disconnect(device_path) if device_path
          raise NotConnectedError
        end
        raise ReadError, translate_dbus_error(e)
      end

      # Write a value to a characteristic
      # @param char_path [String] D-Bus characteristic path
      # @param data [String, Array<Integer>] Data to write
      # @param response [Boolean] Wait for write response (true = 'request', false = 'command')
      # @param timeout [Numeric] Write timeout in seconds (currently unused - D-Bus handles timeout)
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      # @raise [WriteError] if write fails
      def write_characteristic(char_path, data, response: true, timeout: 30) # rubocop:disable Lint/UnusedMethodArgument
        # Check connection before attempting write (thread-safe)
        device_path = extract_device_path(char_path)
        connected = @state_mutex.synchronize { device_path && @connected_devices.key?(device_path) }
        raise NotConnectedError unless connected

        conn = ensure_connection
        wrapper = RBLE::BlueZ::GattCharacteristic.new(conn, char_path)

        # Convert string to bytes array if needed
        bytes = data.is_a?(String) ? data.bytes : data

        # Build options with type variant
        # 'request' = write with response (default), 'command' = write without response
        type_value = response ? 'request' : 'command'
        options = {
          'type' => DBus::Data::Variant.new(type_value, member_type: DBus::Type::STRING)
        }

        wrapper.write_value(bytes, options)
        true
      rescue DBus::Error => e
        # Check if disconnect related - handle unexpected disconnect
        if e.name == 'org.bluez.Error.NotConnected'
          handle_unexpected_disconnect(device_path) if device_path
          raise NotConnectedError
        end
        raise WriteError, translate_dbus_error(e)
      end

      # Subscribe to characteristic notifications
      # @param char_path [String] D-Bus characteristic path
      # @yield [String] Called with value (binary string) on each notification
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      # @raise [NotifyError] if subscription fails
      def subscribe_characteristic(char_path, &callback)
        # Check connection and subscription state (thread-safe)
        device_path = extract_device_path(char_path)
        already_subscribed, connected = @state_mutex.synchronize do
          [@subscriptions.key?(char_path), device_path && @connected_devices.key?(device_path)]
        end

        # Already subscribed - return early
        return true if already_subscribed

        raise NotConnectedError unless connected

        conn = ensure_connection
        wrapper = RBLE::BlueZ::GattCharacteristic.new(conn, char_path)

        # Start notifications - BlueZ handles CCCD automatically
        wrapper.start_notify

        # Subscribe to PropertiesChanged signal for value updates
        wrapper.on_properties_changed do |interface, changed, _invalidated|
          next unless interface == RBLE::BlueZ::GATT_CHARACTERISTIC_INTERFACE
          next unless changed.key?('Value')

          # Convert value bytes to binary string
          value = changed['Value'].map(&:to_i).pack('C*')

          # Enqueue to event loop for thread-safe callback dispatch
          # Note: We need an active event loop for this to work
          @event_loop&.enqueue(:notification, char_path, { value: value, callback: callback })
        end

        # Store subscription for tracking (thread-safe)
        @state_mutex.synchronize do
          @subscriptions[char_path] = { callback: callback, wrapper: wrapper }
        end
        true
      rescue DBus::Error => e
        # Check if disconnect related - handle unexpected disconnect
        if e.name == 'org.bluez.Error.NotConnected'
          handle_unexpected_disconnect(device_path) if device_path
          raise NotConnectedError
        end
        raise NotifyError, translate_dbus_error(e)
      end

      # Unsubscribe from characteristic notifications
      # @param char_path [String] D-Bus characteristic path
      # @return [Boolean] true on success
      # @raise [NotConnectedError] if device is not connected
      def unsubscribe_characteristic(char_path)
        device_path = extract_device_path(char_path)
        subscription, connected = @state_mutex.synchronize do
          sub = @subscriptions.delete(char_path)
          conn = device_path && @connected_devices.key?(device_path)
          [sub, conn]
        end
        return true unless subscription

        # Check connection before attempting unsubscribe
        raise NotConnectedError unless connected

        begin
          subscription[:wrapper].stop_notify
        rescue DBus::Error => e
          # Check if disconnect related - handle unexpected disconnect
          if e.name == 'org.bluez.Error.NotConnected'
            handle_unexpected_disconnect(device_path) if device_path
            raise NotConnectedError
          end
          # Ignore other errors during cleanup
        end

        true
      end

      private

      # Setup PropertiesChanged monitoring for disconnect detection
      # @param device_path [String] D-Bus device path
      # @param connection [Connection] Connection to notify on disconnect
      def setup_disconnect_monitoring(device_path, connection)
        conn = ensure_connection
        device_obj = conn.object(device_path)
        props_iface = device_obj[RBLE::BlueZ::PROPERTIES_INTERFACE]

        # Subscribe to PropertiesChanged for this device
        # The signal handler will be called when any property changes
        props_iface.on_signal('PropertiesChanged') do |interface, changed, _invalidated|
          next unless interface == RBLE::BlueZ::DEVICE_INTERFACE
          next unless changed.key?('Connected')

          if changed['Connected'] == false
            # Device disconnected unexpectedly
            # BlueZ doesn't expose disconnect reason via D-Bus, always use :link_loss
            handle_unexpected_disconnect(device_path)
          end
        end

        # Start monitoring event loop if not already running
        start_monitoring_loop(conn)
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

      # Start the background monitoring event loop for disconnect detection
      # @param conn [DBusConnection] D-Bus connection
      def start_monitoring_loop(conn)
        @monitoring_mutex.synchronize do
          return if @monitoring_loop&.running?

          @monitoring_loop = RBLE::BlueZ::EventLoop.new
          @monitoring_loop.start(conn.bus)
        end
      end

      # Stop the background monitoring event loop
      def stop_monitoring_loop
        @monitoring_mutex.synchronize do
          @monitoring_loop&.stop
          @monitoring_loop = nil
        end
      end

      # Translate D-Bus errors to human-readable messages
      def translate_dbus_error(error)
        case error.name
        when 'org.bluez.Error.Failed'
          'Operation failed'
        when 'org.bluez.Error.InProgress'
          'Another operation in progress'
        when 'org.bluez.Error.NotConnected'
          'Device not connected'
        when 'org.bluez.Error.NotPermitted'
          'Operation not permitted'
        when 'org.bluez.Error.NotAuthorized'
          'Not authorized (may need pairing)'
        when 'org.bluez.Error.NotSupported'
          'Operation not supported by this characteristic'
        when 'org.bluez.Error.InvalidValueLength'
          'Invalid data length for characteristic'
        else
          error.message
        end
      end

      def setup_connection
        @connection = RBLE::BlueZ::DBusConnection.new
        @connection.connect
      end

      def setup_adapter(adapter_name)
        adapter_path = if adapter_name
                         "/org/bluez/#{adapter_name}"
                       else
                         # Find first available adapter
                         om = @connection.object_manager
                         managed = om.GetManagedObjects.first
                         adapter_entry = managed.find { |_path, ifaces| ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
                         raise AdapterNotFoundError unless adapter_entry

                         adapter_entry.first
                       end

        @adapter = RBLE::BlueZ::Adapter.new(@connection, adapter_path)
        raise AdapterDisabledError, @adapter.name unless @adapter.powered?
      end

      def setup_signal_handlers
        @event_loop = RBLE::BlueZ::EventLoop.new

        # Subscribe to InterfacesAdded for new device discovery
        root = @connection.root_object
        object_manager = root[RBLE::BlueZ::OBJECT_MANAGER_INTERFACE]

        object_manager.on_signal('InterfacesAdded') do |path, interfaces|
          # Capture @event_loop to prevent race with cleanup setting it to nil
          event_loop = @event_loop
          if interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE) && event_loop
            event_loop.enqueue(:device_found, path, interfaces[RBLE::BlueZ::DEVICE_INTERFACE])
          end
        end
        @signal_handlers << [:interfaces_added, object_manager]

        object_manager.on_signal('InterfacesRemoved') do |path, interfaces|
          # Capture @event_loop to prevent race with cleanup setting it to nil
          event_loop = @event_loop
          if interfaces.include?(RBLE::BlueZ::DEVICE_INTERFACE) && event_loop
            event_loop.enqueue(:device_removed, path, nil)
          end
        end
        @signal_handlers << [:interfaces_removed, object_manager]
      end

      def subscribe_to_device_properties(device_path)
        device_obj = @connection.object(device_path)
        props_iface = device_obj[RBLE::BlueZ::PROPERTIES_INTERFACE]

        props_iface.on_signal('PropertiesChanged') do |interface, changed, _invalidated|
          # Capture @event_loop to prevent race with cleanup setting it to nil
          event_loop = @event_loop
          if interface == RBLE::BlueZ::DEVICE_INTERFACE && event_loop
            event_loop.enqueue(:properties_changed, device_path, changed)
          end
        end
        @signal_handlers << [:properties_changed, props_iface, device_path]
      rescue StandardError
        # Device may have disappeared, ignore
      end

      def start_discovery(service_uuids:, allow_duplicates:)
        @adapter.set_discovery_filter(
          service_uuids: service_uuids,
          allow_duplicates: allow_duplicates
        )
        @adapter.start_discovery
      end

      def process_existing_devices
        om = @connection.object_manager
        managed = om.GetManagedObjects.first

        managed.each do |path, interfaces|
          next unless interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)
          next unless path.start_with?(@adapter.path)

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
        return unless path.start_with?(@adapter.path)

        device = build_device(path, properties)

        # Thread-safe check-then-act for known_devices
        is_new = @state_mutex.synchronize do
          new_device = !@known_devices.key?(path)
          @known_devices[path] = device
          new_device
        end

        # Subscribe to property changes for this device (only if monitoring updates)
        # Skip subscription when not needed - on_signal makes synchronous D-Bus calls
        # that can block/deadlock when called from within the event loop
        subscribe_to_device_properties(path) if is_new && @allow_duplicates

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

      def cleanup
        # Stop event loop first (before clearing state it might access)
        @event_loop&.stop
        @event_loop = nil
        stop_monitoring_loop

        # Clear all shared state atomically
        @state_mutex.synchronize do
          @scanning = false
          @known_devices.clear
          @connection_objects.clear
          @connected_devices.clear
          @device_services.clear
          @subscriptions.clear
        end

        @signal_handlers.clear
        @connection&.disconnect
        @connection = nil
        @adapter = nil
        @scan_callback = nil
      end

      # Ensure we have a D-Bus connection (reuse if available)
      def ensure_connection
        return @connection if @connection

        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect
        @connection = conn
        conn
      end

      # Setup an event loop for connection state tracking
      def setup_connection_event_loop(conn, device_path)
        event_loop = RBLE::BlueZ::EventLoop.new

        # Subscribe to PropertiesChanged on the device
        device_obj = conn.object(device_path)
        props_iface = device_obj[RBLE::BlueZ::PROPERTIES_INTERFACE]

        props_iface.on_signal('PropertiesChanged') do |interface, changed, _invalidated|
          event_loop.enqueue(:properties_changed, device_path, changed) if interface == RBLE::BlueZ::DEVICE_INTERFACE
        end

        # Start the event loop
        event_loop.start(conn.bus)
        event_loop
      end

      # Cleanup a connection event loop
      def cleanup_connection_event_loop(event_loop)
        event_loop&.stop
      end

      # Wait for a property to change to expected value
      # @param event_loop [EventLoop] Event loop to use
      # @param device_path [String] Device path to watch
      # @param property [String] Property name (e.g., 'Connected', 'ServicesResolved')
      # @param expected_value [Object] Expected property value
      # @param timeout [Numeric] Timeout in seconds
      # @raise [ConnectionTimeoutError] if timeout exceeded
      def wait_for_property(event_loop, device_path, property, expected_value, timeout)
        deadline = Time.now + timeout

        loop do
          remaining = deadline - Time.now
          raise ConnectionTimeoutError, timeout if remaining <= 0

          # Process events with timeout
          shutdown = event_loop.process_events(timeout: [remaining, 0.5].min) do |event|
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

      # Enumerate GATT services and characteristics for a device
      # @param device_path [String] Device path
      # @return [Array<Hash>] Service data with characteristics and their paths
      #   Each hash contains: :uuid, :primary, :characteristics (array of {data:, path:})
      def enumerate_services(device_path)
        conn = ensure_connection
        om = conn.object_manager
        managed = om.GetManagedObjects.first

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

            characteristics << {
              data: Characteristic.new(
                uuid: char_uuid,
                flags: char_flags,
                service_uuid: service_uuid
              ),
              path: char_path
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
