  require './lib/rble'

  address = ARGV[0]

  # Step 1: Find the device (stops scanning as soon as device is found)
  puts "Scanning for #{address}..."
  device = RBLE.find_device(address, timeout: 10)

  unless device
    puts "Device not found during scan. Make sure it's advertising."
    exit 1
  end

  puts "Found device: #{device.name || 'unnamed'}"

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
