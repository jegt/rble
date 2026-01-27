# frozen_string_literal: true

require "bundler/setup"
require "rble"

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.filter_run_when_matching :focus
  config.disable_monkey_patching!
  config.warnings = true

  config.order = :random
  Kernel.srand config.seed

  # Reset backend singleton after each test to prevent state leakage
  # between tests that use real Bluetooth hardware
  config.after(:each) do
    RBLE::Backend.reset! if defined?(RBLE::Backend)
  end
end
