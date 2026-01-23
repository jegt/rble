# frozen_string_literal: true

require 'open3'
require 'json'

module RBLE
  module Backend
    # CoreBluetooth backend for macOS BLE operations via subprocess
    class CoreBluetooth < Base
      HELPER_PATH = File.expand_path('../../../ext/macos_ble/.build/release/RBLEHelper', __dir__)

      def initialize
        @process = nil
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
      end

      # Start the subprocess if not running
      def ensure_subprocess
        return if @process && @wait_thread&.alive?

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
        @process = nil
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

      # Connection methods - stubs for Plan 04
      def connect_device(device_identifier, timeout: 30)
        raise NotImplementedError, "#{self.class}#connect_device not yet implemented"
      end

      def disconnect_device(device_identifier)
        raise NotImplementedError, "#{self.class}#disconnect_device not yet implemented"
      end

      def discover_services(device_identifier, timeout: 30)
        raise NotImplementedError, "#{self.class}#discover_services not yet implemented"
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

      # GATT methods - stubs for Plan 05
      def read_characteristic(char_identifier, timeout: 30)
        raise NotImplementedError, "#{self.class}#read_characteristic not yet implemented"
      end

      def write_characteristic(char_identifier, data, response: true, timeout: 30)
        raise NotImplementedError, "#{self.class}#write_characteristic not yet implemented"
      end

      def subscribe_characteristic(char_identifier, &block)
        raise NotImplementedError, "#{self.class}#subscribe_characteristic not yet implemented"
      end

      def unsubscribe_characteristic(char_identifier)
        raise NotImplementedError, "#{self.class}#unsubscribe_characteristic not yet implemented"
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
        case event[:method]
        when 'device_discovered'
          handle_device_discovered(event[:params])
        when 'state_changed'
          # Could notify app of BT state change
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
    end
  end
end
