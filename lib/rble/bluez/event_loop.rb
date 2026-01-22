# frozen_string_literal: true

module RBLE
  module BlueZ
    # Event types for queue communication
    Event = Data.define(:type, :path, :data) do
      def initialize(type:, path: nil, data: nil)
        super
      end
    end

    # Runs D-Bus main loop in background thread, marshals events via Queue
    class EventLoop
      attr_reader :queue

      def initialize
        @queue = Thread::Queue.new
        @main_loop = nil
        @thread = nil
        @running = false
        @mutex = Mutex.new
      end

      # Start the event loop in a background thread
      # @param bus [DBus::SystemBus] The D-Bus bus to run
      def start(bus)
        @mutex.synchronize do
          return if @running

          @running = true
        end

        @main_loop = DBus::Main.new
        @main_loop << bus

        @thread = Thread.new do
          Thread.current.name = 'rble-dbus-loop'
          begin
            # DBus::Main.run blocks until quit is called
            # Signal handlers registered on the bus will be dispatched
            @main_loop.run
          rescue StandardError => e
            enqueue(:error, nil, { exception: e })
          ensure
            @mutex.synchronize { @running = false }
          end
        end

        # Give the thread a moment to start
        sleep(0.05)
      end

      # Stop the event loop and wait for thread to finish
      # @param timeout [Numeric] Maximum seconds to wait for thread
      def stop(timeout: 5)
        was_running = @mutex.synchronize do
          return unless @running

          @running = false
          true
        end

        return unless was_running

        # Tell DBus::Main to exit its run loop
        @main_loop&.quit

        # Signal any blocked queue readers
        enqueue(:shutdown, nil, nil)

        if @thread&.alive?
          @thread.join(timeout)
          @thread.kill if @thread.alive? # Force kill if still running
        end

        @thread = nil
        @main_loop = nil

        # Drain the queue
        @queue.clear
      end

      # Check if event loop is running
      # @return [Boolean]
      def running?
        @mutex.synchronize { @running }
      end

      # Enqueue an event (called from D-Bus signal handlers)
      # @param type [Symbol] Event type (:device_found, :device_removed, :properties_changed, :error, :shutdown)
      # @param path [String, nil] D-Bus object path
      # @param data [Hash, nil] Event-specific data
      def enqueue(type, path, data)
        @queue.push(Event.new(type: type, path: path, data: data))
      end

      # Process events from the queue with a timeout
      # Yields each event to the block until shutdown or timeout
      # @param timeout [Numeric, nil] Timeout in seconds (nil = block forever)
      # @yield [Event] Called for each event
      # @return [Boolean] true if shutdown received, false if timeout
      def process_events(timeout: nil, &block)
        deadline = timeout ? Time.now + timeout : nil

        loop do
          remaining = deadline ? [deadline - Time.now, 0].max : nil

          begin
            # pop with timeout returns nil on timeout (only in Ruby 3.2+)
            event = if remaining
                      @queue.pop(timeout: remaining)
                    else
                      @queue.pop
                    end
          rescue ThreadError
            # Queue closed
            return true
          end

          return false if event.nil? # Timeout
          return true if event.type == :shutdown

          yield event if block_given?
        end
      end

      # Non-blocking drain of all pending events
      # @yield [Event] Called for each event
      # @return [Integer] Number of events processed
      def drain_events(&block)
        count = 0
        while (event = @queue.pop(true))
          break if event.nil? || event.type == :shutdown

          yield event if block_given?
          count += 1
        end
        count
      rescue ThreadError
        # Queue empty - expected when draining
        count
      end
    end
  end
end
