# frozen_string_literal: true

require 'spec_helper'

RSpec.describe RBLE::ActiveCharacteristic do
  let(:mock_backend) { double('RBLE::Backend::Base') }
  let(:device_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF' }
  let(:address) { 'AA:BB:CC:DD:EE:FF' }
  let(:connection) do
    RBLE::Connection.new(
      address: address,
      device_path: device_path,
      backend: mock_backend
    )
  end
  let(:char_data) do
    RBLE::Characteristic.new(
      uuid: '00002a37-0000-1000-8000-00805f9b34fb',
      flags: %w[read notify],
      service_uuid: '0000180d-0000-1000-8000-00805f9b34fb'
    )
  end
  let(:char_path) { "#{device_path}/service0010/char0011" }

  subject(:active_char) do
    described_class.new(
      characteristic: char_data,
      path: char_path,
      connection: connection,
      backend: mock_backend
    )
  end

  describe '#read routes through gatt_queue' do
    it 'enqueues the read operation via the connection gatt_queue' do
      allow(mock_backend).to receive(:read_characteristic).and_return("\x10\x50")

      # The queue should be used since gatt_queue is now public
      active_char.read

      expect(mock_backend).to have_received(:read_characteristic).with(
        char_path,
        connection: connection,
        timeout: 30
      )
    end

    it 'serializes concurrent reads through the queue' do
      call_order = []
      mutex = Mutex.new

      allow(mock_backend).to receive(:read_characteristic) do
        mutex.synchronize { call_order << :start }
        sleep 0.02
        mutex.synchronize { call_order << :end }
        "\x00"
      end

      threads = 3.times.map do
        Thread.new { active_char.read }
      end
      threads.each(&:join)

      # Verify serialization: starts and ends should alternate
      call_order.each_slice(2) do |pair|
        expect(pair).to eq(%i[start end])
      end
    end
  end

  after do
    # Clean up the gatt queue
    connection.gatt_queue.stop if connection.respond_to?(:gatt_queue) && connection.gatt_queue.running?
  rescue StandardError
    # ignore cleanup errors
  end
end
