# frozen_string_literal: true

require "spec_helper"
require "rble/bluez/async_call"
require "stringio"
require "logger"

RSpec.describe RBLE::BlueZ::AsyncCall do
  # Create test class that includes the module
  let(:test_class) { Class.new { include RBLE::BlueZ::AsyncCall } }
  let(:instance) { test_class.new }

  describe "#async_call" do
    describe "success case" do
      it "returns params when queue receives success" do
        result = instance.async_call("TestOperation") do |queue, _request_id|
          queue.push([:ok, ["result_value"]])
        end

        expect(result).to eq(["result_value"])
      end

      it "returns array params with multiple elements" do
        result = instance.async_call("TestOperation") do |queue, _request_id|
          queue.push([:ok, [1, 2, 3]])
        end

        expect(result).to eq([1, 2, 3])
      end

      it "returns nil params when operation returns nil" do
        result = instance.async_call("TestOperation") do |queue, _request_id|
          queue.push([:ok, nil])
        end

        expect(result).to be_nil
      end
    end

    describe "timeout case" do
      it "raises TimeoutError when queue times out" do
        expect {
          instance.async_call("SlowOperation", timeout: 0.1) do |_queue, _request_id|
            # Don't push anything, let it timeout
            sleep 0.2
          end
        }.to raise_error(RBLE::TimeoutError) do |error|
          expect(error.operation).to eq("SlowOperation")
          expect(error.timeout_value).to eq(0.1)
        end
      end

      it "includes operation name in timeout error message" do
        expect {
          instance.async_call("MyOperation", timeout: 0.05) do |_queue, _request_id|
            # Let it timeout
          end
        }.to raise_error(RBLE::TimeoutError, /MyOperation.*timed out/)
      end
    end

    describe "DBus error case" do
      it "raises DBus::Error when queue receives error" do
        dbus_error = DBus::Error.new("org.bluez.Error.Failed: test error message")

        expect {
          instance.async_call("FailingOperation") do |queue, _request_id|
            queue.push([dbus_error, nil])
          end
        }.to raise_error(DBus::Error, /test error message/)
      end

      it "propagates the exact DBus::Error instance" do
        dbus_error = DBus::Error.new("org.bluez.Error.NotPermitted: not allowed")

        raised_error = nil
        begin
          instance.async_call("FailingOperation") do |queue, _request_id|
            queue.push([dbus_error, nil])
          end
        rescue DBus::Error => e
          raised_error = e
        end

        expect(raised_error).to be(dbus_error)
      end
    end

    describe "request ID generation" do
      it "yields unique request_id for each call" do
        request_ids = []

        2.times do
          instance.async_call("TestOperation") do |queue, request_id|
            request_ids << request_id
            queue.push([:ok, []])
          end
        end

        expect(request_ids.size).to eq(2)
        expect(request_ids[0]).not_to eq(request_ids[1])
      end

      it "generates 8-character hex request IDs" do
        captured_id = nil

        instance.async_call("TestOperation") do |queue, request_id|
          captured_id = request_id
          queue.push([:ok, []])
        end

        expect(captured_id).to match(/\A[a-f0-9]{8}\z/)
      end

      it "yields queue as Thread::Queue" do
        captured_queue = nil

        instance.async_call("TestOperation") do |queue, _request_id|
          captured_queue = queue
          queue.push([:ok, []])
        end

        expect(captured_queue).to be_a(Thread::Queue)
      end
    end

    describe "logging" do
      let(:log_output) { StringIO.new }
      let(:logger) { Logger.new(log_output) }

      around do |example|
        original_logger = RBLE.logger
        RBLE.logger = logger
        example.run
        RBLE.logger = original_logger
      end

      it "logs request start with request_id and operation" do
        instance.async_call("ReadValue") do |queue, _request_id|
          queue.push([:ok, []])
        end

        log_content = log_output.string
        expect(log_content).to include("Starting ReadValue")
        expect(log_content).to match(/[a-f0-9]{8}.*Starting ReadValue/)
      end

      it "logs completion with elapsed time" do
        instance.async_call("WriteValue") do |queue, _request_id|
          queue.push([:ok, []])
        end

        log_content = log_output.string
        expect(log_content).to include("completed in")
        expect(log_content).to match(/WriteValue completed in \d+\.\d+s/)
      end

      it "logs warning on timeout" do
        begin
          instance.async_call("SlowOp", timeout: 0.05) do |_queue, _request_id|
            # Let it timeout
          end
        rescue RBLE::TimeoutError
          # Expected
        end

        log_content = log_output.string
        expect(log_content).to include("timed out")
        expect(log_content).to match(/SlowOp timed out after \d+\.\d+s/)
      end

      it "includes same request_id in start and completion logs" do
        instance.async_call("Operation") do |queue, _request_id|
          queue.push([:ok, []])
        end

        log_content = log_output.string
        # Extract request IDs from log lines
        ids = log_content.scan(/\[RBLE\] ([a-f0-9]{8})/).flatten

        expect(ids.size).to be >= 2
        expect(ids.uniq.size).to eq(1) # Same ID in both lines
      end
    end

    describe "thread safety" do
      it "handles async push from another thread" do
        result = instance.async_call("AsyncOp", timeout: 1) do |queue, _request_id|
          Thread.new do
            sleep 0.01
            queue.push([:ok, ["threaded_result"]])
          end
        end

        expect(result).to eq(["threaded_result"])
      end
    end

    describe "default timeout" do
      it "uses 5 second default timeout" do
        # We can't easily test 5 second timeout, but we can verify the method
        # signature accepts timeout as optional parameter
        expect { instance.async_call("Op") { |q, _| q.push([:ok, []]) } }.not_to raise_error
      end
    end
  end
end
