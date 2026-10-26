require 'spec_helper'

RSpec.describe RBLE::Service do
  subject(:service) do
    described_class.new(
      uuid: '0000180D-0000-1000-8000-00805f9b34fb',
      characteristics: [RBLE::Characteristic.new(uuid: '180D', flags: %w[read notify], service_uuid: '0000180d-0000-1000-8000-00805f9b34fb')]
    )
  end

  describe '#characteristic' do
    it 'finds a characteristic with an upper case' do
      expect(service.characteristic('180D')).not_to be_nil
    end
  end
end