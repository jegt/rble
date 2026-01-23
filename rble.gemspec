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
  spec.metadata['source_code_uri'] = spec.homepage
  spec.metadata['changelog_uri'] = "#{spec.homepage}/blob/main/CHANGELOG.md"
  spec.metadata['rubygems_mfa_required'] = 'true'

  # Include lib/ and ext/ but exclude build artifacts
  spec.files = Dir['lib/**/*', 'LICENSE.txt', 'README.md'] +
               Dir['ext/macos_ble/Package.swift', 'ext/macos_ble/Sources/**/*.swift'] +
               ['ext/macos_ble/extconf.rb']
  spec.require_paths = ['lib']

  # Build macOS Swift helper during gem install
  spec.extensions = ['ext/macos_ble/extconf.rb']

  # Runtime dependencies
  spec.add_dependency 'ruby-dbus', '~> 0.25'
end
