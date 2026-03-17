# frozen_string_literal: true

require 'json'
require 'etc'
begin
  require_relative '../bluez'
rescue LoadError
  # BlueZ backend not available (non-Linux platform)
end

module RBLE
  module CLI
    class Doctor
      def initialize(options)
        @options = options
      end

      def execute
        results = run_checks

        if @options["json"]
          print_json(results)
        else
          print_text(results)
        end

        has_errors = results.any? { |r| r[:severity] == :error }
        exit 1 if has_errors
      end

      private

      def linux?
        RUBY_PLATFORM.include?('linux')
      end

      def run_checks
        checks = %i[check_adapter_present check_adapter_powered]

        if linux?
          checks = %i[
            check_ruby_dbus
            check_kernel_module
            check_bluetoothd_running
            check_dbus_permissions
            check_adapter_present
            check_adapter_powered
            check_rfkill
            check_bluetooth_group
            check_bluetoothd_version
          ]
        end

        checks.filter_map do |check|
          begin
            send(check)
          rescue => e
            { severity: :warning, title: check.to_s.sub("check_", "").tr("_", " "),
              message: "Check failed: #{e.message}" }
          end
        end
      end

      def print_text(results)
        # Phase 1: Compact checklist
        results.each do |result|
          case result[:severity]
          when :info
            extra = compact_extra(result)
            puts "  OK  #{result[:title]}#{extra}"
          when :warning
            puts "WARN  #{result[:title]}"
          when :error
            puts "FAIL  #{result[:title]}"
          end
        end

        # Phase 2: Summary line
        issues = results.select { |r| r[:severity] == :error || r[:severity] == :warning }
        puts
        if issues.empty?
          puts "All checks passed"
        else
          puts "#{issues.size} issue#{'s' unless issues.size == 1} found:"

          # Phase 3: Detailed issue section
          puts
          issues.each do |result|
            label = result[:severity] == :error ? "ERROR" : "WARNING"
            puts "  #{label}: #{result[:title]}"
            puts "    #{result[:message]}"
            puts "    Fix: #{result[:fix]}" if result[:fix]
            puts
          end
        end
      end

      def compact_extra(result)
        case result[:title]
        when "Bluetooth adapter"
          if result[:message] =~ /Adapter (\S+) found \(([^)]+)\)/
            " (#{$1} #{$2})"
          else
            ""
          end
        when "BlueZ version"
          if result[:message] =~ /BlueZ (.+)/
            " (#{$1})"
          else
            ""
          end
        else
          ""
        end
      end

      def print_json(results)
        errors = results.count { |r| r[:severity] == :error }
        warnings = results.count { |r| r[:severity] == :warning }
        info = results.count { |r| r[:severity] == :info }

        output = {
          summary: { errors: errors, warnings: warnings, info: info },
          checks: results.map { |r|
            h = { severity: r[:severity].to_s, title: r[:title], message: r[:message] }
            h[:fix] = r[:fix] if r[:fix]
            h
          }
        }

        puts JSON.generate(output)
      end

      # Check 0: ruby-dbus gem available (Linux only)
      def check_ruby_dbus
        require 'dbus'
        { severity: :info, title: "ruby-dbus gem", message: "ruby-dbus gem is available" }
      rescue LoadError
        { severity: :error, title: "ruby-dbus gem",
          message: "ruby-dbus gem is not installed. The BlueZ backend requires it.",
          fix: "gem install ruby-dbus" }
      end

      # Check 1: Kernel module loaded
      def check_kernel_module
        if File.exist?("/sys/module/bluetooth")
          { severity: :info, title: "Kernel module", message: "Bluetooth kernel module is loaded" }
        else
          { severity: :error, title: "Kernel module",
            message: "Bluetooth kernel module is not loaded",
            fix: "sudo modprobe bluetooth" }
        end
      end

      # Check 2: bluetoothd running
      def check_bluetoothd_running
        running = if command_exists?("systemctl")
                    system("systemctl", "is-active", "--quiet", "bluetooth")
                  elsif command_exists?("pgrep")
                    system("pgrep", "-x", "bluetoothd", out: File::NULL, err: File::NULL)
                  else
                    return nil
                  end

        if running
          { severity: :info, title: "Bluetooth daemon", message: "bluetoothd is running" }
        else
          { severity: :error, title: "Bluetooth daemon",
            message: "bluetoothd service is not active",
            fix: "sudo systemctl start bluetooth" }
        end
      end

      # Check 3: D-Bus permissions
      def check_dbus_permissions
        conn = RBLE::BlueZ::DBusConnection.new
        conn.connect
        conn.disconnect
        { severity: :info, title: "D-Bus access", message: "Can connect to BlueZ D-Bus service" }
      rescue => e
        { severity: :error, title: "D-Bus access",
          message: "Cannot connect to BlueZ D-Bus service: #{e.message}",
          fix: "Ensure bluetoothd is running: sudo systemctl start bluetooth" }
      end

      # Check 4: Adapter present
      def check_adapter_present
        backend = RBLE::Backend.for_platform
        adapters = backend.adapters
        if adapters.empty?
          { severity: :error, title: "Bluetooth adapter",
            message: "No Bluetooth adapter found",
            fix: "Check that adapter is plugged in or not blocked by rfkill" }
        else
          @first_adapter = adapters.first
          { severity: :info, title: "Bluetooth adapter",
            message: "Adapter #{@first_adapter[:name]} found (#{@first_adapter[:address]})" }
        end
      rescue RBLE::AdapterNotFoundError
        { severity: :error, title: "Bluetooth adapter",
          message: "No Bluetooth adapter found",
          fix: "Check that adapter is plugged in or not blocked by rfkill" }
      end

      # Check 5: Adapter powered
      def check_adapter_powered
        return nil unless @first_adapter

        if @first_adapter[:powered]
          { severity: :info, title: "Adapter power", message: "Adapter is powered on" }
        else
          { severity: :error, title: "Adapter power",
            message: "Adapter #{@first_adapter[:name]} is not powered on",
            fix: "rble adapter power on" }
        end
      end

      # Check 6: rfkill blocks
      def check_rfkill
        return nil unless command_exists?("rfkill")

        output, success = run_command("rfkill --json 2>/dev/null")
        unless success
          output, success = run_command("rfkill list bluetooth 2>/dev/null")
          return nil unless success
          return parse_rfkill_text(output)
        end

        data = JSON.parse(output)
        bt_devices = data.dig("rfkilldevices")&.select { |d| d["type"] == "bluetooth" } || []

        if bt_devices.empty?
          { severity: :info, title: "RF kill", message: "No Bluetooth devices in rfkill" }
        else
          hard_blocked = bt_devices.any? { |d| d["hard"] == "blocked" }
          soft_blocked = bt_devices.any? { |d| d["soft"] == "blocked" }

          if hard_blocked
            { severity: :error, title: "RF kill",
              message: "Bluetooth is hard-blocked (hardware switch)",
              fix: "Check for a physical Bluetooth/wireless switch on your device" }
          elsif soft_blocked
            { severity: :error, title: "RF kill",
              message: "Bluetooth is soft-blocked by rfkill",
              fix: "sudo rfkill unblock bluetooth" }
          else
            { severity: :info, title: "RF kill", message: "Bluetooth is not blocked" }
          end
        end
      end

      # Check 7: User in bluetooth group
      def check_bluetooth_group
        group = Etc.getgrnam("bluetooth")
        if Process.groups.include?(group.gid)
          { severity: :info, title: "Bluetooth group",
            message: "User is in 'bluetooth' group" }
        else
          username = Etc.getlogin || ENV["USER"] || "unknown"
          { severity: :warning, title: "Bluetooth group",
            message: "User '#{username}' is not a member of the 'bluetooth' group",
            fix: "sudo usermod -aG bluetooth #{username}" }
        end
      rescue ArgumentError
        { severity: :info, title: "Bluetooth group",
          message: "'bluetooth' group does not exist on this system" }
      end

      # Check 8: bluetoothd version
      def check_bluetoothd_version
        return nil unless command_exists?("bluetoothd")

        output, success = run_command("bluetoothd --version 2>/dev/null")
        return nil unless success

        version = output.strip
        return nil if version.empty?

        { severity: :info, title: "BlueZ version", message: "BlueZ #{version}" }
      end

      def command_exists?(cmd)
        system("which", cmd, out: File::NULL, err: File::NULL)
      end

      def run_command(cmd)
        output = `#{cmd}`
        [output, $?.success?]
      end

      def parse_rfkill_text(output)
        hard_blocked = output.include?("Hard blocked: yes")
        soft_blocked = output.include?("Soft blocked: yes")

        if hard_blocked
          { severity: :error, title: "RF kill",
            message: "Bluetooth is hard-blocked (hardware switch)",
            fix: "Check for a physical Bluetooth/wireless switch on your device" }
        elsif soft_blocked
          { severity: :error, title: "RF kill",
            message: "Bluetooth is soft-blocked by rfkill",
            fix: "sudo rfkill unblock bluetooth" }
        else
          { severity: :info, title: "RF kill", message: "Bluetooth is not blocked" }
        end
      end
    end
  end
end
