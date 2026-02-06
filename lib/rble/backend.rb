# frozen_string_literal: true

require_relative 'backend/base'
require_relative 'errors'

module RBLE
  module Backend
    @backend_mutex = Mutex.new
    @backend_symbol = nil        # :bluez, :corebluetooth
    @backend_instance = nil      # The actual backend object
    @backend_frozen = false      # Locked after first BLE operation

    # Returns the current backend symbol
    # @return [Symbol] :bluez or :corebluetooth
    def self.backend
      @backend_mutex.synchronize do
        ensure_backend_selected
        @backend_symbol
      end
    end

    # Set the backend to use (before first BLE operation)
    # @param value [Symbol, String] Backend name (:bluez, :corebluetooth)
    # @raise [BackendAlreadySelectedError] if backend already frozen
    # @raise [ArgumentError] if backend is invalid for platform
    # @raise [BackendUnavailableError] if backend is unavailable
    def self.backend=(value)
      @backend_mutex.synchronize do
        if @backend_frozen
          raise BackendAlreadySelectedError,
                "Cannot change backend after BLE operations. Current: #{@backend_symbol}"
        end
        perform_backend_selection(value)
      end
    end

    # Get backend information
    # @return [Hash] { name: Symbol, version: String, capabilities: Array }
    def self.backend_info
      {
        name: backend,
        version: backend_version,
        capabilities: backend_capabilities
      }
    end

    # List available backends for the current platform
    # @return [Array<Symbol>] Available backend symbols
    def self.available_backends
      case RUBY_PLATFORM
      when /darwin/
        [:corebluetooth]
      when /linux/
        [:bluez]
      else
        []
      end
    end

    # Returns the appropriate backend for the current platform (singleton)
    # @return [Backend::Base] Platform-specific backend instance
    # @raise [Error] if platform is not supported
    def self.for_platform
      backend_instance
    end

    # Reset the singleton instance (for testing)
    # @api private
    def self.reset!
      @backend_mutex.synchronize do
        @backend_instance&.shutdown if @backend_instance.respond_to?(:shutdown)
        @backend_instance = nil
        @backend_symbol = nil
        @backend_frozen = false
      end
    end

    class << self
      private

      # Ensure a backend is selected (lazy selection)
      # Must be called within @backend_mutex.synchronize
      def ensure_backend_selected
        return if @backend_symbol

        # Check ENV override first (highest priority)
        env_backend = ENV['RBLE_BACKEND']
        if env_backend && !env_backend.empty?
          perform_backend_selection(env_backend)
        else
          perform_backend_selection(platform_default)
        end
      end

      # Get the default backend for the current platform
      # @return [Symbol] Default backend symbol
      # @raise [Error] if platform is not supported
      def platform_default
        case RUBY_PLATFORM
        when /darwin/
          :corebluetooth
        when /linux/
          :bluez
        else
          raise Error, "Unsupported platform: #{RUBY_PLATFORM}"
        end
      end

      # Perform backend selection with validation
      # Must be called within @backend_mutex.synchronize
      # @param value [Symbol, String] Backend name
      def perform_backend_selection(value)
        sym = normalize_backend(value)
        validate_platform_compatibility!(sym)
        validate_backend_availability!(sym)
        @backend_symbol = sym
        @backend_instance = nil # Lazy load
      end

      # Normalize backend value to symbol
      # @param value [Symbol, String] Backend name
      # @return [Symbol] Normalized backend symbol
      def normalize_backend(value)
        value.to_s.downcase.to_sym
      end

      # Validate backend is compatible with current platform
      # @param sym [Symbol] Backend symbol
      # @raise [ArgumentError] if backend is invalid for platform
      def validate_platform_compatibility!(sym)
        available = available_backends
        return if available.include?(sym)

        platform_name = case RUBY_PLATFORM
                        when /darwin/ then 'macOS'
                        when /linux/ then 'Linux'
                        else RUBY_PLATFORM
                        end

        raise ArgumentError,
              "Backend :#{sym} not available on #{platform_name}. Available: #{available.map { |b| ":#{b}" }.join(', ')}"
      end

      # Validate backend can be used
      # @param sym [Symbol] Backend symbol
      # @raise [BackendUnavailableError] if backend is unavailable
      def validate_backend_availability!(sym)
        # :bluez and :corebluetooth validated at use time
      end

      # Get or create backend instance
      # @return [Backend::Base] Backend instance
      def backend_instance
        @backend_mutex.synchronize do
          ensure_backend_selected
          @backend_instance ||= load_backend(@backend_symbol)
          @backend_frozen = true
          @backend_instance
        end
      end

      # Create backend instance
      # @param sym [Symbol] Backend symbol
      # @return [Backend::Base] Backend instance
      def load_backend(sym)
        case sym
        when :bluez
          require_relative 'backend/bluez'
          BlueZ.new
        when :corebluetooth
          require_relative 'backend/corebluetooth'
          CoreBluetooth.new
        else
          raise Error, "Unknown backend: #{sym}"
        end
      end

      # Get backend version
      # @return [String] Version string or 'unknown'
      def backend_version
        inst = backend_instance
        inst.respond_to?(:version) ? inst.version : 'unknown'
      end

      # Get backend capabilities
      # @return [Array] Capabilities array or empty array
      def backend_capabilities
        inst = backend_instance
        inst.respond_to?(:capabilities) ? inst.capabilities : []
      end
    end
  end
end
