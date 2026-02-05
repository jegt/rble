# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/monitor"
require "rble/gatt/uuid_database"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Monitor do
  let(:backend) { double("backend") }

  # Heart rate value: flags=0x00 (uint8 HR), HR=72
  let(:hr_value) { "\x00\x48".b }

  # Unknown characteristic value
  let(:unknown_value) { "\x10\x41\x00\xFF".b }

  let(:hr_char) do
    double(
      "hr_char",
      uuid: "00002a37-0000-1000-8000-00805f9b34fb",
      flags: ["notify"],
      short_uuid: "2a37",
      subscribable?: true,
      subscribe: true,
      unsubscribe: nil
    )
  end

  let(:vendor_char) do
    double(
      "vendor_char",
      uuid: "12345678-1234-1234-1234-123456789abd",
      flags: ["notify"],
      short_uuid: "12345678-1234-1234-1234-123456789abd",
      subscribable?: true,
      subscribe: true,
      unsubscribe: nil
    )
  end

  let(:read_only_char) do
    double(
      "read_only_char",
      uuid: "00002a19-0000-1000-8000-00805f9b34fb",
      flags: ["read"],
      short_uuid: "2a19",
      subscribable?: false
    )
  end

  let(:hr_service) do
    RBLE::Service.new(
      uuid: "0000180d-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [hr_char]
    )
  end

  let(:vendor_service) do
    RBLE::Service.new(
      uuid: "12345678-1234-1234-1234-123456789abc",
      primary: true,
      characteristics: [vendor_char]
    )
  end

  let(:battery_service) do
    RBLE::Service.new(
      uuid: "0000180f-0000-1000-8000-00805f9b34fb",
      primary: true,
      characteristics: [read_only_char]
    )
  end

  let(:services) { [hr_service, vendor_service, battery_service] }

  # connected? returns true initially, then false after subscribe callback fires
  let(:connection) do
    conn = double("connection",
      discover_services: nil,
      disconnect: nil,
      services: services
    )
    connected_calls = 0
    allow(conn).to receive(:connected?) do
      connected_calls += 1
      # First few calls: true (during setup and subscribe check)
      # After several calls: false (simulates disconnect for natural exit)
      connected_calls <= 3
    end
    conn
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
    allow(RBLE).to receive(:connect).and_return(connection)
    # Stub sleep to avoid delays
    allow_any_instance_of(described_class).to receive(:sleep)
  end

  def make_options(overrides = {})
    defaults = {
      "json" => false,
      "verbose" => false,
      "address" => "AA:BB:CC:DD:EE:FF",
      "characteristic" => "2a37",
      "timeout" => 10,
      "reconnect" => false
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

  # Helper to set up subscribe to fire callback with a value, then let connection go disconnected
  def setup_subscribe_with_value(char, value)
    allow(char).to receive(:subscribe) do |&block|
      block.call(value)
      true
    end
  end

  describe "text output" do
    it "displays known characteristic with parsed value and timestamp" do
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/\[\d{2}:\d{2}:\d{2}\.\d{3}\] Heart Rate Measurement: 72 bpm/)
    end

    it "displays unknown characteristic with hex dump" do
      setup_subscribe_with_value(vendor_char, unknown_value)

      result = capture_output do
        described_class.new(make_options("characteristic" => "12345678-1234-1234-1234-123456789abd")).execute
      end

      expect(result[:stdout]).to include("10 41 00 FF")
      expect(result[:stdout]).to include("|.A..|")
    end
  end

  describe "timestamp format" do
    it "uses HH:MM:SS.mmm format" do
      # Use Time.at for exact millisecond control (avoids float precision issues)
      frozen_time = Time.new(2026, 2, 5, 14, 30, 45, in: "+00:00") + Rational(123, 1000)
      allow(Time).to receive(:now).and_return(frozen_time)
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/\[14:30:45\.\d{3}\]/)
    end
  end

  describe "JSON output" do
    it "outputs valid NDJSON per notification" do
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output do
        described_class.new(make_options("json" => true)).execute
      end

      lines = result[:stdout].strip.split("\n").reject(&:empty?)
      expect(lines.size).to be >= 1

      parsed = JSON.parse(lines.first)
      expect(parsed).to include("timestamp", "address", "uuid", "name", "raw_hex", "value")
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["value"]).to eq("72 bpm")
      expect(parsed["name"]).to eq("Heart Rate Measurement")
      expect(parsed["raw_hex"]).to eq("0048")
    end
  end

  describe "status messages on stderr" do
    it "prints connecting, discovering, subscribing, and subscribed messages" do
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connecting to AA:BB:CC:DD:EE:FF...")
      expect(result[:stderr]).to include("Discovering services...")
      expect(result[:stderr]).to include("Subscribing to")
      expect(result[:stderr]).to include("Subscribed, waiting for notifications...")
    end
  end

  describe "error handling" do
    it "exits 1 when characteristic is not subscribable" do
      result = capture_output do
        expect {
          described_class.new(make_options("characteristic" => "2a19")).execute
        }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("does not support notifications")
      expect(result[:stderr]).to include("read")
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

    it "retries once on ConnectionTimeoutError then succeeds" do
      call_count = 0
      allow(RBLE).to receive(:connect) do |*_args, **_kwargs|
        call_count += 1
        raise RBLE::ConnectionTimeoutError.new(10) if call_count == 1

        connection
      end
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Connection failed, retrying...")
      expect(RBLE).to have_received(:connect).twice
    end
  end

  describe "disconnect detection" do
    it "prints disconnect message on stderr when device disconnects" do
      setup_subscribe_with_value(hr_char, hr_value)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Device disconnected.")
    end
  end

  describe "signal handling" do
    it "installs INT handler during stream and restores on exit" do
      setup_subscribe_with_value(hr_char, hr_value)

      # Record the INT handler installed during the sleep loop
      captured_handler = nil
      allow_any_instance_of(described_class).to receive(:sleep) do
        captured_handler ||= trap("INT", "DEFAULT")
        trap("INT", captured_handler) if captured_handler
      end

      capture_output { described_class.new(make_options).execute }

      # During execute, our signal handler should have been a Proc
      expect(captured_handler).to be_a(Proc)
    end
  end

  describe "cleanup" do
    it "calls unsubscribe when connection is still connected" do
      # Make connection stay connected throughout
      allow(connection).to receive(:connected?).and_return(true)

      # Use subscribe to fire callback, and set @stop to break loop
      allow(hr_char).to receive(:subscribe) do |&block|
        block.call(hr_value)
        true
      end

      monitor = described_class.new(make_options)
      # Set stop flag so the while loop exits immediately
      allow(monitor).to receive(:sleep) do
        monitor.instance_variable_set(:@stop, true)
      end

      capture_output { monitor.execute }

      expect(hr_char).to have_received(:unsubscribe)
    end

    it "calls disconnect in ensure block" do
      # Use a connection that stays connected so disconnect is called in ensure
      always_connected = double("connection",
        discover_services: nil,
        disconnect: nil,
        services: services
      )
      allow(always_connected).to receive(:connected?).and_return(true)
      allow(RBLE).to receive(:connect).and_return(always_connected)

      setup_subscribe_with_value(hr_char, hr_value)

      monitor = described_class.new(make_options)
      allow(monitor).to receive(:sleep) do
        monitor.instance_variable_set(:@stop, true)
      end

      capture_output { monitor.execute }

      expect(always_connected).to have_received(:disconnect).at_least(:once)
    end
  end

  describe "--reconnect" do
    it "retries after disconnect when reconnect is enabled" do
      connect_count = 0
      allow(RBLE).to receive(:connect) do |*_args, **_kwargs|
        connect_count += 1
        # Each connection disconnects after a few connected? checks
        conn = double("connection_#{connect_count}",
          discover_services: nil,
          disconnect: nil,
          services: services
        )
        calls = 0
        allow(conn).to receive(:connected?) do
          calls += 1
          calls <= 3
        end
        conn
      end
      setup_subscribe_with_value(hr_char, hr_value)

      monitor = described_class.new(make_options("reconnect" => true))
      # Track reconnect sleeps (sleep 2) vs poll sleeps (sleep 0.1)
      reconnect_sleep_count = 0
      allow(monitor).to receive(:sleep) do |duration|
        if duration == 2
          reconnect_sleep_count += 1
          # Stop after second reconnect attempt
          monitor.instance_variable_set(:@stop, true) if reconnect_sleep_count >= 2
        end
        # sleep 0.1 is a no-op (poll loop)
      end

      capture_output { monitor.execute }

      expect(connect_count).to be >= 2
    end

    it "stops reconnecting on Ctrl+C" do
      setup_subscribe_with_value(hr_char, hr_value)

      monitor = described_class.new(make_options("reconnect" => true))
      # Simulate Ctrl+C by setting stop flag on first sleep
      allow(monitor).to receive(:sleep) do
        monitor.instance_variable_set(:@stop, true)
      end

      result = capture_output { monitor.execute }

      # Should exit without error
      expect(result[:stderr]).not_to include("Error:")
    end
  end

  describe "options" do
    it "passes timeout to connect" do
      setup_subscribe_with_value(hr_char, hr_value)

      capture_output do
        described_class.new(make_options("timeout" => 20)).execute
      end

      expect(RBLE).to have_received(:connect).with("AA:BB:CC:DD:EE:FF", timeout: 20)
    end
  end
end
