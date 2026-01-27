# frozen_string_literal: true

require 'spec_helper'

RSpec.describe 'RBLE Error Classes' do
  describe RBLE::OperationInProgressError do
    it 'includes operation in message' do
      error = described_class.new('connect')
      expect(error.message).to include('connect')
      expect(error.message).to include('in progress')
    end

    it 'has recovery hint' do
      error = described_class.new
      expect(error.recovery_hint).to include('retry')
    end
  end

  describe RBLE::AdapterNotReadyError do
    it 'includes adapter name in message' do
      error = described_class.new('hci0')
      expect(error.message).to include('hci0')
      expect(error.message).to include('not ready')
    end

    it 'has recovery hint' do
      error = described_class.new
      expect(error.recovery_hint).to include('bluetoothctl')
    end
  end

  describe RBLE::AuthenticationError do
    it 'includes address in message' do
      error = described_class.new('AA:BB:CC:DD:EE:FF')
      expect(error.message).to include('AA:BB:CC:DD:EE:FF')
      expect(error.message).to include('Authentication')
    end

    it 'stores address' do
      error = described_class.new('AA:BB:CC:DD:EE:FF')
      expect(error.address).to eq('AA:BB:CC:DD:EE:FF')
    end

    it 'has recovery hint about re-pairing' do
      error = described_class.new
      expect(error.recovery_hint).to include('pair')
    end
  end

  describe RBLE::ConnectionAbortedError do
    it 'includes address and reason in message' do
      error = described_class.new('AA:BB:CC:DD:EE:FF', 'stack error')
      expect(error.message).to include('AA:BB:CC:DD:EE:FF')
      expect(error.message).to include('aborted')
      expect(error.message).to include('stack error')
    end

    it 'stores address' do
      error = described_class.new('AA:BB:CC:DD:EE:FF')
      expect(error.address).to eq('AA:BB:CC:DD:EE:FF')
    end

    it 'has recovery hint about RF interference' do
      error = described_class.new
      expect(error.recovery_hint).to include('interference')
    end
  end

  describe RBLE::ConnectionLostError do
    it 'includes address and operation in message' do
      error = described_class.new('AA:BB:CC:DD:EE:FF', 'read')
      expect(error.message).to include('AA:BB:CC:DD:EE:FF')
      expect(error.message).to include('lost')
      expect(error.message).to include('read')
    end

    it 'stores address and operation' do
      error = described_class.new('AA:BB:CC:DD:EE:FF', 'write')
      expect(error.address).to eq('AA:BB:CC:DD:EE:FF')
      expect(error.operation).to eq('write')
    end

    it 'has recovery hint about reconnecting' do
      error = described_class.new
      expect(error.recovery_hint).to include('Reconnect')
    end
  end

  describe 'error inheritance' do
    it 'OperationInProgressError inherits from ConnectionError' do
      expect(RBLE::OperationInProgressError.ancestors).to include(RBLE::ConnectionError)
    end

    it 'AuthenticationError inherits from ConnectionError' do
      expect(RBLE::AuthenticationError.ancestors).to include(RBLE::ConnectionError)
    end

    it 'ConnectionAbortedError inherits from ConnectionError' do
      expect(RBLE::ConnectionAbortedError.ancestors).to include(RBLE::ConnectionError)
    end

    it 'ConnectionLostError inherits from ConnectionError' do
      expect(RBLE::ConnectionLostError.ancestors).to include(RBLE::ConnectionError)
    end

    it 'AdapterNotReadyError inherits from Error' do
      expect(RBLE::AdapterNotReadyError.ancestors).to include(RBLE::Error)
    end
  end
end
