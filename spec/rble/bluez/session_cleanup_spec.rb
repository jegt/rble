# frozen_string_literal: true

require "spec_helper"
require "rble/bluez"

RSpec.describe RBLE::BlueZ::DBusSession, "signal handler cleanup" do
  let(:session) { described_class.new }
  let(:mock_bus) { double("DBus::SystemBus") }
  let(:mock_service) { double("DBus::Service") }
  let(:mock_connection) { double("DBusConnection") }
  let(:mock_event_loop) { double("EventLoop") }
  let(:mock_proxy_object) { double("DBus::ProxyObject") }
  let(:mock_proxy_iface) { double("DBus::ProxyObjectInterface") }

  before do
    allow(RBLE::BlueZ::DBusConnection).to receive(:new).and_return(mock_connection)
    allow(RBLE::BlueZ::EventLoop).to receive(:new).and_return(mock_event_loop)
    allow(mock_connection).to receive(:connected?).and_return(true)
    allow(mock_connection).to receive(:connect)
    allow(mock_connection).to receive(:disconnect)
    allow(mock_connection).to receive(:bus).and_return(mock_bus)
    allow(mock_connection).to receive(:service).and_return(mock_service)
    allow(mock_connection).to receive(:root_object).and_return(mock_proxy_object)
    allow(mock_proxy_object).to receive(:[]).with(RBLE::BlueZ::OBJECT_MANAGER_INTERFACE).and_return(mock_proxy_iface)
    allow(mock_proxy_iface).to receive(:on_signal)
    allow(mock_event_loop).to receive(:running?).and_return(true)
    allow(mock_event_loop).to receive(:start)
    allow(mock_event_loop).to receive(:stop)
  end

  describe "#register_signal_handler" do
    before do
      session.connect
      session.start_event_loop
    end

    it "registers handler with the interface" do
      test_iface = double("DBus::ProxyObjectInterface")
      expect(test_iface).to receive(:on_signal).with("TestSignal")

      session.register_signal_handler(test_iface, "TestSignal") { |_| }
    end

    it "tracks handlers for later cleanup" do
      test_iface = double("DBus::ProxyObjectInterface")
      allow(test_iface).to receive(:on_signal).with("TestSignal")
      allow(test_iface).to receive(:on_signal).with("AnotherSignal")

      session.register_signal_handler(test_iface, "TestSignal") { |_| }
      session.register_signal_handler(test_iface, "AnotherSignal") { |_| }

      # Verify handlers are tracked by checking they get unregistered on close
      # (unregister is called with no block)
      expect(test_iface).to receive(:on_signal).with("TestSignal").once.ordered
      expect(test_iface).to receive(:on_signal).with("AnotherSignal").once.ordered

      session.close
    end
  end

  describe "#close signal handler cleanup" do
    before do
      session.connect
      session.start_event_loop
    end

    it "unregisters all tracked signal handlers" do
      handler1_iface = instance_double(DBus::ProxyObjectInterface)
      handler2_iface = instance_double(DBus::ProxyObjectInterface)

      allow(handler1_iface).to receive(:on_signal).with("Signal1")
      allow(handler2_iface).to receive(:on_signal).with("Signal2")

      session.register_signal_handler(handler1_iface, "Signal1") { }
      session.register_signal_handler(handler2_iface, "Signal2") { }

      expect(handler1_iface).to receive(:on_signal).with("Signal1").once
      expect(handler2_iface).to receive(:on_signal).with("Signal2").once

      session.close
    end

    it "stops event loop BEFORE unregistering handlers" do
      handler_iface = instance_double(DBus::ProxyObjectInterface)
      allow(handler_iface).to receive(:on_signal)

      session.register_signal_handler(handler_iface, "TestSignal") { }

      call_order = []
      allow(mock_event_loop).to receive(:stop) { call_order << :stop_loop }
      allow(handler_iface).to receive(:on_signal).with("TestSignal") { call_order << :unregister }

      session.close

      expect(call_order).to eq([:stop_loop, :unregister])
    end

    it "clears handlers after unregistering" do
      handler_iface = double("DBus::ProxyObjectInterface")
      # First call is registration, second is unregistration
      call_count = 0
      allow(handler_iface).to receive(:on_signal) do |signal_name, &block|
        call_count += 1
      end

      session.register_signal_handler(handler_iface, "TestSignal") { |_| }
      expect(call_count).to eq(1)

      # Close unregisters
      session.close
      expect(call_count).to eq(2)

      # Second close should not try to unregister again (handlers cleared)
      # since close is idempotent
      session.close
      expect(call_count).to eq(2)
    end

    it "ignores errors during signal cleanup" do
      handler_iface = double("DBus::ProxyObjectInterface")
      # Allow registration to succeed
      allow(handler_iface).to receive(:on_signal).with("BadSignal") do |_, &block|
        raise StandardError, "Cleanup failed" if block.nil?  # Only raise during unregister (no block)
      end

      session.register_signal_handler(handler_iface, "BadSignal") { |_| }

      # Should not raise, just log and continue
      expect { session.close }.not_to raise_error
    end
  end

  describe "#close idempotency" do
    before do
      session.connect
      session.start_event_loop
    end

    it "is safe to call multiple times" do
      expect { session.close }.not_to raise_error
      expect { session.close }.not_to raise_error
      expect { session.close }.not_to raise_error
    end

    it "only stops event loop once" do
      expect(mock_event_loop).to receive(:stop).once

      session.close
      session.close
    end

    it "only disconnects once" do
      expect(mock_connection).to receive(:disconnect).once

      session.close
      session.close
    end
  end

  describe "#closed?" do
    it "returns false before close" do
      session.connect
      expect(session.closed?).to be false
    end

    it "returns true after close" do
      session.connect
      session.close
      expect(session.closed?).to be true
    end

    it "returns true even without connecting first" do
      session.close
      expect(session.closed?).to be true
    end
  end

  describe "cache invalidation handler" do
    before do
      session.connect
    end

    it "registers InterfacesRemoved handler on event loop start" do
      expect(mock_proxy_iface).to receive(:on_signal).with("InterfacesRemoved")

      session.start_event_loop
    end
  end
end
