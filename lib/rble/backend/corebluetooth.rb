# frozen_string_literal: true

require 'open3'
require 'json'

module RBLE
  module Backend
    # CoreBluetooth backend for macOS BLE operations via subprocess
    class CoreBluetooth < Base
      HELPER_PATH = File.expand_path('../../../ext/macos_ble/.build/release/RBLEHelper', __dir__)

      def initialize
        @stdin = nil
        @stdout = nil
        @stderr = nil
        @wait_thread = nil
        @request_id = 0
        @mutex = Mutex.new
        @scanning = false
        @scan_callback = nil
        @reader_thread = nil
        @event_queue = Queue.new

        # Separate queue for responses (id present) vs async events (method present)
        @response_queue = Queue.new

        # Connection tracking
        @connected_devices = {}  # device_uuid => true
        @device_services = {}    # device_uuid => [service_data, ...]
        @connection_objects = {} # device_uuid => Connection instance

        # Subscription tracking
        @subscriptions = {}      # char_identifier => callback

        # Background event processor for async events (disconnect, notifications)
        @event_processor_thread = nil
        @event_processor_running = false

        # Thread safety: protects shared state accessed from multiple threads
        # (event_processor_thread and user thread)
        @state_mutex = Mutex.new
      end

      # Start the subprocess if not running
      def ensure_subprocess
        return if @wait_thread&.alive?

        unless File.exist?(HELPER_PATH)
          raise SubprocessError, <<~MSG.strip
            macOS BLE helper not found at #{HELPER_PATH}

            The helper should build automatically during gem install. To build manually:
              cd #{File.dirname(HELPER_PATH).sub('/.build/release', '')}
              swift build -c release

            Ensure Xcode Command Line Tools are installed:
              xcode-select --install
          MSG
        end

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(HELPER_PATH)

        # Start reader thread for async events
        start_reader_thread

        # Start background event processor
        start_event_processor
      end

      # Send request and wait for response
      def send_request(method, params = nil, timeout: 30)
        ensure_subprocess
        raise SubprocessError, 'Subprocess not running' unless @wait_thread&.alive?

        request_id = nil
        @mutex.synchronize do
          @request_id += 1
          request_id = @request_id
          request = { id: request_id, method: method }
          request[:params] = params if params

          @stdin.puts(JSON.generate(request))
          @stdin.flush
        end

        # Wait for response in response queue (async events handled by event_processor_thread)
        deadline = Time.now + timeout
        while Time.now < deadline
          begin
            response = @response_queue.pop(true) # non-blocking
            if response[:id] == request_id
              handle_response_error(response) if response[:error]
              return response[:result]
            else
              # Not our response, put it back (shouldn't happen often with single-threaded requests)
              @response_queue.push(response)
              sleep 0.001
            end
          rescue ThreadError
            # Queue empty, wait a bit
            sleep 0.01
          end
        end

        raise ConnectionTimeoutError, timeout
      end

      def shutdown
        @event_processor_running = false
        @event_processor_thread&.kill
        @reader_thread&.kill
        @stdin&.close
        @stdout&.close
        @stderr&.close
        @wait_thread&.kill
      end

      # Backend::Base implementations

      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, active: true, &block)
        @state_mutex.synchronize do
          raise ScanInProgressError if @scanning
          @scanning = true
        end
        raise ArgumentError, 'Block required for scan callback' unless block_given?

        unless active
          RBLE.rble_warn "passive scanning (active: false) is not explicitly supported on macOS. " \
               "CoreBluetooth does not expose active/passive scan control. " \
               "Scanning will proceed normally."
        end

        if adapter
          RBLE.rble_warn "macOS does not support adapter selection. The default adapter will be used."
        end

        @scan_callback = block

        params = { allow_duplicates: allow_duplicates }
        params[:service_uuids] = service_uuids if service_uuids

        send_request('scan_start', params)
      end

      def stop_scan
        @state_mutex.synchronize { return unless @scanning }

        send_request('scan_stop')
        @state_mutex.synchronize do
          @scanning = false
          @scan_callback = nil
        end
      end

      def scanning?
        @state_mutex.synchronize { @scanning }
      end

      def adapters
        result = send_request('adapters')
        result['adapters'].map do |a|
          {
            name: a['name'],
            address: nil, # macOS doesn't expose adapter MAC
            powered: a['powered']
          }
        end
      end

      def process_events(timeout: nil)
        deadline = timeout ? Time.now + timeout : nil

        loop do
          remaining = deadline ? [deadline - Time.now, 0].max : 0.1
          break if deadline && remaining <= 0

          begin
            event = @event_queue.pop(true)
            handle_async_event(event)
          rescue ThreadError
            sleep [remaining, 0.1].min
          end

          break if deadline && Time.now >= deadline
        end

        false # Not a clean shutdown
      end

      # Connect to a BLE device
      # @param device_identifier [String] Device UUID (from scanning)
      # @param timeout [Numeric] Connection timeout in seconds
      # @return [Boolean] true on successful connection
      # @raise [AlreadyConnectedError] if already connected
      # @raise [ConnectionTimeoutError] if connection times out
      def connect_device(device_identifier, timeout: 30)
        # Check if already connected (thread-safe)
        @state_mutex.synchronize do
          raise AlreadyConnectedError if @connected_devices.key?(device_identifier)
        end

        send_request('connect', {
          uuid: device_identifier,
          timeout: timeout
        }, timeout: timeout + 5) # Extra buffer for subprocess

        @state_mutex.synchronize { @connected_devices[device_identifier] = true }
        true
      end

      # Disconnect from a BLE device
      # @param device_identifier [String] Device UUID
      # @return [void]
      def disconnect_device(device_identifier)
        @state_mutex.synchronize do
          @connected_devices.delete(device_identifier)
          @device_services.delete(device_identifier)
        end

        begin
          send_request('disconnect', { uuid: device_identifier }, timeout: 5)
        rescue StandardError
          # Ignore errors during cleanup
        end
      end

      # Discover GATT services on a connected device
      # @param device_identifier [String] Device UUID
      # @param timeout [Numeric] Discovery timeout in seconds
      # @return [Array<Hash>] Service data with characteristics
      # @raise [NotConnectedError] if not connected
      # @raise [ServiceDiscoveryError] if discovery fails
      def discover_services(device_identifier, timeout: 30)
        connected, cached_services = @state_mutex.synchronize do
          [@connected_devices.key?(device_identifier), @device_services[device_identifier]]
        end
        raise NotConnectedError unless connected

        # Return cached services if available
        return cached_services if cached_services

        result = send_request('discover_services', {
          uuid: device_identifier,
          timeout: timeout
        }, timeout: timeout + 5)

        services = build_services_from_result(result['services'], device_identifier)
        @state_mutex.synchronize { @device_services[device_identifier] = services }
        services
      end

      def device_path_for_address(address, adapter: nil)
        # On macOS, address IS the UUID - just return it
        # Validate it looks like a UUID
        unless address =~ /^[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$/i
          raise ConnectionError, "Invalid macOS device identifier '#{address}'. " \
            "On macOS, use the UUID from scanning (not MAC address)."
        end
        address
      end

      # Register a Connection object for disconnect monitoring
      # @param device_identifier [String] Device UUID
      # @param connection [Connection] The Connection instance
      # @return [void]
      def register_connection(device_identifier, connection)
        @state_mutex.synchronize { @connection_objects[device_identifier] = connection }
      end

      # Unregister a Connection object from disconnect monitoring
      # @param device_identifier [String] Device UUID
      # @return [void]
      def unregister_connection(device_identifier)
        @state_mutex.synchronize { @connection_objects.delete(device_identifier) }
      end

      # Read a characteristic value
      # @param char_identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @param timeout [Numeric] Read timeout in seconds
      # @return [String] Binary string (ASCII-8BIT encoding)
      # @raise [ReadError] if read fails
      def read_characteristic(char_identifier, timeout: 30)
        device_uuid, service_uuid, char_uuid = parse_char_identifier(char_identifier)

        result = send_request('read_characteristic', {
          device_uuid: device_uuid,
          service_uuid: service_uuid,
          char_uuid: char_uuid,
          timeout: timeout
        }, timeout: timeout + 5)

        # Convert byte array to binary string
        (result['value'] || []).map(&:to_i).pack('C*')
      rescue StandardError => e
        raise ReadError, translate_error(e)
      end

      # Write a value to a characteristic
      # @param char_identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @param data [String, Array<Integer>] Data to write
      # @param response [Boolean] Wait for write response
      # @param timeout [Numeric] Write timeout in seconds
      # @return [Boolean] true on success
      # @raise [WriteError] if write fails
      def write_characteristic(char_identifier, data, response: true, timeout: 30)
        device_uuid, service_uuid, char_uuid = parse_char_identifier(char_identifier)

        # Convert string to bytes array if needed
        bytes = data.is_a?(String) ? data.bytes : data

        send_request('write_characteristic', {
          device_uuid: device_uuid,
          service_uuid: service_uuid,
          char_uuid: char_uuid,
          value: bytes,
          response: response,
          timeout: timeout
        }, timeout: timeout + 5)

        true
      rescue StandardError => e
        raise WriteError, translate_error(e)
      end

      # Subscribe to characteristic notifications
      # @param char_identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @yield [String] Called with value (binary string) on each notification
      # @return [Boolean] true on success
      # @raise [NotifyError] if subscription fails
      def subscribe_characteristic(char_identifier, &callback)
        already_subscribed = @state_mutex.synchronize { @subscriptions.key?(char_identifier) }
        return true if already_subscribed

        device_uuid, service_uuid, char_uuid = parse_char_identifier(char_identifier)

        send_request('subscribe', {
          device_uuid: device_uuid,
          service_uuid: service_uuid,
          char_uuid: char_uuid
        }, timeout: 30)

        @state_mutex.synchronize { @subscriptions[char_identifier] = callback }
        true
      rescue StandardError => e
        raise NotifyError, translate_error(e)
      end

      # Unsubscribe from characteristic notifications
      # @param char_identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @return [Boolean] true on success
      def unsubscribe_characteristic(char_identifier)
        callback = @state_mutex.synchronize { @subscriptions.delete(char_identifier) }
        return true unless callback

        device_uuid, service_uuid, char_uuid = parse_char_identifier(char_identifier)

        begin
          send_request('unsubscribe', {
            device_uuid: device_uuid,
            service_uuid: service_uuid,
            char_uuid: char_uuid
          }, timeout: 5)
        rescue StandardError
          # Ignore errors during cleanup
        end

        true
      end

      private

      def start_reader_thread
        @reader_thread = Thread.new do
          while (line = @stdout.gets)
            begin
              event = JSON.parse(line, symbolize_names: false)
              # Normalize keys for Ruby
              event = event.transform_keys(&:to_sym) if event.is_a?(Hash)

              # Route to appropriate queue based on whether it's a response or async event
              if event[:id]
                # Response to a request
                @response_queue.push(event)
              else
                # Async event (device_discovered, notification, disconnected, etc.)
                @event_queue.push(event)
              end
            rescue JSON::ParserError
              # Log to stderr, don't crash
              warn "[RBLE] Invalid JSON from subprocess: #{line}"
            end
          end
        rescue IOError
          # Subprocess closed
        end
      end

      # Start background thread to process async events
      def start_event_processor
        return if @event_processor_thread&.alive?

        @event_processor_running = true
        @event_processor_thread = Thread.new do
          while @event_processor_running
            begin
              # Block with timeout so we can check @event_processor_running
              event = @event_queue.pop(true) rescue nil
              handle_async_event(event) if event
            rescue LocalJumpError
              # Expected when user's callback uses `break` to exit early from scanning
              # This is normal behavior, not an error
            rescue StandardError => e
              warn "[RBLE] Event processor error: #{e.message}"
            end
            sleep 0.01 # Small sleep to prevent CPU spinning
          end
        end
      end

      def handle_async_event(event)
        case event[:method] || event['method']
        when 'device_discovered'
          handle_device_discovered(event[:params] || event['params'])
        when 'notification'
          handle_notification(event[:params] || event['params'])
        when 'disconnected'
          handle_disconnected(event[:params] || event['params'])
        when 'state_changed'
          # Could notify app of BT state change
        when 'connected'
          # Connection state events (handled via request/response)
        end
      end

      def handle_device_discovered(params)
        return unless @scan_callback

        # Build Device from params
        device = Device.new(
          address: params['uuid'], # On macOS, UUID is the address
          name: params['name'],
          rssi: params['rssi'],
          manufacturer_data: parse_manufacturer_data(params['manufacturer_data']),
          manufacturer_data_raw: parse_manufacturer_data_raw(params['manufacturer_data']),
          service_data: parse_service_data(params['service_data']),
          service_uuids: params['service_uuids'] || [],
          tx_power: params['tx_power'],
          address_type: 'random' # CoreBluetooth doesn't expose this
        )

        @scan_callback.call(device)
      end

      def parse_manufacturer_data(data)
        return {} unless data.is_a?(Hash)

        company_id = data['company_id']
        bytes = data['data']
        return {} unless company_id && bytes

        { company_id => bytes }
      end

      def parse_manufacturer_data_raw(data)
        return {} unless data.is_a?(Hash)

        company_id = data['company_id']
        bytes = data['data']
        return {} unless company_id && bytes

        { company_id => bytes.pack('C*') }
      end

      def parse_service_data(data)
        return {} unless data.is_a?(Hash)

        data.transform_values { |bytes| bytes.is_a?(Array) ? bytes : [] }
      end

      # Build Service hashes from subprocess discover_services result
      # @param raw_services [Array] Raw service data from subprocess
      # @param device_identifier [String] Device UUID
      # @return [Array<Hash>] Services with characteristics and paths
      def build_services_from_result(raw_services, device_identifier)
        (raw_services || []).map do |service_data|
          characteristics = (service_data['characteristics'] || []).map do |char_data|
            {
              data: Characteristic.new(
                uuid: char_data['uuid'],
                flags: char_data['properties'] || [],
                service_uuid: service_data['uuid']
              ),
              path: "#{device_identifier}:#{service_data['uuid']}:#{char_data['uuid']}"
            }
          end

          {
            uuid: service_data['uuid'],
            primary: service_data['primary'] != false,
            characteristics: characteristics
          }
        end
      end

      def handle_response_error(response)
        error = response[:error]
        message = error['message'] || error[:message]
        platform_error = (error['data'] || error[:data])&.dig('platform_error')
        full_message = platform_error ? "#{message} (#{platform_error})" : message

        case message
        when /not powered on/i
          raise BluetoothOffError
        when /unauthorized/i
          raise PermissionError, 'access Bluetooth on macOS'
        when /not connected/i
          raise NotConnectedError, full_message
        when /device not found/i, /no peripheral/i, /unknown device/i
          raise DeviceNotFoundError.new(full_message)
        when /connection.*(failed|refused)/i
          raise ConnectionFailed.new(nil, full_message)
        when /connection.*timeout/i, /timed? ?out/i
          raise ConnectionTimeoutError
        when /service.*discover/i, /discover.*fail/i
          raise ServiceDiscoveryError, full_message
        when /characteristic not found/i
          raise CharacteristicNotFoundError
        else
          raise Error, full_message
        end
      end

      # Handle notification event from subprocess
      # @param params [Hash] Notification parameters from subprocess
      def handle_notification(params)
        return unless params

        device_uuid = params['device_uuid']
        service_uuid = params['service_uuid']
        char_uuid = params['char_uuid']
        value = params['value']

        identifier = "#{device_uuid}:#{service_uuid}:#{char_uuid}"
        callback = @state_mutex.synchronize { @subscriptions[identifier] }
        return unless callback

        # Convert byte array to binary string
        binary_value = (value || []).map(&:to_i).pack('C*')
        callback.call(binary_value)
      end

      # Handle disconnect event from subprocess
      # @param params [Hash] Disconnect parameters from subprocess
      def handle_disconnected(params)
        return unless params

        uuid = params['uuid']
        reason_str = params['reason'] || 'unknown'

        # Map string reason to symbol
        reason = case reason_str
                 when 'user_requested' then :user_requested
                 when 'timeout' then :timeout
                 when 'remote_disconnect' then :remote_disconnect
                 when 'connection_failed' then :connection_failed
                 when 'link_loss' then :link_loss
                 else :unknown
                 end

        # Clean up tracking and get connection object atomically (thread-safe)
        connection = @state_mutex.synchronize do
          @connected_devices.delete(uuid)
          @device_services.delete(uuid)
          @connection_objects.delete(uuid)
        end

        # Notify Connection object OUTSIDE mutex to prevent deadlock
        connection&.handle_disconnect(reason)
      end

      # Parse characteristic identifier into components
      # @param identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @return [Array<String>] [device_uuid, service_uuid, char_uuid]
      # @raise [ArgumentError] if identifier is invalid
      def parse_char_identifier(identifier)
        parts = identifier.split(':')
        raise ArgumentError, "Invalid characteristic identifier: #{identifier}" unless parts.length == 3

        parts
      end

      # Translate error messages to user-friendly format
      # @param error [StandardError] The error to translate
      # @return [String] Translated error message
      def translate_error(error)
        case error.message
        when /not connected/i
          'Device not connected'
        when /characteristic not found/i
          'Characteristic not found'
        when /timeout/i
          'Operation timed out'
        else
          error.message
        end
      end
    end
  end
end
