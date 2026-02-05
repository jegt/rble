# frozen_string_literal: true

require 'dbus'

module RBLE
  module BlueZ
    # Manages the lifecycle of a PairingAgent during pair/unpair operations.
    #
    # Each PairingSession creates a dedicated D-Bus bus connection, exports a
    # PairingAgent on it, registers the agent with BlueZ's AgentManager1, and
    # drives the Pair() call with a DBus::Main event loop so agent callbacks
    # are processed in the same thread context.
    #
    # The agent MUST be on the SAME bus as RegisterAgent and Pair() calls.
    # A dedicated bus per session avoids conflicts with the shared DBusSession.
    #
    # @example
    #   session = PairingSession.new(io_handler: handler, force: false, capability: "KeyboardDisplay")
    #   result = session.pair("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF", timeout: 30)
    #   # => :paired or :already_paired
    #
    class PairingSession
      CAPABILITY_MAP = {
        'low' => 'NoInputNoOutput',
        'medium' => 'DisplayYesNo',
        'high' => 'KeyboardDisplay',
        nil => 'KeyboardDisplay'
      }.freeze

      # @param io_handler [#display, #prompt, #confirm] IO handler for user interaction
      # @param force [Boolean] Skip interactive prompts (auto-accept)
      # @param capability [String] Agent capability from CAPABILITY_MAP values
      def initialize(io_handler:, force: false, capability: 'KeyboardDisplay')
        @io_handler = io_handler
        @force = force
        @capability = capability
        @bus = nil
        @agent = nil
        @main_loop = nil
      end

      # Pair with a device by exporting an agent and calling Device1.Pair()
      #
      # Creates a dedicated D-Bus bus, exports the PairingAgent, registers it
      # with AgentManager1, then calls Pair() with an event loop to process
      # agent callbacks.
      #
      # @param device_path [String] D-Bus device path (e.g., /org/bluez/hci0/dev_AA_BB_...)
      # @param timeout [Numeric] Timeout in seconds for the pairing operation
      # @return [Symbol] :paired on success, :already_paired if already paired
      # @raise [RBLE::AuthenticationError] if authentication fails
      # @raise [RBLE::ConnectionFailed] if connection to device fails
      # @raise [RBLE::TimeoutError] if pairing times out
      # @raise [RBLE::Error] on other failures
      def pair(device_path, timeout: 30)
        setup_bus_and_agent
        register_agent
        call_pair(device_path, timeout: timeout)
      ensure
        cleanup
      end

      private

      # Create dedicated D-Bus bus and export the agent
      def setup_bus_and_agent
        @bus = DBus::ASystemBus.new
        @agent = PairingAgent.new(io_handler: @io_handler, force: @force)
        @bus.object_server.export(@agent)
      end

      # Register the agent with BlueZ's AgentManager1
      def register_agent
        bluez = @bus.service(BLUEZ_SERVICE)
        bluez_root = bluez.object('/')
        bluez_root.introspect

        agent_manager = bluez_root[AGENT_MANAGER_INTERFACE]
        agent_manager.RegisterAgent(PairingAgent::AGENT_PATH, @capability)
        agent_manager.RequestDefaultAgent(PairingAgent::AGENT_PATH)
      end

      # Call Device1.Pair() with an event loop for agent callback processing
      #
      # Uses a Thread::Queue to communicate the result from the async callback
      # back to the calling thread. DBus::Main runs in a background thread to
      # process agent method invocations from BlueZ.
      #
      # @param device_path [String] D-Bus device path
      # @param timeout [Numeric] Timeout in seconds
      # @return [Symbol] :paired or :already_paired
      def call_pair(device_path, timeout: 30)
        result_queue = Thread::Queue.new

        # Introspect device to get Device1 interface
        device_obj = @bus.service(BLUEZ_SERVICE).object(device_path)
        device_obj.introspect
        device_iface = device_obj[DEVICE_INTERFACE]

        # Start event loop in background thread for agent callbacks
        @main_loop = DBus::Main.new
        @main_loop << @bus

        loop_thread = Thread.new do
          @main_loop.run
        rescue StandardError => e
          RBLE.logger&.debug("[RBLE] PairingSession event loop error: #{e.message}")
        end

        # Call Pair() asynchronously - result delivered via callback
        device_iface.Pair do |reply|
          if reply.is_a?(DBus::Error)
            result_queue.push([:error, reply])
          else
            result_queue.push([:success, nil])
          end
        end

        # Wait for result with timeout
        result = result_queue.pop(timeout: timeout)

        # Stop the event loop
        @main_loop&.quit
        loop_thread&.join(2)

        if result.nil?
          raise RBLE::TimeoutError.new('Pair', timeout)
        end

        status, error = result

        if status == :error
          translate_pair_error(error, device_path)
        else
          :paired
        end
      end

      # Translate D-Bus errors from Pair() into RBLE exceptions
      #
      # @param error [DBus::Error] The D-Bus error
      # @param device_path [String] Device path for error context
      # @return [Symbol] :already_paired if device is already paired
      # @raise [RBLE::AuthenticationError] on auth failures
      # @raise [RBLE::ConnectionFailed] on connection failures
      # @raise [RBLE::Error] on other failures
      def translate_pair_error(error, device_path)
        address = extract_address(device_path)

        case error.name
        when 'org.bluez.Error.AlreadyExists'
          :already_paired
        when 'org.bluez.Error.AuthenticationFailed',
             'org.bluez.Error.AuthenticationCanceled',
             'org.bluez.Error.AuthenticationRejected',
             'org.bluez.Error.AuthenticationTimeout'
          raise RBLE::AuthenticationError.new(address)
        when 'org.bluez.Error.ConnectionAttemptFailed'
          raise RBLE::ConnectionFailed.new(address, 'device not reachable (out of range?)')
        else
          raise RBLE::Error, "Pairing failed for #{address}: #{error.message}"
        end
      end

      # Extract MAC address from D-Bus device path
      # @param device_path [String] D-Bus path like /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      # @return [String] MAC address or 'unknown'
      def extract_address(device_path)
        if device_path =~ /dev_([0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2})/i
          ::Regexp.last_match(1).tr('_', ':')
        else
          'unknown'
        end
      end

      # Clean up D-Bus resources
      # Unregisters agent, unexports it, and closes the bus connection.
      # All errors during cleanup are silently ignored.
      def cleanup
        # Stop event loop if still running
        @main_loop&.quit rescue nil

        # Unregister agent from AgentManager1
        if @bus
          begin
            bluez = @bus.service(BLUEZ_SERVICE)
            bluez_root = bluez.object('/')
            bluez_root.introspect
            agent_manager = bluez_root[AGENT_MANAGER_INTERFACE]
            agent_manager.UnregisterAgent(PairingAgent::AGENT_PATH)
          rescue StandardError
            # Ignore errors during cleanup
          end
        end

        # Unexport agent from bus
        if @bus && @agent
          begin
            @bus.object_server.unexport(@agent)
          rescue StandardError
            # Ignore errors during cleanup
          end
        end

        # Close the dedicated bus
        @bus = nil
        @agent = nil
        @main_loop = nil
      end
    end
  end
end
