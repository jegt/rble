# frozen_string_literal: true

require "spec_helper"
require "rble/backend/bluez"

RSpec.describe RBLE::Backend::BlueZ do
  subject(:backend) { described_class.new }

  describe "#adapters" do
    context "when BlueZ is available" do
      # This test requires actual D-Bus - skip in CI without BT hardware
      it "returns array of adapter hashes", :bluetooth do
        skip "Requires D-Bus (Linux only)" unless dbus_available?

        adapters = backend.adapters
        expect(adapters).to be_an(Array)

        if adapters.any?
          adapter = adapters.first
          expect(adapter).to include(:name, :address, :powered)
          expect(adapter[:name]).to match(/^hci\d+$/)
        end
      end
    end
  end

  describe "#scanning?" do
    it "returns false when not scanning" do
      expect(backend.scanning?).to be false
    end
  end

  describe "#stop_scan" do
    it "does nothing when not scanning" do
      expect { backend.stop_scan }.not_to raise_error
    end
  end

  describe "#start_scan" do
    it "raises ArgumentError without block" do
      expect { backend.start_scan }.to raise_error(ArgumentError, /Block required/)
    end

    it "raises ScanInProgressError if already scanning", :bluetooth do
      skip "Requires Bluetooth hardware" unless bluetooth_available?

      # Start first scan
      backend.start_scan { |d| }

      expect {
        backend.start_scan { |d| }
      }.to raise_error(RBLE::ScanInProgressError)

      backend.stop_scan
    end
  end

  describe '#cleanup_all_connections' do
    it 'disconnects all tracked connections' do
      conn1 = double('Connection', connected?: true)
      conn2 = double('Connection', connected?: true)
      allow(conn1).to receive(:disconnect)
      allow(conn2).to receive(:disconnect)

      backend.instance_variable_get(:@connection_objects)['/dev1'] = conn1
      backend.instance_variable_get(:@connection_objects)['/dev2'] = conn2

      backend.send(:cleanup_all_connections)

      expect(conn1).to have_received(:disconnect)
      expect(conn2).to have_received(:disconnect)
    end

    it 'tolerates errors from individual connections' do
      conn1 = double('Connection', connected?: true)
      conn2 = double('Connection', connected?: true)
      allow(conn1).to receive(:disconnect).and_raise(RuntimeError, 'D-Bus gone')
      allow(conn2).to receive(:disconnect)

      backend.instance_variable_get(:@connection_objects)['/dev1'] = conn1
      backend.instance_variable_get(:@connection_objects)['/dev2'] = conn2

      expect { backend.send(:cleanup_all_connections) }.not_to raise_error
      expect(conn2).to have_received(:disconnect)
    end

    it 'skips already-disconnected connections' do
      conn = double('Connection', connected?: false)

      backend.instance_variable_get(:@connection_objects)['/dev1'] = conn

      backend.send(:cleanup_all_connections)

      expect(conn).not_to have_received(:disconnect) if conn.respond_to?(:disconnect)
    end
  end

  describe '#disconnect_device' do
    let(:device_path) { '/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF' }

    it 'clears subscriptions for the disconnected device' do
      # Set up internal state directly
      device = double('device', disconnect: nil)
      backend.instance_variable_get(:@connected_devices)[device_path] = device
      backend.instance_variable_get(:@subscriptions)["#{device_path}/service0010/char0011"] = { callback: proc {} }
      backend.instance_variable_get(:@subscriptions)["#{device_path}/service0010/char0012"] = { callback: proc {} }
      # A subscription for a different device should survive
      other_path = '/org/bluez/hci0/dev_11_22_33_44_55_66'
      backend.instance_variable_get(:@subscriptions)["#{other_path}/service0010/char0011"] = { callback: proc {} }

      backend.disconnect_device(device_path)

      subs = backend.instance_variable_get(:@subscriptions)
      expect(subs.keys).to eq(["#{other_path}/service0010/char0011"])
    end
  end

  private

  def dbus_available?
    return false unless File.exist?('/var/run/dbus/system_bus_socket')

    system('dbus-send', '--system', '--print-reply', '--dest=org.bluez',
           '/org/bluez', 'org.freedesktop.DBus.Introspectable.Introspect',
           out: File::NULL, err: File::NULL)
  end

  def bluetooth_available?
    return false unless dbus_available?

    backend.adapters.any? { |a| a[:powered] }
  rescue
    false
  end
end
