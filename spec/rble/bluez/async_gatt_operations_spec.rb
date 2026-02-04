# frozen_string_literal: true

require 'spec_helper'
require 'rble/bluez/async_gatt_operations'
require 'rble/bluez/async_connection_operations'

RSpec.describe RBLE::BlueZ::AsyncGattOperations do
  # Test helper class that includes all necessary modules
  let(:test_class) do
    Class.new do
      include RBLE::BlueZ::AsyncCall
      include RBLE::BlueZ::AsyncIntrospection
      include RBLE::BlueZ::AsyncConnectionOperations
      include RBLE::BlueZ::AsyncGattOperations

      attr_accessor :service, :introspection_cache

      def initialize(service = nil)
        @service = service
        @introspection_cache = {}
      end
    end
  end

  let(:mock_service) { double('DBus::Service') }
  let(:mock_proxy) { double('DBus::ProxyObject') }
  let(:mock_char_iface) { double('DBus::ProxyObjectInterface') }
  let(:mock_props_iface) { double('DBus::ProxyObjectInterface') }
  let(:subject_instance) { test_class.new(mock_service) }

  let(:char_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF/service0010/char0011' }
  let(:test_uuid) { '00002a00-0000-1000-8000-00805f9b34fb' }

  # Helper to create mock DBus::Message with params
  def mock_dbus_reply(*params)
    double('DBus::Message', params: params)
  end

  before do
    # Default mock setup - override in specific tests
    allow(subject_instance).to receive(:async_introspect).and_return(mock_proxy)
    allow(mock_proxy).to receive(:[]).with('org.bluez.GattCharacteristic1').and_return(mock_char_iface)
    allow(mock_proxy).to receive(:[]).with('org.freedesktop.DBus.Properties').and_return(mock_props_iface)
  end

  describe '#async_read_value' do
    it 'returns binary string on success' do
      # Simulate successful ReadValue - D-Bus returns array of bytes
      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(mock_dbus_reply([72, 101, 108, 108, 111])) # "Hello" in bytes
      end

      result = subject_instance.async_read_value(char_path, timeout: 1)

      expect(result).to eq('Hello')
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'uses async_introspect to get cached proxy (deadline-based)' do
      captured_timeouts = []
      allow(subject_instance).to receive(:async_introspect).and_wrap_original do |_original, *args, **kwargs|
        captured_timeouts << kwargs[:timeout]
        mock_proxy
      end
      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(mock_dbus_reply([65])) # "A"
      end

      subject_instance.async_read_value(char_path)

      # First call should get approximately 5s (default timeout)
      expect(captured_timeouts.first).to be_within(0.5).of(5)
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        # Simulate timeout by not calling the block immediately
        # The async_call implementation will timeout
        Thread.new do
          sleep 2
          block.call(mock_dbus_reply([65]))
        end
      end

      expect {
        subject_instance.async_read_value(char_path, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError) { |e|
        expect(e.message).to include('timed out')
      }
    end

    it 'raises ReadError with UUID on D-Bus error' do
      dbus_error = DBus::Error.new('org.bluez.Error.Failed: Read failed')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.Failed')
      allow(dbus_error).to receive(:message).and_return('Read failed')

      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_read_value(char_path)
      }.to raise_error(RBLE::GATTError) { |e|
        expect(e.message).to include('char0011')
      }
    end

    it 'raises ConnectionLostError for org.bluez.Error.NotConnected' do
      dbus_error = DBus::Error.new('org.bluez.Error.NotConnected: Not connected')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.NotConnected')
      allow(dbus_error).to receive(:message).and_return('Not connected')

      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_read_value(char_path)
      }.to raise_error(RBLE::ConnectionLostError) { |e|
        expect(e.message).to include('char0011')
      }
    end
  end

  describe '#async_write_value' do
    let(:test_bytes) { [0x01, 0x02, 0x03] }

    it 'calls WriteValue with type: request by default' do
      captured_options = nil
      allow(mock_char_iface).to receive(:WriteValue) do |bytes, options, &block|
        captured_options = options
        block.call(mock_dbus_reply(nil))
      end

      subject_instance.async_write_value(char_path, test_bytes)

      expect(captured_options['type']).to be_a(DBus::Data::Variant)
      expect(captured_options['type'].value).to eq('request')
    end

    it 'uses type: command when response: false' do
      captured_options = nil
      allow(mock_char_iface).to receive(:WriteValue) do |bytes, options, &block|
        captured_options = options
        block.call(mock_dbus_reply(nil))
      end

      subject_instance.async_write_value(char_path, test_bytes, response: false)

      expect(captured_options['type'].value).to eq('command')
    end

    it 'uses 1s timeout for write-without-response (deadline-based)' do
      captured_timeouts = []
      allow(subject_instance).to receive(:async_introspect).and_wrap_original do |_original, *args, **kwargs|
        captured_timeouts << kwargs[:timeout]
        mock_proxy
      end

      allow(mock_char_iface).to receive(:WriteValue) do |_bytes, _options, &block|
        block.call(mock_dbus_reply(nil))
      end

      subject_instance.async_write_value(char_path, test_bytes, response: false)

      # First call should get approximately 1s (write-without-response timeout)
      expect(captured_timeouts.first).to be_within(0.1).of(1)
    end

    it 'raises WriteError with UUID on D-Bus error' do
      dbus_error = DBus::Error.new('org.bluez.Error.InvalidValueLength')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.InvalidValueLength')
      allow(dbus_error).to receive(:message).and_return('Invalid value length')

      allow(mock_char_iface).to receive(:WriteValue) do |_bytes, _options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_write_value(char_path, test_bytes)
      }.to raise_error(RBLE::WriteError) { |e|
        expect(e.message).to include('char0011')
      }
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_char_iface).to receive(:WriteValue) do |_bytes, _options, &block|
        Thread.new do
          sleep 2
          block.call(mock_dbus_reply(nil))
        end
      end

      expect {
        subject_instance.async_write_value(char_path, test_bytes, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe '#async_start_notify' do
    before do
      # Default: has notify flag and not currently notifying
      # Use allow_any_instance_of to match the async_get_property calls
      allow(subject_instance).to receive(:async_get_property)
        .with(char_path, 'org.bluez.GattCharacteristic1', 'Flags', timeout: anything)
        .and_return(['notify', 'read'])
      allow(subject_instance).to receive(:async_get_property)
        .with(char_path, 'org.bluez.GattCharacteristic1', 'Notifying', timeout: anything)
        .and_return(false)
    end

    it 'returns true if already notifying (idempotent)' do
      allow(subject_instance).to receive(:async_get_property)
        .with(char_path, 'org.bluez.GattCharacteristic1', 'Notifying', timeout: anything)
        .and_return(true)

      # StartNotify should NOT be called
      expect(mock_char_iface).not_to receive(:StartNotify)

      result = subject_instance.async_start_notify(char_path)
      expect(result).to eq(true)
    end

    it 'calls StartNotify when not notifying' do
      expect(mock_char_iface).to receive(:StartNotify) do |&block|
        block.call(mock_dbus_reply(nil))
      end

      result = subject_instance.async_start_notify(char_path)
      expect(result).to eq(true)
    end

    it 'raises NotifyNotSupported if no notify/indicate flag' do
      allow(subject_instance).to receive(:async_get_property)
        .with(char_path, 'org.bluez.GattCharacteristic1', 'Flags', timeout: anything)
        .and_return(['read', 'write'])

      expect {
        subject_instance.async_start_notify(char_path)
      }.to raise_error(RBLE::NotifyNotSupported) { |e|
        expect(e.uuid).to include('char0011')
        expect(e.flags).to eq(['read', 'write'])
      }
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_char_iface).to receive(:StartNotify) do |&block|
        Thread.new do
          sleep 2
          block.call(mock_dbus_reply(nil))
        end
      end

      expect {
        subject_instance.async_start_notify(char_path, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe '#async_stop_notify' do
    it 'calls StopNotify' do
      expect(mock_char_iface).to receive(:StopNotify) do |&block|
        block.call(mock_dbus_reply(nil))
      end

      result = subject_instance.async_stop_notify(char_path)
      expect(result).to eq(true)
    end

    it 'raises TimeoutError on timeout' do
      allow(mock_char_iface).to receive(:StopNotify) do |&block|
        Thread.new do
          sleep 2
          block.call(mock_dbus_reply(nil))
        end
      end

      expect {
        subject_instance.async_stop_notify(char_path, timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError)
    end
  end

  describe '#translate_gatt_error (via operations)' do
    it 'includes UUID for all error types' do
      dbus_error = DBus::Error.new('org.bluez.Error.NotSupported')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.NotSupported')
      allow(dbus_error).to receive(:message).and_return('Not supported')

      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_read_value(char_path)
      }.to raise_error(RBLE::NotSupportedError) { |e|
        expect(e.message).to include('char0011')
      }
    end

    it 'handles org.bluez.Error.InProgress' do
      dbus_error = DBus::Error.new('org.bluez.Error.InProgress')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.InProgress')
      allow(dbus_error).to receive(:message).and_return('In progress')

      allow(mock_char_iface).to receive(:ReadValue) do |_options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_read_value(char_path)
      }.to raise_error(RBLE::OperationInProgressError) { |e|
        expect(e.message).to include('char0011')
      }
    end

    it 'handles org.bluez.Error.InvalidValueLength' do
      dbus_error = DBus::Error.new('org.bluez.Error.InvalidValueLength')
      allow(dbus_error).to receive(:name).and_return('org.bluez.Error.InvalidValueLength')
      allow(dbus_error).to receive(:message).and_return('Invalid value length')

      allow(mock_char_iface).to receive(:WriteValue) do |_bytes, _options, &block|
        block.call(dbus_error)
      end

      expect {
        subject_instance.async_write_value(char_path, [0x01])
      }.to raise_error(RBLE::WriteError) { |e|
        expect(e.message).to include('char0011')
      }
    end
  end

  describe '#extract_uuid_from_path' do
    it 'returns characteristic segment' do
      # Access private method for testing
      uuid = subject_instance.send(:extract_uuid_from_path, char_path)
      expect(uuid).to eq('char0011')
    end

    it 'handles paths with different segment counts' do
      short_path = '/org/bluez/char0099'
      uuid = subject_instance.send(:extract_uuid_from_path, short_path)
      expect(uuid).to eq('char0099')
    end
  end
end
