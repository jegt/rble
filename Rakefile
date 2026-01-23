# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'rspec/core/rake_task'
require_relative 'lib/rble/tasks'

RSpec::Core::RakeTask.new(:spec)

task default: :spec

# macOS Swift CLI build tasks
namespace :build do
  desc 'Build macOS BLE helper (Swift CLI) in release mode'
  task :macos do
    unless RUBY_PLATFORM.include?('darwin')
      puts 'Skipping macOS build (not on macOS)'
      next
    end

    ext_dir = File.expand_path('ext/macos_ble', __dir__)
    unless File.exist?(File.join(ext_dir, 'Package.swift'))
      abort 'Error: ext/macos_ble/Package.swift not found'
    end

    puts 'Building macOS BLE helper...'
    Dir.chdir(ext_dir) do
      system('swift build -c release') || abort('Swift build failed')
    end

    binary = File.join(ext_dir, '.build', 'release', 'RBLEHelper')
    if File.exist?(binary)
      puts "Built: #{binary}"
    else
      abort 'Error: Binary not found after build'
    end
  end

  desc 'Remove macOS BLE helper build artifacts'
  task :clean_macos do
    ext_dir = File.expand_path('ext/macos_ble', __dir__)
    build_dir = File.join(ext_dir, '.build')
    if File.exist?(build_dir)
      require 'fileutils'
      FileUtils.rm_rf(build_dir)
      puts "Removed: #{build_dir}"
    else
      puts 'No build artifacts to clean'
    end
  end
end

namespace :check do
  desc 'Verify macOS BLE helper binary exists'
  task :macos_binary do
    binary = File.expand_path('ext/macos_ble/.build/release/RBLEHelper', __dir__)
    if File.exist?(binary)
      puts "Found: #{binary}"
      puts "Size: #{File.size(binary)} bytes"
    else
      abort "Error: Binary not found at #{binary}\nRun 'rake build:macos' to compile"
    end
  end
end
