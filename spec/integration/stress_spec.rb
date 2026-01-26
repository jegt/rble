# frozen_string_literal: true

require 'spec_helper'
require 'rble/bluez'
require 'timeout'

RSpec.describe 'Stress Tests', :integration do
  describe 'mock-based stress' do
    let(:mock_session) { double('DBusSession') }

    before do
      allow(RBLE::BlueZ::DBusSession).to receive(:new).and_return(mock_session)
      allow(mock_session).to receive(:connect)
      allow(mock_session).to receive(:start_event_loop)
      allow(mock_session).to receive(:close)
      allow(mock_session).to receive(:closed?).and_return(false)
      allow(mock_session).to receive(:connected?).and_return(true)
      allow(mock_session).to receive(:running?).and_return(true)
    end

    it 'session create/close cycle 10 times without deadlock' do
      Timeout.timeout(30) do
        10.times do |i|
          session = RBLE::BlueZ::DBusSession.new
          session.connect
          session.start_event_loop
          session.close
        end
      end
    end

    it 'rapid close after connect does not deadlock' do
      Timeout.timeout(10) do
        5.times do
          session = RBLE::BlueZ::DBusSession.new
          session.connect
          # Close immediately without starting event loop
          session.close
        end
      end
    end

    it 'double close is safe' do
      session = RBLE::BlueZ::DBusSession.new
      session.connect
      session.start_event_loop

      # Close twice - should not raise or deadlock
      Timeout.timeout(5) do
        session.close
        session.close
      end
    end
  end

  describe 'async_call stress' do
    let(:test_class) do
      Class.new do
        include RBLE::BlueZ::AsyncCall
        attr_accessor :pending_queues

        def initialize
          @pending_queues = []
          @late_callback_count = 0
        end
      end
    end

    let(:instance) { test_class.new }

    it 'handles 20 sequential async calls without issues' do
      Timeout.timeout(30) do
        20.times do |i|
          result = instance.async_call("Op#{i}", timeout: 0.5) do |queue, _request_id, _cancelled|
            queue.push(["success#{i}", [i]])
          end
          expect(result).to eq([i])
        end
      end
    end

    it 'handles 5 concurrent async calls' do
      Timeout.timeout(10) do
        threads = 5.times.map do |i|
          Thread.new do
            instance.async_call("ConcurrentOp#{i}", timeout: 1) do |queue, _request_id, _cancelled|
              sleep(rand * 0.1)  # Random small delay
              queue.push(["done#{i}", [i]])
            end
          end
        end

        results = threads.map(&:value)
        expect(results.map(&:first)).to match_array([0, 1, 2, 3, 4])
      end
    end

    it 'recovers from multiple timeouts' do
      Timeout.timeout(10) do
        3.times do
          begin
            instance.async_call('TimeoutOp', timeout: 0.1) do |_queue, _request_id, _cancelled|
              # Don't push - let it timeout
            end
          rescue RBLE::TimeoutError
            # Expected
          end
        end

        # Should still work after timeouts
        result = instance.async_call('RecoveryOp', timeout: 1) do |queue, _request_id, _cancelled|
          queue.push(['recovered', [:ok]])
        end
        expect(result).to eq([:ok])
      end
    end

    it 'handles rapid sequential calls without accumulating pending queues' do
      Timeout.timeout(10) do
        100.times do |i|
          instance.async_call("RapidOp#{i}", timeout: 0.5) do |queue, _request_id, _cancelled|
            queue.push([:ok, [i]])
          end
        end
        # All queues should be cleaned up
        expect(instance.pending_queues).to be_empty
      end
    end

    it 'handles mixed success and timeout without corruption' do
      Timeout.timeout(15) do
        results = []
        errors = []

        10.times do |i|
          begin
            result = instance.async_call("MixedOp#{i}", timeout: 0.2) do |queue, _request_id, _cancelled|
              if i.even?
                queue.push([:ok, [i]])
              else
                # Don't push - let odd ones timeout
              end
            end
            results << result.first
          rescue RBLE::TimeoutError
            errors << i
          end
        end

        # Even numbers should succeed
        expect(results.sort).to eq([0, 2, 4, 6, 8])
        # Odd numbers should timeout
        expect(errors.sort).to eq([1, 3, 5, 7, 9])
      end
    end
  end

  # Hardware stress tests
  describe 'hardware stress', :hardware do
    before(:all) do
      skip 'Hardware tests require RUN_HARDWARE_TESTS=1' unless ENV['RUN_HARDWARE_TESTS']
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

    it 'runs session lifecycle 5 times without deadlock' do
      skip 'No Bluetooth adapter available' unless adapter_available?

      Timeout.timeout(60) do
        5.times do |i|
          RBLE.logger&.info("[STRESS] Iteration #{i + 1}/5")

          session = RBLE::BlueZ::DBusSession.new
          session.connect
          session.start_event_loop

          # Do something with the session
          objects = session.async_get_managed_objects
          expect(objects).not_to be_empty

          session.close
          expect(session.closed?).to be true

          sleep 0.5  # Brief pause between iterations
        end
      end
    end

    it 'discovery start/stop 5 times without deadlock', :slow do
      skip 'No Bluetooth adapter available' unless adapter_available?

      Timeout.timeout(120) do
        session = RBLE::BlueZ::DBusSession.new
        session.connect
        session.start_event_loop

        begin
          objects = session.async_get_managed_objects
          adapter_path = objects.find { |_p, i| i.key?('org.bluez.Adapter1') }&.first
          adapter = RBLE::BlueZ::Adapter.new_from_session(session, adapter_path)

          5.times do |i|
            RBLE.logger&.info("[STRESS] Discovery cycle #{i + 1}/5")

            adapter.start_discovery
            sleep 2  # Brief scan
            adapter.stop_discovery
            sleep 0.5
          end
        ensure
          session.close
        end
      end
    end
  end
end
