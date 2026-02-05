# frozen_string_literal: true

require 'json'

module RBLE
  module CLI
    module Formatters
      class Json
        def device(device)
          puts JSON.generate({
            address: device.address,
            name: device.name,
            rssi: device.rssi,
            address_type: device.address_type
          })
        end
      end
    end
  end
end
