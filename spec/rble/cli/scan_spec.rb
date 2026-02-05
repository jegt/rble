# frozen_string_literal: true

require "spec_helper"
require "rble/cli"
require "rble/cli/scan"
require "stringio"

RSpec.describe RBLE::CLI::Scan do
  let(:devices) do
    [
      RBLE::Device.new(address: "AA:BB:CC:DD:EE:FF", name: "Polar H10", rssi: -65, address_type: "public"),
      RBLE::Device.new(address: "11:22:33:44:55:66", name: "Ruuvi 1234", rssi: -80, address_type: "random"),
      RBLE::Device.new(address: "22:33:44:55:66:77", name: nil, rssi: -90, address_type: "random"),
      RBLE::Device.new(address: "33:44:55:66:77:88", name: "Polar OH1", rssi: -55, address_type: "public")
    ]
  end

  let(:scanner) { instance_double(RBLE::Scanner) }

  before do
    allow(RBLE::Scanner).to receive(:new).and_return(scanner)
    allow(scanner).to receive(:start) do |&block|
      devices.each { |d| block.call(d) }
    end
    allow(scanner).to receive(:stop)
  end

  def make_options(overrides = {})
    defaults = { "json" => false, "verbose" => false, "timeout" => 1, "name" => nil, "rssi" => nil, "passive" => false }
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
    it "outputs all devices when no filters are set" do
      scan = described_class.new(make_options)
      result = capture_output { scan.execute }

      expect(result[:stdout]).to include("Polar H10")
      expect(result[:stdout]).to include("Ruuvi 1234")
      expect(result[:stdout]).to include("(unknown)")
      expect(result[:stdout]).to include("Polar OH1")
    end

    it "filters by name (case-insensitive substring)" do
      scan = described_class.new(make_options("name" => "polar"))
      result = capture_output { scan.execute }

      expect(result[:stdout]).to include("Polar H10")
      expect(result[:stdout]).to include("Polar OH1")
      expect(result[:stdout]).not_to include("Ruuvi 1234")
    end

    it "excludes unnamed devices when name filter is active" do
      scan = described_class.new(make_options("name" => "polar"))
      result = capture_output { scan.execute }

      expect(result[:stdout]).not_to include("(unknown)")
    end

    it "filters by RSSI threshold" do
      scan = described_class.new(make_options("rssi" => -70))
      result = capture_output { scan.execute }

      expect(result[:stdout]).to include("Polar H10")    # -65 >= -70
      expect(result[:stdout]).to include("Polar OH1")    # -55 >= -70
      expect(result[:stdout]).not_to include("Ruuvi 1234")  # -80 < -70
    end

    it "applies AND logic for combined filters" do
      scan = described_class.new(make_options("name" => "polar", "rssi" => -60))
      result = capture_output { scan.execute }

      expect(result[:stdout]).to include("Polar OH1")      # name matches AND -55 >= -60
      expect(result[:stdout]).not_to include("Polar H10")  # name matches BUT -65 < -60
      expect(result[:stdout]).not_to include("Ruuvi 1234")
    end

    it "uses JSON formatter when --json is set" do
      scan = described_class.new(make_options("json" => true))
      result = capture_output { scan.execute }

      lines = result[:stdout].strip.split("\n")
      expect(lines.size).to eq(4)

      parsed = JSON.parse(lines.first)
      expect(parsed).to include("address", "name", "rssi", "address_type")
    end

    it "passes passive mode to Scanner" do
      capture_output { described_class.new(make_options("passive" => true)).execute }

      expect(RBLE::Scanner).to have_received(:new).with(hash_including(active: false))
    end

    it "passes active mode by default" do
      capture_output { described_class.new(make_options).execute }

      expect(RBLE::Scanner).to have_received(:new).with(hash_including(active: true))
    end

    it "passes timeout to Scanner" do
      capture_output { described_class.new(make_options("timeout" => 5)).execute }

      expect(RBLE::Scanner).to have_received(:new).with(hash_including(timeout: 5))
    end

    it "always sets allow_duplicates to true" do
      capture_output { described_class.new(make_options).execute }

      expect(RBLE::Scanner).to have_received(:new).with(hash_including(allow_duplicates: true))
    end

    it "prints summary with unique devices and advertisement count to stderr" do
      scan = described_class.new(make_options)
      result = capture_output { scan.execute }

      expect(result[:stderr]).to match(/Discovered 4 devices \(4 advertisements\) in \d+\.\ds/)
    end

    it "distinguishes unique devices from repeated advertisements" do
      repeated_devices = [
        RBLE::Device.new(address: "AA:BB:CC:DD:EE:FF", name: "Polar H10", rssi: -65, address_type: "public"),
        RBLE::Device.new(address: "AA:BB:CC:DD:EE:FF", name: "Polar H10", rssi: -63, address_type: "public"),
        RBLE::Device.new(address: "11:22:33:44:55:66", name: "Ruuvi 1234", rssi: -80, address_type: "random")
      ]
      allow(scanner).to receive(:start) do |&block|
        repeated_devices.each { |d| block.call(d) }
      end

      scan = described_class.new(make_options)
      result = capture_output { scan.execute }

      expect(result[:stderr]).to match(/Discovered 2 devices \(3 advertisements\) in/)
    end

    it "uses singular forms for count of 1" do
      allow(scanner).to receive(:start) do |&block|
        block.call(devices.first)
      end

      scan = described_class.new(make_options)
      result = capture_output { scan.execute }

      expect(result[:stderr]).to match(/Discovered 1 device \(1 advertisement\) in/)
    end

    it "shows unnamed devices when no name filter is active" do
      scan = described_class.new(make_options)
      result = capture_output { scan.execute }

      # Device with nil name should appear as (unknown)
      expect(result[:stdout]).to include("22:33:44:55:66:77")
    end

    it "prints 'No devices found matching filters' when timed scan with filters finds nothing" do
      allow(scanner).to receive(:start) do |&block|
        # yield no devices
      end

      scan = described_class.new(make_options("timeout" => 5, "name" => "nonexistent"))
      result = capture_output { scan.execute }

      expect(result[:stderr]).to include("No devices found matching filters")
    end

    it "does not print filter message when no filters are set" do
      allow(scanner).to receive(:start) do |&block|
        # yield no devices
      end

      scan = described_class.new(make_options("timeout" => 5))
      result = capture_output { scan.execute }

      expect(result[:stderr]).not_to include("No devices found matching filters")
    end
  end

  describe "error handling" do
    before do
      allow(scanner).to receive(:start).and_raise(
        RBLE::AdapterNotFoundError.new
      )
    end

    it "prints friendly error message and exits 1" do
      scan = described_class.new(make_options)

      result = capture_output do
        expect { scan.execute }.to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end

      expect(result[:stderr]).to include("Error:")
      expect(result[:stderr]).to include("No Bluetooth adapter found")
    end

    it "shows recovery hint in verbose mode" do
      error = RBLE::AdapterNotReadyError.new
      allow(scanner).to receive(:start).and_raise(error)

      scan = described_class.new(make_options("verbose" => true))

      result = capture_output do
        expect { scan.execute }.to raise_error(SystemExit)
      end

      expect(result[:stderr]).to include(error.recovery_hint)
    end

    it "shows backtrace in verbose mode" do
      scan = described_class.new(make_options("verbose" => true))

      result = capture_output do
        expect { scan.execute }.to raise_error(SystemExit)
      end

      # Backtrace should contain file paths
      expect(result[:stderr]).to match(%r{/.*\.rb:\d+})
    end

    it "does not show backtrace without verbose" do
      scan = described_class.new(make_options)

      result = capture_output do
        expect { scan.execute }.to raise_error(SystemExit)
      end

      # Should only have "Error: ..." line, no backtrace paths
      error_lines = result[:stderr].lines.select { |l| l.match?(%r{/.*\.rb:\d+}) }
      expect(error_lines).to be_empty
    end
  end

  describe "signal handling" do
    it "installs INT handler that calls scanner.stop" do
      int_handler = nil
      allow(scanner).to receive(:start) do |&block|
        # Capture the current INT handler installed during execute
        int_handler = trap("INT", "DEFAULT")
        # Restore it so ensure block works
        trap("INT", int_handler) if int_handler
        devices.each { |d| block.call(d) }
      end

      scan = described_class.new(make_options)
      capture_output { scan.execute }

      # The handler should be a Proc (our lambda that calls scanner.stop)
      expect(int_handler).to be_a(Proc)
    end
  end
end
