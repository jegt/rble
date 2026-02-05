# frozen_string_literal: true

require "spec_helper"

require "rble/cli/hex_dump"

RSpec.describe RBLE::CLI::HexDump do
  describe ".format" do
    it "returns empty string for empty data" do
      expect(described_class.format("".b)).to eq("")
    end

    it "returns empty string for nil" do
      expect(described_class.format(nil)).to eq("")
    end

    it "formats short data as single line with hex and ASCII" do
      result = described_class.format("\x10\x41\x00\xFF".b)
      expect(result).to include("10 41 00 FF")
      expect(result).to include("|.A..|")
    end

    it "shows printable ASCII characters (0x20-0x7E)" do
      result = described_class.format("Hello".b)
      expect(result).to include("48 65 6C 6C 6F")
      expect(result).to include("|Hello|")
    end

    it "shows dots for non-printable bytes" do
      result = described_class.format("\x01\x02\x03".b)
      expect(result).to include("01 02 03")
      expect(result).to include("|...|")
    end

    it "formats exactly 16 bytes as one full row" do
      data = (0..15).map(&:chr).join.b
      result = described_class.format(data)
      lines = result.split("\n")
      expect(lines.size).to eq(1)
    end

    it "formats multi-line data with 16 bytes per row" do
      data = (("A".."Z").to_a.join + "123456").b  # 32 bytes
      result = described_class.format(data)
      lines = result.split("\n")
      expect(lines.size).to eq(2)
    end

    it "pads hex section to consistent width on multi-line output" do
      # 20 bytes: first row 16, second row 4
      data = ("A" * 20).b
      result = described_class.format(data)
      lines = result.split("\n")
      # Both lines should have ASCII section aligned
      expect(lines.size).to eq(2)
      # Second line hex section should be padded
      expect(lines[1]).to match(/\|/)
    end

    it "wraps ASCII section in pipe delimiters" do
      result = described_class.format("AB".b)
      expect(result).to match(/\|AB\|/)
    end
  end
end
