# frozen_string_literal: true

module RBLE
  # Immutable snapshot of a discovered BLE device
  #
  # @!attribute address [String] MAC address (uppercase, colon-separated: "12:34:56:78:9A:BC")
  # @!attribute name [String, nil] Device local name from advertisement
  # @!attribute rssi [Integer, nil] Signal strength in dBm
  # @!attribute manufacturer_data [Hash{Integer => Array<Integer>}] Company ID => byte array
  # @!attribute manufacturer_data_raw [Hash{Integer => String}] Company ID => binary string
  # @!attribute service_data [Hash{String => Array<Integer>}] UUID => byte array
  # @!attribute service_uuids [Array<String>] Advertised service UUIDs
  # @!attribute tx_power [Integer, nil] Transmit power level in dBm
  # @!attribute address_type [String] "public" or "random"
  Device = Data.define(
    :address,
    :name,
    :rssi,
    :manufacturer_data,
    :manufacturer_data_raw,
    :service_data,
    :service_uuids,
    :tx_power,
    :address_type
  ) do
    def initialize(
      address:,
      name: nil,
      rssi: nil,
      manufacturer_data: {},
      manufacturer_data_raw: {},
      service_data: {},
      service_uuids: [],
      tx_power: nil,
      address_type: 'public'
    )
      super
    end

    # Create a new Device with updated attributes
    # @param attrs [Hash] attributes to update
    # @return [Device] new Device instance with updates
    def update(**attrs)
      with(**attrs)
    end

    # Get manufacturer data as a binary string for a given company ID
    # @param company_id [Integer] BLE company identifier (e.g., 0x0499 for Ruuvi)
    # @return [String, nil] Binary string (ASCII-8BIT) or nil if not present
    def manufacturer_data_bytes(company_id)
      manufacturer_data_raw[company_id]
    end
  end
end
