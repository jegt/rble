# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "stringio"

RSpec.describe RBLE::CLI::Formatters::Text do
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
    it "outputs address, name, RSSI, and address type in fixed-width columns" do
      device = make_device(name: "TestDevice", rssi: -72)
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("AA:BB:CC:DD:EE:FF")
      expect(output).to include("TestDevice")
      expect(output).to include("-72 dBm")
      expect(output).to include("public")
    end

    it "shows (unknown) for nil name" do
      device = make_device(rssi: -80)
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("(unknown)")
    end

    it "shows company name when device has no name but has manufacturer data" do
      device = make_device(rssi: -65, manufacturer_data: { 0x0075 => [0x01, 0x02] })
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("(Samsung)")
      expect(output).not_to include("(unknown)")
    end

    it "shows company name for Apple manufacturer data" do
      device = make_device(rssi: -65, manufacturer_data: { 0x004C => [0x01, 0x02] })
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("(Apple)")
      expect(output).not_to include("(unknown)")
    end

    it "shows (unknown) when manufacturer data has unrecognized company ID" do
      device = make_device(rssi: -65, manufacturer_data: { 0xFFFF => [0x01] })
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("(unknown)")
    end

    it "prefers device name over company name" do
      device = make_device(name: "MyDevice", rssi: -65, manufacturer_data: { 0x004C => [0x01] })
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("MyDevice")
      expect(output).not_to include("(Apple)")
    end

    it "shows 0 dBm for nil RSSI" do
      device = make_device(name: "Test")
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("   0 dBm")
    end

    it "truncates long names with ~ suffix" do
      long_name = "A" * 30
      device = make_device(name: long_name, rssi: -50)
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("A" * 24 + "~")
      expect(output).not_to include("A" * 25)
    end

    it "does not truncate names at exactly max length" do
      name = "A" * 25
      device = make_device(name: name, rssi: -50)
      output = capture_stdout { formatter.device(device) }

      expect(output).to include("A" * 25)
      expect(output).not_to include("~")
    end

    it "outputs a trailing newline" do
      device = make_device(name: "Test", rssi: -60)
      output = capture_stdout { formatter.device(device) }

      expect(output).to end_with("\n")
    end
  end
end
