# frozen_string_literal: true

require 'dbus'
require 'securerandom'

module RBLE
  module BlueZ
    # Provides async D-Bus call wrapper with Queue-based result delivery.
    # Use this to make D-Bus method calls without blocking the event loop.
    #
    # This module is the foundation for the v0.4.0 async architecture. By routing
    # D-Bus method call results through Thread::Queue instead of blocking on the
    # D-Bus socket, we eliminate the conflict between DBus::Main and synchronous calls.
    #
    # @example
    #   include AsyncCall
    #
    #   result = async_call('ReadValue', timeout: 5) do |queue, request_id|
    #     proxy.ReadValue({}) do |reply, *params|
    #       if reply.is_a?(DBus::Error)
    #         queue.push([reply, nil])
    #       else
    #         queue.push([reply, params])
    #       end
    #     end
    #   end
    #
    module AsyncCall
      # Execute a D-Bus call asynchronously with Queue-based result delivery
      #
      # @param operation [String] Operation name for logging/errors
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @yield [queue, request_id] Block that performs async D-Bus call
      # @yieldparam queue [Thread::Queue] Push [reply, params] to deliver result
      # @yieldparam request_id [String] Request ID for log correlation
      # @return [Array, nil] Method call result params
      # @raise [TimeoutError] if timeout exceeded
      # @raise [DBus::Error] propagated from D-Bus (for caller to translate)
      def async_call(operation, timeout: 5)
        queue = Thread::Queue.new
        request_id = SecureRandom.hex(4)
        start_time = Time.now

        RBLE.logger&.debug("[RBLE] #{request_id} Starting #{operation}")

        yield(queue, request_id)

        result = queue.pop(timeout: timeout)
        elapsed = Time.now - start_time

        if result.nil?
          RBLE.logger&.warn("[RBLE] #{request_id} #{operation} timed out after #{elapsed.round(3)}s")
          raise TimeoutError.new(operation, timeout)
        end

        RBLE.logger&.debug("[RBLE] #{request_id} #{operation} completed in #{elapsed.round(3)}s")

        reply, params = result
        raise reply if reply.is_a?(DBus::Error)

        params
      end
    end
  end
end
