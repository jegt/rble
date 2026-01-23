require './lib/rble'
  RBLE.scan(timeout: 5) { |d| puts "#{d.name || 'unnamed'} - #{d.address}" }
