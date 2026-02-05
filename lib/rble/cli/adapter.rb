# frozen_string_literal: true

module RBLE
  module CLI
    class AdapterCli < Thor
      class_option :json, type: :boolean, default: false,
                          desc: "Output as JSON"
      class_option :adapter, type: :string,
                             desc: "Adapter name, e.g. hci1"

      desc "list", "Show all available Bluetooth adapters"
      def list
        formatter = options["json"] ? Formatters::Json.new : Formatters::Text.new
        adapter_list = Backend.for_platform.adapters
        formatter.adapter_list(adapter_list)
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}"
        exit 1
      end

      desc "power STATE", "Turn adapter power on or off"
      def power(state)
        bool = parse_on_off(state)
        name = resolve_adapter_name
        Backend.for_platform.adapter_set_property(name, :powered, bool)
        formatter_for_options.adapter_confirm("Adapter #{bool ? 'powered on' : 'powered off'}")
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}. Run `rble doctor` to diagnose."
        exit 1
      end

      desc "discoverable STATE", "Set discoverable mode on or off"
      def discoverable(state)
        bool = parse_on_off(state)
        name = resolve_adapter_name
        Backend.for_platform.adapter_set_property(name, :discoverable, bool)
        formatter_for_options.adapter_confirm("Discoverable mode #{bool ? 'enabled' : 'disabled'}")
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}. Run `rble doctor` to diagnose."
        exit 1
      end

      desc "pairable STATE", "Set pairable mode on or off"
      def pairable(state)
        bool = parse_on_off(state)
        name = resolve_adapter_name
        Backend.for_platform.adapter_set_property(name, :pairable, bool)
        formatter_for_options.adapter_confirm("Pairable mode #{bool ? 'enabled' : 'disabled'}")
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}. Run `rble doctor` to diagnose."
        exit 1
      end

      desc "name NAME", "Set adapter friendly name"
      def name(new_name)
        adapter_name = resolve_adapter_name
        Backend.for_platform.adapter_set_property(adapter_name, :alias, new_name)
        formatter_for_options.adapter_confirm("Adapter name set to '#{new_name}'")
      rescue RBLE::Error => e
        $stderr.puts "Error: #{e.message}. Run `rble doctor` to diagnose."
        exit 1
      end

      private

      def parse_on_off(state)
        case state.downcase
        when "on"  then true
        when "off" then false
        else
          raise Thor::Error, "Invalid state '#{state}'. Use 'on' or 'off'."
        end
      end

      def resolve_adapter_name
        options["adapter"] || Backend.for_platform.default_adapter_name
      end

      def formatter_for_options
        options["json"] ? Formatters::Json.new : Formatters::Text.new
      end
    end
  end
end
