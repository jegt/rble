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

  def make_device(address: "AA:BB:CC:DD:EE:FF", name: nil, rssi: nil, address_type: "public")
    RBLE::Device.new(address: address, name: name, rssi: rssi, address_type: address_type)
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
end
