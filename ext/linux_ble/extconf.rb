# frozen_string_literal: true

# Extension configuration for Linux BLE helper
# This runs during `gem install` to compile the Swift CLI

require 'mkmf'

# Create a dummy Makefile - actual build happens below
# We need a Makefile for RubyGems to consider the extension "built"
File.write('Makefile', <<~MAKEFILE)
  .PHONY: all install clean

  all:
  \t@echo "Swift build completed during extconf.rb"

  install:
  \t@echo "No install step needed"

  clean:
  \t@echo "Run 'swift package clean' to clean Swift build"
MAKEFILE

# Only build on Linux
unless RUBY_PLATFORM.include?('linux')
  puts 'Skipping Linux BLE helper build (not on Linux)'
  exit 0
end

# Allow users to skip Swift build (BlueZ D-Bus backend only)
if ENV['RBLE_SKIP_SWIFT'] == '1'
  puts 'Skipping Linux BLE helper build (RBLE_SKIP_SWIFT=1)'
  exit 0
end

# Check for Swift compiler
swift_path = find_executable('swift')
unless swift_path
  abort <<~MSG

    ERROR: Swift compiler not found.
    The Linux BLE helper requires Swift 5.9 or later to compile.

    Install Swift from: https://www.swift.org/install/linux/

    Or skip this build (BlueZ D-Bus backend only):
      RBLE_SKIP_SWIFT=1 gem install rble

  MSG
end

# Check Swift version (minimum 5.9)
swift_version_output = `swift --version 2>&1`
version_match = swift_version_output.match(/Swift version (\d+)\.(\d+)/)

unless version_match
  abort <<~MSG

    ERROR: Could not determine Swift version.
    Output: #{swift_version_output}

    The Linux BLE helper requires Swift 5.9 or later.
    Install Swift from: https://www.swift.org/install/linux/

  MSG
end

major = version_match[1].to_i
minor = version_match[2].to_i

if major < 5 || (major == 5 && minor < 9)
  abort <<~MSG

    ERROR: Swift version #{major}.#{minor} is too old.
    The Linux BLE helper requires Swift 5.9 or later.
    You have: #{swift_version_output.lines.first&.strip}

    Install a newer Swift from: https://www.swift.org/install/linux/

    Or skip this build (BlueZ D-Bus backend only):
      RBLE_SKIP_SWIFT=1 gem install rble

  MSG
end

# Build the Swift CLI
puts 'Building Linux BLE helper (Swift CLI)...'
puts "  Source: #{Dir.pwd}"
puts "  Swift: #{swift_version_output.lines.first&.strip}"

# Run swift build in release mode
success = system('swift build -c release')

unless success
  abort <<~MSG

    ERROR: Swift build failed.
    You can try building manually:
      cd #{Dir.pwd} && swift build -c release

    Or skip this build (BlueZ D-Bus backend only):
      RBLE_SKIP_SWIFT=1 gem install rble

  MSG
end

# Verify the binary was created
binary = File.join(Dir.pwd, '.build', 'release', 'RBLELinuxHelper')
unless File.exist?(binary)
  abort <<~MSG

    ERROR: Build succeeded but binary not found at #{binary}
    This is unexpected. Please report this issue.

    You can try building manually:
      cd #{Dir.pwd} && swift build -c release

  MSG
end

puts "  Built: #{binary}"
puts "  Size: #{File.size(binary)} bytes"
