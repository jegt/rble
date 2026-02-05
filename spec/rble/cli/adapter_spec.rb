# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/adapter"
require "stringio"

RSpec.describe RBLE::CLI::AdapterCli do
  let(:adapters_list) do
    [
      { name: "hci0", address: "AA:BB:CC:DD:EE:FF", powered: true, discoverable: false, pairable: true, alias: "hci0", discovering: false },
      { name: "hci1", address: "11:22:33:44:55:66", powered: false, discoverable: false, pairable: false, alias: "hci1", discovering: false }
    ]
  end

  let(:backend) do
    double(
      "backend",
      adapters: adapters_list,
      default_adapter_name: "hci0",
      adapter_set_property: true
    )
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
  end

  def make_options(overrides = {})
    defaults = { "json" => false, "adapter" => nil }
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

  # Helper to invoke AdapterCli commands directly
  def invoke_command(command, args = [], options = {})
    cli = described_class.new(args, make_options(options))
    cli.invoke(command)
  end

  describe "#list" do
    it "shows adapter names and addresses in text output" do
      result = capture_output { invoke_command(:list) }

      expect(result[:stdout]).to include("hci0")
      expect(result[:stdout]).to include("AA:BB:CC:DD:EE:FF")
      expect(result[:stdout]).to include("hci1")
      expect(result[:stdout]).to include("11:22:33:44:55:66")
    end

    it "shows power state (up/down)" do
      result = capture_output { invoke_command(:list) }

      expect(result[:stdout]).to include("up")
      expect(result[:stdout]).to include("down")
    end

    it "outputs valid JSON array when --json is set" do
      result = capture_output { invoke_command(:list, [], "json" => true) }

      parsed = JSON.parse(result[:stdout])
      expect(parsed).to be_an(Array)
      expect(parsed.size).to eq(2)
      expect(parsed.first["name"]).to eq("hci0")
    end

    it "shows message when no adapters found" do
      allow(backend).to receive(:adapters).and_return([])

      result = capture_output { invoke_command(:list) }

      expect(result[:stdout]).to include("No Bluetooth adapters found")
    end
  end

  describe "#power" do
    it "'on' calls adapter_set_property with true" do
      capture_output { invoke_command(:power, ["on"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :powered, true)
    end

    it "'off' calls adapter_set_property with false" do
      capture_output { invoke_command(:power, ["off"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :powered, false)
    end

    it "prints confirmation for power on" do
      result = capture_output { invoke_command(:power, ["on"]) }

      expect(result[:stdout]).to include("Adapter powered on")
    end

    it "prints confirmation for power off" do
      result = capture_output { invoke_command(:power, ["off"]) }

      expect(result[:stdout]).to include("Adapter powered off")
    end

    it "uses specified adapter" do
      capture_output { invoke_command(:power, ["on"], "adapter" => "hci1") }

      expect(backend).to have_received(:adapter_set_property).with("hci1", :powered, true)
    end

    it "raises error for invalid state" do
      expect {
        capture_output { invoke_command(:power, ["maybe"]) }
      }.to raise_error(Thor::Error, /Invalid state/)
    end

    it "prints error and exits 1 on RBLE::Error" do
      allow(backend).to receive(:adapter_set_property).and_raise(RBLE::Error.new("permission denied"))

      result = capture_output do
        expect { invoke_command(:power, ["on"]) }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("permission denied")
      expect(result[:stderr]).to include("rble doctor")
    end
  end

  describe "#discoverable" do
    it "'on' calls adapter_set_property with true" do
      capture_output { invoke_command(:discoverable, ["on"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :discoverable, true)
    end

    it "'off' calls adapter_set_property with false" do
      capture_output { invoke_command(:discoverable, ["off"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :discoverable, false)
    end

    it "prints confirmation" do
      result = capture_output { invoke_command(:discoverable, ["on"]) }

      expect(result[:stdout]).to include("Discoverable mode enabled")
    end

    it "raises error for invalid state" do
      expect {
        capture_output { invoke_command(:discoverable, ["maybe"]) }
      }.to raise_error(Thor::Error, /Invalid state/)
    end
  end

  describe "#pairable" do
    it "'on' calls adapter_set_property with true" do
      capture_output { invoke_command(:pairable, ["on"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :pairable, true)
    end

    it "'off' calls adapter_set_property with false" do
      capture_output { invoke_command(:pairable, ["off"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :pairable, false)
    end

    it "prints confirmation" do
      result = capture_output { invoke_command(:pairable, ["off"]) }

      expect(result[:stdout]).to include("Pairable mode disabled")
    end
  end

  describe "#name" do
    it "sets alias via adapter_set_property" do
      capture_output { invoke_command(:name, ["MyNewDevice"]) }

      expect(backend).to have_received(:adapter_set_property).with("hci0", :alias, "MyNewDevice")
    end

    it "prints confirmation with new name" do
      result = capture_output { invoke_command(:name, ["MyNewDevice"]) }

      expect(result[:stdout]).to include("Adapter name set to 'MyNewDevice'")
    end

    it "uses specified adapter" do
      capture_output { invoke_command(:name, ["Test"], "adapter" => "hci1") }

      expect(backend).to have_received(:adapter_set_property).with("hci1", :alias, "Test")
    end

    it "prints error and exits 1 on RBLE::Error" do
      allow(backend).to receive(:adapter_set_property).and_raise(RBLE::Error.new("failed"))

      result = capture_output do
        expect { invoke_command(:name, ["Bad"]) }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("failed")
    end
  end

  describe "JSON output for property commands" do
    it "outputs JSON confirmation for power on" do
      result = capture_output { invoke_command(:power, ["on"], "json" => true) }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["status"]).to eq("ok")
      expect(parsed["message"]).to include("powered on")
    end

    it "outputs JSON confirmation for name set" do
      result = capture_output { invoke_command(:name, ["Test"], "json" => true) }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["status"]).to eq("ok")
      expect(parsed["message"]).to include("Test")
    end
  end
end
