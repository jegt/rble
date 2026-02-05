# frozen_string_literal: true

require "spec_helper"
require "rble/gatt/uuid_database"

RSpec.describe RBLE::GATT::UUIDDatabase do
  describe "constants" do
    it "defines SERVICES as a frozen hash" do
      expect(described_class::SERVICES).to be_a(Hash)
      expect(described_class::SERVICES).to be_frozen
    end

    it "defines CHARACTERISTICS as a frozen hash" do
      expect(described_class::CHARACTERISTICS).to be_a(Hash)
      expect(described_class::CHARACTERISTICS).to be_frozen
    end

    it "defines DESCRIPTORS as a frozen hash" do
      expect(described_class::DESCRIPTORS).to be_a(Hash)
      expect(described_class::DESCRIPTORS).to be_frozen
    end

    it "has all lowercase keys in SERVICES" do
      described_class::SERVICES.each_key do |key|
        expect(key).to eq(key.downcase), "Expected key '#{key}' to be lowercase"
      end
    end

    it "has all lowercase keys in CHARACTERISTICS" do
      described_class::CHARACTERISTICS.each_key do |key|
        expect(key).to eq(key.downcase), "Expected key '#{key}' to be lowercase"
      end
    end

    it "has all lowercase keys in DESCRIPTORS" do
      described_class::DESCRIPTORS.each_key do |key|
        expect(key).to eq(key.downcase), "Expected key '#{key}' to be lowercase"
      end
    end

    it "includes at least 60 standard services" do
      standard_count = described_class::SERVICES.keys.count { |k| k.length == 4 }
      expect(standard_count).to be >= 60
    end

    it "includes at least 80 standard characteristics" do
      standard_count = described_class::CHARACTERISTICS.keys.count { |k| k.length == 4 }
      expect(standard_count).to be >= 80
    end

    it "includes at least 10 standard descriptors" do
      standard_count = described_class::DESCRIPTORS.keys.count { |k| k.length == 4 }
      expect(standard_count).to be >= 10
    end

    it "includes vendor services" do
      # Nordic UART Service
      expect(described_class::SERVICES).to have_key("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
    end

    it "includes vendor characteristics" do
      # Nordic UART RX
      expect(described_class::CHARACTERISTICS).to have_key("6e400002-b5a3-f393-e0a9-e50e24dcca9e")
      # Nordic UART TX
      expect(described_class::CHARACTERISTICS).to have_key("6e400003-b5a3-f393-e0a9-e50e24dcca9e")
    end
  end

  describe ".resolve" do
    context "with type: :service" do
      it "resolves short UUID to service name" do
        expect(described_class.resolve("180d", type: :service)).to eq("Heart Rate")
      end

      it "resolves full Bluetooth Base UUID to service name" do
        result = described_class.resolve("0000180d-0000-1000-8000-00805f9b34fb", type: :service)
        expect(result).to eq("Heart Rate")
      end

      it "resolves case-insensitively" do
        expect(described_class.resolve("180D", type: :service)).to eq("Heart Rate")
      end

      it "resolves Generic Access service" do
        expect(described_class.resolve("1800", type: :service)).to eq("Generic Access")
      end

      it "resolves Battery Service" do
        expect(described_class.resolve("180f", type: :service)).to eq("Battery Service")
      end

      it "resolves Device Information service" do
        expect(described_class.resolve("180a", type: :service)).to eq("Device Information")
      end

      it "resolves vendor UUID (Nordic UART Service)" do
        result = described_class.resolve("6e400001-b5a3-f393-e0a9-e50e24dcca9e", type: :service)
        expect(result).to eq("Nordic UART Service")
      end

      it "resolves vendor UUID case-insensitively" do
        result = described_class.resolve("6E400001-B5A3-F393-E0A9-E50E24DCCA9E", type: :service)
        expect(result).to eq("Nordic UART Service")
      end

      it "returns nil for unknown UUID" do
        expect(described_class.resolve("ffff", type: :service)).to be_nil
      end
    end

    context "with type: :characteristic" do
      it "resolves Heart Rate Measurement" do
        expect(described_class.resolve("2a37", type: :characteristic)).to eq("Heart Rate Measurement")
      end

      it "resolves full UUID for Heart Rate Measurement" do
        result = described_class.resolve("00002a37-0000-1000-8000-00805f9b34fb", type: :characteristic)
        expect(result).to eq("Heart Rate Measurement")
      end

      it "resolves Device Name" do
        expect(described_class.resolve("2a00", type: :characteristic)).to eq("Device Name")
      end

      it "resolves Battery Level" do
        expect(described_class.resolve("2a19", type: :characteristic)).to eq("Battery Level")
      end

      it "resolves Body Sensor Location" do
        expect(described_class.resolve("2a38", type: :characteristic)).to eq("Body Sensor Location")
      end

      it "resolves vendor characteristic (Nordic UART RX)" do
        result = described_class.resolve("6e400002-b5a3-f393-e0a9-e50e24dcca9e", type: :characteristic)
        expect(result).to eq("Nordic UART RX")
      end

      it "returns nil for unknown UUID" do
        expect(described_class.resolve("ffff", type: :characteristic)).to be_nil
      end
    end

    context "with type: :descriptor" do
      it "resolves Client Characteristic Configuration" do
        expect(described_class.resolve("2902", type: :descriptor)).to eq("Client Characteristic Configuration")
      end

      it "resolves Characteristic User Description" do
        expect(described_class.resolve("2901", type: :descriptor)).to eq("Characteristic User Description")
      end

      it "resolves full UUID for CCCD" do
        result = described_class.resolve("00002902-0000-1000-8000-00805f9b34fb", type: :descriptor)
        expect(result).to eq("Client Characteristic Configuration")
      end

      it "returns nil for unknown UUID" do
        expect(described_class.resolve("ffff", type: :descriptor)).to be_nil
      end
    end

    context "without type (searches all databases)" do
      it "finds service by short UUID" do
        expect(described_class.resolve("180d")).to eq("Heart Rate")
      end

      it "finds characteristic by short UUID" do
        expect(described_class.resolve("2a37")).to eq("Heart Rate Measurement")
      end

      it "finds descriptor by short UUID" do
        expect(described_class.resolve("2902")).to eq("Client Characteristic Configuration")
      end

      it "finds vendor service without type" do
        result = described_class.resolve("6e400001-b5a3-f393-e0a9-e50e24dcca9e")
        expect(result).to eq("Nordic UART Service")
      end

      it "returns nil for unknown UUID without type" do
        expect(described_class.resolve("dead-beef-1234-5678-abcdef012345")).to be_nil
      end
    end
  end

  describe ".extract_short_uuid" do
    it "extracts short UUID from standard Bluetooth Base UUID" do
      expect(described_class.extract_short_uuid("0000180d-0000-1000-8000-00805f9b34fb")).to eq("180d")
    end

    it "returns short UUID as-is" do
      expect(described_class.extract_short_uuid("180d")).to eq("180d")
    end

    it "returns vendor UUID as-is (not in Bluetooth Base range)" do
      uuid = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
      expect(described_class.extract_short_uuid(uuid)).to eq(uuid)
    end

    it "handles uppercase input" do
      expect(described_class.extract_short_uuid("0000180D-0000-1000-8000-00805F9B34FB")).to eq("180d")
    end

    it "handles uppercase short UUID" do
      expect(described_class.extract_short_uuid("180D")).to eq("180d")
    end
  end

  describe ".standard_uuid?" do
    it "returns true for short 4-char hex strings" do
      expect(described_class.standard_uuid?("180d")).to be true
    end

    it "returns true for Bluetooth Base UUID" do
      expect(described_class.standard_uuid?("0000180d-0000-1000-8000-00805f9b34fb")).to be true
    end

    it "returns false for vendor 128-bit UUID" do
      expect(described_class.standard_uuid?("6e400001-b5a3-f393-e0a9-e50e24dcca9e")).to be false
    end

    it "handles uppercase input" do
      expect(described_class.standard_uuid?("0000180D-0000-1000-8000-00805F9B34FB")).to be true
    end

    it "returns true for uppercase short UUID" do
      expect(described_class.standard_uuid?("180D")).to be true
    end
  end
end
