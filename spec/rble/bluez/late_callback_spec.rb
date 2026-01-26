# frozen_string_literal: true

require "spec_helper"
require "rble/bluez/async_call"

RSpec.describe RBLE::BlueZ::AsyncCall, "late callback handling" do
  # Create test class that includes the module
  let(:test_class) { Class.new { include RBLE::BlueZ::AsyncCall } }
  let(:instance) { test_class.new }

  before do
    # Suppress logging by default
    allow(RBLE).to receive(:logger).and_return(nil)
  end

  describe "cancelled flag" do
    it "is passed to yielded block" do
      captured_cancelled = nil

      instance.async_call("TestOperation") do |queue, _request_id, cancelled|
        captured_cancelled = cancelled
        queue.push([:ok, []])
      end

      expect(captured_cancelled).to be_an(Array)
      expect(captured_cancelled.size).to eq(1)
    end

    it "is false when operation completes successfully" do
      captured_cancelled = nil

      instance.async_call("TestOperation") do |queue, _request_id, cancelled|
        captured_cancelled = cancelled
        queue.push([:ok, []])
      end

      expect(captured_cancelled[0]).to be false
    end

    it "is set to true on timeout" do
      captured_cancelled = nil

      begin
        instance.async_call("SlowOperation", timeout: 0.05) do |_queue, _request_id, cancelled|
          captured_cancelled = cancelled
          # Don't push anything, let it timeout
          sleep 0.1
        end
      rescue RBLE::TimeoutError
        # Expected
      end

      expect(captured_cancelled[0]).to be true
    end

    it "is mutable array to allow callback to check before pushing" do
      captured_cancelled = nil

      begin
        instance.async_call("SlowOperation", timeout: 0.05) do |_queue, _request_id, cancelled|
          captured_cancelled = cancelled
          # Simulate late callback that checks flag
          Thread.new do
            sleep 0.1  # Wait past timeout
            # Late callback would check: next if cancelled[0]
          end
        end
      rescue RBLE::TimeoutError
        # Expected
      end

      # After timeout, cancelled[0] should be true
      expect(captured_cancelled).to respond_to(:[]=)
      expect(captured_cancelled[0]).to be true
    end
  end

  describe "#late_callback_count" do
    it "starts at 0 (nil until first late callback)" do
      # Fresh instance hasn't timed out yet
      expect(instance.late_callback_count).to be_nil
    end

    it "increments on timeout" do
      begin
        instance.async_call("Op1", timeout: 0.05) do |_queue, _request_id, _cancelled|
          # Let it timeout
        end
      rescue RBLE::TimeoutError
        # Expected
      end

      expect(instance.late_callback_count).to eq(1)
    end

    it "increments each time a timeout occurs" do
      3.times do |i|
        begin
          instance.async_call("Op#{i}", timeout: 0.05) do |_queue, _request_id, _cancelled|
            # Let it timeout
          end
        rescue RBLE::TimeoutError
          # Expected
        end
      end

      expect(instance.late_callback_count).to eq(3)
    end

    it "does not increment on successful completion" do
      # First, cause a timeout to set count to 1
      begin
        instance.async_call("SlowOp", timeout: 0.05) do |_queue, _request_id, _cancelled|
          # Let it timeout
        end
      rescue RBLE::TimeoutError
        # Expected
      end

      initial_count = instance.late_callback_count

      # Now do a successful operation
      instance.async_call("FastOp", timeout: 1) do |queue, _request_id, _cancelled|
        queue.push([:ok, ["result"]])
      end

      expect(instance.late_callback_count).to eq(initial_count)
    end
  end

  describe "late callback pattern demonstration" do
    it "shows how callback can check cancelled flag before pushing" do
      cancelled_flag = nil
      push_attempted = false

      begin
        instance.async_call("DemoOp", timeout: 0.05) do |queue, _request_id, cancelled|
          cancelled_flag = cancelled

          # Simulate async D-Bus callback that arrives late
          Thread.new do
            sleep 0.1  # Arrive after timeout
            # Correct pattern: check cancelled before pushing
            unless cancelled[0]
              queue.push([:ok, ["late_result"]])
              push_attempted = true
            end
          end
        end
      rescue RBLE::TimeoutError
        # Expected
      end

      # Give the thread time to check the flag
      sleep 0.15

      # The late callback should have checked cancelled[0] and NOT pushed
      expect(cancelled_flag[0]).to be true
      expect(push_attempted).to be false
    end
  end
end
