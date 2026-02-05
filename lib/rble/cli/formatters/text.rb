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

        def status(info)
          puts "Adapter:       #{info[:name]}"
          puts "Address:       #{info[:address]}"
          puts "Alias:         #{info[:alias]}" if info[:alias]
          puts "Powered:       #{info[:powered] ? 'yes' : 'no'}"
          puts "Discoverable:  #{info[:discoverable] ? 'yes' : 'no'}"
          puts "Pairable:      #{info[:pairable] ? 'yes' : 'no'}"
          puts "Discovering:   #{info[:discovering] ? 'yes' : 'no'}"
        end

        def adapter_list(adapters)
          if adapters.empty?
            puts "No Bluetooth adapters found"
            return
          end

          adapters.each do |a|
            powered = a[:powered] ? "up" : "down"
            puts format("%-8s  %-17s  %s", a[:name], a[:address], powered)
          end
        end

        def adapter_confirm(message)
          puts message
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
