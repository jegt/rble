# frozen_string_literal: true

module RBLE
  module GATT
    # Database of Bluetooth SIG assigned UUIDs and common vendor UUIDs
    # for GATT services, characteristics, and descriptors.
    #
    # Loaded on-demand (not auto-required by lib/rble.rb).
    # Use: require 'rble/gatt/uuid_database'
    #
    # @example Resolve a service UUID
    #   RBLE::GATT::UUIDDatabase.resolve("180d", type: :service) # => "Heart Rate"
    #
    # @example Resolve without specifying type
    #   RBLE::GATT::UUIDDatabase.resolve("2a37") # => "Heart Rate Measurement"
    #
    # @example Check if UUID is standard Bluetooth SIG
    #   RBLE::GATT::UUIDDatabase.standard_uuid?("180d") # => true
    module UUIDDatabase
      # Bluetooth Base UUID suffix for standard 16-bit UUIDs
      BLUETOOTH_BASE_UUID_SUFFIX = "-0000-1000-8000-00805f9b34fb"

      # Bluetooth SIG Assigned Services + common vendor services
      # Standard UUIDs keyed by short 4-char hex (lowercase)
      # Vendor UUIDs keyed by full 128-bit UUID (lowercase)
      SERVICES = {
        # Generic Access Profile
        "1800" => "Generic Access",
        "1801" => "Generic Attribute",

        # Alert / Proximity
        "1802" => "Immediate Alert",
        "1803" => "Link Loss",
        "1804" => "Tx Power",

        # Time
        "1805" => "Current Time",
        "1806" => "Reference Time Update",
        "1807" => "Next DST Change",

        # Health
        "1808" => "Glucose",
        "1809" => "Health Thermometer",

        # Device Information
        "180a" => "Device Information",

        # Heart Rate
        "180d" => "Heart Rate",

        # Phone
        "180e" => "Phone Alert Status",

        # Battery
        "180f" => "Battery Service",

        # Blood Pressure
        "1810" => "Blood Pressure",

        # Alert Notification
        "1811" => "Alert Notification",

        # HID
        "1812" => "Human Interface Device",

        # Scan Parameters
        "1813" => "Scan Parameters",

        # Running / Cycling
        "1814" => "Running Speed and Cadence",
        "1815" => "Automation IO",
        "1816" => "Cycling Speed and Cadence",
        "1818" => "Cycling Power",

        # Location
        "1819" => "Location and Navigation",

        # Environmental / Body
        "181a" => "Environmental Sensing",
        "181b" => "Body Composition",
        "181c" => "User Data",
        "181d" => "Weight Scale",

        # Bond Management
        "181e" => "Bond Management",

        # Continuous Glucose
        "181f" => "Continuous Glucose Monitoring",

        # Internet / Indoor
        "1820" => "Internet Protocol Support",
        "1821" => "Indoor Positioning",

        # Pulse Oximeter
        "1822" => "Pulse Oximeter",

        # HTTP / Transport
        "1823" => "HTTP Proxy",
        "1824" => "Transport Discovery",

        # Object Transfer
        "1825" => "Object Transfer",

        # Fitness
        "1826" => "Fitness Machine",

        # Mesh
        "1827" => "Mesh Provisioning",
        "1828" => "Mesh Proxy",

        # Reconnection
        "1829" => "Reconnection Configuration",

        # Insulin
        "183a" => "Insulin Delivery",

        # Binary Sensor
        "183b" => "Binary Sensor",

        # Emergency
        "183c" => "Emergency Configuration",

        # Physical Activity
        "183e" => "Physical Activity Monitor",

        # Audio / Volume / Media (LE Audio)
        "1843" => "Audio Input Control",
        "1844" => "Volume Control",
        "1845" => "Volume Offset Control",
        "1846" => "Coordinated Set Identification",
        "1847" => "Device Time",
        "1848" => "Media Control",
        "1849" => "Generic Media Control",
        "184a" => "Constant Tone Extension",
        "184b" => "Telephone Bearer",
        "184c" => "Generic Telephone Bearer",
        "184d" => "Microphone Control",
        "184e" => "Audio Stream Control",
        "184f" => "Broadcast Audio Scan",
        "1850" => "Published Audio Capabilities",
        "1851" => "Basic Audio Announcement",
        "1852" => "Broadcast Audio Announcement",
        "1853" => "Common Audio",
        "1854" => "Hearing Access",
        "1855" => "Telephony and Media Audio",
        "1856" => "Public Broadcast Announcement",
        "1857" => "Electronic Shelf Label",
        "1858" => "Gaming Audio",
        "1859" => "Mesh Proxy Solicitation",

        # Vendor: Nordic UART Service
        "6e400001-b5a3-f393-e0a9-e50e24dcca9e" => "Nordic UART Service",

        # Vendor: Nordic DFU (Device Firmware Update)
        "00001530-1212-efde-1523-785feabcd123" => "Nordic DFU",

        # Vendor: Apple ANCS (Apple Notification Center Service)
        "7905f431-b5ce-4e99-a40f-4b1e122d00d0" => "Apple ANCS",

        # Vendor: Apple AMS (Apple Media Service)
        "89d3502b-0f36-433a-8ef4-c502ad55f8dc" => "Apple AMS",

        # Vendor: Google Eddystone
        "feaa" => "Google Eddystone",

        # Vendor: Google Fast Pair
        "fe2c" => "Google Fast Pair",

        # Vendor: TI OAD (Over-the-Air Download)
        "f000ffc0-0451-4000-b000-000000000000" => "TI OAD",

        # Vendor: Exposure Notification (COVID-19)
        "fd6f" => "Exposure Notification",
      }.freeze

      # Bluetooth SIG Assigned Characteristics + common vendor characteristics
      # Standard UUIDs keyed by short 4-char hex (lowercase)
      # Vendor UUIDs keyed by full 128-bit UUID (lowercase)
      CHARACTERISTICS = {
        # GAP Characteristics
        "2a00" => "Device Name",
        "2a01" => "Appearance",
        "2a02" => "Peripheral Privacy Flag",
        "2a03" => "Reconnection Address",
        "2a04" => "Peripheral Preferred Connection Parameters",
        "2a05" => "Service Changed",

        # Alert / Tx Power
        "2a06" => "Alert Level",
        "2a07" => "Tx Power Level",

        # Date / Time
        "2a08" => "Date Time",
        "2a09" => "Day of Week",
        "2a0a" => "Day Date Time",

        # Temperature
        "2a1c" => "Temperature Measurement",
        "2a1d" => "Temperature Type",
        "2a1e" => "Intermediate Temperature",

        # Glucose
        "2a18" => "Glucose Measurement",

        # Battery
        "2a19" => "Battery Level",

        # Measurement Interval
        "2a21" => "Measurement Interval",

        # Boot Keyboard / Mouse
        "2a22" => "Boot Keyboard Input Report",

        # Device Information
        "2a23" => "System ID",
        "2a24" => "Model Number String",
        "2a25" => "Serial Number String",
        "2a26" => "Firmware Revision String",
        "2a27" => "Hardware Revision String",
        "2a28" => "Software Revision String",
        "2a29" => "Manufacturer Name String",
        "2a2a" => "IEEE Regulatory Certification Data List",

        # Current Time
        "2a2b" => "Current Time",

        # Scan
        "2a31" => "Scan Refresh",

        # Boot Keyboard / Mouse (continued)
        "2a32" => "Boot Keyboard Output Report",
        "2a33" => "Boot Mouse Input Report",

        # Blood Pressure
        "2a35" => "Blood Pressure Measurement",
        "2a36" => "Intermediate Cuff Pressure",

        # Heart Rate
        "2a37" => "Heart Rate Measurement",
        "2a38" => "Body Sensor Location",
        "2a39" => "Heart Rate Control Point",

        # Alert Status / Ringer
        "2a3f" => "Alert Status",
        "2a40" => "Ringer Control Point",
        "2a41" => "Ringer Setting",
        "2a42" => "Alert Category ID Bit Mask",
        "2a43" => "Alert Category ID",
        "2a44" => "Alert Notification Control Point",
        "2a45" => "Unread Alert Status",
        "2a46" => "New Alert",
        "2a47" => "Supported New Alert Category",
        "2a48" => "Supported Unread Alert Category",

        # Blood Pressure Feature
        "2a49" => "Blood Pressure Feature",

        # HID
        "2a4a" => "HID Information",
        "2a4b" => "Report Map",
        "2a4c" => "HID Control Point",
        "2a4d" => "Report",
        "2a4e" => "Protocol Mode",

        # PnP ID
        "2a50" => "PnP ID",

        # Glucose Feature
        "2a51" => "Glucose Feature",

        # Running Speed and Cadence
        "2a53" => "RSC Measurement",
        "2a54" => "RSC Feature",
        "2a55" => "SC Control Point",

        # Cycling Speed and Cadence
        "2a5b" => "CSC Measurement",
        "2a5c" => "CSC Feature",
        "2a5d" => "Sensor Location",

        # Cycling Power
        "2a63" => "Cycling Power Measurement",
        "2a65" => "Cycling Power Feature",
        "2a66" => "Cycling Power Control Point",

        # Location and Navigation
        "2a67" => "Location and Speed",
        "2a68" => "Navigation",
        "2a6a" => "LN Feature",
        "2a6b" => "LN Control Point",

        # Environmental Sensing
        "2a6c" => "Elevation",
        "2a6d" => "Pressure",
        "2a6e" => "Temperature",
        "2a6f" => "Humidity",
        "2a70" => "True Wind Speed",
        "2a72" => "Apparent Wind Speed",
        "2a75" => "Pollen Concentration",
        "2a76" => "UV Index",
        "2a77" => "Irradiance",
        "2a78" => "Rainfall",
        "2a79" => "Wind Chill",

        # Fitness Machine
        "2acc" => "Fitness Machine Feature",
        "2acd" => "Treadmill Data",
        "2ad2" => "Indoor Bike Data",
        "2ad3" => "Training Status",
        "2ad4" => "Supported Speed Range",
        "2ad6" => "Supported Resistance Level Range",

        # Vendor: Nordic UART
        "6e400002-b5a3-f393-e0a9-e50e24dcca9e" => "Nordic UART RX",
        "6e400003-b5a3-f393-e0a9-e50e24dcca9e" => "Nordic UART TX",

        # Vendor: Nordic DFU
        "00001531-1212-efde-1523-785feabcd123" => "Nordic DFU Control Point",
        "00001532-1212-efde-1523-785feabcd123" => "Nordic DFU Packet",
      }.freeze

      # Bluetooth SIG Assigned Descriptors
      # Standard UUIDs keyed by short 4-char hex (lowercase)
      DESCRIPTORS = {
        "2900" => "Characteristic Extended Properties",
        "2901" => "Characteristic User Description",
        "2902" => "Client Characteristic Configuration",
        "2903" => "Server Characteristic Configuration",
        "2904" => "Characteristic Presentation Format",
        "2905" => "Characteristic Aggregate Format",
        "2906" => "Valid Range",
        "2907" => "External Report Reference",
        "2908" => "Report Reference",
        "2909" => "Number of Digitals",
        "290a" => "Value Trigger Setting",
        "290b" => "Environmental Sensing Configuration",
        "290c" => "Environmental Sensing Measurement",
        "290d" => "Environmental Sensing Trigger Setting",
        "290e" => "Time Trigger Setting",
      }.freeze

      # Bluetooth Base UUID pattern for standard 16-bit UUIDs
      BLUETOOTH_BASE_UUID_RE = /\A0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb\z/i

      # Short UUID pattern (4-char hex)
      SHORT_UUID_RE = /\A[0-9a-f]{4}\z/i

      # Mapping from type symbols to hash constants
      TYPE_MAP = {
        service: SERVICES,
        characteristic: CHARACTERISTICS,
        descriptor: DESCRIPTORS,
      }.freeze

      # Resolve a UUID to a human-readable name.
      #
      # @param uuid [String] UUID to resolve (short 4-char hex or full 128-bit)
      # @param type [Symbol, nil] :service, :characteristic, :descriptor, or nil for all
      # @return [String, nil] Human-readable name, or nil if unknown
      def self.resolve(uuid, type: nil)
        short = extract_short_uuid(uuid)

        if type
          db = TYPE_MAP[type]
          return nil unless db

          db[short]
        else
          # Search all databases in order: services, characteristics, descriptors
          SERVICES[short] || CHARACTERISTICS[short] || DESCRIPTORS[short]
        end
      end

      # Extract the short 4-char UUID from a standard Bluetooth Base UUID.
      # Returns the full UUID unchanged if it is not in the Bluetooth Base range.
      #
      # @param uuid [String] UUID to extract from
      # @return [String] Short UUID (lowercase) or full UUID (lowercase)
      def self.extract_short_uuid(uuid)
        downcased = uuid.downcase
        if (match = BLUETOOTH_BASE_UUID_RE.match(downcased))
          match[1]
        elsif SHORT_UUID_RE.match?(downcased)
          downcased
        else
          downcased
        end
      end

      # Check if a UUID is in the standard Bluetooth SIG range.
      #
      # @param uuid [String] UUID to check
      # @return [Boolean] true if standard (short 4-char hex or Bluetooth Base UUID)
      def self.standard_uuid?(uuid)
        downcased = uuid.downcase
        SHORT_UUID_RE.match?(downcased) || BLUETOOTH_BASE_UUID_RE.match?(downcased)
      end
    end
  end
end
