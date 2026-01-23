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

        # Connection tracking
        @connected_devices = {}  # device_uuid => true
        @device_services = {}    # device_uuid => [service_data, ...]

        # Subscription tracking
        @subscriptions = {}      # char_identifier => callback
      end

      # Start the subprocess if not running
      def ensure_subprocess
        return if @wait_thread&.alive?

        unless File.exist?(HELPER_PATH)
          raise SubprocessError, "Helper not found at #{HELPER_PATH}. Run 'swift build -c release' in ext/macos_ble/"
        end

        @stdin, @stdout, @stderr, @wait_thread = Open3.popen3(HELPER_PATH)

        # Start reader thread for async events
        start_reader_thread
      end

      # Send request and wait for response
      def send_request(method, params = nil, timeout: 30)
        ensure_subprocess
        raise SubprocessError, 'Subprocess not running' unless @wait_thread&.alive?

        @mutex.synchronize do
          @request_id += 1
          request = { id: @request_id, method: method }
          request[:params] = params if params

          @stdin.puts(JSON.generate(request))
          @stdin.flush

          # Read response with timeout
          deadline = Time.now + timeout
          while Time.now < deadline
            # Check for response in event queue
            begin
              event = @event_queue.pop(true) # non-blocking
              if event[:id] == @request_id
                handle_response_error(event) if event[:error]
                return event[:result]
              else
                # It's an async event, process it
                handle_async_event(event)
              end
            rescue ThreadError
              # Queue empty, wait a bit
              sleep 0.01
            end
          end

          raise ConnectionTimeoutError, timeout
        end
      end

      def shutdown
        @reader_thread&.kill
        @stdin&.close
        @stdout&.close
        @stderr&.close
        @wait_thread&.kill
      end

      # Backend::Base implementations

      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, &block)
        raise ScanInProgressError if @scanning
        raise ArgumentError, 'Block required for scan callback' unless block_given?

        @scan_callback = block
        @scanning = true

        params = { allow_duplicates: allow_duplicates }
        params[:service_uuids] = service_uuids if service_uuids

        send_request('scan_start', params)
      end

      def stop_scan
        return unless @scanning

        send_request('scan_stop')
        @scanning = false
        @scan_callback = nil
      end

      def scanning?
        @scanning
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
        # Check if already connected
        raise AlreadyConnectedError if @connected_devices.key?(device_identifier)

        send_request('connect', {
          uuid: device_identifier,
          timeout: timeout
        }, timeout: timeout + 5) # Extra buffer for subprocess

        @connected_devices[device_identifier] = true
        true
      end

      # Disconnect from a BLE device
      # @param device_identifier [String] Device UUID
      # @return [void]
      def disconnect_device(device_identifier)
        @connected_devices.delete(device_identifier)
        @device_services.delete(device_identifier)

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
        raise NotConnectedError unless @connected_devices.key?(device_identifier)

        # Return cached services if available
        return @device_services[device_identifier] if @device_services.key?(device_identifier)

        result = send_request('discover_services', {
          uuid: device_identifier,
          timeout: timeout
        }, timeout: timeout + 5)

        services = build_services_from_result(result['services'], device_identifier)
        @device_services[device_identifier] = services
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
        return true if @subscriptions.key?(char_identifier)

        device_uuid, service_uuid, char_uuid = parse_char_identifier(char_identifier)

        send_request('subscribe', {
          device_uuid: device_uuid,
          service_uuid: service_uuid,
          char_uuid: char_uuid
        }, timeout: 30)

        @subscriptions[char_identifier] = callback
        true
      rescue StandardError => e
        raise NotifyError, translate_error(e)
      end

      # Unsubscribe from characteristic notifications
      # @param char_identifier [String] Format: "device_uuid:service_uuid:char_uuid"
      # @return [Boolean] true on success
      def unsubscribe_characteristic(char_identifier)
        callback = @subscriptions.delete(char_identifier)
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
              @event_queue.push(event)
            rescue JSON::ParserError
              # Log to stderr, don't crash
              warn "[rble] Invalid JSON from subprocess: #{line}"
            end
          end
        rescue IOError
          # Subprocess closed
        end
      end

      def handle_async_event(event)
        case event[:method] || event['method']
        when 'device_discovered'
          handle_device_discovered(event[:params] || event['params'])
        when 'notification'
          handle_notification(event[:params] || event['params'])
        when 'state_changed'
          # Could notify app of BT state change
        when 'connected', 'disconnected'
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
        code = error['code'] || error[:code]
        message = error['message'] || error[:message]
        platform_error = (error['data'] || error[:data])&.dig('platform_error')

        case message
        when /not powered on/i
          raise BluetoothOffError
        when /unauthorized/i
          raise PermissionError, 'access Bluetooth on macOS'
        else
          raise Error, "#{message}#{platform_error ? " (#{platform_error})" : ''}"
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
        callback = @subscriptions[identifier]
        return unless callback

        # Convert byte array to binary string
        binary_value = (value || []).map(&:to_i).pack('C*')
        callback.call(binary_value)
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
