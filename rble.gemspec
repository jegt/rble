# frozen_string_literal: true

require_relative 'lib/rble/version'

Gem::Specification.new do |spec|
  spec.name = 'rble'
  spec.version = RBLE::VERSION
  spec.authors = ['Jonas Tehler']
  spec.email = ['jonas@tehler.se']

  spec.summary = 'Ruby Bluetooth Low Energy library'
  spec.description = 'Reliable BLE communication for Ruby - scanning, connections, GATT operations on Linux and macOS'
  spec.homepage = 'https://github.com/jegt/rble'
  spec.license = 'MIT'
  spec.required_ruby_version = '>= 3.2'

  spec.metadata['homepage_uri'] = spec.homepage
  spec.metadata['source_code_uri'] = "#{spec.homepage}/tree/main"
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Include lib/, ext/, and exe/ but exclude build artifacts
  spec.files = Dir['lib/**/*', 'exe/*', 'LICENSE.txt', 'README.md', 'CHANGELOG.md'] +
               Dir['ext/macos_ble/Package.swift', 'ext/macos_ble/Sources/**/*.swift'] +
               ['ext/macos_ble/extconf.rb'] +
               Dir['ext/linux_ble/Package.swift', 'ext/linux_ble/Sources/**/*.swift'] +
               ['ext/linux_ble/extconf.rb']
  spec.bindir = 'exe'
  spec.executables = ['rble']
  spec.require_paths = ['lib']

  # Build Swift helpers during gem install (each skips on wrong platform)
  spec.extensions = [
    'ext/macos_ble/extconf.rb',
    'ext/linux_ble/extconf.rb'
  ]

  # Runtime dependencies
  spec.add_dependency 'ruby-dbus', '~> 0.25'
  spec.add_dependency 'thor', '~> 1.3'
end
