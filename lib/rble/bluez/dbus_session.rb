# frozen_string_literal: true

require_relative 'async_call'
require_relative 'async_introspection'
require_relative 'async_gatt_operations'
require_relative 'async_connection_operations'

module RBLE
  module BlueZ
    # Encapsulates a D-Bus connection and event loop lifecycle for a single BLE session.
    #
    # Each DBusSession provides an isolated D-Bus communication channel with its own
    # event loop. This design eliminates state corruption issues that occur when a
    # shared D-Bus connection is used across multiple operations (scan, connect, notify).
    #
    # Key design decisions:
    # - Composition over inheritance: DBusSession composes DBusConnection + EventLoop
    # - Event loop uses the session's connection.bus
    # - Session tracks its own lifecycle (connected/running state)
    # - Thread::Queue is owned by EventLoop (already implemented there)
    #
    # @example Basic usage
    #   session = RBLE::BlueZ::DBusSession.new
    #   session.connect
    #   session.start_event_loop
    #   # ... use session.bus for D-Bus operations ...
    #   session.disconnect  # stops event loop and closes connection
    #
    class DBusSession
      include AsyncCall
      include AsyncIntrospection
      include AsyncGattOperations
      include AsyncConnectionOperations

      # Create a new DBusSession (not yet connected)
      def initialize
        @connection = nil
        @event_loop = nil
        @mutex = Mutex.new
        @introspection_cache = {}
        @registered_handlers = []  # Array of [proxy_iface, signal_name] tuples
        @pending_queues = []       # Array of Thread::Queue for pending async calls
        @closed = false            # Track closed state for idempotent close
      end

      # Get the D-Bus service
      # Required by AsyncIntrospection module
      # @return [DBus::Service, nil]
      def service
        @mutex.synchronize { @connection&.service }
      end

      # Register a signal handler with tracking for cleanup
      # @param proxy_iface [DBus::ProxyObjectInterface] The interface
      # @param signal_name [String] Signal name (e.g., 'PropertiesChanged')
      # @yield Signal handler block
      # @return [void]
      def register_signal_handler(proxy_iface, signal_name, &block)
        proxy_iface.on_signal(signal_name, &block)
        @registered_handlers << [proxy_iface, signal_name]
      end

      # Check if session is closed
      # @return [Boolean]
      def closed?
        @mutex.synchronize { @closed }
      end

      # Connect to the D-Bus system bus
      # Creates a new DBusConnection and establishes connection to BlueZ
      # @return [void]
      # @raise [PermissionError] if permission denied
      # @raise [Error] if BlueZ service not available
      def connect
        @mutex.synchronize do
          return if @connection&.connected?

          @connection = DBusConnection.new
          @connection.connect
        end
      end

      # Start the event loop in a background thread
      # The event loop processes D-Bus signals and enqueues events for the main thread
      # @return [void]
      # @raise [Error] if not connected
      def start_event_loop
        @mutex.synchronize do
          raise Error, 'Cannot start event loop: not connected' unless @connection&.connected?
          return if @event_loop&.running?

          # Register handlers BEFORE starting event loop — avoids synchronous
          # AddMatch deadlock with the event loop reading the same socket.
          setup_cache_invalidation_handler

          @event_loop = EventLoop.new
          @event_loop.start(@connection.bus)
        end
      end

      # Stop the event loop
      # Waits for the background thread to finish
      # @param timeout [Numeric] Maximum seconds to wait for thread
      # @return [void]
      def stop_event_loop(timeout: 1)
        @mutex.synchronize do
          @event_loop&.stop(timeout: timeout)
        end
      end

      # Close the session (idempotent)
      # Stops event loop, unregisters signal handlers, closes connection
      # Safe teardown order: notify pending -> stop loop -> unregister handlers -> close connection
      # @return [void]
      def close
        @mutex.synchronize do
          return if @closed
          @closed = true

          # Notify pending async callers they won't get results
          @pending_queues.each { |q| q.push([:session_closed, nil]) }
          @pending_queues.clear

          # Stop event loop FIRST (critical - prevents RemoveMatch deadlock)
          @event_loop&.stop(timeout: 1)
          @event_loop = nil

          # NOW safe to unregister signal handlers (no Main loop = no deadlock)
          unregister_signal_handlers

          # Close D-Bus connection last
          @connection&.disconnect
          @connection = nil

          RBLE.logger&.debug('[RBLE] Session closed')
        end
      end

      # Backward compatibility alias
      alias disconnect close

      # Check if connected to D-Bus
      # @return [Boolean]
      def connected?
        @mutex.synchronize { !@closed && (@connection&.connected? || false) }
      end

      # Check if event loop is running
      # @return [Boolean]
      def running?
        @mutex.synchronize { @event_loop&.running? || false }
      end

      # Get the event loop's raw queue for signal-safe direct push
      # Returns nil if no event loop is active
      # Reads @event_loop directly (no mutex) which is safe for reading a single
      # instance variable - used from signal trap context where mutex is unsafe
      # @return [Thread::Queue, nil]
      def event_loop_queue
        @event_loop&.queue
      end

      # Get the D-Bus bus for signal registration
      # @return [DBus::SystemBus, nil]
      def bus
        @mutex.synchronize { @connection&.bus }
      end

      # Get a D-Bus object by path
      # @param path [String] D-Bus object path
      # @return [DBus::ProxyObject]
      # @raise [Error] if not connected
      def object(path)
        conn = @mutex.synchronize { @connection }
        raise Error, 'Not connected' unless conn&.connected?

        conn.object(path)
      end

      # Get the ObjectManager interface
      # @return [DBus::ProxyObjectInterface]
      # @raise [Error] if not connected
      def object_manager
        conn = @mutex.synchronize { @connection }
        raise Error, 'Not connected' unless conn&.connected?

        conn.object_manager
      end

      # Enqueue an event for processing
      # Thread-safe - can be called from D-Bus signal handlers
      # @param type [Symbol] Event type (:device_found, :notification, etc.)
      # @param path [String, nil] D-Bus object path
      # @param data [Hash, nil] Event-specific data
      # @return [void]
      def enqueue(type, path, data)
        event_loop = @mutex.synchronize { @event_loop }
        event_loop&.enqueue(type, path, data)
      end

      # Process events from the queue with a timeout
      # Yields each event to the block until shutdown or timeout
      # @param timeout [Numeric, nil] Timeout in seconds (nil = block forever)
      # @yield [Event] Called for each event
      # @return [Boolean] true if shutdown received, false if timeout
      def process_events(timeout: nil, &block)
        event_loop = @mutex.synchronize { @event_loop }
        return false unless event_loop

        event_loop.process_events(timeout: timeout, &block)
      end

      # Non-blocking drain of all pending events
      # @yield [Event] Called for each event
      # @return [Integer] Number of events processed
      def drain_events(&block)
        event_loop = @mutex.synchronize { @event_loop }
        return 0 unless event_loop

        event_loop.drain_events(&block)
      end

      # Register a signal handler asynchronously (safe while event loop is running).
      #
      # Splits on_signal into two steps:
      # 1. Local handler registration (immediate, no D-Bus I/O)
      # 2. D-Bus AddMatch message (async via event loop)
      #
      # @param proxy_iface [DBus::ProxyObjectInterface] The interface to watch
      # @param signal_name [String] Signal name (e.g., 'PropertiesChanged')
      # @param timeout [Numeric] Timeout for AddMatch acknowledgement
      # @yield [*params] Called when matching signal arrives
      # @return [void]
      def async_register_signal_handler(proxy_iface, signal_name, timeout: 5, &block)
        bus = proxy_iface.object.bus
        mr = DBus::MatchRule.new.from_signal(proxy_iface, signal_name)
        mrs = mr.to_s

        # Step 1: Register handler locally (no D-Bus I/O)
        # Call Connection#add_match directly, bypassing BusConnection's synchronous override
        DBus::Connection.instance_method(:add_match).bind_call(bus, mrs) do |msg|
          block.call(*msg.params)
        end

        # Step 2: Send AddMatch to D-Bus daemon asynchronously
        async_call("AddMatch(#{signal_name})", timeout: timeout) do |queue, _request_id, cancelled|
          msg = DBus::Message.new(DBus::Message::METHOD_CALL)
          msg.path = '/org/freedesktop/DBus'
          msg.interface = 'org.freedesktop.DBus'
          msg.destination = 'org.freedesktop.DBus'
          msg.member = 'AddMatch'
          msg.sender = bus.unique_name
          msg.add_param('s', mrs)

          bus.send_sync_or_async(msg) do |reply|
            next if cancelled[0]
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        @registered_handlers << [proxy_iface, signal_name]
      end

      # Unregister a signal handler asynchronously (safe while event loop is running).
      #
      # @param proxy_iface [DBus::ProxyObjectInterface] The interface
      # @param signal_name [String] Signal name
      # @param timeout [Numeric] Timeout for RemoveMatch acknowledgement
      # @return [void]
      def async_unregister_signal_handler(proxy_iface, signal_name, timeout: 5)
        bus = proxy_iface.object.bus
        mr = DBus::MatchRule.new.from_signal(proxy_iface, signal_name)
        mrs = mr.to_s

        # Step 1: Remove handler locally (no D-Bus I/O)
        DBus::Connection.instance_method(:remove_match).bind_call(bus, mrs)

        # Step 2: Send RemoveMatch to D-Bus daemon asynchronously
        async_call("RemoveMatch(#{signal_name})", timeout: timeout) do |queue, _request_id, cancelled|
          msg = DBus::Message.new(DBus::Message::METHOD_CALL)
          msg.path = '/org/freedesktop/DBus'
          msg.interface = 'org.freedesktop.DBus'
          msg.destination = 'org.freedesktop.DBus'
          msg.member = 'RemoveMatch'
          msg.sender = bus.unique_name
          msg.add_param('s', mrs)

          bus.send_sync_or_async(msg) do |reply|
            next if cancelled[0]
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        @registered_handlers.delete_if { |pi, sn| pi == proxy_iface && sn == signal_name }
      rescue StandardError => e
        RBLE.logger&.debug("[RBLE] async_unregister_signal_handler error: #{e.message}")
      end

      private

      # Setup handler to clear introspection cache when devices are removed
      # Called when event loop starts to ensure stale introspection data is cleared
      # when BlueZ removes devices
      # Must be called within @mutex.synchronize
      def setup_cache_invalidation_handler
        return unless @connection&.connected?

        root = @connection.root_object
        om = root[OBJECT_MANAGER_INTERFACE]

        register_signal_handler(om, 'InterfacesRemoved') do |path, _interfaces|
          # Clear the removed path
          clear_introspection(path)

          # Clear all child paths (e.g., /dev_XX/service0001 when /dev_XX removed)
          @introspection_cache.keys.each do |cached_path|
            clear_introspection(cached_path) if cached_path.start_with?("#{path}/")
          end
        end
      end

      # Unregister all tracked signal handlers
      # Must be called AFTER event loop is stopped to avoid RemoveMatch deadlock
      def unregister_signal_handlers
        @registered_handlers.each do |proxy_iface, signal_name|
          begin
            proxy_iface.on_signal(signal_name)  # No block = unregister
          rescue StandardError => e
            RBLE.logger&.debug("[RBLE] Signal cleanup ignored: #{e.message}")
          end
        end
        @registered_handlers.clear
      end
    end
  end
end
