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

        def status(info)
          puts JSON.generate(info)
        end

        def adapter_list(adapters)
          puts JSON.generate(adapters)
        end

        def adapter_confirm(message)
          puts JSON.generate({ status: "ok", message: message })
        end
      end
    end
  end
end
