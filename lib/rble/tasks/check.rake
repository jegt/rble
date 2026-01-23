# frozen_string_literal: true

namespace :rble do
  desc 'Check system BLE readiness'
  task :check do
    require 'rble'

    checker = RBLE::SystemChecker.new
    checker.run
    exit(checker.success? ? 0 : 1)
  end
end

module RBLE
  # System BLE readiness checker
  #
  # Validates that the system is properly configured for BLE operations.
  # Performs platform-specific checks and provides actionable fix suggestions.
  #
  # @api private
  class SystemChecker
    def initialize
      @checks_run = 0
      @failures = []
      @suggestions = {}
    end

    # Run all platform-specific checks
    def run
      puts "RBLE System Check"
      puts "=" * 40
      puts

      case RUBY_PLATFORM
      when /linux/
        run_linux_checks
      when /darwin/
        run_macos_checks
      else
        puts "[FAIL] Unsupported platform: #{RUBY_PLATFORM}"
        @failures << "Unsupported platform"
        return
      end

      print_summary
      print_suggestions unless @failures.empty?
    end

    # Check if all checks passed
    # @return [Boolean]
    def success?
      @failures.empty?
    end

    private

    # Run a single check with standardized output
    #
    # @param name [String] Check name
    # @param suggestion [String, nil] Fix suggestion if check fails
    # @yield Block that returns truthy/falsy result
    def check(name, suggestion: nil)
      @checks_run += 1
      result = yield
      if result
        puts "[OK] #{name}"
        true
      else
        puts "[FAIL] #{name}"
        @failures << name
        @suggestions[name] = suggestion if suggestion
        false
      end
    rescue StandardError => e
      puts "[FAIL] #{name}: #{e.message}"
      @failures << name
      @suggestions[name] = suggestion if suggestion
      false
    end

    # Linux-specific BLE readiness checks
    def run_linux_checks
      puts "Platform: Linux"
      puts

      check("BlueZ D-Bus service",
            suggestion: "Install BlueZ: sudo apt install bluez") do
        system("busctl list 2>/dev/null | grep -q org.bluez")
      end

      check("bluetoothd running",
            suggestion: "Start Bluetooth: sudo systemctl start bluetooth") do
        system("systemctl is-active --quiet bluetooth 2>/dev/null") ||
          system("pgrep -x bluetoothd >/dev/null 2>&1")
      end

      check("Bluetooth adapter found",
            suggestion: "No adapter found. Connect USB adapter or enable built-in.") do
        RBLE.adapters.any?
      end

      check("Bluetooth adapter powered",
            suggestion: "Enable adapter: bluetoothctl power on") do
        RBLE.adapters.any? { |a| a[:powered] }
      end
    end

    # macOS-specific BLE readiness checks
    def run_macos_checks
      puts "Platform: macOS"
      puts

      # Determine helper path relative to gem root
      helper_path = File.expand_path('../../../ext/macos_ble/.build/release/RBLEHelper', __dir__)

      helper_exists = check("Helper binary exists",
                            suggestion: "Build helper: rake build:macos") do
        File.exist?(helper_path)
      end

      helper_executable = check("Helper binary executable",
                                suggestion: "Fix permissions: chmod +x #{helper_path}") do
        File.executable?(helper_path)
      end

      # Only try RBLE operations if helper exists and is executable
      # This avoids triggering CoreBluetooth permission prompts unnecessarily
      if helper_exists && helper_executable
        check("Bluetooth powered",
              suggestion: "Enable Bluetooth in System Settings > Bluetooth") do
          RBLE.adapters.any? { |a| a[:powered] }
        end
      end
    end

    # Print summary of check results
    def print_summary
      puts
      passed = @checks_run - @failures.length
      puts "#{passed}/#{@checks_run} checks passed"
    end

    # Print grouped fix suggestions for failures
    def print_suggestions
      puts
      puts "Suggestions:"
      @failures.each do |name|
        if (suggestion = @suggestions[name])
          puts "  - #{name}: #{suggestion}"
        end
      end
    end
  end
end
