# frozen_string_literal: true

module RBLE
  # Immutable representation of a GATT characteristic (data only)
  #
  # @!attribute uuid [String] Characteristic UUID (128-bit format)
  # @!attribute flags [Array<String>] Capability flags: "read", "write", "write-without-response", "notify", "indicate"
  # @!attribute service_uuid [String] Parent service UUID
  Characteristic = Data.define(:uuid, :flags, :service_uuid) do
    def initialize(uuid:, flags: [], service_uuid: nil)
      super
    end

    # Get short UUID for standard characteristics
    def short_uuid
      if uuid =~ /^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/i
        Regexp.last_match(1).downcase
      else
        uuid
      end
    end

    # Check if characteristic supports reading
    def readable?
      flags.include?('read')
    end

    # Check if characteristic supports writing with response
    def writable?
      flags.include?('write')
    end

    # Check if characteristic supports writing without response
    def writable_without_response?
      flags.include?('write-without-response')
    end

    # Check if characteristic supports notifications
    def notifiable?
      flags.include?('notify')
    end

    # Check if characteristic supports indications
    def indicatable?
      flags.include?('indicate')
    end

    # Check if characteristic supports any form of subscription
    def subscribable?
      notifiable? || indicatable?
    end
  end

  # Active characteristic with read/write/subscribe operations
  #
  # Returned by Connection service discovery. Wraps immutable Characteristic
  # data with operations that interact with the device via the backend.
  #
  # @example Reading a value
  #   hr_char = service.characteristic('2a37')
  #   value = hr_char.read  # => binary string
  #   bytes = hr_char.read_bytes  # => [0x10, 0x65, ...]
  #
  # @example Writing a value
  #   char.write([0x01, 0x02])  # write with response
  #   char.write([0x01], response: false)  # write without response
  #
  # @example Subscribing to notifications
  #   char.subscribe do |value|
  #     puts "Got notification: #{value.bytes.inspect}"
  #   end
  #   # ... later ...
  #   char.unsubscribe
  #
  class ActiveCharacteristic
    attr_reader :uuid, :flags, :service_uuid, :path

    # Create an active characteristic
    # @param characteristic [Characteristic] Underlying characteristic data
    # @param path [String] D-Bus object path
    # @param connection [Connection] Parent connection (for state checks)
    # @param backend [Backend::Base] Backend for GATT operations
    def initialize(characteristic:, path:, connection:, backend:)
      @uuid = characteristic.uuid
      @flags = characteristic.flags
      @service_uuid = characteristic.service_uuid
      @path = path
      @connection = connection
      @backend = backend
      @subscribed = false
    end

    # Get short UUID for standard characteristics (e.g., "2a37" from full UUID)
    # @return [String] Short UUID if standard, otherwise full UUID
    def short_uuid
      if uuid =~ /^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/i
        Regexp.last_match(1).downcase
      else
        uuid
      end
    end

    # Check if characteristic supports reading
    # @return [Boolean]
    def readable?
      flags.include?('read')
    end

    # Check if characteristic supports writing with response
    # @return [Boolean]
    def writable?
      flags.include?('write')
    end

    # Check if characteristic supports writing without response
    # @return [Boolean]
    def writable_without_response?
      flags.include?('write-without-response')
    end

    # Check if characteristic supports notifications
    # @return [Boolean]
    def notifiable?
      flags.include?('notify')
    end

    # Check if characteristic supports indications
    # @return [Boolean]
    def indicatable?
      flags.include?('indicate')
    end

    # Check if characteristic supports any form of subscription
    # @return [Boolean]
    def subscribable?
      notifiable? || indicatable?
    end

    # Read the characteristic value
    # @param timeout [Numeric] Read timeout in seconds
    # @return [String] Binary string (ASCII-8BIT encoding)
    # @raise [NotSupportedError] if characteristic doesn't support read
    # @raise [NotConnectedError] if not connected
    # @raise [ReadError] if read fails
    def read(timeout: 30)
      raise NotSupportedError, 'read' unless readable?
      raise NotConnectedError unless @connection.connected?

      # Pass connection so backend can use its D-Bus session
      @backend.read_characteristic(@path, connection: @connection, timeout: timeout)
    end

    # Read the characteristic value as byte array
    # @param timeout [Numeric] Read timeout in seconds
    # @return [Array<Integer>] Byte array
    # @raise [NotSupportedError] if characteristic doesn't support read
    # @raise [NotConnectedError] if not connected
    # @raise [ReadError] if read fails
    def read_bytes(timeout: 30)
      read(timeout: timeout).bytes
    end

    # Write a value to the characteristic
    # @param data [String, Array<Integer>] Data to write (binary string or byte array)
    # @param response [Boolean] Wait for write response (default: true)
    # @param timeout [Numeric] Write timeout in seconds
    # @return [Boolean] true on success
    # @raise [NotSupportedError] if write type not supported
    # @raise [NotConnectedError] if not connected
    # @raise [WriteError] if write fails
    def write(data, response: true, timeout: 30)
      if response
        raise NotSupportedError, 'write' unless writable?
      else
        raise NotSupportedError, 'write-without-response' unless writable_without_response?
      end
      raise NotConnectedError unless @connection.connected?

      # Pass connection so backend can use its D-Bus session
      @backend.write_characteristic(@path, data, connection: @connection, response: response, timeout: timeout)
    end

    # Subscribe to characteristic notifications/indications
    # @yield [String] Called with value (binary string) on each notification
    # @return [Boolean] true on success
    # @raise [ArgumentError] if no block given
    # @raise [NotifyNotSupported] if characteristic doesn't support notifications
    # @raise [NotConnectedError] if not connected
    # @raise [NotifyError] if subscription fails
    def subscribe(&)
      raise ArgumentError, 'Block required' unless block_given?
      raise NotifyNotSupported.new(short_uuid, flags) unless subscribable?
      raise NotConnectedError unless @connection.connected?

      # Pass connection so backend can use its D-Bus session for event delivery
      @backend.subscribe_characteristic(@path, connection: @connection, &)
      @subscribed = true
    end

    # Unsubscribe from notifications
    # @return [void]
    def unsubscribe
      return unless @subscribed

      @backend.unsubscribe_characteristic(@path)
      @subscribed = false
    end

    # Check if currently subscribed to notifications
    # @return [Boolean]
    def subscribed?
      @subscribed
    end
  end
end
