# frozen_string_literal: true

require "spec_helper"
require "rble/backend/bluez"

RSpec.describe RBLE::Backend::BlueZ do
  subject(:backend) { described_class.new }

  describe "#adapters" do
    context "when BlueZ is available" do
      # This test requires actual D-Bus - skip in CI without BT hardware
      it "returns array of adapter hashes", :bluetooth do
        adapters = backend.adapters
        expect(adapters).to be_an(Array)

        if adapters.any?
          adapter = adapters.first
          expect(adapter).to include(:name, :address, :powered)
          expect(adapter[:name]).to match(/^hci\d+$/)
        end
      end
    end
  end

  describe "#scanning?" do
    it "returns false when not scanning" do
      expect(backend.scanning?).to be false
    end
  end

  describe "#stop_scan" do
    it "does nothing when not scanning" do
      expect { backend.stop_scan }.not_to raise_error
    end
  end

  describe "#start_scan" do
    it "raises ArgumentError without block" do
      expect { backend.start_scan }.to raise_error(ArgumentError, /Block required/)
    end

    it "raises ScanInProgressError if already scanning", :bluetooth do
      skip "Requires Bluetooth hardware" unless bluetooth_available?

      # Start first scan
      backend.start_scan { |d| }

      expect {
        backend.start_scan { |d| }
      }.to raise_error(RBLE::ScanInProgressError)

      backend.stop_scan
    end
  end

  private

  def bluetooth_available?
    backend.adapters.any? { |a| a[:powered] }
  rescue
    false
  end
end
