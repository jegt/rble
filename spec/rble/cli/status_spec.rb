# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/status"
require "stringio"

RSpec.describe RBLE::CLI::Status do
  let(:adapter_info) do
    {
      name: "hci0",
      address: "AA:BB:CC:DD:EE:FF",
      powered: true,
      discoverable: false,
      pairable: true,
      alias: "MyDevice",
      discovering: false
    }
  end

  let(:backend) do
    double(
      "backend",
      default_adapter_name: "hci0",
      adapter_info: adapter_info
    )
  end

  before do
    allow(RBLE::Backend).to receive(:for_platform).and_return(backend)
  end

  def make_options(overrides = {})
    defaults = { "json" => false, "verbose" => false, "adapter" => nil }
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

  describe "#execute" do
    it "shows adapter name in text output" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("hci0")
    end

    it "shows adapter address in text output" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("AA:BB:CC:DD:EE:FF")
    end

    it "shows powered state as yes/no" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/Powered:\s+yes/)
    end

    it "shows discoverable state" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/Discoverable:\s+no/)
    end

    it "shows pairable state" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/Pairable:\s+yes/)
    end

    it "shows discovering state" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to match(/Discovering:\s+no/)
    end

    it "shows alias" do
      result = capture_output { described_class.new(make_options).execute }

      expect(result[:stdout]).to include("MyDevice")
    end

    it "outputs valid JSON when --json is set" do
      result = capture_output { described_class.new(make_options("json" => true)).execute }

      parsed = JSON.parse(result[:stdout])
      expect(parsed["name"]).to eq("hci0")
      expect(parsed["address"]).to eq("AA:BB:CC:DD:EE:FF")
      expect(parsed["powered"]).to eq(true)
      expect(parsed["discoverable"]).to eq(false)
      expect(parsed["pairable"]).to eq(true)
      expect(parsed["discovering"]).to eq(false)
    end

    it "passes --adapter option to adapter_info" do
      allow(backend).to receive(:adapter_info).with("hci1").and_return(adapter_info)

      capture_output { described_class.new(make_options("adapter" => "hci1")).execute }

      expect(backend).to have_received(:adapter_info).with("hci1")
    end

    it "uses default adapter when no --adapter given" do
      capture_output { described_class.new(make_options).execute }

      expect(backend).to have_received(:default_adapter_name)
      expect(backend).to have_received(:adapter_info).with("hci0")
    end
  end

  describe "error handling" do
    it "prints doctor hint and exits 1 when adapter not found" do
      allow(backend).to receive(:default_adapter_name).and_raise(RBLE::AdapterNotFoundError.new)

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("rble doctor")
    end

    it "prints error message and exits 1 on RBLE::Error" do
      allow(backend).to receive(:adapter_info).and_raise(RBLE::Error.new("D-Bus failure"))

      result = capture_output do
        expect { described_class.new(make_options).execute }.to raise_error(SystemExit) { |e|
          expect(e.status).to eq(1)
        }
      end

      expect(result[:stderr]).to include("D-Bus failure")
    end
  end
end
