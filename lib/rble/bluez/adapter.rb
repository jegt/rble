# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wraps a BlueZ Bluetooth adapter (org.bluez.Adapter1)
    class Adapter
      attr_reader :path, :name

      # @param connection [DBusConnection] Active D-Bus connection
      # @param path [String] D-Bus object path (e.g., "/org/bluez/hci0")
      # @deprecated Use new_from_session instead for async operations
      def initialize(connection, path)
        @connection = connection
        @session = nil
        @path = path
        @name = path.split('/').last # "hci0" from "/org/bluez/hci0"
        @object = connection.object(path)
        @adapter_iface = @object[ADAPTER_INTERFACE]
        @properties_iface = @object[PROPERTIES_INTERFACE]
      end

      # Create an Adapter from a DBusSession
      # This is the preferred constructor for async operations
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
        if @session
          @session.async_get_property(@path, ADAPTER_INTERFACE, 'Address', timeout: 5)
        else
          get_property('Address')
        end
      end

      # Check if adapter is powered on
      # @return [Boolean]
      def powered?
        if @session
          @session.async_get_property(@path, ADAPTER_INTERFACE, 'Powered', timeout: 5)
        else
          get_property('Powered')
        end
      end

      # Check if discovery is in progress
      # @return [Boolean]
      def discovering?
        if @session
          @session.async_get_property(@path, ADAPTER_INTERFACE, 'Discovering', timeout: 5)
        else
          get_property('Discovering')
        end
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

        # If using session, delegate to async_start_discovery (which handles filter)
        # Otherwise fall back to synchronous call for backward compatibility
        unless @session
          # Legacy synchronous path
          filter = build_legacy_filter(filter_options)
          @adapter_iface.SetDiscoveryFilter(filter)
        end
        # When using @session, filter is applied in start_discovery via async_start_discovery
        @pending_filter = filter_options if @session
      rescue DBus::Error => e
        raise ScanError, "Failed to set discovery filter: #{e.message}"
      end

      # Start BLE discovery
      # @raise [AdapterDisabledError] if adapter not powered (legacy mode only)
      def start_discovery
        if @session
          # Async path: idempotent, handles powered? check internally
          filter = @pending_filter || { transport: 'le' }
          @session.async_start_discovery(@path, filter: filter, timeout: 10)
          @pending_filter = nil
        else
          # Legacy synchronous path
          raise AdapterDisabledError.new(@name) unless powered?
          raise ScanInProgressError if discovering?

          @adapter_iface.StartDiscovery
        end
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
        if @session
          # Async path: idempotent, no need to check discovering?
          @session.async_stop_discovery(@path, timeout: 10)
        else
          # Legacy synchronous path
          return unless discovering?

          @adapter_iface.StopDiscovery
        end
      rescue DBus::Error => e
        # Ignore "not discovering" errors during cleanup
        unless e.message.include?('NotAuthorized') || e.message.include?('NotDiscovering')
          raise ScanError, "Failed to stop discovery: #{e.message}"
        end
      end

      # Get adapter info as hash
      # @return [Hash] with :name, :address, :powered keys
      def to_h
        {
          name: @name,
          address: address,
          powered: powered?
        }
      end

      private

      def get_property(name)
        @properties_iface.Get(ADAPTER_INTERFACE, name).first
      rescue DBus::Error
        nil
      end

      # Build legacy D-Bus filter hash from filter options
      # @param options [Hash] Filter options
      # @return [Hash] D-Bus compatible filter hash with Variants
      def build_legacy_filter(options)
        filter = {}

        # Transport: STRING
        if options[:transport]
          filter['Transport'] = DBus::Data::Variant.new(
            options[:transport].to_s,
            member_type: DBus::Type::STRING
          )
        end

        # DuplicateData: BOOLEAN
        if options.key?(:duplicate_data)
          filter['DuplicateData'] = DBus::Data::Variant.new(
            !!options[:duplicate_data],
            member_type: DBus::Type::BOOLEAN
          )
        end

        # UUIDs: Array[STRING]
        if options[:uuids] && !options[:uuids].empty?
          filter['UUIDs'] = DBus::Data::Variant.new(
            options[:uuids],
            member_type: DBus::Type::Array[DBus::Type::STRING]
          )
        end

        # RSSI: INT16
        if options[:rssi]
          filter['RSSI'] = DBus::Data::Variant.new(
            options[:rssi].to_i,
            member_type: DBus::Type::INT16
          )
        end

        # Pathloss: UINT16
        if options[:pathloss]
          filter['Pathloss'] = DBus::Data::Variant.new(
            options[:pathloss].to_i,
            member_type: DBus::Type::UINT16
          )
        end

        filter
      end

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
