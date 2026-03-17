# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "json"
require "stringio"

RSpec.describe RBLE::CLI::Formatters::Json do
  subject(:formatter) { described_class.new }

  def capture_stdout
    original = $stdout
    $stdout = StringIO.new
    yield
    $stdout.string
  ensure
    $stdout = original
  end

  def make_device(address: "AA:BB:CC:DD:EE:FF", name: nil, rssi: nil, address_type: "public", manufacturer_data: {})
    RBLE::Device.new(address: address, name: name, rssi: rssi, address_type: address_type, manufacturer_data: manufacturer_data)
  end

  describe "#device" do
    it "outputs valid JSON" do
      device = make_device(name: "TestDevice", rssi: -72)
      output = capture_stdout { formatter.device(device) }

      expect { JSON.parse(output) }.not_to raise_error
    end

    it "contains address, name, rssi, and address_type keys" do
      device = make_device(name: "TestDevice", rssi: -72)
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed).to include(
        "address" => "AA:BB:CC:DD:EE:FF",
        "name" => "TestDevice",
        "rssi" => -72,
        "address_type" => "public"
      )
    end

    it "outputs null for nil name" do
      device = make_device(rssi: -80)
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed["name"]).to be_nil
    end

    it "outputs null for nil rssi" do
      device = make_device(name: "Test")
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed["rssi"]).to be_nil
    end

    it "includes company_id and company when manufacturer data present" do
      device = make_device(rssi: -65, manufacturer_data: { 0x0075 => [0x01, 0x02] })
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed["company_id"]).to eq(0x0075)
      expect(parsed["company"]).to eq("Samsung")
    end

    it "includes company_id and company for Apple manufacturer data" do
      device = make_device(rssi: -65, manufacturer_data: { 0x004C => [0x01, 0x02] })
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed["company_id"]).to eq(0x004C)
      expect(parsed["company"]).to eq("Apple")
    end

    it "includes company_id with nil company for unknown manufacturer" do
      device = make_device(rssi: -65, manufacturer_data: { 0xFFFF => [0x01] })
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed["company_id"]).to eq(0xFFFF)
      expect(parsed["company"]).to be_nil
    end

    it "omits company fields when no manufacturer data" do
      device = make_device(name: "Test", rssi: -50)
      output = capture_stdout { formatter.device(device) }
      parsed = JSON.parse(output)

      expect(parsed).not_to have_key("company_id")
      expect(parsed).not_to have_key("company")
    end

    it "outputs one JSON object per line (NDJSON)" do
      device1 = make_device(address: "11:22:33:44:55:66", name: "A", rssi: -50)
      device2 = make_device(address: "AA:BB:CC:DD:EE:FF", name: "B", rssi: -60)

      output = capture_stdout do
        formatter.device(device1)
        formatter.device(device2)
      end

      lines = output.strip.split("\n")
      expect(lines.size).to eq(2)
      expect(JSON.parse(lines[0])["address"]).to eq("11:22:33:44:55:66")
      expect(JSON.parse(lines[1])["address"]).to eq("AA:BB:CC:DD:EE:FF")
    end
  end

  describe "#read_value" do
    it "uses raw_hex format for raw bytes" do
      output = capture_stdout do
        formatter.read_value(
          address: "AA:BB:CC:DD:EE:FF",
          uuid: "00002a19-0000-1000-8000-00805f9b34fb",
          name: "Battery Level",
          raw: "\x5F".b,
          formatted: "95%"
        )
      end
      parsed = JSON.parse(output)

      expect(parsed["characteristic"]["raw_hex"]).to eq("5f")
      expect(parsed["characteristic"]).not_to have_key("raw_bytes")
    end

    it "formats multi-byte raw data as contiguous hex string" do
      output = capture_stdout do
        formatter.read_value(
          address: "AA:BB:CC:DD:EE:FF",
          uuid: "00002a37-0000-1000-8000-00805f9b34fb",
          name: "Heart Rate Measurement",
          raw: "\x00\x48".b,
          formatted: "72 bpm"
        )
      end
      parsed = JSON.parse(output)

      expect(parsed["characteristic"]["raw_hex"]).to eq("0048")
    end
  end

  describe "#write_result" do
    it "omits verified key when verified is nil" do
      output = capture_stdout do
        formatter.write_result(
          address: "AA:BB:CC:DD:EE:FF",
          uuid: "00002a19-0000-1000-8000-00805f9b34fb",
          name: "Battery Level",
          success: true,
          verified: nil,
          written_bytes: "\x5F".b
        )
      end
      parsed = JSON.parse(output)

      expect(parsed).not_to have_key("verified")
    end

    it "includes verified key when verify was requested" do
      output = capture_stdout do
        formatter.write_result(
          address: "AA:BB:CC:DD:EE:FF",
          uuid: "00002a19-0000-1000-8000-00805f9b34fb",
          name: "Battery Level",
          success: true,
          verified: "95%",
          written_bytes: "\x5F".b
        )
      end
      parsed = JSON.parse(output)

      expect(parsed["verified"]).to eq("95%")
    end
  end
end
