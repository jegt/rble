require './lib/rble'
RBLE.scan(timeout: 15, allow_duplicates: false) { |d| puts("#{d.name || 'unnamed'} - #{d.address}") }
