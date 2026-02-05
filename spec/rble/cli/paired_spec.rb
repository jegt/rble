# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/paired"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Paired do
  let(:devices) do
    [
      {
        address: "AA:BB:CC:DD:EE:FF",
        name: "Heart Rate Monitor",
        paired: true,
        bonded: true,
        connected: true,
        trusted: false,
        address_type: "public",
        rssi: -55,
        icon: nil,
        adapter: "/org/bluez/hci0"
      },
      {
        address: "11:22:33:44:55:66",
        name: nil,
        paired: true,
        bonded: false,
        connected: false,
        trusted: true,
        address_type: "random",
        rssi: -72,
        icon: nil,
        adapter: "/org/bluez/hci0"
      }
    ]
  end

  let(:backend) do
    double("backend", bonded_devices: devices)
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
  end

  def make_options(overrides = {})
    defaults = {
      "json" => false,
      "verbose" => false
    }
    Thor::CoreExt::HashWithIndifferentAccess.new(defaults.merge(overrides))
  end

  def capture_output
    original_stdout = $stdout
    original_stderr = $stderr
    $stdout = StringIO.new
    $stderr = StringIO.new
    yield
    { stdout: $stdout.string, stderr: $stderr.string }
  ensure
    $stdout = original_stdout
    $stderr = original_stderr
  end

  describe "text output with devices" do
    it "shows all devices with address, name, and connection status" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("AA:BB:CC:DD:EE:FF")
      expect(result[:stdout]).to include("Heart Rate Monitor")
      expect(result[:stdout]).to include("connected")
      expect(result[:stdout]).to include("11:22:33:44:55:66")
      expect(result[:stdout]).to include("not connected")
    end

    it "shows Unknown for devices with nil name" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Unknown")
    end

    it "shows address type" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("BLE (public)")
      expect(result[:stdout]).to include("BLE (random)")
    end

    it "shows footer with device count" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("2 bonded devices")
    end

    it "shows singular form for one device" do
      allow(backend).to receive(:bonded_devices).and_return([devices.first])

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("1 bonded device")
      expect(result[:stdout]).not_to include("1 bonded devices")
    end
  end

  describe "no devices" do
    before do
      allow(backend).to receive(:bonded_devices).and_return([])
    end

    it "shows no bonded devices message in text mode" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("No bonded devices")
    end

    it "outputs empty array in JSON mode" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed).to eq([])
    end
  end

  describe "JSON output" do
    it "outputs all devices as JSON array" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed).to be_an(Array)
      expect(parsed.size).to eq(2)
    end

    it "includes all device fields" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      device = parsed.first

      expect(device["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(device["name"]).to eq("Heart Rate Monitor")
      expect(device["paired"]).to eq(true)
      expect(device["connected"]).to eq(true)
      expect(device["address_type"]).to eq("public")
    end
  end

  describe "error handling" do
    before do
      allow(backend).to receive(:bonded_devices).and_raise(RBLE::Error.new("D-Bus error"))
    end

    it "prints error and exits 1" do
      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("D-Bus error")
    end
  end
end
