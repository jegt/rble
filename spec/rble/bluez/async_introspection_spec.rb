# frozen_string_literal: true

require "spec_helper"
require "rble/bluez/async_introspection"
require "stringio"
require "logger"

RSpec.describe RBLE::BlueZ::AsyncIntrospection do
  # Create test class that includes both AsyncCall and AsyncIntrospection
  let(:test_class) do
    Class.new do
      include RBLE::BlueZ::AsyncCall
      include RBLE::BlueZ::AsyncIntrospection

      attr_accessor :service

      def initialize(service)
        @service = service
      end
    end
  end

  let(:mock_service) { double("DBus::Service") }
  let(:instance) { test_class.new(mock_service) }

  # Mock D-Bus objects - use plain double because D-Bus methods are dynamic
  let(:mock_proxy) { double("DBus::ProxyObject") }
  let(:mock_introspectable) { double("DBus::ProxyObjectInterface") }
  let(:mock_object_manager) { double("DBus::ProxyObjectInterface") }

  let(:introspection_xml) do
    <<~XML
      <!DOCTYPE node PUBLIC "-//freedesktop//DTD D-BUS Object Introspection 1.0//EN"
      "http://www.freedesktop.org/standards/dbus/1.0/introspect.dtd">
      <node>
        <interface name="org.bluez.Device1">
          <method name="Connect"/>
          <method name="Disconnect"/>
        </interface>
      </node>
    XML
  end

  before do
    # Suppress logging by default
    allow(RBLE).to receive(:logger).and_return(nil)
  end

  describe "#async_introspect" do
    let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }

    context "cache miss (first call)" do
      before do
        allow(mock_service).to receive(:object).with(device_path).and_return(mock_proxy)
        allow(mock_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(mock_introspectable)
      end

      it "calls D-Bus Introspect method asynchronously" do
        expect(mock_introspectable).to receive(:Introspect) do |&callback|
          # Simulate async callback with introspection XML
          callback.call(introspection_xml)
        end

        allow(DBus::ProxyObjectFactory).to receive(:introspect_into).with(mock_proxy, introspection_xml)

        result = instance.async_introspect(device_path, timeout: 1)
        expect(result).to eq(mock_proxy)
      end

      it "parses introspection XML into ProxyObject" do
        allow(mock_introspectable).to receive(:Introspect) do |&callback|
          callback.call(introspection_xml)
        end

        expect(DBus::ProxyObjectFactory).to receive(:introspect_into).with(mock_proxy, introspection_xml)

        instance.async_introspect(device_path, timeout: 1)
      end

      it "caches the introspected ProxyObject" do
        allow(mock_introspectable).to receive(:Introspect) do |&callback|
          callback.call(introspection_xml)
        end
        allow(DBus::ProxyObjectFactory).to receive(:introspect_into).with(mock_proxy, introspection_xml)

        # First call
        instance.async_introspect(device_path, timeout: 1)

        # Verify cache entry exists
        expect(instance.instance_variable_get(:@introspection_cache)).to have_key(device_path)
        expect(instance.instance_variable_get(:@introspection_cache)[device_path]).to eq(mock_proxy)
      end
    end

    context "cache hit (second call)" do
      it "returns cached result without D-Bus call" do
        # Pre-populate cache
        instance.instance_variable_set(:@introspection_cache, { device_path => mock_proxy })

        # Should NOT call D-Bus
        expect(mock_service).not_to receive(:object)

        result = instance.async_introspect(device_path, timeout: 1)
        expect(result).to eq(mock_proxy)
      end
    end

    context "timeout" do
      before do
        allow(mock_service).to receive(:object).with(device_path).and_return(mock_proxy)
        allow(mock_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(mock_introspectable)
      end

      it "raises TimeoutError when timeout exceeded" do
        allow(mock_introspectable).to receive(:Introspect) do |&_callback|
          # Don't call callback - simulate timeout
          sleep 0.2
        end

        expect {
          instance.async_introspect(device_path, timeout: 0.1)
        }.to raise_error(RBLE::TimeoutError) do |error|
          expect(error.message).to include("Introspect")
          expect(error.message).to include("timed out")
        end
      end
    end

    context "D-Bus error" do
      before do
        allow(mock_service).to receive(:object).with(device_path).and_return(mock_proxy)
        allow(mock_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(mock_introspectable)
      end

      it "propagates DBus::Error from D-Bus" do
        dbus_error = DBus::Error.new("org.freedesktop.DBus.Error.UnknownObject: No such object")

        allow(mock_introspectable).to receive(:Introspect) do |&callback|
          callback.call(dbus_error)
        end

        expect {
          instance.async_introspect(device_path, timeout: 1)
        }.to raise_error(DBus::Error, /UnknownObject/)
      end
    end

    context "default timeout" do
      it "uses 5 second default timeout" do
        # Pre-populate cache to avoid actual D-Bus call
        instance.instance_variable_set(:@introspection_cache, { device_path => mock_proxy })

        # Method should accept call without timeout parameter
        expect { instance.async_introspect(device_path) }.not_to raise_error
      end
    end
  end

  describe "#async_get_managed_objects" do
    let(:root_path) { "/" }
    let(:mock_root_proxy) { double("DBus::ProxyObject") }

    let(:managed_objects_result) do
      {
        "/org/bluez/hci0" => {
          "org.bluez.Adapter1" => { "Address" => "AA:BB:CC:DD:EE:FF" }
        },
        "/org/bluez/hci0/dev_11_22_33_44_55_66" => {
          "org.bluez.Device1" => { "Address" => "11:22:33:44:55:66" }
        }
      }
    end

    before do
      allow(mock_service).to receive(:object).with(root_path).and_return(mock_root_proxy)
      allow(mock_root_proxy).to receive(:[]).with("org.freedesktop.DBus.ObjectManager").and_return(mock_object_manager)
    end

    it "calls ObjectManager.GetManagedObjects asynchronously" do
      expect(mock_object_manager).to receive(:GetManagedObjects) do |&callback|
        callback.call(managed_objects_result)
      end

      result = instance.async_get_managed_objects(timeout: 1)
      expect(result).to eq(managed_objects_result)
    end

    it "returns hash of path => interfaces" do
      allow(mock_object_manager).to receive(:GetManagedObjects) do |&callback|
        callback.call(managed_objects_result)
      end

      result = instance.async_get_managed_objects(timeout: 1)

      expect(result).to be_a(Hash)
      expect(result.keys).to include("/org/bluez/hci0")
      expect(result["/org/bluez/hci0"]["org.bluez.Adapter1"]["Address"]).to eq("AA:BB:CC:DD:EE:FF")
    end

    it "uses longer default timeout (10 seconds)" do
      allow(mock_object_manager).to receive(:GetManagedObjects) do |&callback|
        callback.call(managed_objects_result)
      end

      # Method should accept call without timeout parameter (uses 10s default)
      expect { instance.async_get_managed_objects }.not_to raise_error
    end

    it "raises TimeoutError when timeout exceeded" do
      allow(mock_object_manager).to receive(:GetManagedObjects) do |&_callback|
        # Don't call callback - simulate timeout
        sleep 0.2
      end

      expect {
        instance.async_get_managed_objects(timeout: 0.1)
      }.to raise_error(RBLE::TimeoutError) do |error|
        expect(error.message).to include("GetManagedObjects")
        expect(error.message).to include("timed out")
      end
    end

    it "propagates DBus::Error from D-Bus" do
      dbus_error = DBus::Error.new("org.freedesktop.DBus.Error.Failed: Internal error")

      allow(mock_object_manager).to receive(:GetManagedObjects) do |&callback|
        callback.call(dbus_error)
      end

      expect {
        instance.async_get_managed_objects(timeout: 1)
      }.to raise_error(DBus::Error, /Internal error/)
    end
  end

  describe "#refresh_introspection" do
    let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }
    let(:old_proxy) { double("DBus::ProxyObject") }
    let(:new_proxy) { double("DBus::ProxyObject") }
    let(:new_introspectable) { double("DBus::ProxyObjectInterface") }

    before do
      # Pre-populate cache with old proxy
      instance.instance_variable_set(:@introspection_cache, { device_path => old_proxy })
    end

    it "clears cache entry before re-introspecting" do
      allow(mock_service).to receive(:object).with(device_path).and_return(new_proxy)
      allow(new_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(new_introspectable)
      allow(new_introspectable).to receive(:Introspect) do |&callback|
        callback.call(introspection_xml)
      end
      allow(DBus::ProxyObjectFactory).to receive(:introspect_into)

      # Should actually call D-Bus even though path was in cache
      expect(mock_service).to receive(:object).with(device_path)

      instance.refresh_introspection(device_path, timeout: 1)
    end

    it "returns fresh ProxyObject" do
      allow(mock_service).to receive(:object).with(device_path).and_return(new_proxy)
      allow(new_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(new_introspectable)
      allow(new_introspectable).to receive(:Introspect) do |&callback|
        callback.call(introspection_xml)
      end
      allow(DBus::ProxyObjectFactory).to receive(:introspect_into)

      result = instance.refresh_introspection(device_path, timeout: 1)
      expect(result).to eq(new_proxy)
    end

    it "updates cache with new result" do
      allow(mock_service).to receive(:object).with(device_path).and_return(new_proxy)
      allow(new_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(new_introspectable)
      allow(new_introspectable).to receive(:Introspect) do |&callback|
        callback.call(introspection_xml)
      end
      allow(DBus::ProxyObjectFactory).to receive(:introspect_into)

      instance.refresh_introspection(device_path, timeout: 1)

      cache = instance.instance_variable_get(:@introspection_cache)
      expect(cache[device_path]).to eq(new_proxy)
    end
  end

  describe "#clear_introspection" do
    let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }
    let(:other_path) { "/org/bluez/hci0/dev_11_22_33_44_55_66" }

    before do
      instance.instance_variable_set(:@introspection_cache, {
        device_path => mock_proxy,
        other_path => double("DBus::ProxyObject")
      })
    end

    it "removes path from cache" do
      instance.clear_introspection(device_path)

      cache = instance.instance_variable_get(:@introspection_cache)
      expect(cache).not_to have_key(device_path)
    end

    it "does not affect other cache entries" do
      instance.clear_introspection(device_path)

      cache = instance.instance_variable_get(:@introspection_cache)
      expect(cache).to have_key(other_path)
    end

    it "handles clearing non-existent path gracefully" do
      expect {
        instance.clear_introspection("/nonexistent/path")
      }.not_to raise_error
    end
  end

  describe "logging" do
    let(:log_output) { StringIO.new }
    let(:logger) { Logger.new(log_output) }
    let(:device_path) { "/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF" }

    before do
      # Remove the global nil stub and set up actual logger
      RSpec::Mocks.space.proxy_for(RBLE).reset
      allow(RBLE).to receive(:logger).and_return(logger)
      allow(mock_service).to receive(:object).with(device_path).and_return(mock_proxy)
      allow(mock_proxy).to receive(:[]).with("org.freedesktop.DBus.Introspectable").and_return(mock_introspectable)
      allow(mock_introspectable).to receive(:Introspect) do |&callback|
        callback.call(introspection_xml)
      end
      allow(DBus::ProxyObjectFactory).to receive(:introspect_into)
    end

    it "logs with request ID for correlation" do
      instance.async_introspect(device_path, timeout: 1)

      log_content = log_output.string
      expect(log_content).to match(/[a-f0-9]{8}/)
    end

    it "logs completion with timing" do
      instance.async_introspect(device_path, timeout: 1)

      log_content = log_output.string
      expect(log_content).to include("completed in")
      expect(log_content).to match(/\d+\.\d+s/)
    end
  end
end
