# frozen_string_literal: true

require "spec_helper"

# ValueParser is a standalone module with no external dependencies beyond Ruby stdlib
require "rble/cli/value_parser"

RSpec.describe RBLE::CLI::ValueParser do
  describe ".parse" do
    context "Battery Level (2a19)" do
      it "parses uint8 percentage" do
        expect(described_class.parse("2a19", "\x5F".b)).to eq("95%")
      end
    end

    context "Heart Rate Measurement (2a37)" do
      it "parses uint8 heart rate when flags bit 0 is 0" do
        # flags=0x00 (uint8 HR), HR=72
        expect(described_class.parse("2a37", "\x00\x48".b)).to eq("72 bpm")
      end

      it "parses uint16 heart rate when flags bit 0 is 1" do
        # flags=0x01 (uint16 HR), HR=304 (0x0130 LE)
        expect(described_class.parse("2a37", "\x01\x30\x01".b)).to eq("304 bpm")
      end
    end

    context "Temperature Environmental (2a6e)" do
      it "parses sint16 LE / 100 with C unit" do
        # 2348 as sint16 LE = "\x2C\x09", 2348/100 = 23.48
        expect(described_class.parse("2a6e", "\x2C\x09".b)).to eq("23.48 C")
      end
    end

    context "Temperature Measurement (2a1c)" do
      it "parses IEEE 11073 FLOAT for temperature in Celsius" do
        # flags=0x00 (Celsius), IEEE 11073 FLOAT for 37.2
        # 37.2 = mantissa 372, exponent -1
        # mantissa 372 = 0x000174, exponent -1 = 0xFF
        # Little-endian: [0x74, 0x01, 0x00, 0xFF]
        expect(described_class.parse("2a1c", "\x00\x74\x01\x00\xFF".b)).to eq("37.2 C")
      end

      it "parses IEEE 11073 FLOAT for temperature in Fahrenheit" do
        # flags=0x01 (Fahrenheit), IEEE 11073 FLOAT for 98.6
        # 98.6 = mantissa 986, exponent -1
        # mantissa 986 = 0x0003DA, exponent -1 = 0xFF
        # Little-endian: [0xDA, 0x03, 0x00, 0xFF]
        expect(described_class.parse("2a1c", "\x01\xDA\x03\x00\xFF".b)).to eq("98.6 F")
      end
    end

    context "Tx Power Level (2a07)" do
      it "parses sint8 with dBm unit" do
        # -4 as sint8 = 0xFC
        expect(described_class.parse("2a07", "\xFC".b)).to eq("-4 dBm")
      end
    end

    context "Blood Pressure Measurement (2a35)" do
      it "parses 3x SFLOAT for systolic/diastolic in mmHg" do
        # flags=0x00 (mmHg)
        # SFLOAT for 120: mantissa=120 (0x078), exponent=0 -> raw = 0x0078
        # SFLOAT for 80: mantissa=80 (0x050), exponent=0 -> raw = 0x0050
        # SFLOAT for 0 (MAP): mantissa=0, exponent=0 -> raw = 0x0000
        # Little-endian: [0x78, 0x00], [0x50, 0x00], [0x00, 0x00]
        expect(described_class.parse("2a35", "\x00\x78\x00\x50\x00\x00\x00".b)).to eq("120/80 mmHg")
      end
    end

    context "Humidity (2a6f)" do
      it "parses uint16 LE / 100 with percent" do
        # 6534 as uint16 LE = "\x86\x19", 6534/100 = 65.34
        expect(described_class.parse("2a6f", "\x86\x19".b)).to eq("65.34%")
      end
    end

    context "Device Name (2a00)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a00", "Polar H10".b)).to eq("Polar H10")
      end
    end

    context "Firmware Revision String (2a26)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a26", "1.2.3".b)).to eq("1.2.3")
      end
    end

    context "Serial Number String (2a25)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a25", "ABC123".b)).to eq("ABC123")
      end
    end

    context "Manufacturer Name String (2a29)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a29", "Polar Electro".b)).to eq("Polar Electro")
      end
    end

    context "Model Number String (2a24)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a24", "H10".b)).to eq("H10")
      end
    end

    context "Hardware Revision String (2a27)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a27", "2.0.0".b)).to eq("2.0.0")
      end
    end

    context "Software Revision String (2a28)" do
      it "parses UTF-8 string" do
        expect(described_class.parse("2a28", "3.1.0".b)).to eq("3.1.0")
      end
    end

    context "Body Sensor Location (2a38)" do
      it "parses uint8 enum to location name" do
        expect(described_class.parse("2a38", "\x01".b)).to eq("Chest")
      end

      it "parses all known locations" do
        expect(described_class.parse("2a38", "\x00".b)).to eq("Other")
        expect(described_class.parse("2a38", "\x02".b)).to eq("Wrist")
        expect(described_class.parse("2a38", "\x03".b)).to eq("Finger")
        expect(described_class.parse("2a38", "\x04".b)).to eq("Hand")
        expect(described_class.parse("2a38", "\x05".b)).to eq("Ear Lobe")
        expect(described_class.parse("2a38", "\x06".b)).to eq("Foot")
      end

      it "falls back to numeric for unknown location" do
        expect(described_class.parse("2a38", "\x07".b)).to eq("Location: 7")
      end
    end

    context "unknown UUID" do
      it "returns nil" do
        expect(described_class.parse("ffff", "\x01\x02".b)).to be_nil
      end
    end
  end

  describe ".known?" do
    it "returns true for known UUID" do
      expect(described_class.known?("2a19")).to be true
    end

    it "returns false for unknown UUID" do
      expect(described_class.known?("ffff")).to be false
    end

    it "is case-insensitive" do
      expect(described_class.known?("2A19")).to be true
    end

    it "handles 0x prefix" do
      expect(described_class.known?("0x2a19")).to be true
    end

    it "handles full 128-bit UUID" do
      expect(described_class.known?("00002a19-0000-1000-8000-00805f9b34fb")).to be true
    end
  end

  describe ".parse case insensitivity" do
    it "handles uppercase short UUID" do
      expect(described_class.parse("2A19", "\x5F".b)).to eq("95%")
    end

    it "handles 0x prefix" do
      expect(described_class.parse("0x2a19", "\x5F".b)).to eq("95%")
    end

    it "handles full 128-bit UUID" do
      expect(described_class.parse("00002a19-0000-1000-8000-00805f9b34fb", "\x5F".b)).to eq("95%")
    end
  end

  describe "PARSERS" do
    it "is frozen" do
      expect(described_class::PARSERS).to be_frozen
    end
  end
end
