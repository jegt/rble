# frozen_string_literal: true

require 'spec_helper'
require 'dbus'
require 'rble/bluez/retry_policy'

RSpec.describe RBLE::BlueZ::RetryPolicy do
  # Create test class that includes the module
  let(:test_class) do
    Class.new do
      include RBLE::BlueZ::RetryPolicy
    end
  end
  let(:instance) { test_class.new }

  # DBus::Error takes (message, name) - name is the second argument
  let(:in_progress_error) { DBus::Error.new('Operation in progress', 'org.bluez.Error.InProgress') }
  let(:other_error) { DBus::Error.new('Something else failed', 'org.bluez.Error.Failed') }

  describe '#with_inprogress_retry' do
    it 'returns block result on success' do
      result = instance.with_inprogress_retry { 42 }
      expect(result).to eq(42)
    end

    it 'retries on InProgress error' do
      attempt = 0
      result = instance.with_inprogress_retry do
        attempt += 1
        raise in_progress_error if attempt < 2

        'success'
      end

      expect(result).to eq('success')
      expect(attempt).to eq(2)
    end

    it 'retries up to MAX_RETRIES times' do
      attempt = 0

      expect {
        instance.with_inprogress_retry do
          attempt += 1
          raise in_progress_error
        end
      }.to raise_error(DBus::Error)

      # 1 initial attempt + MAX_RETRIES
      expect(attempt).to eq(1 + RBLE::BlueZ::RetryPolicy::MAX_RETRIES)
    end

    it 'uses exponential backoff' do
      delays = []
      attempt = 0

      # Capture sleep calls
      allow(instance).to receive(:sleep) do |delay|
        delays << delay
      end

      expect {
        instance.with_inprogress_retry do
          attempt += 1
          raise in_progress_error
        end
      }.to raise_error(DBus::Error)

      # Verify exponential pattern: 50ms -> 100ms -> 200ms
      expect(delays.length).to eq(RBLE::BlueZ::RetryPolicy::MAX_RETRIES)
      expect(delays[0]).to eq(RBLE::BlueZ::RetryPolicy::INITIAL_DELAY)
      expect(delays[1]).to eq(RBLE::BlueZ::RetryPolicy::INITIAL_DELAY * 2)
      expect(delays[2]).to eq(RBLE::BlueZ::RetryPolicy::INITIAL_DELAY * 4)
    end

    it 'caps delay at MAX_DELAY' do
      delays = []

      # Use a very small initial delay so we hit the cap quickly
      stub_const('RBLE::BlueZ::RetryPolicy::INITIAL_DELAY', 0.3)
      stub_const('RBLE::BlueZ::RetryPolicy::MAX_DELAY', 0.5)
      stub_const('RBLE::BlueZ::RetryPolicy::MAX_RETRIES', 3)

      allow(instance).to receive(:sleep) { |delay| delays << delay }

      expect {
        instance.with_inprogress_retry do
          raise in_progress_error
        end
      }.to raise_error(DBus::Error)

      # Third delay would be 0.3 * 4 = 1.2, but capped at 0.5
      expect(delays.last).to be <= 0.5
    end

    it 'does not retry on other errors' do
      attempt = 0

      expect {
        instance.with_inprogress_retry do
          attempt += 1
          raise other_error
        end
      }.to raise_error(DBus::Error) do |error|
        expect(error.name).to eq('org.bluez.Error.Failed')
      end

      expect(attempt).to eq(1)
    end
  end
end
