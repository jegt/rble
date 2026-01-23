# frozen_string_literal: true

# Extension configuration for macOS BLE helper
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

# Only build on macOS
unless RUBY_PLATFORM.include?('darwin')
  puts 'Skipping macOS BLE helper build (not on macOS)'
  exit 0
end

# Check for Swift
swift_path = find_executable('swift')
unless swift_path
  warn <<~MSG

    WARNING: Swift compiler not found.
    The macOS BLE helper requires Swift to compile.
    Install Xcode or Xcode Command Line Tools:
      xcode-select --install

    You can build manually later with:
      cd #{Dir.pwd} && swift build -c release

  MSG
  exit 0 # Don't fail the gem install, just warn
end

# Build the Swift CLI
puts 'Building macOS BLE helper (Swift CLI)...'
puts "  Source: #{Dir.pwd}"

# Run swift build in release mode
success = system('swift build -c release')

if success
  binary = File.join(Dir.pwd, '.build', 'release', 'RBLEHelper')
  if File.exist?(binary)
    puts "  Built: #{binary}"
    puts "  Size: #{File.size(binary)} bytes"
  else
    warn "  WARNING: Build succeeded but binary not found at #{binary}"
  end
else
  warn <<~MSG

    WARNING: Swift build failed.
    You can try building manually:
      cd #{Dir.pwd} && swift build -c release

    Check that Xcode Command Line Tools are installed:
      xcode-select --install

  MSG
  # Don't fail gem install - user can build manually
end
