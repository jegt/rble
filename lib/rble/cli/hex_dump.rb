# frozen_string_literal: true

module RBLE
  module CLI
    # Hex + ASCII dump formatter for unknown BLE characteristic data.
    #
    # Produces output similar to `hexdump -C` with hex bytes on the left
    # and printable ASCII on the right, wrapped in pipe delimiters.
    #
    # @example Short data (single line)
    #   HexDump.format("\x10\x41\x00\xFF".b)
    #   # => "10 41 00 FF  |.A..|"
    #
    # @example Multi-line data
    #   HexDump.format(long_data)
    #   # => "41 42 43 44 45 46 47 48 49 4A 4B 4C 4D 4E 4F 50  |ABCDEFGHIJKLMNOP|"
    #   #    "51 52 53 54                                        |QRST|"
    module HexDump
      BYTES_PER_ROW = 16

      # Format raw bytes as hex + ASCII dump.
      #
      # @param raw_bytes [String, nil] Binary string to format
      # @return [String] Formatted hex+ASCII dump (empty string if no data)
      def self.format(raw_bytes)
        return "" if raw_bytes.nil? || raw_bytes.empty?

        bytes = raw_bytes.bytes
        rows = bytes.each_slice(BYTES_PER_ROW).map { |row| format_row(row) }
        rows.join("\n")
      end

      # Format a single row of bytes.
      #
      # @param row [Array<Integer>] Up to 16 bytes
      # @return [String] Formatted row with hex and ASCII sections
      def self.format_row(row)
        hex = row.map { |b| "%02X" % b }.join(' ')
        # Pad hex section to consistent width: 16 * 3 - 1 = 47 chars
        hex = hex.ljust(47)
        ascii = row.map { |b| (0x20..0x7E).include?(b) ? b.chr : '.' }.join
        "#{hex}  |#{ascii}|"
      end

      private_class_method :format_row
    end
  end
end
