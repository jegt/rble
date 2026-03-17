# frozen_string_literal: true

module RBLE
  module BlueZ
    # Per-connection queue for serializing GATT operations.
    #
    # BlueZ can behave unpredictably when multiple GATT operations (read, write,
    # start_notify) are executed concurrently on the same connection. This queue
    # ensures operations are executed sequentially with a small delay between them.
    #
    # @example
    #   queue = GattOperationQueue.new
    #   queue.enqueue { session.async_read_value(char_path) }
    #   queue.enqueue { session.async_write_value(char_path, [0x01]) }
    #   queue.stop  # Call on disconnect
    #
    class GattOperationQueue
      # Delay between GATT operations to prevent BlueZ contention
      INTER_OPERATION_DELAY = 0.05

      def initialize
        @queue = Thread::Queue.new
        @worker_thread = nil
        @running = false
        @mutex = Mutex.new
        @active_result_queue = nil
      end

      # Enqueue a GATT operation for sequential execution
      #
      # @yield Block containing the GATT operation to execute
      # @return [Object] Result from the block execution
      # @raise [RuntimeError] if queue is stopped
      # @raise Re-raises any exception from the block
      def enqueue(&block)
        raise 'GattOperationQueue is stopped' unless running?

        result_queue = Thread::Queue.new
        @queue.push([block, result_queue])

        # Wait for result (blocking)
        result, error = result_queue.pop
        raise error if error

        result
      end

      # Start the worker thread if not already running
      # @return [void]
      def start
        @mutex.synchronize do
          return if @running

          @running = true
          @worker_thread = Thread.new { worker_loop }
          @worker_thread.name = 'rble-gatt-queue'
        end
      end

      # Stop the worker thread and clear pending operations
      # @return [void]
      def stop
        @mutex.synchronize do
          return unless @running

          @running = false
          @queue.push(:shutdown)
        end

        # Wait for worker thread to finish
        @worker_thread&.join(2)
        @worker_thread&.kill if @worker_thread&.alive?
        @worker_thread = nil

        # Unblock caller of the currently-executing operation (if any)
        active_rq = @active_result_queue
        @active_result_queue = nil
        active_rq&.push([nil, RuntimeError.new('GATT queue stopped')])

        # Drain remaining operations and unblock waiting callers
        drain_pending_operations
      end

      # Check if queue is running
      # @return [Boolean]
      def running?
        @mutex.synchronize { @running }
      end

      private

      # Drain pending operations, notifying callers with an error
      # @return [void]
      def drain_pending_operations
        while (item = @queue.pop(true) rescue nil)
          next if item == :shutdown

          _block, result_queue = item
          result_queue.push([nil, RuntimeError.new('GATT queue stopped')])
        end
      end

      def worker_loop
        RBLE.logger&.debug('[RBLE] GATT operation queue started')

        while @running
          item = @queue.pop
          break if item == :shutdown

          block, result_queue = item
          @active_result_queue = result_queue
          begin
            result = block.call
            result_queue.push([result, nil])
          rescue StandardError => e
            result_queue.push([nil, e])
          ensure
            @active_result_queue = nil
          end

          # Inter-operation delay to prevent BlueZ contention
          sleep(INTER_OPERATION_DELAY) if @running
        end

        RBLE.logger&.debug('[RBLE] GATT operation queue stopped')
      end
    end
  end
end
