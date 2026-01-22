# frozen_string_literal: true

require_relative "../bluez"

module RBLE
  module Backend
    # BlueZ D-Bus backend for Linux BLE operations
    class BlueZ < Base
      def initialize
        @connection = nil
        @adapter = nil
        @event_loop = nil
        @scanning = false
        @scan_callback = nil
        @known_devices = {}  # path => Device
        @allow_duplicates = false
        @signal_handlers = []
      end

      # Start scanning for BLE devices
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs
      # @param allow_duplicates [Boolean] Callback on every advertisement
      # @param adapter [String, nil] Adapter name (e.g., "hci0")
      # @yield [Device] Called when device discovered/updated
      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, &block)
        raise ScanInProgressError if @scanning
        raise ArgumentError, "Block required for scan callback" unless block_given?

        @scan_callback = block
        @allow_duplicates = allow_duplicates
        @known_devices.clear

        begin
          setup_connection
          setup_adapter(adapter)
          setup_signal_handlers
          start_discovery(service_uuids: service_uuids, allow_duplicates: allow_duplicates)

          @scanning = true

          # Process existing devices (already discovered before scan started)
          process_existing_devices

          # Start event processing
          @event_loop.start(@connection.bus)
        rescue
          cleanup
          raise
        end
      end

      # Stop current scan
      def stop_scan
        return unless @scanning

        begin
          @adapter&.stop_discovery
        rescue
          # Ignore errors during cleanup
        end

        cleanup
      end

      # Check if scanning
      # @return [Boolean]
      def scanning?
        @scanning
      end

      # List available adapters
      # @return [Array<Hash>]
      def adapters
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect

        om = conn.object_manager
        managed = om.GetManagedObjects.first

        adapters = managed.select { |path, ifaces| ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
        adapters.map do |path, ifaces|
          props = ifaces[RBLE::BlueZ::ADAPTER_INTERFACE]
          {
            name: path.split("/").last,
            address: props["Address"],
            powered: props["Powered"]
          }
        end
      rescue => e
        raise Error, "Failed to list adapters: #{e.message}"
      ensure
        conn&.disconnect
      end

      # Process events (blocking) - call this to receive callbacks
      # @param timeout [Numeric, nil] Timeout in seconds
      # @return [Boolean] true if shutdown, false if timeout
      def process_events(timeout: nil)
        return false unless @scanning

        @event_loop.process_events(timeout: timeout) do |event|
          handle_event(event)
        end
      end

      private

      def setup_connection
        @connection = RBLE::BlueZ::DBusConnection.new
        @connection.connect
      end

      def setup_adapter(adapter_name)
        adapter_path = if adapter_name
          "/org/bluez/#{adapter_name}"
        else
          # Find first available adapter
          om = @connection.object_manager
          managed = om.GetManagedObjects.first
          adapter_entry = managed.find { |path, ifaces| ifaces.key?(RBLE::BlueZ::ADAPTER_INTERFACE) }
          raise AdapterNotFoundError unless adapter_entry
          adapter_entry.first
        end

        @adapter = RBLE::BlueZ::Adapter.new(@connection, adapter_path)
        raise AdapterDisabledError.new(@adapter.name) unless @adapter.powered?
      end

      def setup_signal_handlers
        @event_loop = RBLE::BlueZ::EventLoop.new

        # Subscribe to InterfacesAdded for new device discovery
        root = @connection.root_object
        object_manager = root[RBLE::BlueZ::OBJECT_MANAGER_INTERFACE]

        object_manager.on_signal("InterfacesAdded") do |path, interfaces|
          if interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)
            @event_loop.enqueue(:device_found, path, interfaces[RBLE::BlueZ::DEVICE_INTERFACE])
          end
        end
        @signal_handlers << [:interfaces_added, object_manager]

        object_manager.on_signal("InterfacesRemoved") do |path, interfaces|
          if interfaces.include?(RBLE::BlueZ::DEVICE_INTERFACE)
            @event_loop.enqueue(:device_removed, path, nil)
          end
        end
        @signal_handlers << [:interfaces_removed, object_manager]
      end

      def subscribe_to_device_properties(device_path)
        begin
          device_obj = @connection.object(device_path)
          props_iface = device_obj[RBLE::BlueZ::PROPERTIES_INTERFACE]

          props_iface.on_signal("PropertiesChanged") do |interface, changed, invalidated|
            if interface == RBLE::BlueZ::DEVICE_INTERFACE
              @event_loop.enqueue(:properties_changed, device_path, changed)
            end
          end
          @signal_handlers << [:properties_changed, props_iface, device_path]
        rescue
          # Device may have disappeared, ignore
        end
      end

      def start_discovery(service_uuids:, allow_duplicates:)
        @adapter.set_discovery_filter(
          service_uuids: service_uuids,
          allow_duplicates: allow_duplicates
        )
        @adapter.start_discovery
      end

      def process_existing_devices
        om = @connection.object_manager
        managed = om.GetManagedObjects.first

        managed.each do |path, interfaces|
          next unless interfaces.key?(RBLE::BlueZ::DEVICE_INTERFACE)
          next unless path.start_with?(@adapter.path)

          device_props = interfaces[RBLE::BlueZ::DEVICE_INTERFACE]
          handle_device_found(path, device_props)
        end
      end

      def handle_event(event)
        case event.type
        when :device_found
          handle_device_found(event.path, event.data)
        when :device_removed
          handle_device_removed(event.path)
        when :properties_changed
          handle_properties_changed(event.path, event.data)
        when :error
          raise event.data[:exception] if event.data&.key?(:exception)
        end
      end

      def handle_device_found(path, properties)
        return unless path.start_with?(@adapter.path)

        device = build_device(path, properties)
        is_new = !@known_devices.key?(path)

        @known_devices[path] = device

        # Subscribe to property changes for this device
        subscribe_to_device_properties(path) if is_new

        # Callback if new device or allow_duplicates
        if is_new || @allow_duplicates
          @scan_callback&.call(device)
        end
      end

      def handle_device_removed(path)
        @known_devices.delete(path)
      end

      def handle_properties_changed(path, changed)
        return unless @known_devices.key?(path)

        # Update device with changed properties
        old_device = @known_devices[path]
        updates = parse_property_updates(changed)

        return if updates.empty?

        new_device = old_device.update(**updates)
        @known_devices[path] = new_device

        # Callback if allow_duplicates (for RSSI monitoring)
        @scan_callback&.call(new_device) if @allow_duplicates
      end

      def build_device(path, properties)
        Device.new(
          address: properties["Address"]&.upcase || extract_address_from_path(path),
          name: properties["Name"],
          rssi: properties["RSSI"],
          manufacturer_data: parse_manufacturer_data(properties["ManufacturerData"]),
          manufacturer_data_raw: parse_manufacturer_data_raw(properties["ManufacturerData"]),
          service_data: parse_service_data(properties["ServiceData"]),
          service_uuids: properties["UUIDs"] || [],
          tx_power: properties["TxPower"],
          address_type: properties["AddressType"] || "public"
        )
      end

      def parse_property_updates(changed)
        updates = {}
        updates[:name] = changed["Name"] if changed.key?("Name")
        updates[:rssi] = changed["RSSI"] if changed.key?("RSSI")
        updates[:tx_power] = changed["TxPower"] if changed.key?("TxPower")

        if changed.key?("ManufacturerData")
          updates[:manufacturer_data] = parse_manufacturer_data(changed["ManufacturerData"])
          updates[:manufacturer_data_raw] = parse_manufacturer_data_raw(changed["ManufacturerData"])
        end

        if changed.key?("ServiceData")
          updates[:service_data] = parse_service_data(changed["ServiceData"])
        end

        if changed.key?("UUIDs")
          updates[:service_uuids] = changed["UUIDs"] || []
        end

        updates
      end

      # Parse ManufacturerData D-Bus dict (a{qay}) to Hash of byte arrays
      def parse_manufacturer_data(data)
        return {} if data.nil?

        result = {}
        data.each do |company_id, bytes|
          # company_id is uint16, bytes is array of uint8
          result[company_id.to_i] = bytes.map(&:to_i)
        end
        result
      end

      # Parse ManufacturerData to raw binary strings
      def parse_manufacturer_data_raw(data)
        return {} if data.nil?

        result = {}
        data.each do |company_id, bytes|
          result[company_id.to_i] = bytes.map(&:to_i).pack("C*")
        end
        result
      end

      # Parse ServiceData D-Bus dict (a{say}) to Hash of byte arrays
      def parse_service_data(data)
        return {} if data.nil?

        result = {}
        data.each do |uuid, bytes|
          result[uuid.to_s] = bytes.map(&:to_i)
        end
        result
      end

      # Extract MAC address from D-Bus path like /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      def extract_address_from_path(path)
        if path =~ /dev_([0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2})/i
          $1.tr("_", ":").upcase
        else
          "UNKNOWN"
        end
      end

      def cleanup
        @scanning = false
        @event_loop&.stop
        @event_loop = nil
        @signal_handlers.clear
        @connection&.disconnect
        @connection = nil
        @adapter = nil
        @scan_callback = nil
        @known_devices.clear
      end
    end
  end
end
