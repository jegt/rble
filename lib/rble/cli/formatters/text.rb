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

        def show_tree(tree_data)
          header = if tree_data[:name]
                     "#{tree_data[:name]} (#{tree_data[:address]})"
                   else
                     tree_data[:address]
                   end
          service_count = tree_data[:services].size
          char_count = tree_data[:total_characteristics]
          puts "#{header} - #{service_count} service#{'s' unless service_count == 1}, " \
               "#{char_count} characteristic#{'s' unless char_count == 1}"
          puts

          tree_data[:services].each do |service|
            puts format_uuid_line(service[:uuid], service[:resolved_name], type: :service)

            chars = service[:characteristics]
            chars.each_with_index do |char, ci|
              last_char = ci == chars.size - 1
              char_prefix = last_char ? "\u2514\u2500\u2500 " : "\u251C\u2500\u2500 "
              props = "(#{char[:properties].join(', ')})"
              char_line = format_uuid_line(char[:uuid], char[:resolved_name], type: :characteristic)
              puts "#{char_prefix}#{char_line} #{props}"

              descs = char[:descriptors] || []
              descs.each_with_index do |desc, di|
                last_desc = di == descs.size - 1
                vert = last_char ? "    " : "\u2502   "
                desc_prefix = last_desc ? "\u2514\u2500\u2500 " : "\u251C\u2500\u2500 "
                desc_line = format_uuid_line(desc[:uuid], desc[:resolved_name], type: :descriptor)
                puts "#{vert}#{desc_prefix}#{desc_line}"
              end
            end
            puts
          end
        end

        private

        def format_uuid_line(uuid, resolved_name, type:)
          type_label = case type
                       when :service then "Service"
                       when :characteristic then "Characteristic"
                       when :descriptor then "Descriptor"
                       else "Unknown"
                       end

          is_standard = RBLE::GATT::UUIDDatabase.standard_uuid?(uuid)
          short = RBLE::GATT::UUIDDatabase.extract_short_uuid(uuid)

          if resolved_name
            if is_standard
              "#{resolved_name} [0x#{short.upcase}]"
            else
              "#{resolved_name} [#{uuid}]"
            end
          else
            if is_standard
              "Unknown #{type_label} [0x#{short.upcase}]"
            else
              "Unknown #{type_label} [#{uuid}]"
            end
          end
        end

        def truncate(str, max)
          return str if str.length <= max

          str[0, max - 1] + "~"
        end
      end
    end
  end
end
