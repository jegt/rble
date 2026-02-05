# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/doctor"
require "stringio"

# Define stub for BlueZ::DBusConnection since ruby-dbus isn't loaded in test context
module RBLE
  module BlueZ
    class DBusConnection
    end
  end unless defined?(RBLE::BlueZ)
end

RSpec.describe RBLE::CLI::Doctor do
  let(:backend) do
    double(
      "backend",
      adapters: [{ name: "hci0", address: "AA:BB:CC:DD:EE:FF", powered: true }]
    )
  end

  let(:dbus_conn) do
    double("dbus_connection", connect: nil, disconnect: nil)
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)

    # Default: all checks pass
    allow(File).to receive(:exist?).and_call_original
    allow(File).to receive(:exist?).with("/sys/module/bluetooth").and_return(true)

    allow_any_instance_of(described_class).to receive(:command_exists?).with("systemctl").and_return(true)
    allow_any_instance_of(described_class).to receive(:command_exists?).with("pgrep").and_return(true)
    allow_any_instance_of(described_class).to receive(:command_exists?).with("rfkill").and_return(true)
    allow_any_instance_of(described_class).to receive(:command_exists?).with("bluetoothd").and_return(true)
    allow_any_instance_of(described_class).to receive(:system).with("systemctl", "is-active", "--quiet", "bluetooth").and_return(true)

    allow(RBLE::BlueZ::DBusConnection).to receive(:new).and_return(dbus_conn)

    allow_any_instance_of(described_class).to receive(:run_command).with("rfkill --json 2>/dev/null").and_return(['{"rfkilldevices":[]}', true])
    allow_any_instance_of(described_class).to receive(:run_command).with("bluetoothd --version 2>/dev/null").and_return(["5.66\n", true])

    allow(Etc).to receive(:getgrnam).with("bluetooth").and_return(double("group", gid: 112))
    allow(Process).to receive(:groups).and_return([112])
    allow(Etc).to receive(:getlogin).and_return("testuser")
  end

  def make_options(overrides = {})
    defaults = { "json" => false, "verbose" => false }
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

  describe "summary output" do
    it "prints 'No issues found' when all checks pass" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("No issues found")
    end

    it "exits 0 when all checks pass" do
      expect {
        capture_output { described_class.new(make_options).execute }
      }.not_to raise_error
    end

    it "prints issue count and exits 1 when errors exist" do
      allow(File).to receive(:exist?).with("/sys/module/bluetooth").and_return(false)

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stdout]).to match(/\d+ issues? found/)
    end

    it "exits 0 when only warnings exist (no errors)" do
      allow(Process).to receive(:groups).and_return([])

      expect {
        capture_output { described_class.new(make_options).execute }
      }.not_to raise_error
    end
  end

  describe "kernel module check" do
    it "reports info when kernel module is loaded" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Kernel module")
      expect(result[:stdout]).to include("loaded")
    end

    it "reports error with fix when kernel module is missing" do
      allow(File).to receive(:exist?).with("/sys/module/bluetooth").and_return(false)

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] Kernel module")
      expect(result[:stdout]).to include("sudo modprobe bluetooth")
    end
  end

  describe "bluetoothd check" do
    it "reports info when bluetoothd is running" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Bluetooth daemon")
      expect(result[:stdout]).to include("running")
    end

    it "reports error with fix when bluetoothd is not running" do
      allow_any_instance_of(described_class).to receive(:system).with("systemctl", "is-active", "--quiet", "bluetooth").and_return(false)

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] Bluetooth daemon")
      expect(result[:stdout]).to include("sudo systemctl start bluetooth")
    end

    it "falls back to pgrep when systemctl not found" do
      allow_any_instance_of(described_class).to receive(:command_exists?).with("systemctl").and_return(false)
      allow_any_instance_of(described_class).to receive(:system).with("pgrep", "-x", "bluetoothd", out: File::NULL, err: File::NULL).and_return(true)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Bluetooth daemon")
    end

    it "skips check when neither systemctl nor pgrep found" do
      allow_any_instance_of(described_class).to receive(:command_exists?).with("systemctl").and_return(false)
      allow_any_instance_of(described_class).to receive(:command_exists?).with("pgrep").and_return(false)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).not_to include("Bluetooth daemon")
    end
  end

  describe "D-Bus permissions check" do
    it "reports info when D-Bus connection succeeds" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] D-Bus access")
    end

    it "reports error when D-Bus connection fails" do
      allow(dbus_conn).to receive(:connect).and_raise(StandardError.new("Connection refused"))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] D-Bus access")
      expect(result[:stdout]).to include("Connection refused")
    end
  end

  describe "adapter present check" do
    it "reports info when adapter is found" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Bluetooth adapter")
      expect(result[:stdout]).to include("hci0")
    end

    it "reports error when no adapters found" do
      allow(backend).to receive(:adapters).and_return([])

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] Bluetooth adapter")
      expect(result[:stdout]).to include("No Bluetooth adapter found")
    end

    it "reports error when AdapterNotFoundError is raised" do
      allow(backend).to receive(:adapters).and_raise(RBLE::AdapterNotFoundError.new)

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] Bluetooth adapter")
    end
  end

  describe "adapter powered check" do
    it "reports info when adapter is powered" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Adapter power")
      expect(result[:stdout]).to include("powered on")
    end

    it "reports error with fix when adapter is not powered" do
      allow(backend).to receive(:adapters).and_return([{ name: "hci0", address: "AA:BB:CC:DD:EE:FF", powered: false }])

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] Adapter power")
      expect(result[:stdout]).to include("rble adapter power on")
    end

    it "skips when no adapter was found" do
      allow(backend).to receive(:adapters).and_return([])

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).not_to include("Adapter power")
    end
  end

  describe "rfkill check" do
    it "reports info when not blocked" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] RF kill")
    end

    it "reports error when soft-blocked" do
      allow_any_instance_of(described_class).to receive(:run_command).with("rfkill --json 2>/dev/null").and_return(
        ['{"rfkilldevices":[{"type":"bluetooth","soft":"blocked","hard":"unblocked"}]}', true]
      )

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] RF kill")
      expect(result[:stdout]).to include("soft-blocked")
      expect(result[:stdout]).to include("sudo rfkill unblock bluetooth")
    end

    it "reports error when hard-blocked" do
      allow_any_instance_of(described_class).to receive(:run_command).with("rfkill --json 2>/dev/null").and_return(
        ['{"rfkilldevices":[{"type":"bluetooth","soft":"unblocked","hard":"blocked"}]}', true]
      )

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit)
      end

      expect(result[:stdout]).to include("[error] RF kill")
      expect(result[:stdout]).to include("hard-blocked")
    end

    it "skips when rfkill command not found" do
      allow_any_instance_of(described_class).to receive(:command_exists?).with("rfkill").and_return(false)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).not_to include("RF kill")
    end
  end

  describe "bluetooth group check" do
    it "reports info when user is in bluetooth group" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Bluetooth group")
      expect(result[:stdout]).to include("in 'bluetooth' group")
    end

    it "reports warning with fix when user is not in group" do
      allow(Process).to receive(:groups).and_return([])

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[warning] Bluetooth group")
      expect(result[:stdout]).to include("testuser")
      expect(result[:stdout]).to include("sudo usermod -aG bluetooth testuser")
    end

    it "reports info when bluetooth group does not exist" do
      allow(Etc).to receive(:getgrnam).with("bluetooth").and_raise(ArgumentError)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] Bluetooth group")
      expect(result[:stdout]).to include("does not exist")
    end
  end

  describe "bluetoothd version check" do
    it "reports info with version number" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("[info] BlueZ version")
      expect(result[:stdout]).to include("5.66")
    end

    it "skips when bluetoothd command not found" do
      allow_any_instance_of(described_class).to receive(:command_exists?).with("bluetoothd").and_return(false)

      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).not_to include("BlueZ version")
    end
  end

  describe "JSON output" do
    it "outputs valid JSON with summary and checks" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["summary"]).to include("errors", "warnings", "info")
      expect(parsed["checks"]).to be_an(Array)
      expect(parsed["checks"].first).to include("severity", "title", "message")
    end

    it "maps severities correctly in JSON" do
      allow(File).to receive(:exist?).with("/sys/module/bluetooth").and_return(false)
      allow(Process).to receive(:groups).and_return([])

      result = capture_output do
        expect { described_class.new(make_options("json" => true)).execute }.to raise_error(SystemExit)
      end

      parsed = JSON.parse(result[:stdout])
      severities = parsed["checks"].map { |c| c["severity"] }
      expect(severities).to include("error")
      expect(severities).to include("warning")
      expect(severities).to include("info")
    end

    it "includes fix commands in JSON when present" do
      allow(File).to receive(:exist?).with("/sys/module/bluetooth").and_return(false)

      result = capture_output do
        expect { described_class.new(make_options("json" => true)).execute }.to raise_error(SystemExit)
      end

      parsed = JSON.parse(result[:stdout])
      kernel_check = parsed["checks"].find { |c| c["title"] == "Kernel module" }
      expect(kernel_check["fix"]).to eq("sudo modprobe bluetooth")
    end

    it "counts errors, warnings, and info in summary" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["summary"]["errors"]).to eq(0)
      expect(parsed["summary"]["warnings"]).to eq(0)
      expect(parsed["summary"]["info"]).to be > 0
    end
  end

  describe "error resilience" do
    it "continues when one check raises an exception" do
      allow(dbus_conn).to receive(:connect).and_raise(StandardError.new("unexpected"))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      # D-Bus check should report the error
      expect(result[:stdout]).to include("[error] D-Bus access")
      # Other checks should still run
      expect(result[:stdout]).to include("Kernel module")
      expect(result[:stdout]).to include("Bluetooth adapter")
    end
  end
end
