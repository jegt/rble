# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/show"
require "rble/gatt/uuid_database"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Show do
  let(:backend) do
    double("backend", device_name: "Test Device")
  end

  let(:hr_measurement_desc) do
    {
      uuid: "00002902-0000-1000-8000-00805f9b34fb",
      path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011/desc0012"
    }
  end

  let(:hr_measurement_char) do
    double(
      "hr_measurement_char",
      uuid: "00002a37-0000-1000-8000-00805f9b34fb",
      flags: ["notify"],
      service_uuid: "0000180d-0000-1000-8000-00805f9b34fb",
      path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011",
      short_uuid: "2a37",
      descriptors: [hr_measurement_desc]
    )
  end

  let(:body_sensor_char) do
    double(
      "body_sensor_char",
      uuid: "00002a38-0000-1000-8000-00805f9b34fb",
      flags: ["read"],
      service_uuid: "0000180d-0000-1000-8000-00805f9b34fb",
      path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0013",
      short_uuid: "2a38",
      descriptors: []
    )
  end

  let(:hr_service) do
    RBLE::Service.new(
      uuid: "0000180d-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [hr_measurement_char, body_sensor_char]
    )
  end

  let(:vendor_char) do
    double(
      "vendor_char",
      uuid: "12345678-1234-1234-1234-123456789abd",
      flags: ["read", "write"],
      service_uuid: "12345678-1234-1234-1234-123456789abc",
      path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0020/char0021",
      short_uuid: "12345678-1234-1234-1234-123456789abd",
      descriptors: []
    )
  end

  let(:vendor_service) do
    RBLE::Service.new(
      uuid: "12345678-1234-1234-1234-123456789abc",
      primary: true,
      characteristics: [vendor_char]
    )
  end

  let(:services) { [hr_service, vendor_service] }

  let(:connection) do
    double(
      "connection",
      discover_services: nil,
      disconnect: nil,
      device_path: "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF",
      connected?: true,
      services: services
    )
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
    allow(RBLE).to receive(:connect).and_return(connection)
  end

  def make_options(overrides = {})
    defaults = { "json" => false, "verbose" => false, "address" => "AA:BB:CC:DD:EE:FF", "timeout" => 10 }
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

  describe "text output" do
    it "shows device header with name, address, service count, and characteristic count" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Test Device (AA:BB:CC:DD:EE:FF)")
      expect(result[:stdout]).to include("2 services")
      expect(result[:stdout]).to include("3 characteristics")
    end

    it "shows address-only header when device name is nil" do
      allow(backend).to receive(:device_name).and_return(nil)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/\AAA:BB:CC:DD:EE:FF/)
    end

    it "shows resolved service name with short UUID" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Heart Rate [0x180D]")
    end

    it "shows resolved characteristic name with short UUID" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Heart Rate Measurement [0x2A37]")
    end

    it "shows characteristic properties in parentheses" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("(notify)")
    end

    it "shows descriptor under characteristic with tree lines" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Client Characteristic Configuration [0x2902]")
    end

    it "shows resolved descriptor name" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Client Characteristic Configuration [0x2902]")
    end

    it "shows unknown vendor service with full UUID" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Unknown Service [12345678-1234-1234-1234-123456789abc]")
    end

    it "shows unknown vendor characteristic with full UUID" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Unknown Characteristic [12345678-1234-1234-1234-123456789abd]")
    end

    it "uses Unicode tree characters" do
      result = capture_output { described_class.new(make_options).execute }

      output = result[:stdout]
      # Should use box-drawing characters for tree structure
      expect(output).to match(/\u251C\u2500\u2500/) # ├──
      expect(output).to match(/\u2514\u2500\u2500/) # └──
    end
  end

  describe "JSON output" do
    it "outputs valid JSON with all fields" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["name"]).to eq("Test Device")
      expect(parsed["services"]).to be_an(Array)
      expect(parsed["services"].size).to eq(2)
    end

    it "includes resolved names or nil for unknown" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      hr_svc = parsed["services"].find { |s| s["uuid"].include?("180d") }
      vendor_svc = parsed["services"].find { |s| s["uuid"].include?("12345678") }

      expect(hr_svc["name"]).to eq("Heart Rate")
      expect(vendor_svc["name"]).to be_nil
    end

    it "includes properties array for characteristics" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      hr_svc = parsed["services"].find { |s| s["uuid"].include?("180d") }
      hr_char = hr_svc["characteristics"].find { |c| c["uuid"].include?("2a37") }

      expect(hr_char["properties"]).to eq(["notify"])
    end

    it "includes nested descriptors" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      hr_svc = parsed["services"].find { |s| s["uuid"].include?("180d") }
      hr_char = hr_svc["characteristics"].find { |c| c["uuid"].include?("2a37") }

      expect(hr_char["descriptors"]).to be_an(Array)
      expect(hr_char["descriptors"].size).to eq(1)
      expect(hr_char["descriptors"].first["name"]).to eq("Client Characteristic Configuration")
    end
  end

  describe "status messages" do
    it "prints 'Connecting to <address>...' on stderr" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connecting to AA:BB:CC:DD:EE:FF...")
    end

    it "prints 'Discovering services...' on stderr" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Discovering services...")
    end

    it "prints 'Found N service(s)' on stderr" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Found 2 services")
    end
  end

  describe "error handling" do
    it "prints scan hint and exits 1 for DeviceNotFoundError without retry" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::DeviceNotFoundError.new("AA:BB:CC:DD:EE:FF"))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("rble scan")
      # Should only attempt connect once (no retry for DeviceNotFoundError)
      expect(RBLE).to have_received(:connect).once
    end

    it "retries once then exits 1 for ConnectionTimeoutError" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::ConnectionTimeoutError.new(10))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("Connection failed, retrying...")
      expect(RBLE).to have_received(:connect).twice
    end

    it "retries once then exits 1 for ConnectionFailed" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::ConnectionFailed.new("AA:BB:CC:DD:EE:FF"))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("Connection failed, retrying...")
      expect(RBLE).to have_received(:connect).twice
    end

    it "succeeds on second attempt after ConnectionTimeoutError" do
      call_count = 0
      allow(RBLE).to receive(:connect) do |*_args, **_kwargs|
        call_count += 1
        raise RBLE::ConnectionTimeoutError.new(10) if call_count == 1

        connection
      end

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connection failed, retrying...")
      expect(result[:stdout]).to include("Heart Rate")
      expect(RBLE).to have_received(:connect).twice
    end
  end

  describe "options" do
    it "passes timeout to RBLE.connect" do
      capture_output { described_class.new(make_options("timeout" => 20)).execute }

      expect(RBLE).to have_received(:connect).with("AA:BB:CC:DD:EE:FF", timeout: 20)
    end
  end
end
