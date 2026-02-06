# frozen_string_literal: true

source 'https://rubygems.org'

gemspec

# BlueZ backend dependency (Linux only)
gem 'ruby-dbus', '~> 0.25' if RUBY_PLATFORM.include?('linux')

group :development, :test do
  gem 'rake', '~> 13.0'
  gem 'rspec', '~> 3.0'
  gem 'rubocop', '~> 1.0'
  gem 'yard', '~> 0.9'
end
