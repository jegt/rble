# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/write"
require "rble/gatt/uuid_database"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Write do
  let(:backend) { double("backend") }

  let(:rw_char) do
    double(
      "rw_char",
      uuid: "00002a06-0000-1000-8000-00805f9b34fb",
      flags: ["read", "write"],
      short_uuid: "2a06",
      readable?: true,
      writable?: true,
      writable_without_response?: false,
      write: true,
      read: "\x01".b
    )
  end

  let(:wwnr_char) do
    double(
      "wwnr_char",
      uuid: "00002a06-0000-1000-8000-00805f9b34fb",
      flags: ["write-without-response"],
      short_uuid: "2a06",
      readable?: false,
      writable?: false,
      writable_without_response?: true,
      write: true
    )
  end

  let(:read_only_char) do
    double(
      "read_only_char",
      uuid: "00002a19-0000-1000-8000-00805f9b34fb",
      flags: ["read"],
      short_uuid: "2a19",
      readable?: true,
      writable?: false,
      writable_without_response?: false
    )
  end

  let(:rw_service) do
    RBLE::Service.new(
      uuid: "00001802-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [rw_char]
    )
  end

  let(:services) { [rw_service] }

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
      "characteristic" => "2a06",
      "value" => "01",
      "timeout" => 10,
      "hex" => false,
      "string" => false,
      "uint8" => false,
      "uint16" => false,
      "uint32" => false,
      "int8" => false,
      "int16" => false,
      "int32" => false,
      "verify" => false
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

  describe "type flag validation" do
    it "exits 1 when no type flag provided" do
      result = capture_output do
        expect {
          described_class.new(make_options).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("Exactly one type flag required")
    end

    it "exits 1 when multiple type flags provided" do
      result = capture_output do
        expect {
          described_class.new(make_options("hex" => true, "uint8" => true)).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("Only one type flag allowed")
    end
  end

  describe "hex encoding" do
    it "encodes valid hex string" do
      capture_output do
        described_class.new(make_options("hex" => true, "value" => "0A1BFF")).execute
      end

      expect(rw_char).to have_received(:write).with("\x0A\x1B\xFF".b, response: true)
    end

    it "strips 0x prefix from hex" do
      capture_output do
        described_class.new(make_options("hex" => true, "value" => "0x0A1B")).execute
      end

      expect(rw_char).to have_received(:write).with("\x0A\x1B".b, response: true)
    end

    it "exits 1 for invalid hex characters" do
      result = capture_output do
        expect {
          described_class.new(make_options("hex" => true, "value" => "ZZZZ")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("Invalid hex string")
    end

    it "exits 1 for odd-length hex string" do
      result = capture_output do
        expect {
          described_class.new(make_options("hex" => true, "value" => "0A1")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("even length")
    end
  end

  describe "string encoding" do
    it "encodes UTF-8 string" do
      capture_output do
        described_class.new(make_options("string" => true, "value" => "hello")).execute
      end

      expect(rw_char).to have_received(:write).with("hello", response: true)
    end
  end

  describe "uint8 encoding" do
    it "encodes valid uint8" do
      capture_output do
        described_class.new(make_options("uint8" => true, "value" => "42")).execute
      end

      expect(rw_char).to have_received(:write).with("\x2A".b, response: true)
    end

    it "exits 1 for uint8 out of range (256)" do
      result = capture_output do
        expect {
          described_class.new(make_options("uint8" => true, "value" => "256")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for uint8")
    end

    it "exits 1 for uint8 negative" do
      result = capture_output do
        expect {
          described_class.new(make_options("uint8" => true, "value" => "-1")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for uint8")
    end
  end

  describe "uint16 encoding" do
    it "encodes valid uint16 as little-endian" do
      capture_output do
        described_class.new(make_options("uint16" => true, "value" => "500")).execute
      end

      expect(rw_char).to have_received(:write).with([500].pack('S<'), response: true)
    end

    it "exits 1 for uint16 out of range" do
      result = capture_output do
        expect {
          described_class.new(make_options("uint16" => true, "value" => "65536")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for uint16")
    end
  end

  describe "uint32 encoding" do
    it "encodes valid uint32 as little-endian" do
      capture_output do
        described_class.new(make_options("uint32" => true, "value" => "100000")).execute
      end

      expect(rw_char).to have_received(:write).with([100_000].pack('L<'), response: true)
    end

    it "exits 1 for uint32 out of range" do
      result = capture_output do
        expect {
          described_class.new(make_options("uint32" => true, "value" => "4294967296")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for uint32")
    end
  end

  describe "int8 encoding" do
    it "encodes positive int8" do
      capture_output do
        described_class.new(make_options("int8" => true, "value" => "100")).execute
      end

      expect(rw_char).to have_received(:write).with([100].pack('c'), response: true)
    end

    it "encodes negative int8" do
      capture_output do
        described_class.new(make_options("int8" => true, "value" => "-50")).execute
      end

      expect(rw_char).to have_received(:write).with([-50].pack('c'), response: true)
    end

    it "exits 1 for int8 out of range" do
      result = capture_output do
        expect {
          described_class.new(make_options("int8" => true, "value" => "128")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for int8")
    end
  end

  describe "int16 encoding" do
    it "encodes int16 as little-endian" do
      capture_output do
        described_class.new(make_options("int16" => true, "value" => "-1000")).execute
      end

      expect(rw_char).to have_received(:write).with([-1000].pack('s<'), response: true)
    end

    it "exits 1 for int16 out of range" do
      result = capture_output do
        expect {
          described_class.new(make_options("int16" => true, "value" => "32768")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for int16")
    end
  end

  describe "int32 encoding" do
    it "encodes int32 as little-endian" do
      capture_output do
        described_class.new(make_options("int32" => true, "value" => "-100000")).execute
      end

      expect(rw_char).to have_received(:write).with([-100_000].pack('l<'), response: true)
    end

    it "exits 1 for int32 out of range" do
      result = capture_output do
        expect {
          described_class.new(make_options("int32" => true, "value" => "2147483648")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("out of range for int32")
    end
  end

  describe "write mode detection" do
    it "uses write-with-response when char supports write" do
      capture_output do
        described_class.new(make_options("hex" => true, "value" => "01")).execute
      end

      expect(rw_char).to have_received(:write).with(anything, hash_including(response: true))
    end

    it "falls back to write-without-response when write not supported" do
      wwnr_service = RBLE::Service.new(
        uuid: "00001802-0000-1000-8000-00805f9b34fb",
        primary: true,
        characteristics: [wwnr_char]
      )
      allow(connection).to receive(:services).and_return([wwnr_service])

      capture_output do
        described_class.new(make_options("hex" => true, "value" => "01")).execute
      end

      expect(wwnr_char).to have_received(:write).with(anything, hash_including(response: false))
    end

    it "exits 1 when characteristic is not writable at all" do
      read_service = RBLE::Service.new(
        uuid: "0000180f-0000-1000-8000-00805f9b34fb",
        primary: true,
        characteristics: [read_only_char]
      )
      allow(connection).to receive(:services).and_return([read_service])

      result = capture_output do
        expect {
          described_class.new(make_options("characteristic" => "2a19", "hex" => true, "value" => "01")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("does not support write")
      expect(result[:stderr]).to include("read")
    end
  end

  describe "--verify flag" do
    it "reads back after writing and shows verified value" do
      allow(rw_char).to receive(:read).and_return("\x01".b)

      result = capture_output do
        described_class.new(make_options("hex" => true, "value" => "01", "verify" => true)).execute
      end

      expect(result[:stderr]).to include("Verifying...")
      expect(result[:stderr]).to include("Verified:")
      expect(rw_char).to have_received(:read)
    end

    it "warns when characteristic is not readable for verify" do
      wwnr_service = RBLE::Service.new(
        uuid: "00001802-0000-1000-8000-00805f9b34fb",
        primary: true,
        characteristics: [wwnr_char]
      )
      allow(connection).to receive(:services).and_return([wwnr_service])

      result = capture_output do
        described_class.new(make_options("hex" => true, "value" => "01", "verify" => true)).execute
      end

      expect(result[:stderr]).to include("Cannot verify")
      expect(result[:stderr]).to include("not readable")
    end
  end

  describe "JSON output" do
    it "outputs valid JSON with write result" do
      result = capture_output do
        described_class.new(make_options("json" => true, "hex" => true, "value" => "01")).execute
      end

      parsed = JSON.parse(result[:stdout])
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["status"]).to eq("ok")
      expect(parsed["characteristic"]["uuid"]).to include("2a06")
      expect(parsed["written"]).to eq([1])
    end

    it "includes verified value in JSON when --verify used" do
      allow(rw_char).to receive(:read).and_return("\x01".b)

      result = capture_output do
        described_class.new(make_options("json" => true, "hex" => true, "value" => "01", "verify" => true)).execute
      end

      parsed = JSON.parse(result[:stdout])
      expect(parsed["verified"]).not_to be_nil
    end
  end

  describe "text output" do
    it "does not produce stdout output in text mode (status on stderr)" do
      result = capture_output do
        described_class.new(make_options("hex" => true, "value" => "01")).execute
      end

      # Text write_result is a no-op (status already on stderr)
      expect(result[:stdout]).to eq("")
      expect(result[:stderr]).to include("Write successful")
    end
  end

  describe "error handling" do
    it "exits 1 with scan hint for DeviceNotFoundError" do
      allow(RBLE).to receive(:connect).and_raise(RBLE::DeviceNotFoundError.new("AA:BB:CC:DD:EE:FF"))

      result = capture_output do
        expect {
          described_class.new(make_options("hex" => true, "value" => "01")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("rble scan")
    end

    it "exits 1 for invalid integer value" do
      result = capture_output do
        expect {
          described_class.new(make_options("uint8" => true, "value" => "abc")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("Invalid integer")
    end

    it "disconnects in ensure block even when write raises" do
      allow(rw_char).to receive(:write).and_raise(RBLE::WriteError, "write failed")

      capture_output do
        expect {
          described_class.new(make_options("hex" => true, "value" => "01")).execute
        }.to raise_error(SystemExit)
      end

      expect(connection).to have_received(:disconnect)
    end
  end

  describe "options" do
    it "passes timeout to connect" do
      capture_output do
        described_class.new(make_options("hex" => true, "value" => "01", "timeout" => 20)).execute
      end

      expect(RBLE).to have_received(:connect).with("AA:BB:CC:DD:EE:FF", timeout: 20)
    end
  end
end
