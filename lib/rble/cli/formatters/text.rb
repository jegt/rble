# frozen_string_literal: true

module RBLE
  module CLI
    module Formatters
      class Text
        def device(device)
          name = truncate(device.name || "(unknown)", 25)
          rssi = device.rssi || 0
          puts format("%-17s  %-25s  %4d dBm  %s", device.address, name, rssi, device.address_type)
        end

        private

        def truncate(str, max)
          return str if str.length <= max

          str[0, max - 1] + "~"
        end
      end
    end
  end
end
