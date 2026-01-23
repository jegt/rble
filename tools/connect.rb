  require './lib/rble'

  address = ARGV[0]

  # Step 1: Scan to discover the device
  puts "Scanning for #{address}..."
  found = false
  RBLE.scan(timeout: 10, allow_duplicates: false) do |device|
    if device.address == address
      puts "Found device: #{device.name || 'unnamed'}"
      found = true
    end
  end

  unless found
    puts "Device not found during scan. Make sure it's advertising."
    exit 1
  end

  # Step 2: Now connect
  puts "Connecting..."
  conn = RBLE.connect(address, timeout: 15)
  puts "Connected!"

  services = conn.discover_services
  puts "Found #{services.length} services:"
  services.each do |svc|
    puts "  #{svc.short_uuid}"
    svc.characteristics.each { |c| puts "    #{c.short_uuid} [#{c.flags.join(', ')}]" }
  end

  conn.disconnect
  puts "Done"
