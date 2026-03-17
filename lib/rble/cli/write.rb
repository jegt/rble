# frozen_string_literal: true

require_relative 'characteristic_helpers'

module RBLE
  module CLI
    class Write
      include CharacteristicHelpers

      # Type flag names -> encoder method symbols
      ENCODERS = {
        "hex"    => :encode_hex,
        "string" => :encode_string,
        "uint8"  => :encode_uint8,
        "uint16" => :encode_uint16,
        "uint32" => :encode_uint32,
        "int8"   => :encode_int8,
        "int16"  => :encode_int16,
        "int32"  => :encode_int32
      }.freeze

      # Range limits for integer types
      RANGES = {
        uint8:  0..255,
        uint16: 0..65_535,
        uint32: 0..4_294_967_295,
        int8:   -128..127,
        int16:  -32_768..32_767,
        int32:  -2_147_483_648..2_147_483_647
      }.freeze

      def initialize(options)
        @options = options
        @formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        @address = options["address"]
        @characteristic_uuid = options["characteristic"]
        @value = options["value"]
        @timeout = options["timeout"] || 10
        @verify = options["verify"] || false
      end

      def execute
        type_flag = detect_type_flag
        encoded = encode(@value, type_flag)

        connection = connect_and_discover(@address, timeout: @timeout)

        begin
          char = find_characteristic(connection, @characteristic_uuid)

          # Auto-detect write mode: prefer write-with-response, fall back to write-without-response
          response = if char.writable?
                       true
                     elsif char.writable_without_response?
                       false
                     else
                       $stderr.puts "Error: Characteristic #{@characteristic_uuid} does not support write."
                       $stderr.puts "Supported: #{char.flags.join(', ')}"
                       exit 1
                     end

          name = resolve_char_name(char.uuid)
          $stderr.puts "Writing to #{name}..."
          char.write(encoded, response: response)
          $stderr.puts "Write successful"

          verified_value = nil
          if @verify
            if char.readable?
              $stderr.puts "Verifying..."
              raw_readback = char.read
              verified_value = format_value(char.uuid, raw_readback)
              $stderr.puts "Verified: #{verified_value}"
            else
              $stderr.puts "Warning: Cannot verify -- characteristic is not readable"
            end
          end

          char_name = RBLE::GATT::UUIDDatabase.resolve(char.uuid, type: :characteristic)
          @formatter.write_result(
            address: @address,
            uuid: char.uuid,
            name: char_name,
            success: true,
            verified: verified_value,
            written_bytes: encoded
          )
        ensure
          connection.disconnect if connection.connected?
        end
      rescue RBLE::DeviceNotFoundError => e
        $stderr.puts "Error: #{e.message}"
        $stderr.puts "Run `rble scan` first to discover nearby devices."
        exit 1
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end

      private

      # Detect which type flag the user set. Exactly one must be present.
      # @return [String] The type flag name ("hex", "string", "uint8", etc.)
      # @raise [SystemExit] if zero or multiple type flags set
      def detect_type_flag
        active = ENCODERS.keys.select { |flag| @options[flag] }

        if active.empty?
          $stderr.puts "Error: Exactly one type flag required: --hex, --string, --uint8, --uint16, --uint32, --int8, --int16, --int32"
          exit 1
        elsif active.size > 1
          $stderr.puts "Error: Only one type flag allowed, got: #{active.map { |f| "--#{f}" }.join(', ')}"
          exit 1
        end

        active.first
      end

      # Encode value string based on type flag.
      # @param value_string [String] User-provided value
      # @param type_flag [String] Type flag name
      # @return [String] Encoded binary string
      def encode(value_string, type_flag)
        send(ENCODERS[type_flag], value_string)
      end

      def encode_hex(value)
        hex = value.sub(/\A0x/i, '')
        unless hex.match?(/\A[0-9a-fA-F]+\z/)
          $stderr.puts "Error: Invalid hex string: '#{value}'. Expected hex digits (e.g., '0A1BFF')"
          exit 1
        end
        unless hex.length.even?
          $stderr.puts "Error: Hex string must have even length, got #{hex.length} characters"
          exit 1
        end
        [hex].pack('H*')
      end

      def encode_string(value)
        value.encode('UTF-8')
      end

      def encode_uint8(value)
        v = parse_integer(value)
        validate_range(v, :uint8)
        [v].pack('C')
      end

      def encode_uint16(value)
        v = parse_integer(value)
        validate_range(v, :uint16)
        [v].pack('S<')
      end

      def encode_uint32(value)
        v = parse_integer(value)
        validate_range(v, :uint32)
        [v].pack('L<')
      end

      def encode_int8(value)
        v = parse_integer(value)
        validate_range(v, :int8)
        [v].pack('c')
      end

      def encode_int16(value)
        v = parse_integer(value)
        validate_range(v, :int16)
        [v].pack('s<')
      end

      def encode_int32(value)
        v = parse_integer(value)
        validate_range(v, :int32)
        [v].pack('l<')
      end

      def parse_integer(value)
        Integer(value, 10)
      rescue ArgumentError
        $stderr.puts "Error: Invalid integer: '#{value}'. Use decimal digits only."
        exit 1
      end

      def validate_range(v, type)
        range = RANGES[type]
        return if range.include?(v)

        $stderr.puts "Error: Value #{v} out of range for #{type} (#{range.min} to #{range.max})"
        exit 1
      end
    end
  end
end
