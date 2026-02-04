# frozen_string_literal: true

require "spec_helper"

RSpec.describe RBLE::Device do
  describe "#manufacturer_data_bytes" do
    it "returns binary string for known company_id" do
      raw_data = [0xFF, 0x05, 0x12, 0x34].pack("C*")
      device = described_class.new(
        address: "AA:BB:CC:DD:EE:FF",
        manufacturer_data_raw: { 0x0499 => raw_data }
      )

      result = device.manufacturer_data_bytes(0x0499)
      expect(result).to eq(raw_data)
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it "returns nil for unknown company_id" do
      device = described_class.new(
        address: "AA:BB:CC:DD:EE:FF",
        manufacturer_data_raw: { 0x0499 => "data" }
      )

      expect(device.manufacturer_data_bytes(0x004C)).to be_nil
    end

    it "returns nil when no manufacturer data" do
      device = described_class.new(address: "AA:BB:CC:DD:EE:FF")
      expect(device.manufacturer_data_bytes(0x0499)).to be_nil
    end
  end
end
