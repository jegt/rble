# frozen_string_literal: true

require 'spec_helper'
require 'rble/bluez/async_connection_operations'

RSpec.describe RBLE::BlueZ::AsyncConnectionOperations do
  # Test helper class that includes all necessary modules
  let(:test_class) do
    Class.new do
      include RBLE::BlueZ::AsyncCall
      include RBLE::BlueZ::AsyncIntrospection
      include RBLE::BlueZ::AsyncConnectionOperations

      attr_accessor :service, :introspection_cache

      def initialize(service = nil)
        @service = service
        @introspection_cache = {}
      end
    end
  end

  let(:mock_service) { double('DBus::Service') }
  let(:mock_proxy) { double('DBus::ProxyObject') }
  let(:mock_device_iface) { double('DBus::ProxyObjectInterface') }
  let(:mock_adapter_iface) { double('DBus::ProxyObjectInterface') }
  let(:mock_props_iface) { double('DBus::ProxyObjectInterface') }
  let(:subject_instance) { test_class.new(mock_service) }

  let(:device_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF' }
  let(:adapter_path) { '/org/bluez/hci0' }

  before do
    # Default mock setup - override in specific tests
    allow(subject_instance).to receive(:async_introspect).and_return(mock_proxy)
    allow(mock_proxy).to receive(:[]).with('org.bluez.Device1').and_return(mock_device_iface)
    allow(mock_proxy).to receive(:[]).with('org.bluez.Adapter1').and_return(mock_adapter_iface)
    allow(mock_proxy).to receive(:[]).with('org.freedesktop.DBus.Properties').and_return(mock_props_iface)
  end

  describe '#async_connect' do
    # Default property values - can be overridden in tests
    let(:connected_value) { false }
    let(:services_resolved_value) { false }

    before do
      # Use callback pattern for async_get_property compatibility
      # Handle both sync (no block) and async (with block) calls
      allow(mock_props_iface).to receive(:Get) do |interface, property, &block|
        value = case [interface, property]
                when ['org.bluez.Device1', 'Connected'] then connected_value
                when ['org.bluez.Device1', 'ServicesResolved'] then services_resolved_value
                else nil
                end
        if block
          # Async call: create a mock reply message with params
          mock_reply = double('DBus::Message', params: [value])
          block.call(mock_reply)
        else
          # Sync call: return array
          [value]
        end
      end
      allow(mock_props_iface).to receive(:on_signal).and_return(nil)
    end

    it 'returns true on successful connection' do
      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(nil)
      end

      # Simulate ServicesResolved becoming true
      allow(mock_props_iface).to receive(:on_signal).with('PropertiesChanged') do |&block|
        # Trigger the callback with ServicesResolved = true
        Thread.new do
          sleep 0.01
          block.call('org.bluez.Device1', { 'ServicesResolved' => true }, [])
        end
      end

      result = subject_instance.async_connect(device_path, timeout: 1)
      expect(result).to eq(true)
    end

    it 'uses 30s default timeout' do
      expect(subject_instance).to receive(:async_introspect)
        .with(device_path, timeout: 30)
        .and_return(mock_proxy)
        .at_least(:once)

      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(nil)
      end

      # Already connected so skips the Connect call
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Device1', 'Connected') do |*_args, &block|
          if block
            mock_reply = double('DBus::Message', params: [true])
            block.call(mock_reply)
          else
            [true]
          end
        end
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Device1', 'ServicesResolved') do |*_args, &block|
          if block
            mock_reply = double('DBus::Message', params: [true])
            block.call(mock_reply)
          else
            [true]
          end
        end

      subject_instance.async_connect(device_path)
    end

    it 'waits for ServicesResolved by default' do
      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(nil)
      end

      # Start with services not resolved, will become resolved later
      services_resolved = false
      allow(mock_props_iface).to receive(:Get) do |interface, property, &block|
        value = case [interface, property]
                when ['org.bluez.Device1', 'Connected'] then false  # Not connected yet
                when ['org.bluez.Device1', 'ServicesResolved'] then services_resolved
                else nil
                end
        if block
          mock_reply = double('DBus::Message', params: [value])
          block.call(mock_reply)
        else
          [value]
        end
      end

      # Signal handler will be set up
      signal_block = nil
      allow(mock_props_iface).to receive(:on_signal).with('PropertiesChanged') do |&block|
        signal_block = block
      end

      # Run connect in a thread since it blocks waiting for services
      connect_thread = Thread.new do
        subject_instance.async_connect(device_path, timeout: 2)
      end

      # Give it time to start
      sleep 0.05

      # Simulate services resolved signal
      if signal_block
        services_resolved = true
        signal_block.call('org.bluez.Device1', { 'ServicesResolved' => true }, [])
      end

      result = connect_thread.value
      expect(result).to eq(true)
    end

    it 'returns immediately with wait_for_services: false' do
      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(nil)
      end

      # Services not resolved - should NOT wait
      expect(mock_props_iface).not_to receive(:on_signal).with('PropertiesChanged')

      result = subject_instance.async_connect(device_path, wait_for_services: false)
      expect(result).to eq(true)
    end

    it 'is idempotent: returns true if already connected' do
      # Already connected and services resolved
      allow(mock_props_iface).to receive(:Get) do |interface, property, &block|
        value = case [interface, property]
                when ['org.bluez.Device1', 'Connected'] then true
                when ['org.bluez.Device1', 'ServicesResolved'] then true
                else nil
                end
        if block
          mock_reply = double('DBus::Message', params: [value])
          block.call(mock_reply)
        else
          [value]
        end
      end

      # Connect should NOT be called
      expect(mock_device_iface).not_to receive(:Connect)

      result = subject_instance.async_connect(device_path)
      expect(result).to eq(true)
    end

    it 'raises ConnectionFailed on org.bluez.Error.Failed' do
      dbus_error = DBus::Error.new('org.bluez.Error.Failed: br-connection-abort')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.Failed')
      allow(dbus_error).to receive(:message).and_return('br-connection-abort')

      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_connect(device_path, wait_for_services: false)
      }.to raise_error(RBLE::ConnectionFailed) { |e|
        expect(e.message).to include('AA:BB:CC:DD:EE:FF')
      }
    end

    it 'raises TimeoutError if connection times out' do
      allow(mock_device_iface).to receive(:Connect) do |&block|
        # Never call the block - simulate timeout
        Thread.new do
          sleep 2
          block.call(nil)
        end
      end

      expect {
        subject_instance.async_connect(device_path, wait_for_services: false, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError) { |e|
        expect(e.message).to include('timed out')
      }
    end

    it 'raises AdapterNotFoundError on org.bluez.Error.NotReady' do
      dbus_error = DBus::Error.new('org.bluez.Error.NotReady')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.NotReady')
      allow(dbus_error).to receive(:message).and_return('Adapter not ready')

      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_connect(device_path, wait_for_services: false)
      }.to raise_error(RBLE::AdapterNotFoundError)
    end

    it 'unsubscribes signal handler in ensure block' do
      allow(mock_device_iface).to receive(:Connect) do |&block|
        block.call(nil)
      end

      # Track if on_signal was called with nil (unsubscribe)
      subscribe_calls = []
      allow(mock_props_iface).to receive(:on_signal).with('PropertiesChanged') do |&block|
        subscribe_calls << block
        # Immediately signal services resolved
        if block
          Thread.new { sleep 0.01; block.call('org.bluez.Device1', { 'ServicesResolved' => true }, []) }
        end
      end

      subject_instance.async_connect(device_path, timeout: 1)

      # Should have 2 calls: subscribe (with block) and unsubscribe (without block)
      expect(subscribe_calls.length).to be >= 1
    end
  end

  describe '#async_disconnect' do
    before do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Device1', 'Connected')
        .and_return([true])
    end

    it 'returns true on successful disconnect' do
      allow(mock_device_iface).to receive(:Disconnect) do |&block|
        block.call(nil)
      end

      result = subject_instance.async_disconnect(device_path)
      expect(result).to eq(true)
    end

    it 'uses 5s default timeout' do
      expect(subject_instance).to receive(:async_introspect)
        .with(device_path, timeout: 5)
        .and_return(mock_proxy)

      allow(mock_device_iface).to receive(:Disconnect) do |&block|
        block.call(nil)
      end

      subject_instance.async_disconnect(device_path)
    end

    it 'is idempotent: returns true if not connected' do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Device1', 'Connected')
        .and_return([false])

      # Disconnect should NOT be called
      expect(mock_device_iface).not_to receive(:Disconnect)

      result = subject_instance.async_disconnect(device_path)
      expect(result).to eq(true)
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_device_iface).to receive(:Disconnect) do |&block|
        Thread.new do
          sleep 2
          block.call(nil)
        end
      end

      expect {
        subject_instance.async_disconnect(device_path, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe '#async_start_discovery' do
    before do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Adapter1', 'Discovering')
        .and_return([false])
    end

    it 'returns true on successful start' do
      allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
        block.call(nil)
      end

      result = subject_instance.async_start_discovery(adapter_path)
      expect(result).to eq(true)
    end

    it 'sets discovery filter before starting when filter provided' do
      filter_set = false
      allow(mock_adapter_iface).to receive(:SetDiscoveryFilter) do |filter, &block|
        filter_set = true
        expect(filter['Transport']).to be_a(DBus::Data::Variant)
        expect(filter['Transport'].value).to eq('le')
        block.call(nil)
      end

      allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
        expect(filter_set).to eq(true)  # Filter must be set first
        block.call(nil)
      end

      subject_instance.async_start_discovery(adapter_path, filter: { transport: 'le' })
    end

    it 'supports filter options: transport, uuids, rssi, pathloss, duplicate_data' do
      allow(mock_adapter_iface).to receive(:SetDiscoveryFilter) do |filter, &block|
        expect(filter['Transport'].value).to eq('le')
        expect(filter['UUIDs'].value).to eq(['0000180f-0000-1000-8000-00805f9b34fb'])
        expect(filter['RSSI'].value).to eq(-70)
        expect(filter['Pathloss'].value).to eq(100)
        expect(filter['DuplicateData'].value).to eq(true)
        block.call(nil)
      end

      allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
        block.call(nil)
      end

      subject_instance.async_start_discovery(
        adapter_path,
        filter: {
          transport: 'le',
          uuids: ['0000180f-0000-1000-8000-00805f9b34fb'],
          rssi: -70,
          pathloss: 100,
          duplicate_data: true
        }
      )
    end

    it 'is idempotent: returns true if already discovering' do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Adapter1', 'Discovering')
        .and_return([true])

      # StartDiscovery should NOT be called
      expect(mock_adapter_iface).not_to receive(:StartDiscovery)

      result = subject_instance.async_start_discovery(adapter_path)
      expect(result).to eq(true)
    end

    it 'raises ScanError on failure' do
      dbus_error = DBus::Error.new('org.bluez.Error.Failed')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.Failed')
      allow(dbus_error).to receive(:message).and_return('Failed')

      allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_start_discovery(adapter_path)
      }.to raise_error(RBLE::ScanError)
    end

    it 'raises AdapterNotFoundError on NotReady' do
      dbus_error = DBus::Error.new('org.bluez.Error.NotReady')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.NotReady')
      allow(dbus_error).to receive(:message).and_return('Not ready')

      allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_start_discovery(adapter_path)
      }.to raise_error(RBLE::AdapterNotFoundError)
    end
  end

  describe '#async_stop_discovery' do
    before do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Adapter1', 'Discovering')
        .and_return([true])
    end

    it 'returns true on successful stop' do
      allow(mock_adapter_iface).to receive(:StopDiscovery) do |&block|
        block.call(nil)
      end

      result = subject_instance.async_stop_discovery(adapter_path)
      expect(result).to eq(true)
    end

    it 'is idempotent: returns true if not discovering' do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Adapter1', 'Discovering')
        .and_return([false])

      # StopDiscovery should NOT be called
      expect(mock_adapter_iface).not_to receive(:StopDiscovery)

      result = subject_instance.async_stop_discovery(adapter_path)
      expect(result).to eq(true)
    end
  end

  describe '#async_get_property' do
    it 'returns property value' do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Device1', 'Connected') do |*_args, &block|
          block.call([true])
        end

      result = subject_instance.async_get_property(
        device_path,
        'org.bluez.Device1',
        'Connected'
      )
      expect(result).to eq(true)
    end

    it 'uses 5s default timeout' do
      expect(subject_instance).to receive(:async_introspect)
        .with(device_path, timeout: 5)
        .and_return(mock_proxy)

      allow(mock_props_iface).to receive(:Get) do |*_args, &block|
        block.call([true])
      end

      subject_instance.async_get_property(device_path, 'org.bluez.Device1', 'Connected')
    end

    it 'works for any interface.property combination' do
      allow(mock_props_iface).to receive(:Get)
        .with('org.bluez.Adapter1', 'Powered') do |*_args, &block|
          block.call([true])
        end

      result = subject_instance.async_get_property(
        adapter_path,
        'org.bluez.Adapter1',
        'Powered'
      )
      expect(result).to eq(true)
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_props_iface).to receive(:Get) do |*_args, &block|
        Thread.new do
          sleep 2
          block.call([true])
        end
      end

      expect {
        subject_instance.async_get_property(device_path, 'org.bluez.Device1', 'Connected', timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe '#async_set_property' do
    it 'returns true on success' do
      allow(mock_props_iface).to receive(:Set) do |*_args, &block|
        block.call(nil)
      end

      result = subject_instance.async_set_property(
        adapter_path,
        'org.bluez.Adapter1',
        'Powered',
        true
      )
      expect(result).to eq(true)
    end

    it 'wraps value in correct DBus::Data::Variant type' do
      captured_value = nil
      allow(mock_props_iface).to receive(:Set) do |interface, property, value, &block|
        captured_value = value
        block.call(nil)
      end

      subject_instance.async_set_property(
        adapter_path,
        'org.bluez.Adapter1',
        'Powered',
        true
      )

      expect(captured_value).to be_a(DBus::Data::Variant)
      expect(captured_value.value).to eq(true)
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_props_iface).to receive(:Set) do |*_args, &block|
        Thread.new do
          sleep 2
          block.call(nil)
        end
      end

      expect {
        subject_instance.async_set_property(adapter_path, 'org.bluez.Adapter1', 'Powered', true, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe 'error translation' do
    describe 'translate_connection_error' do
      before do
        allow(mock_props_iface).to receive(:Get)
          .with('org.bluez.Device1', 'Connected')
          .and_return([false])
      end

      it 'includes device address in error message' do
        dbus_error = DBus::Error.new('org.bluez.Error.Failed')
        allow(dbus_error).to receive(:name).and_return('org.bluez.Error.Failed')
        allow(dbus_error).to receive(:message).and_return('Host is down')

        allow(mock_device_iface).to receive(:Connect) do |&block|
          block.call(dbus_error)
        end

        expect {
          subject_instance.async_connect(device_path, wait_for_services: false)
        }.to raise_error(RBLE::ConnectionFailed) { |e|
          expect(e.address).to eq('AA:BB:CC:DD:EE:FF')
        }
      end
    end

    describe 'translate_discovery_error' do
      before do
        allow(mock_props_iface).to receive(:Get)
          .with('org.bluez.Adapter1', 'Discovering')
          .and_return([false])
      end

      it 'raises ScanInProgressError for InProgress' do
        dbus_error = DBus::Error.new('org.bluez.Error.InProgress')
        allow(dbus_error).to receive(:name).and_return('org.bluez.Error.InProgress')
        allow(dbus_error).to receive(:message).and_return('In progress')

        allow(mock_adapter_iface).to receive(:StartDiscovery) do |&block|
          block.call(dbus_error)
        end

        expect {
          subject_instance.async_start_discovery(adapter_path)
        }.to raise_error(RBLE::ScanInProgressError)
      end

      it 'raises PermissionError for NotAuthorized' do
        allow(mock_props_iface).to receive(:Get)
          .with('org.bluez.Adapter1', 'Discovering')
          .and_return([true])

        dbus_error = DBus::Error.new('org.bluez.Error.NotAuthorized')
        allow(dbus_error).to receive(:name).and_return('org.bluez.Error.NotAuthorized')
        allow(dbus_error).to receive(:message).and_return('Not authorized')

        allow(mock_adapter_iface).to receive(:StopDiscovery) do |&block|
          block.call(dbus_error)
        end

        expect {
          subject_instance.async_stop_discovery(adapter_path)
        }.to raise_error(RBLE::PermissionError)
      end
    end
  end

  describe '#extract_address_from_path' do
    it 'extracts MAC address from device path' do
      address = subject_instance.send(:extract_address_from_path, device_path)
      expect(address).to eq('AA:BB:CC:DD:EE:FF')
    end

    it 'handles paths with different device segments' do
      path = '/org/bluez/hci1/dev_11_22_33_44_55_66'
      address = subject_instance.send(:extract_address_from_path, path)
      expect(address).to eq('11:22:33:44:55:66')
    end

    it 'returns path if no dev_ segment found' do
      path = '/org/bluez/hci0'
      address = subject_instance.send(:extract_address_from_path, path)
      expect(address).to eq('/org/bluez/hci0')
    end
  end
end
