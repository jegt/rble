# frozen_string_literal: true

require "spec_helper"
require "rble/bluez"

RSpec.describe RBLE::BlueZ::DBusSession, "shutdown with pending operations" do
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

    # Suppress logging by default
    allow(RBLE).to receive(:logger).and_return(nil)
  end

  describe "pending queue notification" do
    before do
      session.connect
      session.start_event_loop
    end

    it "pushes :session_closed marker to pending queues on close" do
      # Access the internal pending_queues
      pending_queues = session.instance_variable_get(:@pending_queues)

      # Simulate a pending operation by adding a queue
      test_queue = Thread::Queue.new
      pending_queues << test_queue

      session.close

      # The queue should receive the session_closed marker
      result = test_queue.pop(true) rescue nil
      expect(result).to eq([:session_closed, nil])
    end

    it "notifies multiple pending queues" do
      pending_queues = session.instance_variable_get(:@pending_queues)

      queue1 = Thread::Queue.new
      queue2 = Thread::Queue.new
      queue3 = Thread::Queue.new
      pending_queues << queue1
      pending_queues << queue2
      pending_queues << queue3

      session.close

      [queue1, queue2, queue3].each do |q|
        result = q.pop(true) rescue nil
        expect(result).to eq([:session_closed, nil])
      end
    end

    it "clears pending queues after notification" do
      pending_queues = session.instance_variable_get(:@pending_queues)

      test_queue = Thread::Queue.new
      pending_queues << test_queue

      expect(pending_queues.size).to eq(1)

      session.close

      expect(pending_queues.size).to eq(0)
    end
  end

  describe "SessionClosedError handling" do
    it "async_call raises SessionClosedError when receiving :session_closed marker" do
      # Create a test class that includes AsyncCall
      test_class = Class.new do
        include RBLE::BlueZ::AsyncCall
        attr_accessor :pending_queues

        def initialize
          @pending_queues = []
        end
      end
      instance = test_class.new

      expect {
        instance.async_call("TestOperation", timeout: 1) do |queue, _request_id, _cancelled|
          # Simulate session closed notification
          queue.push([:session_closed, nil])
        end
      }.to raise_error(RBLE::SessionClosedError)
    end

    it "SessionClosedError has descriptive message" do
      error = RBLE::SessionClosedError.new
      expect(error.message).to include("Session closed")
      expect(error.message).to include("pending")
    end

    it "SessionClosedError inherits from ConnectionError" do
      expect(RBLE::SessionClosedError.superclass).to eq(RBLE::ConnectionError)
    end
  end

  describe "concurrent close and async_call" do
    before do
      session.connect
      session.start_event_loop
    end

    it "properly delivers SessionClosedError to waiting operations" do
      # Create a test class that uses the session's pending_queues
      test_class = Class.new do
        include RBLE::BlueZ::AsyncCall
        attr_accessor :pending_queues

        def initialize(pending_queues)
          @pending_queues = pending_queues
        end
      end

      pending_queues = session.instance_variable_get(:@pending_queues)
      instance = test_class.new(pending_queues)

      error_received = nil
      thread = Thread.new do
        begin
          instance.async_call("WaitingOp", timeout: 5) do |queue, _request_id, _cancelled|
            # Block waiting for result (simulating D-Bus callback that never comes)
            # The queue will receive :session_closed from close()
          end
        rescue RBLE::SessionClosedError => e
          error_received = e
        end
      end

      # Give the thread time to start and register its queue
      sleep 0.05

      # Close the session while operation is pending
      session.close

      # Wait for thread to receive the error
      thread.join(1)

      expect(error_received).to be_a(RBLE::SessionClosedError)
    end
  end

  describe "close behavior" do
    before do
      session.connect
      session.start_event_loop
    end

    it "is immediate (does not wait for pending operations)" do
      pending_queues = session.instance_variable_get(:@pending_queues)

      # Add a queue simulating a long-running operation
      test_queue = Thread::Queue.new
      pending_queues << test_queue

      # Close should return immediately, not wait for operations
      start_time = Time.now
      session.close
      elapsed = Time.now - start_time

      # Should complete very quickly (well under 1 second)
      expect(elapsed).to be < 0.5
    end
  end

  describe "#disconnect alias" do
    before do
      session.connect
      session.start_event_loop
    end

    it "is an alias for close" do
      expect(session.method(:disconnect)).to eq(session.method(:close))
    end

    it "works correctly" do
      pending_queues = session.instance_variable_get(:@pending_queues)
      test_queue = Thread::Queue.new
      pending_queues << test_queue

      session.disconnect

      result = test_queue.pop(true) rescue nil
      expect(result).to eq([:session_closed, nil])
      expect(session.closed?).to be true
    end
  end
end
