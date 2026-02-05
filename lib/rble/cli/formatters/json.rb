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

        def paired_list(devices)
          puts JSON.generate(devices)
        end

        def pair_result(success:, address:, message:)
          puts JSON.generate({
            status: success ? "ok" : "error",
            address: address,
            message: message
          })
        end

        def read_value(address:, uuid:, name:, raw:, formatted:)
          puts JSON.generate({
            address: address,
            characteristic: {
              uuid: uuid,
              name: name,
              value: formatted,
              raw: raw.bytes
            }
          })
        end

        def write_result(address:, uuid:, name:, success:, verified: nil, written_bytes: nil)
          output = {
            address: address,
            characteristic: {
              uuid: uuid,
              name: name
            },
            status: success ? "ok" : "error"
          }
          output[:written] = written_bytes.bytes if written_bytes
          output[:verified] = verified
          puts JSON.generate(output)
        end

        def show_tree(tree_data)
          output = {
            address: tree_data[:address],
            name: tree_data[:name],
            services: tree_data[:services].map do |service|
              {
                uuid: service[:uuid],
                name: service[:resolved_name],
                primary: service[:primary],
                characteristics: service[:characteristics].map do |char|
                  {
                    uuid: char[:uuid],
                    name: char[:resolved_name],
                    properties: char[:properties],
                    handle: char[:handle],
                    descriptors: (char[:descriptors] || []).map do |desc|
                      {
                        uuid: desc[:uuid],
                        name: desc[:resolved_name],
                        handle: desc[:handle]
                      }
                    end
                  }
                end
              }
            end
          }

          puts JSON.generate(output)
        end
      end
    end
  end
end
