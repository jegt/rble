# frozen_string_literal: true

module RBLE
  module BlueZ
    # Wraps a BlueZ Bluetooth adapter (org.bluez.Adapter1)
    class Adapter
      attr_reader :path, :name

      # @param connection [DBusConnection] Active D-Bus connection
      # @param path [String] D-Bus object path (e.g., "/org/bluez/hci0")
      def initialize(connection, path)
        @connection = connection
        @path = path
        @name = path.split('/').last # "hci0" from "/org/bluez/hci0"
        @object = connection.object(path)
        @adapter_iface = @object[ADAPTER_INTERFACE]
        @properties_iface = @object[PROPERTIES_INTERFACE]
      end

      # Create an Adapter from a DBusSession
      # @param session [DBusSession] Active D-Bus session
      # @param path [String] D-Bus object path (e.g., "/org/bluez/hci0")
      # @return [Adapter]
      def self.new_from_session(session, path)
        adapter = allocate
        adapter.instance_variable_set(:@path, path)
        adapter.instance_variable_set(:@name, path.split('/').last)
        object = session.object(path)
        object.introspect
        adapter.instance_variable_set(:@object, object)
        adapter.instance_variable_set(:@adapter_iface, object[ADAPTER_INTERFACE])
        adapter.instance_variable_set(:@properties_iface, object[PROPERTIES_INTERFACE])
        adapter
      end

      # Get adapter MAC address
      # @return [String]
      def address
        get_property('Address')
      end

      # Check if adapter is powered on
      # @return [Boolean]
      def powered?
        get_property('Powered')
      end

      # Check if discovery is in progress
      # @return [Boolean]
      def discovering?
        get_property('Discovering')
      end

      # Set discovery filter before starting scan
      # @param service_uuids [Array<String>, nil] Filter by these UUIDs
      # @param allow_duplicates [Boolean] Receive every advertisement
      def set_discovery_filter(service_uuids: nil, allow_duplicates: false)
        filter = {}

        # Transport: 'le' for BLE only (not classic Bluetooth)
        filter['Transport'] = DBus::Data::Variant.new('le', member_type: DBus::Type::STRING)

        # DuplicateData: whether to receive every advertisement packet
        filter['DuplicateData'] = DBus::Data::Variant.new(allow_duplicates, member_type: DBus::Type::BOOLEAN)

        # UUIDs: filter by service UUIDs if provided
        if service_uuids && !service_uuids.empty?
          # Normalize UUIDs to lowercase with hyphens (BlueZ format)
          normalized = service_uuids.map { |uuid| normalize_uuid(uuid) }
          filter['UUIDs'] = DBus::Data::Variant.new(normalized, member_type: DBus::Type::Array[DBus::Type::STRING])
        end

        @adapter_iface.SetDiscoveryFilter(filter)
      rescue DBus::Error => e
        raise ScanError, "Failed to set discovery filter: #{e.message}"
      end

      # Start BLE discovery
      # @raise [ScanInProgressError] if already scanning
      # @raise [AdapterDisabledError] if adapter not powered
      def start_discovery
        raise AdapterDisabledError.new(@name) unless powered?
        raise ScanInProgressError if discovering?

        @adapter_iface.StartDiscovery
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
        return unless discovering?

        @adapter_iface.StopDiscovery
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
