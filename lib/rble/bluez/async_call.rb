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
    #   result = async_call('ReadValue', timeout: 5) do |queue, request_id, cancelled|
    #     proxy.ReadValue({}) do |reply, *params|
    #       next if cancelled[0]  # Discard late callback
    #       if reply.is_a?(DBus::Error)
    #         queue.push([reply, nil])
    #       else
    #         queue.push([reply, params])
    #       end
    #     end
    #   end
    #
    module AsyncCall
      # Count of late callbacks received after timeout (for metrics)
      attr_reader :late_callback_count
      # Execute a D-Bus call asynchronously with Queue-based result delivery
      #
      # @param operation [String] Operation name for logging/errors
      # @param timeout [Numeric] Timeout in seconds (default: 5)
      # @yield [queue, request_id, cancelled] Block that performs async D-Bus call
      # @yieldparam queue [Thread::Queue] Push [reply, params] to deliver result
      # @yieldparam request_id [String] Request ID for log correlation
      # @yieldparam cancelled [Array<Boolean>] Mutable container - check cancelled[0] before pushing
      # @return [Array, nil] Method call result params
      # @raise [TimeoutError] if timeout exceeded
      # @raise [SessionClosedError] if session closed while operation pending
      # @raise [DBus::Error] propagated from D-Bus (for caller to translate)
      def async_call(operation, timeout: 5)
        queue = Thread::Queue.new
        request_id = SecureRandom.hex(4)
        start_time = Time.now
        cancelled = [false]  # Mutable container for cancellation state

        # Track queue for shutdown notification (if @pending_queues exists)
        @pending_queues&.push(queue)

        RBLE.logger&.debug("[RBLE] #{request_id} Starting #{operation}")
        warn "      [rble] #{request_id} #{operation} timeout=#{timeout.round(2)}s" if RBLE.trace

        yield(queue, request_id, cancelled)

        result = queue.pop(timeout: timeout)
        elapsed = Time.now - start_time
        warn "      [rble] #{request_id} #{operation} -> #{result.nil? ? 'TIMEOUT' : 'ok'} (#{elapsed.round(2)}s)" if RBLE.trace

        if result.nil?
          cancelled[0] = true
          @late_callback_count = (@late_callback_count || 0) + 1
          RBLE.logger&.warn("[RBLE] #{request_id} #{operation} timed out after #{elapsed.round(3)}s (late callbacks: #{@late_callback_count})")
          raise TimeoutError.new(operation, timeout)
        end

        # Check for session close marker
        if result.is_a?(Array) && result.first == :session_closed
          raise SessionClosedError.new
        end

        RBLE.logger&.debug("[RBLE] #{request_id} #{operation} completed in #{elapsed.round(3)}s")

        reply, params = result
        raise reply if reply.is_a?(DBus::Error)

        params
      ensure
        @pending_queues&.delete(queue)
      end
    end
  end
end
