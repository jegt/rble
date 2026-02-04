# frozen_string_literal: true

require "spec_helper"

RSpec.describe "RBLE.warnings" do
  after do
    RBLE.warnings = true
  end

  describe ".warnings" do
    it "defaults to true" do
      RBLE.instance_variable_set(:@warnings, nil)
      expect(RBLE.warnings).to be true
    end

    it "returns false when set to false" do
      RBLE.warnings = false
      expect(RBLE.warnings).to be false
    end

    it "returns true when explicitly set to true" do
      RBLE.warnings = false
      RBLE.warnings = true
      expect(RBLE.warnings).to be true
    end
  end

  describe ".rble_warn" do
    it "outputs [RBLE] prefixed message to stderr" do
      expect { RBLE.rble_warn("test message") }.to output("[RBLE] test message\n").to_stderr
    end

    it "outputs nothing when warnings are disabled" do
      RBLE.warnings = false
      expect { RBLE.rble_warn("test message") }.not_to output.to_stderr
    end

    it "outputs again after re-enabling warnings" do
      RBLE.warnings = false
      RBLE.warnings = true
      expect { RBLE.rble_warn("back on") }.to output("[RBLE] back on\n").to_stderr
    end
  end
end
