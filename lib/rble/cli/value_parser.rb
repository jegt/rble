# frozen_string_literal: true

module RBLE
  module CLI
    # Smart parser registry for known BLE characteristic data types.
    #
    # Converts raw binary characteristic values into human-readable strings
    # with appropriate units and formatting. Unknown UUIDs return nil,
    # allowing callers to fall back to hex dump display.
    #
    # @example Parse a known characteristic
    #   ValueParser.parse("2a19", "\x5F".b)  # => "95%"
    #   ValueParser.parse("2a37", "\x00\x48".b)  # => "72 bpm"
    #
    # @example Check if a UUID has a parser
    #   ValueParser.known?("2a19")  # => true
    #   ValueParser.known?("ffff")  # => false
    module ValueParser
      # Body Sensor Location enum (Bluetooth SIG)
      BODY_SENSOR_LOCATIONS = {
        0 => "Other",
        1 => "Chest",
        2 => "Wrist",
        3 => "Finger",
        4 => "Hand",
        5 => "Ear Lobe",
        6 => "Foot"
      }.freeze

      # Registry of parsers keyed by short 4-char characteristic UUID (lowercase).
      # Each parser is a lambda: (raw_bytes_string) -> formatted_string
      PARSERS = {
        # Battery Level: uint8, percentage
        "2a19" => ->(raw) { "#{raw.unpack1('C')}%" },

        # Heart Rate Measurement: flags + uint8/uint16
        "2a37" => ->(raw) {
          flags = raw.getbyte(0)
          hr_16bit = (flags & 0x01) == 1
          if hr_16bit
            hr = raw[1, 2].unpack1('S<')
          else
            hr = raw.getbyte(1)
          end
          "#{hr} bpm"
        },

        # Temperature (Environmental Sensing): sint16 LE / 100
        "2a6e" => ->(raw) {
          raw_val = raw.unpack1('s<')
          temp = raw_val / 100.0
          format('%.2f C', temp)
        },

        # Temperature Measurement (Health Thermometer): flags + IEEE 11073 FLOAT
        "2a1c" => ->(raw) {
          flags = raw.getbyte(0)
          unit = (flags & 0x01) == 0 ? 'C' : 'F'
          temp = ieee_11073_float(raw[1, 4])
          format('%.1f %s', temp, unit)
        },

        # Tx Power Level: sint8, dBm
        "2a07" => ->(raw) { "#{raw.unpack1('c')} dBm" },

        # Blood Pressure Measurement: flags + 3x SFLOAT
        "2a35" => ->(raw) {
          flags = raw.getbyte(0)
          unit = (flags & 0x01) == 0 ? 'mmHg' : 'kPa'
          systolic = ieee_11073_sfloat(raw[1, 2])
          diastolic = ieee_11073_sfloat(raw[3, 2])
          format('%.0f/%.0f %s', systolic, diastolic, unit)
        },

        # Humidity: uint16 LE / 100
        "2a6f" => ->(raw) {
          raw_val = raw.unpack1('S<')
          humidity = raw_val / 100.0
          format('%.2f%%', humidity)
        },

        # Device Name: UTF-8 string
        "2a00" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Model Number String: UTF-8 string
        "2a24" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Serial Number String: UTF-8 string
        "2a25" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Firmware Revision String: UTF-8 string
        "2a26" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Hardware Revision String: UTF-8 string
        "2a27" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Software Revision String: UTF-8 string
        "2a28" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Manufacturer Name String: UTF-8 string
        "2a29" => ->(raw) { raw.force_encoding('UTF-8').scrub('?').strip },

        # Body Sensor Location: uint8 enum
        "2a38" => ->(raw) {
          val = raw.unpack1('C')
          BODY_SENSOR_LOCATIONS.fetch(val, "Location: #{val}")
        }
      }.freeze

      # Parse raw characteristic bytes into a human-readable string.
      #
      # @param uuid [String] Characteristic UUID (short, full, or with 0x prefix)
      # @param raw_bytes [String] Binary string of raw characteristic data
      # @return [String, nil] Formatted value string, or nil if UUID is unknown
      def self.parse(uuid, raw_bytes)
        key = normalize_key(uuid)
        PARSERS[key]&.call(raw_bytes)
      end

      # Check if a UUID has a registered parser.
      #
      # @param uuid [String] Characteristic UUID
      # @return [Boolean]
      def self.known?(uuid)
        key = normalize_key(uuid)
        PARSERS.key?(key)
      end

      # Parse IEEE 11073 32-bit FLOAT.
      # Format: 8-bit exponent (signed) + 24-bit mantissa (signed)
      # Value = mantissa * 10^exponent
      #
      # @param bytes [String] 4-byte binary string (little-endian)
      # @return [Float] Parsed value
      def self.ieee_11073_float(bytes)
        return Float::NAN if bytes.nil? || bytes.bytesize < 4

        # Little-endian: bytes[0..2] = mantissa (24-bit), bytes[3] = exponent (8-bit)
        # Pad to 4 bytes for uint32 unpack, then mask to 24 bits
        mantissa = (bytes[0, 3] + "\x00".b).unpack1('V') & 0x00FFFFFF
        # Sign-extend 24-bit to Ruby integer
        mantissa -= 0x1000000 if mantissa >= 0x800000
        exponent = bytes.getbyte(3)
        exponent -= 256 if exponent >= 128 # sign-extend 8-bit

        # Special values
        return Float::NAN if mantissa == 0x7FFFFF && exponent == 0
        return Float::INFINITY if mantissa == 0x7FFFFE && exponent == 0
        return -Float::INFINITY if mantissa == -0x7FFFFE && exponent == 0

        mantissa * (10.0**exponent)
      end

      # Parse IEEE 11073 16-bit SFLOAT.
      # Format: 4-bit exponent (signed) + 12-bit mantissa (signed)
      # Value = mantissa * 10^exponent
      #
      # @param bytes [String] 2-byte binary string (little-endian)
      # @return [Float] Parsed value
      def self.ieee_11073_sfloat(bytes)
        return Float::NAN if bytes.nil? || bytes.bytesize < 2

        raw = bytes.unpack1('S<')
        mantissa = raw & 0x0FFF
        exponent = (raw >> 12) & 0x0F

        # Sign-extend
        mantissa -= 0x1000 if mantissa >= 0x800
        exponent -= 16 if exponent >= 8

        # Special values
        return Float::NAN if mantissa == 0x7FF && exponent == 0
        return Float::INFINITY if mantissa == 0x7FE && exponent == 0
        return -Float::INFINITY if mantissa == -0x7FE && exponent == 0

        mantissa * (10.0**exponent)
      end

      # Normalize a UUID input to a short 4-char key for PARSERS lookup.
      # Handles: "2a19", "2A19", "0x2a19", "00002a19-0000-1000-8000-00805f9b34fb"
      #
      # @param uuid [String] UUID input
      # @return [String] Normalized short key (lowercase)
      def self.normalize_key(uuid)
        key = uuid.downcase.sub(/\A0x/, '')
        if key =~ /\A0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb\z/
          Regexp.last_match(1)
        else
          key
        end
      end

      private_class_method :normalize_key
    end
  end
end
