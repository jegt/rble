# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/unpair"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Unpair do
  let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }

  let(:backend) do
    double("backend",
           device_path_for_address: device_path,
           unpair_device: :unpaired)
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
  end

  def make_options(overrides = {})
    defaults = {
      "json" => false,
      "verbose" => false,
      "address" => "AA:BB:CC:DD:EE:FF"
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

  describe "successful unpair" do
    it "prints status messages on stderr" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Removing pairing for AA:BB:CC:DD:EE:FF...")
      expect(result[:stderr]).to include("Pairing removed")
    end
  end

  describe "device not found (nil device_path)" do
    before do
      allow(backend).to receive(:device_path_for_address).and_return(nil)
    end

    it "prints not paired message and exits 0" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Device not paired")
    end

    it "does not call unpair_device" do
      capture_output { described_class.new(make_options).execute }

      expect(backend).not_to have_received(:unpair_device)
    end
  end

  describe "backend returns :not_paired" do
    before do
      allow(backend).to receive(:unpair_device).and_return(:not_paired)
    end

    it "prints not paired message" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Device not paired")
    end
  end

  describe "error handling" do
    before do
      allow(backend).to receive(:unpair_device).and_raise(RBLE::Error.new("D-Bus error"))
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

  describe "JSON output" do
    it "outputs structured JSON on success" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["status"]).to eq("ok")
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["message"]).to eq("Pairing removed")
    end
  end
end
