# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wraps a BlueZ Bluetooth adapter (org.bluez.Adapter1)
    class Adapter
      attr_reader :path, :name

      # Create an Adapter from a DBusSession
      # @param session [DBusSession] Active D-Bus session
      # @param path [String] D-Bus object path (e.g., "/org/bluez/hci0")
      # @return [Adapter]
      def self.new_from_session(session, path)
        adapter = allocate
        adapter.instance_variable_set(:@session, session)
        adapter.instance_variable_set(:@path, path)
        adapter.instance_variable_set(:@name, path.split('/').last)
        # Async introspect for non-blocking setup
        proxy = session.async_introspect(path, timeout: 5)
        adapter.instance_variable_set(:@object, proxy)
        adapter.instance_variable_set(:@adapter_iface, proxy[ADAPTER_INTERFACE])
        adapter.instance_variable_set(:@properties_iface, proxy[PROPERTIES_INTERFACE])
        adapter
      end

      # Get adapter MAC address
      # @return [String]
      def address
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Address', timeout: 5)
      end

      # Check if adapter is powered on
      # @return [Boolean]
      def powered?
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Powered', timeout: 5)
      end

      # Check if discovery is in progress
      # @return [Boolean]
      def discovering?
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Discovering', timeout: 5)
      end

      # Check if adapter is discoverable
      # @return [Boolean]
      def discoverable?
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Discoverable', timeout: 5)
      end

      # Check if adapter is pairable
      # @return [Boolean]
      def pairable?
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Pairable', timeout: 5)
      end

      # Get adapter alias (friendly name)
      # @return [String]
      def alias_name
        @session.async_get_property(@path, ADAPTER_INTERFACE, 'Alias', timeout: 5)
      end

      # Set adapter power state
      # @param value [Boolean] true to power on, false to power off
      def set_powered(value)
        @session.async_set_property(@path, ADAPTER_INTERFACE, 'Powered', value, timeout: 5)
      end

      # Set adapter discoverable mode
      # @param value [Boolean] true to enable, false to disable
      def set_discoverable(value)
        @session.async_set_property(@path, ADAPTER_INTERFACE, 'Discoverable', value, timeout: 5)
      end

      # Set adapter pairable mode
      # @param value [Boolean] true to enable, false to disable
      def set_pairable(value)
        @session.async_set_property(@path, ADAPTER_INTERFACE, 'Pairable', value, timeout: 5)
      end

      # Set adapter alias (friendly name)
      # @param name [String] New alias
      def set_alias(name)
        @session.async_set_property(@path, ADAPTER_INTERFACE, 'Alias', name, timeout: 5)
      end

      # Set discovery filter before starting scan
      # @param service_uuids [Array<String>, nil] Filter by these UUIDs
      # @param allow_duplicates [Boolean] Receive every advertisement
      # @param rssi [Integer, nil] Minimum RSSI value
      # @param pathloss [Integer, nil] Maximum path loss
      def set_discovery_filter(service_uuids: nil, allow_duplicates: false, rssi: nil, pathloss: nil)
        # Build filter options for async method
        filter_options = {
          transport: 'le',
          duplicate_data: allow_duplicates
        }

        # Add optional filters
        if service_uuids && !service_uuids.empty?
          filter_options[:uuids] = service_uuids.map { |uuid| normalize_uuid(uuid) }
        end
        filter_options[:rssi] = rssi if rssi
        filter_options[:pathloss] = pathloss if pathloss

        # Store filter for application in start_discovery via async_start_discovery
        @pending_filter = filter_options
      rescue DBus::Error => e
        raise ScanError, "Failed to set discovery filter: #{e.message}"
      end

      # Start BLE discovery
      def start_discovery
        # Async path: idempotent, handles powered? check internally
        filter = @pending_filter || { transport: 'le' }
        @session.async_start_discovery(@path, filter: filter, timeout: 10)
        @pending_filter = nil
      rescue DBus::Error => e
        if e.message.include?('InProgress')
          raise ScanInProgressError
        elsif e.message.include?('NotReady') || e.message.include?('NotPowered')
          raise AdapterDisabledError.new(@name)
        end
        raise ScanError, "Failed to start discovery: #{e.message}"
      end

      # Stop BLE discovery
      def stop_discovery
        # Async path: idempotent, no need to check discovering?
        @session.async_stop_discovery(@path, timeout: 10)
      rescue DBus::Error => e
        # Ignore "not discovering" errors during cleanup
        unless e.message.include?('NotAuthorized') || e.message.include?('NotDiscovering')
          raise ScanError, "Failed to stop discovery: #{e.message}"
        end
      end

      # Get adapter info as hash
      # @return [Hash] with adapter properties
      def to_h
        {
          name: @name,
          address: address,
          powered: powered?,
          discoverable: discoverable?,
          pairable: pairable?,
          alias: alias_name,
          discovering: discovering?
        }
      end

      private

      # Normalize UUID to BlueZ format (lowercase, with hyphens for 128-bit)
      def normalize_uuid(uuid)
        uuid = uuid.to_s.downcase.delete('-')

        # 16-bit UUIDs (4 hex chars) stay short
        return uuid if uuid.length == 4

        # 32-bit and 128-bit get full format with hyphens
        if uuid.length == 32
          "#{uuid[0..7]}-#{uuid[8..11]}-#{uuid[12..15]}-#{uuid[16..19]}-#{uuid[20..31]}"
        else
          uuid
        end
      end
    end
  end
end
