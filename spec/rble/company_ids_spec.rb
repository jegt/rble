# frozen_string_literal: true

require "spec_helper"
require "rble/company_ids"

RSpec.describe RBLE::CompanyIdentifiers do
  describe ".resolve" do
    it "resolves known company IDs" do
      expect(described_class.resolve(0x004C)).to eq("Apple")
      expect(described_class.resolve(0x0006)).to eq("Microsoft")
      expect(described_class.resolve(0x0059)).to eq("Nordic Semiconductor")
      expect(described_class.resolve(0x0499)).to eq("Ruuvi Innovations")
    end

    it "returns nil for unknown company IDs" do
      expect(described_class.resolve(0xFFFF)).to be_nil
    end
  end
end
