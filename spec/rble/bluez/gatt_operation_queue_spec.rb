# frozen_string_literal: true

require 'spec_helper'
require 'rble/bluez/gatt_operation_queue'

RSpec.describe RBLE::BlueZ::GattOperationQueue do
  let(:queue) { described_class.new }

  after do
    queue.stop if queue.running?
  end

  describe '#start' do
    it 'starts the queue worker thread' do
      expect(queue.running?).to be false
      queue.start
      expect(queue.running?).to be true
    end

    it 'is idempotent' do
      queue.start
      queue.start
      expect(queue.running?).to be true
    end
  end

  describe '#stop' do
    it 'stops the queue worker thread' do
      queue.start
      queue.stop
      expect(queue.running?).to be false
    end

    it 'is idempotent' do
      queue.start
      queue.stop
      queue.stop
      expect(queue.running?).to be false
    end

    it 'unblocks threads waiting on enqueue' do
      queue.start

      # Start a thread that will block on enqueue
      error = nil
      thread = Thread.new do
        queue.enqueue do
          sleep 5 # simulate long-running operation
        end
      rescue RuntimeError => e
        error = e
      end

      # Give thread time to block on pop
      sleep 0.05
      queue.stop

      thread.join(2)
      # The thread should have been unblocked by stop draining pending ops
      # OR the operation was already executing and was killed with the worker
      expect(thread.alive?).to be false
    end

    it 'unblocks multiple waiting threads on stop' do
      queue.start

      # Block the queue with a long operation
      blocker = Thread.new do
        queue.enqueue { sleep 5 }
      rescue RuntimeError
        # expected
      end

      sleep 0.05

      # Queue up more operations that will be pending
      errors = []
      waiters = 3.times.map do
        Thread.new do
          queue.enqueue { :result }
        rescue RuntimeError => e
          errors << e
        end
      end

      sleep 0.05
      queue.stop

      [blocker, *waiters].each { |t| t.join(2) }
      # All pending waiters should have received errors
      expect(errors).to all(have_attributes(message: 'GATT queue stopped'))
    end
  end

  describe '#enqueue' do
    before { queue.start }

    it 'executes the block and returns the result' do
      result = queue.enqueue { 42 }
      expect(result).to eq(42)
    end

    it 'raises if queue is not running' do
      queue.stop
      expect { queue.enqueue { 1 } }.to raise_error(RuntimeError, /stopped/)
    end

    it 're-raises exceptions from the block' do
      expect {
        queue.enqueue { raise ArgumentError, 'test error' }
      }.to raise_error(ArgumentError, 'test error')
    end

    it 'serializes operations' do
      order = []
      mutex = Mutex.new

      threads = 5.times.map do |i|
        Thread.new do
          queue.enqueue do
            mutex.synchronize { order << "start_#{i}" }
            sleep 0.01
            mutex.synchronize { order << "end_#{i}" }
            i
          end
        end
      end

      threads.each(&:join)

      # Verify serialization: each operation should complete before the next starts
      # Pattern should be: start_X, end_X, start_Y, end_Y, ...
      order.each_slice(2) do |pair|
        start_event, end_event = pair
        expect(start_event).to start_with('start_')
        expect(end_event).to start_with('end_')
        # Same operation number
        expect(start_event.delete_prefix('start_')).to eq(end_event.delete_prefix('end_'))
      end
    end
  end

  describe 'inter-operation delay' do
    before { queue.start }

    it 'has a delay between operations' do
      times = []

      3.times do
        queue.enqueue { times << Time.now }
      end

      # Each pair of consecutive operations should have at least INTER_OPERATION_DELAY
      times.each_cons(2) do |t1, t2|
        delay = t2 - t1
        expect(delay).to be >= RBLE::BlueZ::GattOperationQueue::INTER_OPERATION_DELAY
      end
    end
  end
end
