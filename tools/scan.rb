require './lib/rble'
  RBLE.scan(timeout: 5, allow_duplicates: false) { |d| puts "#{d.name || 'unnamed'} - #{d.address}" }
