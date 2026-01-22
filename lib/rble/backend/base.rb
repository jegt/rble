# frozen_string_literal: true

module RBLE
  module Backend
    # Abstract base class for platform-specific BLE backends.
    # Subclasses must implement all public methods.
    class Base
      # Start scanning for BLE devices
      #
      # @param service_uuids [Array<String>, nil] Filter by service UUIDs (nil = all devices)
      # @param allow_duplicates [Boolean] If true, callback fires on every advertisement
      # @param adapter [String, nil] Specific adapter to use (nil = default)
      # @yield [Device] Called when a device is discovered
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def start_scan(service_uuids: nil, allow_duplicates: false, adapter: nil, &block)
        raise NotImplementedError, "#{self.class}#start_scan must be implemented"
      end

      # Stop the current scan
      #
      # @return [void]
      # @raise [NotImplementedError] if not implemented by subclass
      def stop_scan
        raise NotImplementedError, "#{self.class}#stop_scan must be implemented"
      end

      # Check if a scan is currently running
      #
      # @return [Boolean]
      # @raise [NotImplementedError] if not implemented by subclass
      def scanning?
        raise NotImplementedError, "#{self.class}#scanning? must be implemented"
      end

      # List available Bluetooth adapters
      #
      # @return [Array<Hash>] Array of adapter info hashes with :name, :address, :powered keys
      # @raise [NotImplementedError] if not implemented by subclass
      def adapters
        raise NotImplementedError, "#{self.class}#adapters must be implemented"
      end

      # Get the default adapter name
      #
      # @return [String, nil] Default adapter name or nil if none available
      def default_adapter
        adapters.first&.dig(:name)
      end
    end
  end
end
