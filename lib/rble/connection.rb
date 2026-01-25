# frozen_string_literal: true

module RBLE
  # Represents a connection to a BLE device
  #
  # Provides access to GATT services and characteristics for reading,
  # writing, and subscribing to values. Includes a state machine for
  # tracking connection lifecycle and callback support for disconnect
  # notifications.
  #
  # @example Connect and read a characteristic
  #   connection = RBLE.connect(device.address)
  #   connection.discover_services
  #   hr_service = connection.service('180d')
  #   measurement = hr_service.characteristic('2a37')
  #   # Future: value = measurement.read (Plan 04)
  #   connection.disconnect
  #
  # @example Register disconnect callback
  #   connection = RBLE.connect(device.address)
  #   connection.on_disconnect { |reason| puts "Disconnected: #{reason}" }
  #   connection.on_state_change { |old_state, new_state| puts "#{old_state} -> #{new_state}" }
  #
  class Connection
    # Valid state transitions for the connection lifecycle
    # @return [Hash{Symbol => Array<Symbol>}]
    VALID_TRANSITIONS = {
      disconnected: [:connecting],
      connecting: [:connected, :disconnected],
      connected: [:disconnecting, :discovering_services, :disconnected],
      discovering_services: [:connected, :disconnected],
      disconnecting: [:disconnected]
    }.freeze

    attr_reader :address, :device_path, :dbus_session

    # Create a connection (internal - use RBLE.connect)
    # @param address [String] Device MAC address
    # @param device_path [String] D-Bus device path
    # @param backend [Backend::Base] Platform backend instance
    def initialize(address:, device_path:, backend:)
      @address = address
      @device_path = device_path
      @backend = backend
      @services = nil
      @dbus_session = nil

      # State machine infrastructure
      @state = :connecting
      @state_mutex = Mutex.new
      @state_callbacks = []
      @disconnect_callbacks = []

      # Create owned D-Bus session for BlueZ backend
      # Each Connection gets its own D-Bus connection + event loop to avoid
      # state corruption issues when shared connections are used
      setup_dbus_session if bluez_backend?

      # Transition to connected (connection already established by RBLE.connect)
      transition_to(:connected)
    end

    # Get the current connection state
    # @return [Symbol] One of :disconnected, :connecting, :connected, :disconnecting, :discovering_services
    def state
      @state_mutex.synchronize { @state }
    end

    # Check if still connected
    # @return [Boolean]
    def connected?
      state == :connected
    end

    # Register a callback for disconnect events
    # @yield [Symbol] Called with disconnect reason when disconnection occurs
    # @yieldparam reason [Symbol] The disconnect reason (:user_requested, :link_loss, :timeout, etc.)
    # @raise [ArgumentError] if no block given
    # @return [void]
    def on_disconnect(&block)
      raise ArgumentError, 'Block required for on_disconnect' unless block_given?

      @state_mutex.synchronize { @disconnect_callbacks << block }
    end

    # Register a callback for state change events
    # @yield [Symbol, Symbol] Called with (old_state, new_state) on every state transition
    # @yieldparam old_state [Symbol] The previous state
    # @yieldparam new_state [Symbol] The new state
    # @raise [ArgumentError] if no block given
    # @return [void]
    def on_state_change(&block)
      raise ArgumentError, 'Block required for on_state_change' unless block_given?

      @state_mutex.synchronize { @state_callbacks << block }
    end

    # Discover GATT services on the connected device
    # Must be called before accessing services
    #
    # @param timeout [Numeric] Discovery timeout in seconds (default: 30)
    # @return [Array<Service>] Discovered services with ActiveCharacteristic instances
    # @raise [NotConnectedError] if not connected
    # @raise [ServiceDiscoveryError] if discovery fails
    def discover_services(timeout: 30)
      raise NotConnectedError unless connected?

      transition_to(:discovering_services)
      begin
        # Pass self so backend can use our D-Bus session
        raw_services = @backend.discover_services(@device_path, connection: self, timeout: timeout)
        @services = build_services_with_active_characteristics(raw_services)
        transition_to(:connected)
        @services
      rescue StandardError
        # On failure, return to connected state (if not already disconnected)
        transition_to(:connected) if state == :discovering_services
        raise
      end
    end

    # Get all discovered services
    # @return [Array<Service>]
    # @raise [ServiceDiscoveryError] if discover_services not called
    def services
      raise ServiceDiscoveryError, 'Call discover_services first' if @services.nil?

      @services
    end

    # Get list of currently subscribed characteristic UUIDs
    # Useful for debugging and status checking
    # @return [Array<String>] UUIDs of subscribed characteristics (empty if none)
    def active_subscriptions
      return [] unless @backend.respond_to?(:subscriptions_for_connection)

      @backend.subscriptions_for_connection(self).filter_map { |sub| sub[:uuid] }
    end

    # Find a service by UUID
    # Supports both full UUID and short UUID (e.g., "180d")
    #
    # @param uuid [String] Service UUID to find
    # @return [Service]
    # @raise [ServiceNotFoundError] if service not found
    # @raise [ServiceDiscoveryError] if discover_services not called
    def service(uuid)
      normalized = normalize_uuid(uuid)
      found = services.find { |s| s.uuid.downcase == normalized || s.short_uuid == uuid.downcase }
      raise ServiceNotFoundError, uuid unless found

      found
    end

    # Disconnect from the device
    # @return [void]
    def disconnect
      current = state
      return if current == :disconnected || current == :disconnecting

      transition_to(:disconnecting)
      begin
        # Unregister from backend before disconnect to avoid receiving our own disconnect event
        @backend.unregister_connection(@device_path) if @backend.respond_to?(:unregister_connection)
        @backend.disconnect_device(@device_path)
      ensure
        # Destroy D-Bus session (stops event loop, closes connection)
        destroy_dbus_session
        transition_to(:disconnected, reason: :user_requested)
        @services = nil
      end
    end

    # Handle disconnection detected by backend
    # @param reason [Symbol] Disconnect reason (:link_loss, :timeout, :remote_disconnect, etc.)
    # @return [Boolean] true if transition happened, false if already disconnected
    def handle_disconnect(reason)
      return false if state == :disconnected

      # Destroy D-Bus session on unexpected disconnect
      destroy_dbus_session
      transition_to(:disconnected, reason: reason)
      @services = nil
      true
    end

    # Process events from the Connection's event loop
    # Call this to receive notifications from subscribed characteristics
    # @param timeout [Numeric, nil] Timeout in seconds (nil = block forever)
    # @yield [Event] Called for each event (optional - handles notifications automatically)
    # @return [Boolean] true if shutdown received, false if timeout
    def process_events(timeout: nil, &block)
      return false unless @dbus_session

      @dbus_session.process_events(timeout: timeout) do |event|
        handle_connection_event(event)
        block&.call(event)
      end
    end

    # Drain all pending events without blocking
    # @yield [Event] Called for each event (optional)
    # @return [Integer] Number of events processed
    def drain_events(&block)
      return 0 unless @dbus_session

      @dbus_session.drain_events do |event|
        handle_connection_event(event)
        block&.call(event)
      end
    end

    private

    # Handle events from the Connection's event loop
    # @param event [Event] Event to handle
    def handle_connection_event(event)
      case event.type
      when :notification
        # Notification events contain callback and value
        data = event.data
        if data.is_a?(Hash) && data[:callback]
          data[:callback].call(data[:value])
        end
      end
    end

    # Build Service objects with ActiveCharacteristic instances
    # @param raw_services [Array<Hash>] Service data from backend
    # @return [Array<Service>] Services with active characteristics
    def build_services_with_active_characteristics(raw_services)
      raw_services.map do |service_data|
        characteristics = service_data[:characteristics].map do |char_info|
          ActiveCharacteristic.new(
            characteristic: char_info[:data],
            path: char_info[:path],
            connection: self,
            backend: @backend
          )
        end

        Service.new(
          uuid: service_data[:uuid],
          primary: service_data[:primary],
          characteristics: characteristics
        )
      end
    end

    # Normalize a short UUID to full 128-bit format
    # @param short_uuid [String] Short or full UUID
    # @return [String] Full 128-bit UUID in lowercase
    def normalize_uuid(short_uuid)
      if short_uuid.length == 4
        "0000#{short_uuid.downcase}-0000-1000-8000-00805f9b34fb"
      else
        short_uuid.downcase
      end
    end

    # Check if using BlueZ backend
    # @return [Boolean]
    def bluez_backend?
      # Use class name check to avoid requiring BlueZ backend when not needed
      @backend.class.name == 'RBLE::Backend::BlueZ'
    end

    # Setup D-Bus session for BlueZ backend
    # Creates a new DBusSession, connects, and starts event loop
    # @return [void]
    # @raise [Error] if session creation fails
    def setup_dbus_session
      @dbus_session = RBLE::BlueZ::DBusSession.new
      @dbus_session.connect
      @dbus_session.start_event_loop
    rescue StandardError => e
      # Clean up partial session on failure
      @dbus_session&.disconnect
      @dbus_session = nil
      raise Error, "Failed to create D-Bus session: #{e.message}"
    end

    # Destroy D-Bus session
    # Stops event loop and closes connection
    # @return [void]
    def destroy_dbus_session
      return unless @dbus_session

      begin
        @dbus_session.disconnect
      rescue StandardError => e
        # Log warning but continue - fire and forget
        warn "[RBLE] Failed to disconnect D-Bus session: #{e.message}"
      ensure
        @dbus_session = nil
      end
    end

    # Transition to a new state, calling callbacks outside the mutex
    # @param new_state [Symbol] The state to transition to
    # @param reason [Symbol, nil] Disconnect reason (only for :disconnected state)
    # @return [Boolean] true if transition succeeded, false if invalid
    def transition_to(new_state, reason: nil)
      old_state = nil
      state_callbacks_copy = []
      disconnect_callbacks_copy = []

      @state_mutex.synchronize do
        return false unless VALID_TRANSITIONS[@state]&.include?(new_state)

        old_state = @state
        @state = new_state

        # Copy callbacks while holding lock
        state_callbacks_copy = @state_callbacks.dup
        disconnect_callbacks_copy = @disconnect_callbacks.dup if new_state == :disconnected
      end

      # Call callbacks outside mutex to prevent deadlocks
      state_callbacks_copy.each do |callback|
        begin
          callback.call(old_state, new_state)
        rescue StandardError => e
          warn "[RBLE] State change callback error: #{e.message}"
        end
      end

      # Call disconnect callbacks if transitioning to disconnected
      if new_state == :disconnected
        disconnect_callbacks_copy.each do |callback|
          begin
            callback.call(reason)
          rescue StandardError => e
            warn "[RBLE] Disconnect callback error: #{e.message}"
          end
        end
      end

      true
    end
  end

  class << self
    # Connect to a BLE device by address
    #
    # @param address [String] Device MAC address (e.g., "AA:BB:CC:DD:EE:FF")
    # @param timeout [Numeric] Connection timeout in seconds (default: 30)
    # @param adapter [String, nil] Bluetooth adapter name (e.g., "hci0")
    # @return [Connection] Connected device handle
    # @raise [ConnectionTimeoutError] if connection times out
    # @raise [ConnectionError] if connection fails
    #
    # @example
    #   conn = RBLE.connect("AA:BB:CC:DD:EE:FF", timeout: 10)
    #   conn.discover_services
    #   # ... use services ...
    #   conn.disconnect
    #
    def connect(address, timeout: 30, adapter: nil)
      backend = Backend.for_platform

      # Convert address to D-Bus path
      device_path = backend.device_path_for_address(address, adapter: adapter)
      raise ConnectionError, "Device '#{address}' not found. Scan for devices first." unless device_path

      # Connect via backend
      backend.connect_device(device_path, timeout: timeout)

      connection = Connection.new(
        address: address,
        device_path: device_path,
        backend: backend
      )

      # Register connection for disconnect monitoring (BlueZ backend)
      backend.register_connection(device_path, connection) if backend.respond_to?(:register_connection)

      connection
    end
  end
end
