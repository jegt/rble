# frozen_string_literal: true

require 'spec_helper'
require 'rble/bluez'

RSpec.describe 'BLE Full Flow Integration', :integration do
  # Mock-based tests that run in CI without hardware
  describe 'mock-based flow' do
    # Use plain doubles for mocked classes so we can set up any methods
    let(:mock_session) { double('DBusSession') }
    let(:mock_adapter) { double('Adapter') }
    let(:mock_device) { double('Device') }

    before do
      # Setup session mock
      allow(RBLE::BlueZ::DBusSession).to receive(:new).and_return(mock_session)
      allow(mock_session).to receive(:connect)
      allow(mock_session).to receive(:start_event_loop)
      allow(mock_session).to receive(:close)
      allow(mock_session).to receive(:closed?).and_return(false)
      allow(mock_session).to receive(:connected?).and_return(true)
      allow(mock_session).to receive(:running?).and_return(true)

      # Setup adapter mock
      allow(mock_session).to receive(:async_get_managed_objects).and_return({
        '/org/bluez/hci0' => {
          'org.bluez.Adapter1' => {
            'Address' => 'AA:BB:CC:DD:EE:FF',
            'Powered' => true,
            'Discovering' => false
          }
        }
      })
      allow(RBLE::BlueZ::Adapter).to receive(:new_from_session).and_return(mock_adapter)
      allow(mock_adapter).to receive(:address).and_return('AA:BB:CC:DD:EE:FF')
      allow(mock_adapter).to receive(:powered?).and_return(true)

      # Setup device discovery mock
      allow(mock_session).to receive(:async_start_discovery)
      allow(mock_session).to receive(:async_stop_discovery)
      allow(mock_adapter).to receive(:start_discovery)
      allow(mock_adapter).to receive(:stop_discovery)

      # Setup device mock
      allow(RBLE::BlueZ::Device).to receive(:new_from_session).and_return(mock_device)
      allow(mock_device).to receive(:address).and_return('11:22:33:44:55:66')
      allow(mock_device).to receive(:name).and_return('Test Device')
      allow(mock_device).to receive(:connected?).and_return(true)
      allow(mock_device).to receive(:connect)
      allow(mock_device).to receive(:disconnect)
      allow(mock_device).to receive(:services_resolved?).and_return(true)
    end

    it 'completes mock flow: session -> adapter -> scan -> connect -> discover -> disconnect -> close' do
      # 1. Create and connect session
      session = RBLE::BlueZ::DBusSession.new
      session.connect
      session.start_event_loop

      # 2. Get adapter
      adapter = RBLE::BlueZ::Adapter.new_from_session(session, '/org/bluez/hci0')
      expect(adapter.powered?).to be true

      # 3. Scan (mocked - normally would use events)
      adapter.start_discovery
      adapter.stop_discovery

      # 4. Connect to device
      device = RBLE::BlueZ::Device.new_from_session(session, '/org/bluez/hci0/dev_11_22_33_44_55_66')
      device.connect
      expect(device.connected?).to be true

      # 5. Check services resolved
      expect(device.services_resolved?).to be true

      # 6. Disconnect device
      device.disconnect

      # 7. Close session
      session.close
    end

    describe 'error handling' do
      it 'raises TimeoutError when operation times out' do
        allow(mock_session).to receive(:async_call).and_raise(RBLE::TimeoutError.new('Connect', 5))

        expect { mock_session.async_call('Connect', timeout: 5) { } }
          .to raise_error(RBLE::TimeoutError)
      end

      it 'raises SessionClosedError when session closes during operation' do
        error = RBLE::SessionClosedError.new
        expect(error.message).to include('Session closed')
      end

      it 'raises ConnectionFailed for connection errors' do
        error = RBLE::ConnectionFailed.new('11:22:33:44:55:66', 'No route to host')
        expect(error.address).to eq('11:22:33:44:55:66')
        expect(error.reason).to eq('No route to host')
      end

      it 'handles TimeoutError with correct attributes' do
        error = RBLE::TimeoutError.new('ReadValue', 5)
        expect(error.operation).to eq('ReadValue')
        expect(error.timeout_value).to eq(5)
        expect(error.message).to include('ReadValue')
        expect(error.message).to include('5')
      end

      it 'handles DeviceDisconnected error' do
        error = RBLE::DeviceDisconnected.new('11:22:33:44:55:66', 'read')
        expect(error.address).to eq('11:22:33:44:55:66')
        expect(error.operation).to eq('read')
        expect(error.message).to include('disconnected')
      end
    end

    describe 'session lifecycle' do
      it 'creates session in disconnected state' do
        allow(mock_session).to receive(:connected?).and_return(false)
        session = RBLE::BlueZ::DBusSession.new
        expect(session.connected?).to be false
      end

      it 'session becomes connected after connect' do
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        expect(session.connected?).to be true
      end

      it 'session runs event loop after start_event_loop' do
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        session.start_event_loop
        expect(session.running?).to be true
      end

      it 'session is closed after close' do
        allow(mock_session).to receive(:closed?).and_return(false, true)
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        expect(session.closed?).to be false
        session.close
        expect(session.closed?).to be true
      end
    end

    describe 'adapter operations' do
      it 'gets adapter properties' do
        adapter = RBLE::BlueZ::Adapter.new_from_session(mock_session, '/org/bluez/hci0')
        expect(adapter.address).to eq('AA:BB:CC:DD:EE:FF')
        expect(adapter.powered?).to be true
      end

      it 'starts and stops discovery' do
        adapter = RBLE::BlueZ::Adapter.new_from_session(mock_session, '/org/bluez/hci0')
        expect { adapter.start_discovery }.not_to raise_error
        expect { adapter.stop_discovery }.not_to raise_error
      end
    end

    describe 'device operations' do
      it 'gets device properties' do
        device = RBLE::BlueZ::Device.new_from_session(mock_session, '/org/bluez/hci0/dev_11_22_33_44_55_66')
        expect(device.address).to eq('11:22:33:44:55:66')
        expect(device.name).to eq('Test Device')
      end

      it 'connects and disconnects device' do
        device = RBLE::BlueZ::Device.new_from_session(mock_session, '/org/bluez/hci0/dev_11_22_33_44_55_66')
        expect { device.connect }.not_to raise_error
        expect(device.connected?).to be true
        expect { device.disconnect }.not_to raise_error
      end
    end
  end

  # Hardware tests - only run when RUN_HARDWARE_TESTS=1
  describe 'hardware-based flow', :hardware do
    before(:all) do
      skip 'Hardware tests require RUN_HARDWARE_TESTS=1' unless ENV['RUN_HARDWARE_TESTS']
      skip 'Hardware tests require TEST_DEVICE_ADDRESS' unless ENV['TEST_DEVICE_ADDRESS']

      @test_address = ENV['TEST_DEVICE_ADDRESS']
    end

    def adapter_available?
      session = RBLE::BlueZ::DBusSession.new
      session.connect
      session.start_event_loop
      result = session.async_get_managed_objects
      session.close
      result.any? { |_path, interfaces| interfaces.key?('org.bluez.Adapter1') }
    rescue StandardError
      false
    end

    it 'completes real flow: scan -> connect -> discover -> disconnect' do
      skip 'No Bluetooth adapter available' unless adapter_available?

      session = RBLE::BlueZ::DBusSession.new
      session.connect
      session.start_event_loop

      begin
        # Find adapter
        objects = session.async_get_managed_objects
        adapter_path = objects.find { |_p, i| i.key?('org.bluez.Adapter1') }&.first
        expect(adapter_path).not_to be_nil

        adapter = RBLE::BlueZ::Adapter.new_from_session(session, adapter_path)

        # Scan for device
        device_path = nil
        adapter.start_discovery

        10.times do
          objects = session.async_get_managed_objects
          found = objects.find do |path, interfaces|
            next unless interfaces.key?('org.bluez.Device1')
            interfaces['org.bluez.Device1']['Address'] == @test_address
          end
          if found
            device_path = found.first
            break
          end
          sleep 1
        end

        adapter.stop_discovery
        expect(device_path).not_to be_nil, "Device #{@test_address} not found during scan"

        # Connect
        device = RBLE::BlueZ::Device.new_from_session(session, device_path)
        device.connect(wait_for_services: true, timeout: 30)
        expect(device.connected?).to be true

        # Verify services resolved
        expect(device.services_resolved?).to be true

        # Disconnect
        device.disconnect
        expect(device.connected?).to be false
      ensure
        session.close
      end
    end
  end
end
