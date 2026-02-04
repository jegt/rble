# frozen_string_literal: true

require 'dbus'
require_relative 'async_call'
require_relative 'async_introspection'
require_relative 'retry_policy'

module RBLE
  module BlueZ
    # Provides async GATT operations using AsyncCall + AsyncIntrospection patterns.
    # Use this to perform GATT read/write/notify operations without blocking the event loop.
    #
    # This module is part of the v0.4.0 async architecture. It builds on AsyncCall
    # and AsyncIntrospection to provide non-blocking GATT operations.
    #
    # Including class must:
    # - Include AsyncCall module (provides async_call method)
    # - Include AsyncIntrospection module (provides async_introspect method)
    # - Have @service attribute pointing to D-Bus service
    #
    # @example
    #   include AsyncCall
    #   include AsyncIntrospection
    #   include AsyncGattOperations
    #
    #   value = async_read_value("/org/bluez/hci0/.../char0011")
    #   async_write_value("/org/bluez/hci0/.../char0011", [0x01, 0x02])
    #   async_start_notify("/org/bluez/hci0/.../char0011")
    #   async_stop_notify("/org/bluez/hci0/.../char0011")
    #
    module AsyncGattOperations
      include RetryPolicy
      GATT_CHARACTERISTIC_INTERFACE = 'org.bluez.GattCharacteristic1'
      PROPERTIES_INTERFACE = 'org.freedesktop.DBus.Properties'

      # Default timeouts (Claude's discretion per CONTEXT.md)
      DEFAULT_READ_TIMEOUT = 5
      DEFAULT_WRITE_TIMEOUT = 5
      DEFAULT_NOTIFY_TIMEOUT = 5
      WRITE_NO_RESPONSE_TIMEOUT = 1

      # Async read characteristic value
      #
      # @param char_path [String] D-Bus characteristic path
      # @param timeout [Numeric] Total timeout in seconds for the entire read operation (default: 5)
      # @return [String] Binary string (ASCII-8BIT encoding)
      # @raise [TimeoutError] if read times out
      # @raise [ReadError] if read fails
      # @raise [NotConnectedError] if device disconnected
      # @raise [OperationInProgressError] if retries exhausted
      def async_read_value(char_path, timeout: DEFAULT_READ_TIMEOUT)
        uuid = extract_uuid_from_path(char_path)
        deadline = Time.now + timeout

        proxy = async_introspect(char_path, timeout: gatt_remaining_timeout(deadline, timeout, 'ReadValue'))
        char_iface = proxy[GATT_CHARACTERISTIC_INTERFACE]

        result = with_inprogress_retry do
          async_call("ReadValue(#{uuid})", timeout: gatt_remaining_timeout(deadline, timeout, 'ReadValue')) do |queue, _request_id, cancelled|
            char_iface.ReadValue({}) do |reply|
              next if cancelled[0]  # Discard late callback
              if reply.is_a?(DBus::Error)
                queue.push([reply, nil])
              else
                # Extract params from DBus::Message - ReadValue returns [Array<Byte>]
                params = reply.respond_to?(:params) ? reply.params : [reply]
                queue.push([nil, params.first])
              end
            end
          end
        end

        # Convert D-Bus byte array to binary string
        bytes = result || []
        bytes.map(&:to_i).pack('C*')
      rescue DBus::Error => e
        translate_gatt_error(e, char_path, 'Read')
      end

      # Async write characteristic value
      #
      # @param char_path [String] D-Bus characteristic path
      # @param bytes [Array<Integer>] Byte array to write
      # @param response [Boolean] Wait for write response (default: true)
      # @param timeout [Numeric] Total timeout in seconds for the entire write operation (default: 5)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if write times out
      # @raise [WriteError] if write fails
      # @raise [NotConnectedError] if device disconnected
      # @raise [OperationInProgressError] if retries exhausted
      def async_write_value(char_path, bytes, response: true, timeout: DEFAULT_WRITE_TIMEOUT)
        uuid = extract_uuid_from_path(char_path)

        # Write-without-response uses minimal timeout (CONTEXT.md decision)
        effective_timeout = response ? timeout : WRITE_NO_RESPONSE_TIMEOUT
        deadline = Time.now + effective_timeout

        proxy = async_introspect(char_path, timeout: gatt_remaining_timeout(deadline, effective_timeout, 'WriteValue'))
        char_iface = proxy[GATT_CHARACTERISTIC_INTERFACE]

        # Build write options
        type_value = response ? 'request' : 'command'
        options = {
          'type' => DBus::Data::Variant.new(type_value, member_type: DBus::Type::STRING)
        }

        with_inprogress_retry do
          async_call("WriteValue(#{uuid})", timeout: gatt_remaining_timeout(deadline, effective_timeout, 'WriteValue')) do |queue, _request_id, cancelled|
            char_iface.WriteValue(bytes, options) do |reply|
              next if cancelled[0]  # Discard late callback
              if reply.is_a?(DBus::Error)
                queue.push([reply, nil])
              else
                queue.push([nil, :ok])
              end
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_gatt_error(e, char_path, 'Write')
      end

      # Async start notifications (idempotent)
      #
      # @param char_path [String] D-Bus characteristic path
      # @param timeout [Numeric] Total timeout in seconds for the entire operation (default: 5)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if call times out
      # @raise [NotifyNotSupported] if characteristic doesn't support notifications
      # @raise [NotConnectedError] if device disconnected
      # @raise [OperationInProgressError] if retries exhausted
      def async_start_notify(char_path, timeout: DEFAULT_NOTIFY_TIMEOUT)
        uuid = extract_uuid_from_path(char_path)
        deadline = Time.now + timeout

        proxy = async_introspect(char_path, timeout: gatt_remaining_timeout(deadline, timeout, 'StartNotify'))
        char_iface = proxy[GATT_CHARACTERISTIC_INTERFACE]

        # Check flags before calling (use async to avoid deadlock)
        flags = async_get_property(char_path, GATT_CHARACTERISTIC_INTERFACE, 'Flags', timeout: gatt_remaining_timeout(deadline, timeout, 'StartNotify'))
        unless flags.include?('notify') || flags.include?('indicate')
          raise NotifyNotSupported.new(uuid, flags)
        end

        # Idempotent: return early if already notifying (use async to avoid deadlock)
        notifying = async_get_property(char_path, GATT_CHARACTERISTIC_INTERFACE, 'Notifying', timeout: gatt_remaining_timeout(deadline, timeout, 'StartNotify'))
        return true if notifying

        with_inprogress_retry do
          async_call("StartNotify(#{uuid})", timeout: gatt_remaining_timeout(deadline, timeout, 'StartNotify')) do |queue, _request_id, cancelled|
            char_iface.StartNotify do |reply|
              next if cancelled[0]  # Discard late callback
              if reply.is_a?(DBus::Error)
                queue.push([reply, nil])
              else
                queue.push([nil, :ok])
              end
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_gatt_error(e, char_path, 'StartNotify')
      end

      # Async stop notifications
      #
      # @param char_path [String] D-Bus characteristic path
      # @param timeout [Numeric] Total timeout in seconds for the entire operation (default: 5)
      # @return [Boolean] true on success
      # @raise [TimeoutError] if call times out
      # @raise [NotConnectedError] if device disconnected
      def async_stop_notify(char_path, timeout: DEFAULT_NOTIFY_TIMEOUT)
        uuid = extract_uuid_from_path(char_path)
        deadline = Time.now + timeout

        proxy = async_introspect(char_path, timeout: gatt_remaining_timeout(deadline, timeout, 'StopNotify'))
        char_iface = proxy[GATT_CHARACTERISTIC_INTERFACE]

        async_call("StopNotify(#{uuid})", timeout: gatt_remaining_timeout(deadline, timeout, 'StopNotify')) do |queue, _request_id, cancelled|
          char_iface.StopNotify do |reply|
            next if cancelled[0]  # Discard late callback
            if reply.is_a?(DBus::Error)
              queue.push([reply, nil])
            else
              queue.push([nil, :ok])
            end
          end
        end

        true
      rescue DBus::Error => e
        translate_gatt_error(e, char_path, 'StopNotify')
      end

      private

      # Calculate remaining timeout from deadline, raising TimeoutError if expired
      # @param deadline [Time] Absolute deadline
      # @param original_timeout [Numeric] Original timeout for error message
      # @param operation [String] Operation name for error message
      # @return [Numeric] Remaining seconds (minimum 0.1 to allow one more attempt)
      # @raise [TimeoutError] if deadline has passed
      def gatt_remaining_timeout(deadline, original_timeout, operation)
        remaining = deadline - Time.now
        raise TimeoutError.new(operation, original_timeout) if remaining <= 0
        [remaining, 0.1].max
      end

      # Translate D-Bus errors to RBLE errors with UUID
      # CONTEXT.md decision: error messages must include characteristic UUID
      def translate_gatt_error(error, char_path, operation)
        uuid = extract_uuid_from_path(char_path) || char_path

        case error.name
        when 'org.bluez.Error.NotSupported'
          raise NotSupportedError, "#{operation} on #{uuid}"
        when 'org.bluez.Error.NotPermitted'
          raise NotPermittedError, "#{operation} on #{uuid}"
        when 'org.bluez.Error.NotAuthorized'
          raise NotAuthorizedError, "#{operation} on #{uuid}"
        when 'org.bluez.Error.AuthenticationFailed'
          raise AuthenticationError.new
        when 'org.bluez.Error.NotConnected'
          raise ConnectionLostError.new(nil, "#{operation} on #{uuid}")
        when 'org.bluez.Error.InProgress'
          raise OperationInProgressError.new("#{operation} on #{uuid}")
        when 'org.bluez.Error.InvalidValueLength'
          raise WriteError, "Invalid data length for #{uuid} (org.bluez.Error.InvalidValueLength)"
        when 'org.bluez.Error.InvalidOffset'
          raise ReadError, "Invalid offset for #{uuid} (org.bluez.Error.InvalidOffset)"
        when 'org.bluez.Error.Failed'
          raise GATTError, "#{operation} failed on #{uuid}: #{error.message} (org.bluez.Error.Failed)"
        else
          raise GATTError, "#{operation} failed on #{uuid}: #{error.message} (#{error.name})"
        end
      end

      # Extract UUID from characteristic path for error messages
      # Path format: /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX/serviceXXXX/charYYYY
      def extract_uuid_from_path(char_path)
        char_path.split('/').last
      end
    end
  end
end
