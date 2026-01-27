# frozen_string_literal: true

module RBLE
  module BlueZ
    # Retry policy for handling transient BlueZ errors with exponential backoff.
    #
    # BlueZ can return org.bluez.Error.InProgress when operations are attempted
    # too quickly or when the stack is busy. This module provides retry logic
    # with exponential backoff to handle these cases gracefully.
    #
    # @example
    #   include RetryPolicy
    #
    #   with_inprogress_retry do
    #     session.async_read_value(char_path)
    #   end
    #
    module RetryPolicy
      # Maximum number of retry attempts for InProgress errors
      MAX_RETRIES = 3

      # Initial delay before first retry (50ms)
      INITIAL_DELAY = 0.05

      # Maximum delay between retries (500ms)
      MAX_DELAY = 0.5

      # Execute a block with retry logic for InProgress errors
      #
      # @yield Block containing the operation to execute
      # @return [Object] Result from the block
      # @raise [OperationInProgressError] if all retries exhausted
      # @raise Re-raises any other exception
      def with_inprogress_retry
        attempts = 0
        delay = INITIAL_DELAY

        begin
          yield
        rescue DBus::Error => e
          if e.name == 'org.bluez.Error.InProgress' && attempts < MAX_RETRIES
            attempts += 1
            RBLE.logger&.debug("[RBLE] InProgress error, retry #{attempts}/#{MAX_RETRIES} after #{(delay * 1000).round}ms")
            sleep(delay)
            delay = [delay * 2, MAX_DELAY].min  # Exponential backoff with cap
            retry
          end

          # Re-raise if not InProgress or retries exhausted
          raise
        end
      end
    end
  end
end
