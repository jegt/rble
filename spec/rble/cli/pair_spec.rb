# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/pair"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Pair do
  let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }

  let(:backend) do
    double("backend",
           device_path_for_address: device_path,
           pair_device: :paired)
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
  end

  def make_options(overrides = {})
    defaults = {
      "json" => false,
      "verbose" => false,
      "address" => "AA:BB:CC:DD:EE:FF",
      "timeout" => 30,
      "security" => nil,
      "force" => false
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

  describe "successful pairing" do
    it "prints status messages on stderr and reports success" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Pairing with AA:BB:CC:DD:EE:FF...")
      expect(result[:stderr]).to include("Bonded successfully")
    end

    it "calls backend.pair_device with correct arguments" do
      capture_output { described_class.new(make_options).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: an_instance_of(RBLE::CLI::TerminalIOHandler),
        force: false,
        capability: nil,
        timeout: 30
      )
    end
  end

  describe "already paired" do
    before do
      allow(backend).to receive(:pair_device).and_return(:already_paired)
    end

    it "prints already paired message and exits 0" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stderr]).to include("Device already paired")
    end
  end

  describe "device not found (nil device_path)" do
    before do
      allow(backend).to receive(:device_path_for_address).and_return(nil)
    end

    it "suggests rble scan and exits 1" do
      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("not found")
      expect(result[:stderr]).to include("rble scan")
    end
  end

  describe "authentication error" do
    before do
      allow(backend).to receive(:pair_device).and_raise(RBLE::AuthenticationError.new("AA:BB:CC:DD:EE:FF"))
    end

    it "prints actionable message about pairing mode and exits 1" do
      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("Pairing rejected")
      expect(result[:stderr]).to include("pairing mode")
    end
  end

  describe "connection failed" do
    before do
      allow(backend).to receive(:pair_device).and_raise(RBLE::ConnectionFailed.new("AA:BB:CC:DD:EE:FF"))
    end

    it "prints message about range and exits 1" do
      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("Connection failed")
      expect(result[:stderr]).to include("out of range")
    end
  end

  describe "generic error" do
    before do
      allow(backend).to receive(:pair_device).and_raise(RBLE::Error.new("something went wrong"))
    end

    it "prints error message and exits 1" do
      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("something went wrong")
    end
  end

  describe "--force flag" do
    it "passes force: true to backend" do
      capture_output { described_class.new(make_options("force" => true)).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: true,
        capability: nil,
        timeout: 30
      )
    end
  end

  describe "--security flag" do
    it "maps 'low' to NoInputNoOutput capability" do
      capture_output { described_class.new(make_options("security" => "low")).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: false,
        capability: "NoInputNoOutput",
        timeout: 30
      )
    end

    it "maps 'medium' to DisplayYesNo capability" do
      capture_output { described_class.new(make_options("security" => "medium")).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: false,
        capability: "DisplayYesNo",
        timeout: 30
      )
    end

    it "maps 'high' to KeyboardDisplay capability" do
      capture_output { described_class.new(make_options("security" => "high")).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: false,
        capability: "KeyboardDisplay",
        timeout: 30
      )
    end

    it "passes nil capability when security is nil" do
      capture_output { described_class.new(make_options("security" => nil)).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: false,
        capability: nil,
        timeout: 30
      )
    end
  end

  describe "--timeout flag" do
    it "passes custom timeout to backend" do
      capture_output { described_class.new(make_options("timeout" => 60)).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: anything,
        force: false,
        capability: nil,
        timeout: 60
      )
    end
  end

  describe "JSON output" do
    it "outputs structured JSON on success" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["status"]).to eq("ok")
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["message"]).to eq("Bonded successfully")
    end

    it "uses NullIOHandler in JSON mode" do
      capture_output { described_class.new(make_options("json" => true)).execute }

      expect(backend).to have_received(:pair_device).with(
        device_path,
        io_handler: an_instance_of(RBLE::CLI::NullIOHandler),
        force: false,
        capability: nil,
        timeout: 30
      )
    end
  end
end
