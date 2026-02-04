# frozen_string_literal: true

require "spec_helper"
require "timeout"

RSpec.describe RBLE::Scanner do
  describe ".new" do
    it "creates scanner with default options" do
      scanner = described_class.new
      expect(scanner).to be_a(described_class)
    end

    it "accepts all options" do
      scanner = described_class.new(
        service_uuids: ["180d"],
        timeout: 10,
        allow_duplicates: true,
        adapter: "hci0",
        on_stop: -> { }
      )
      expect(scanner).to be_a(described_class)
    end

    it "accepts active: parameter" do
      scanner = described_class.new(active: false)
      expect(scanner).to be_a(described_class)
    end

    it "defaults allow_duplicates to false for active scanning" do
      scanner = described_class.new(active: true)
      expect(scanner.instance_variable_get(:@allow_duplicates)).to be false
    end

    it "defaults allow_duplicates to true for passive scanning" do
      scanner = described_class.new(active: false)
      expect(scanner.instance_variable_get(:@allow_duplicates)).to be true
    end

    it "respects explicit allow_duplicates override in passive mode" do
      scanner = described_class.new(active: false, allow_duplicates: false)
      expect(scanner.instance_variable_get(:@allow_duplicates)).to be false
    end

    it "respects explicit allow_duplicates override in active mode" do
      scanner = described_class.new(active: true, allow_duplicates: true)
      expect(scanner.instance_variable_get(:@allow_duplicates)).to be true
    end
  end

  describe "#scanning?" do
    it "returns false before start" do
      scanner = described_class.new
      expect(scanner.scanning?).to be false
    end
  end

  describe "#stop" do
    it "can be called when not scanning" do
      scanner = described_class.new
      expect { scanner.stop }.not_to raise_error
    end
  end

  describe "#start" do
    it "raises ArgumentError without block" do
      scanner = described_class.new
      expect { scanner.start }.to raise_error(ArgumentError, /Block required/)
    end

    it "raises ScanInProgressError when already scanning" do
      # Scanner checks @started directly, so we use instance_variable_set
      scanner = described_class.new
      scanner.instance_variable_set(:@started, true)
      expect { scanner.start { |d| } }.to raise_error(RBLE::ScanInProgressError)
    end

    context "with Bluetooth hardware", :bluetooth do
      it "discovers devices and returns scanner" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        devices = []
        scanner = described_class.new(timeout: 2)

        result = scanner.start { |d| devices << d }

        expect(result).to be(scanner)
        expect(scanner.scanning?).to be false
      end

      it "respects timeout" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        # Give BlueZ time to clean up from any previous tests
        sleep 1.0

        # Wrap in overall timeout to catch hangs in setup/teardown
        elapsed = nil
        Timeout.timeout(30) do
          start_time = Time.now
          scanner = described_class.new(timeout: 2)
          scanner.start { |d| }
          elapsed = Time.now - start_time
        end

        # Async D-Bus architecture adds overhead for session setup/teardown.
        # When BlueZ has residual state from previous tests, setup can take longer.
        # A 2s timeout typically completes in 3-5s total; allow up to 15s for edge cases.
        expect(elapsed).to be < 15.0
        expect(elapsed).to be > 2.0  # Should take at least the timeout duration
      end

      it "calls on_stop callback" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        stopped = false
        scanner = described_class.new(timeout: 1, on_stop: -> { stopped = true })
        scanner.start { |d| }

        expect(stopped).to be true
      end

      it "supports manual stop" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        devices = []
        scanner = described_class.new
        stop_after = 3

        result = scanner.start do |device|
          devices << device
          scanner.stop if devices.size >= stop_after
        end

        expect(result).to be(scanner)
        expect(devices.size).to be >= stop_after
      end

      it "discovers devices with passive scanning" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        devices = []
        scanner = described_class.new(active: false, timeout: 5)

        result = scanner.start { |d| devices << d }

        expect(result).to be(scanner)
        # With allow_duplicates defaulting to true, we should get many callbacks
        expect(devices.size).to be > 0
      end
    end
  end

  private

  def bluetooth_available?
    RBLE.adapters.any? { |a| a[:powered] }
  rescue
    false
  end
end

RSpec.describe RBLE do
  describe ".scan" do
    context "without hardware" do
      it "creates and returns a Scanner" do
        # We can't actually run scan without hardware, test structure only
        scanner = RBLE::Scanner.new(timeout: 0.1)
        expect(scanner).to be_a(RBLE::Scanner)
      end
    end

    context "with Bluetooth hardware", :bluetooth do
      it "returns a Scanner after scan completes" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        result = RBLE.scan(timeout: 1) { |d| }
        expect(result).to be_a(RBLE::Scanner)
      end

      it "receives RuuviTag advertisements in passive mode", :bluetooth do
        skip "Requires Bluetooth hardware" unless bluetooth_available?
        skip "Requires RuuviTag in range" if ENV["SKIP_BLE_HARDWARE"]

        ruuvi_company_id = 0x0499
        found_ruuvi = false

        RBLE.scan(active: false, timeout: 10) do |device|
          if device.manufacturer_data_bytes(ruuvi_company_id)
            found_ruuvi = true
            break
          end
        end

        expect(found_ruuvi).to be true
      end
    end
  end

  describe ".adapters" do
    it "returns an array" do
      # This requires D-Bus - may return empty array or error without BT
      adapters = RBLE.adapters
      expect(adapters).to be_an(Array)
    rescue RBLE::Error
      skip "D-Bus/BlueZ not available"
    end

    context "with Bluetooth hardware", :bluetooth do
      it "returns adapter info hashes" do
        skip "Requires Bluetooth hardware" unless bluetooth_available?

        adapters = RBLE.adapters
        expect(adapters).not_to be_empty

        adapter = adapters.first
        expect(adapter).to include(:name, :address, :powered)
      end
    end
  end

  private

  def bluetooth_available?
    RBLE.adapters.any? { |a| a[:powered] }
  rescue
    false
  end
end
