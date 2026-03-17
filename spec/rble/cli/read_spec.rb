# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/read"
require "rble/gatt/uuid_database"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Read do
  let(:backend) { double("backend") }

  let(:battery_char) do
    double(
      "battery_char",
      uuid: "00002a19-0000-1000-8000-00805f9b34fb",
      flags: ["read"],
      short_uuid: "2a19",
      readable?: true,
      read: "\x5F".b  # 95%
    )
  end

  let(:vendor_char) do
    double(
      "vendor_char",
      uuid: "12345678-1234-1234-1234-123456789abd",
      flags: ["read"],
      short_uuid: "12345678-1234-1234-1234-123456789abd",
      readable?: true,
      read: "\x10\x41\x00\xFF".b
    )
  end

  let(:notify_only_char) do
    double(
      "notify_only_char",
      uuid: "00002a37-0000-1000-8000-00805f9b34fb",
      flags: ["notify"],
      short_uuid: "2a37",
      readable?: false
    )
  end

  let(:hr_service) do
    RBLE::Service.new(
      uuid: "0000180d-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [notify_only_char]
    )
  end

  let(:battery_service) do
    RBLE::Service.new(
      uuid: "0000180f-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [battery_char]
    )
  end

  let(:vendor_service) do
    RBLE::Service.new(
      uuid: "12345678-1234-1234-1234-123456789abc",
      primary: true,
      characteristics: [vendor_char]
    )
  end

  let(:services) { [battery_service, vendor_service, hr_service] }

  let(:connection) do
    double(
      "connection",
      discover_services: nil,
      disconnect: nil,
      connected?: true,
      services: services
    )
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
    allow(RBLE).to receive(:connect).and_return(connection)
  end

  def make_options(overrides = {})
    defaults = {
      "json" => false,
      "verbose" => false,
      "address" => "AA:BB:CC:DD:EE:FF",
      "characteristic" => "2a19",
      "timeout" => 10
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

  describe "text output" do
    it "displays known characteristic with name and parsed value" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("Battery Level (2a19): 95%")
    end

    it "displays unknown characteristic with hex dump" do
      result = capture_output do
        described_class.new(make_options("characteristic" => "12345678-1234-1234-1234-123456789abd")).execute
      end

      expect(result[:stdout]).to include("10 41 00 FF")
      expect(result[:stdout]).to include("|.A..|")
    end
  end

  describe "JSON output" do
    it "outputs valid JSON with characteristic data" do
      result = capture_output do
        described_class.new(make_options("json" => true)).execute
      end

      parsed = JSON.parse(result[:stdout])
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["characteristic"]["uuid"]).to eq("00002a19-0000-1000-8000-00805f9b34fb")
      expect(parsed["characteristic"]["name"]).to eq("Battery Level")
      expect(parsed["characteristic"]["value"]).to eq("95%")
      expect(parsed["characteristic"]["raw_hex"]).to eq("5f")
    end
  end

  describe "status messages on stderr" do
    it "prints connecting and discovering messages" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connecting to AA:BB:CC:DD:EE:FF...")
      expect(result[:stderr]).to include("Discovering services...")
      expect(result[:stderr]).to include("Reading Battery Level (2a19)...")
    end
  end

  describe "error handling" do
    it "exits 1 with hint when characteristic is not readable" do
      result = capture_output do
        expect {
          described_class.new(make_options("characteristic" => "2a37")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("does not support read")
      expect(result[:stderr]).to include("notify")
    end

    it "exits 1 when characteristic not found" do
      result = capture_output do
        expect {
          described_class.new(make_options("characteristic" => "ffff")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("not found on device")
    end

    it "exits 1 with scan hint for DeviceNotFoundError" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::DeviceNotFoundError.new("AA:BB:CC:DD:EE:FF"))

      result = capture_output do
        expect {
          described_class.new(make_options).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("rble scan")
    end

    it "exits 1 for generic RBLE::Error" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::Error, "something went wrong")

      result = capture_output do
        expect {
          described_class.new(make_options).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("something went wrong")
    end

    it "retries once on ConnectionTimeoutError then succeeds" do
      call_count = 0
      allow(RBLE).to receive(:connect) do |*_args, **_kwargs|
        call_count += 1
        raise RBLE::ConnectionTimeoutError.new(10) if call_count == 1

        connection
      end

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connection failed, retrying...")
      expect(result[:stdout]).to include("95%")
      expect(RBLE).to have_received(:connect).twice
    end
  end

  describe "connection management" do
    it "disconnects in ensure block even when read raises" do
      allow(battery_char).to receive(:read).and_raise(RBLE::ReadError, "read failed")

      capture_output do
        expect {
          described_class.new(make_options).execute
        }.to raise_error(SystemExit)
      end

      expect(connection).to have_received(:disconnect)
    end
  end

  describe "options" do
    it "passes timeout to connect" do
      capture_output { described_class.new(make_options("timeout" => 20)).execute }

      expect(RBLE).to have_received(:connect).with("AA:BB:CC:DD:EE:FF", timeout: 20)
    end
  end
end
