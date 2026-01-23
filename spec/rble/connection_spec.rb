# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RBLE::Connection do
  let(:mock_backend) { instance_double('RBLE::Backend::Base') }
  let(:device_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF' }
  let(:address) { 'AA:BB:CC:DD:EE:FF' }

  subject(:connection) do
    described_class.new(
      address: address,
      device_path: device_path,
      backend: mock_backend
    )
  end

  describe 'VALID_TRANSITIONS' do
    it 'is frozen' do
      expect(RBLE::Connection::VALID_TRANSITIONS).to be_frozen
    end

    it 'defines all expected states' do
      expect(RBLE::Connection::VALID_TRANSITIONS.keys).to contain_exactly(
        :disconnected, :connecting, :connected, :disconnecting, :discovering_services
      )
    end

    it 'allows connecting -> connected' do
      expect(RBLE::Connection::VALID_TRANSITIONS[:connecting]).to include(:connected)
    end

    it 'allows connected -> disconnected' do
      expect(RBLE::Connection::VALID_TRANSITIONS[:connected]).to include(:disconnected)
    end
  end

  describe '#initialize' do
    it 'starts in connected state' do
      expect(connection.state).to eq(:connected)
    end

    it 'sets address' do
      expect(connection.address).to eq(address)
    end

    it 'sets device_path' do
      expect(connection.device_path).to eq(device_path)
    end
  end

  describe '#state' do
    it 'returns current state' do
      expect(connection.state).to eq(:connected)
    end

    it 'is thread-safe for concurrent reads' do
      threads = 10.times.map do
        Thread.new { 100.times { connection.state } }
      end
      expect { threads.each(&:join) }.not_to raise_error
    end
  end

  describe '#connected?' do
    it 'returns true when state is :connected' do
      expect(connection.connected?).to be true
    end

    it 'returns false after disconnect' do
      allow(mock_backend).to receive(:disconnect_device)
      connection.disconnect
      expect(connection.connected?).to be false
    end
  end

  describe '#on_disconnect' do
    it 'raises ArgumentError without block' do
      expect { connection.on_disconnect }.to raise_error(ArgumentError, /Block required/)
    end

    it 'registers callback that receives reason on disconnect' do
      allow(mock_backend).to receive(:disconnect_device)

      received_reason = nil
      connection.on_disconnect { |reason| received_reason = reason }
      connection.disconnect

      expect(received_reason).to eq(:user_requested)
    end

    it 'supports multiple callbacks' do
      allow(mock_backend).to receive(:disconnect_device)

      reasons = []
      connection.on_disconnect { |reason| reasons << "first:#{reason}" }
      connection.on_disconnect { |reason| reasons << "second:#{reason}" }
      connection.disconnect

      expect(reasons).to eq(['first:user_requested', 'second:user_requested'])
    end

    it 'receives reason from handle_disconnect' do
      received_reason = nil
      connection.on_disconnect { |reason| received_reason = reason }
      connection.handle_disconnect(:link_loss)

      expect(received_reason).to eq(:link_loss)
    end
  end

  describe '#on_state_change' do
    it 'raises ArgumentError without block' do
      expect { connection.on_state_change }.to raise_error(ArgumentError, /Block required/)
    end

    it 'receives (old_state, new_state) on transitions' do
      allow(mock_backend).to receive(:disconnect_device)

      transitions = []
      connection.on_state_change { |old_state, new_state| transitions << [old_state, new_state] }
      connection.disconnect

      expect(transitions).to include([:connected, :disconnecting])
      expect(transitions).to include([:disconnecting, :disconnected])
    end

    it 'supports multiple callbacks in registration order' do
      allow(mock_backend).to receive(:disconnect_device)

      order = []
      connection.on_state_change { |_, _| order << 'first' }
      connection.on_state_change { |_, _| order << 'second' }
      connection.disconnect

      # Two transitions (connected->disconnecting, disconnecting->disconnected)
      # Each triggers both callbacks in order
      expect(order).to eq(%w[first second first second])
    end
  end

  describe 'callback error handling' do
    it 'continues after state_change callback error' do
      allow(mock_backend).to receive(:disconnect_device)

      second_called = false
      connection.on_state_change { |_, _| raise 'callback error' }
      connection.on_state_change { |_, _| second_called = true }

      expect { connection.disconnect }.not_to raise_error
      expect(second_called).to be true
    end

    it 'continues after disconnect callback error' do
      allow(mock_backend).to receive(:disconnect_device)

      second_called = false
      connection.on_disconnect { |_| raise 'callback error' }
      connection.on_disconnect { |_| second_called = true }

      expect { connection.disconnect }.not_to raise_error
      expect(second_called).to be true
    end

    it 'does not break state machine on callback error' do
      allow(mock_backend).to receive(:disconnect_device)

      connection.on_state_change { |_, _| raise 'callback error' }
      connection.disconnect

      expect(connection.state).to eq(:disconnected)
    end
  end

  describe '#disconnect' do
    before do
      allow(mock_backend).to receive(:disconnect_device)
    end

    it 'transitions to :disconnecting then :disconnected' do
      transitions = []
      connection.on_state_change { |old_state, new_state| transitions << [old_state, new_state] }
      connection.disconnect

      expect(transitions).to eq([
        [:connected, :disconnecting],
        [:disconnecting, :disconnected]
      ])
    end

    it 'calls backend disconnect_device' do
      connection.disconnect
      expect(mock_backend).to have_received(:disconnect_device).with(device_path)
    end

    it 'is idempotent when already disconnected' do
      connection.disconnect
      connection.disconnect

      expect(mock_backend).to have_received(:disconnect_device).once
    end

    it 'returns early when disconnecting in progress' do
      # Simulate already in :disconnecting state
      connection.instance_variable_set(:@state, :disconnecting)
      connection.disconnect

      expect(mock_backend).not_to have_received(:disconnect_device)
    end

    it 'clears services cache' do
      allow(mock_backend).to receive(:discover_services).and_return([])
      connection.discover_services
      connection.disconnect

      expect { connection.services }.to raise_error(RBLE::ServiceDiscoveryError)
    end
  end

  describe '#handle_disconnect' do
    it 'transitions to :disconnected with given reason' do
      received_reason = nil
      connection.on_disconnect { |reason| received_reason = reason }
      connection.handle_disconnect(:timeout)

      expect(connection.state).to eq(:disconnected)
      expect(received_reason).to eq(:timeout)
    end

    it 'returns true if transition happened' do
      expect(connection.handle_disconnect(:link_loss)).to be true
    end

    it 'returns false if already disconnected' do
      connection.handle_disconnect(:link_loss)
      expect(connection.handle_disconnect(:link_loss)).to be false
    end

    it 'clears services cache' do
      allow(mock_backend).to receive(:discover_services).and_return([])
      connection.discover_services
      connection.handle_disconnect(:link_loss)

      expect { connection.services }.to raise_error(RBLE::ServiceDiscoveryError)
    end

    it 'supports various disconnect reasons' do
      reasons = []
      connection.on_disconnect { |r| reasons << r }

      # Create new connection for each reason test
      [:link_loss, :timeout, :remote_disconnect, :user_requested, :unknown].each_with_index do |reason, i|
        conn = described_class.new(
          address: address,
          device_path: device_path,
          backend: mock_backend
        )
        conn.on_disconnect { |r| reasons << r }
        conn.handle_disconnect(reason)
      end

      expect(reasons).to contain_exactly(:link_loss, :timeout, :remote_disconnect, :user_requested, :unknown)
    end
  end

  describe '#discover_services' do
    it 'raises NotConnectedError when not connected' do
      allow(mock_backend).to receive(:disconnect_device)
      connection.disconnect

      expect { connection.discover_services }.to raise_error(RBLE::NotConnectedError)
    end

    it 'transitions to :discovering_services and back to :connected' do
      allow(mock_backend).to receive(:discover_services).and_return([])

      transitions = []
      connection.on_state_change { |old_state, new_state| transitions << [old_state, new_state] }
      connection.discover_services

      expect(transitions).to eq([
        [:connected, :discovering_services],
        [:discovering_services, :connected]
      ])
    end

    it 'returns to :connected on discovery failure' do
      allow(mock_backend).to receive(:discover_services).and_raise(RBLE::ServiceDiscoveryError)

      expect { connection.discover_services }.to raise_error(RBLE::ServiceDiscoveryError)
      expect(connection.state).to eq(:connected)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent state access without deadlock' do
      readers = 5.times.map do
        Thread.new do
          100.times do
            connection.state
            connection.connected?
          end
        end
      end

      writers = 2.times.map do
        Thread.new do
          conn = described_class.new(
            address: address,
            device_path: device_path,
            backend: mock_backend
          )
          allow(mock_backend).to receive(:disconnect_device)
          conn.disconnect
        end
      end

      expect { (readers + writers).each(&:join) }.not_to raise_error
    end

    it 'maintains consistent state under concurrent access' do
      allow(mock_backend).to receive(:disconnect_device)

      final_states = []
      threads = 10.times.map do
        Thread.new do
          conn = described_class.new(
            address: address,
            device_path: device_path,
            backend: mock_backend
          )
          conn.disconnect
          final_states << conn.state
        end
      end

      threads.each(&:join)
      expect(final_states).to all(eq(:disconnected))
    end
  end
end
