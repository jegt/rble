# frozen_string_literal: true

module RBLE
  # BLE device scanner
  #
  # Provides a high-level API for scanning BLE devices with options for
  # filtering, timeout, and continuous monitoring.
  #
  # @example Basic scanning (blocking with timeout)
  #   RBLE.scan(timeout: 10) do |device|
  #     puts "Found: #{device.name} (#{device.address})"
  #   end
  #
  # @example Manual stop control
  #   scanner = RBLE.scan do |device|
  #     puts device.name
  #     scanner.stop if device.name == "MyDevice"
  #   end
  #
  # @example Filter by service UUID
  #   RBLE.scan(service_uuids: ['180d']) do |device|
  #     puts "Heart rate monitor: #{device.name}"
  #   end
  #
  # @example Continuous RSSI monitoring (RuuviTag style)
  #   RBLE.scan(allow_duplicates: true, timeout: 60) do |device|
  #     puts "#{device.address}: RSSI #{device.rssi}"
  #   end
  #
  class Scanner
    attr_reader :backend

    # Create a new scanner
    #
    # @param service_uuids [Array<String>, nil] Filter by service UUIDs
    # @param timeout [Numeric, nil] Stop after N seconds (nil = manual stop only)
    # @param allow_duplicates [Boolean] Callback on every advertisement
    # @param adapter [String, nil] Bluetooth adapter name (e.g., "hci0")
    # @param on_stop [Proc, nil] Callback when scan stops
    def initialize(service_uuids: nil, timeout: nil, allow_duplicates: false, adapter: nil, on_stop: nil)
      @service_uuids = service_uuids
      @timeout = timeout
      @allow_duplicates = allow_duplicates
      @adapter = adapter
      @on_stop = on_stop
      @backend = nil
      @stop_requested = false
      @started = false
    end

    # Start scanning with a callback block
    #
    # @yield [Device] Called when device is discovered/updated
    # @return [self] Returns self for stop control
    # @raise [ScanInProgressError] if this scanner is already running
    # @raise [AdapterNotFoundError] if no Bluetooth adapter available
    # @raise [AdapterDisabledError] if adapter is not powered on
    def start(&block)
      raise ScanInProgressError if @started
      raise ArgumentError, "Block required" unless block_given?

      @started = true
      @stop_requested = false
      @backend = Backend.for_platform

      begin
        @backend.start_scan(
          service_uuids: @service_uuids,
          allow_duplicates: @allow_duplicates,
          adapter: @adapter,
          &block
        )

        # Process events until stop or timeout
        process_until_stop

      ensure
        # Ensure cleanup on any error or normal completion
        cleanup_scan
        @on_stop&.call
      end

      self
    end

    # Stop the current scan
    #
    # @return [void]
    def stop
      @stop_requested = true
    end

    # Check if scan is running
    #
    # @return [Boolean]
    def scanning?
      @started && @backend&.scanning?
    end

    private

    def process_until_stop
      deadline = @timeout ? Time.now + @timeout : nil

      loop do
        break if @stop_requested

        # Calculate remaining time
        remaining = if deadline
          time_left = deadline - Time.now
          break if time_left <= 0
          [time_left, 0.5].min  # Process in chunks for responsiveness
        else
          0.5  # Default poll interval
        end

        @backend.process_events(timeout: remaining)
      end
    end

    def cleanup_scan
      @backend&.stop_scan
      @backend = nil
      @started = false
    end
  end

  class << self
    # Scan for BLE devices
    #
    # @param service_uuids [Array<String>, nil] Filter by service UUIDs
    # @param timeout [Numeric, nil] Stop after N seconds
    # @param allow_duplicates [Boolean] Callback on every advertisement
    # @param adapter [String, nil] Bluetooth adapter name
    # @param on_stop [Proc, nil] Callback when scan stops
    # @yield [Device] Called when device discovered
    # @return [Scanner] Scanner instance for stop control
    #
    # @example
    #   RBLE.scan(timeout: 5) { |d| puts d.name }
    #
    def scan(service_uuids: nil, timeout: nil, allow_duplicates: false, adapter: nil, on_stop: nil, &block)
      scanner = Scanner.new(
        service_uuids: service_uuids,
        timeout: timeout,
        allow_duplicates: allow_duplicates,
        adapter: adapter,
        on_stop: on_stop
      )
      scanner.start(&block)
      scanner
    end

    # List available Bluetooth adapters
    #
    # @return [Array<Hash>] Array of adapter info hashes
    # @example
    #   RBLE.adapters
    #   # => [{name: "hci0", address: "AA:BB:CC:DD:EE:FF", powered: true}]
    #
    def adapters
      Backend.for_platform.adapters
    end
  end
end
