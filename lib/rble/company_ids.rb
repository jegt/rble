# frozen_string_literal: true

module RBLE
  # Bluetooth SIG assigned Company Identifiers.
  # Used to identify device manufacturers from BLE advertisement data
  # when no device name is broadcast.
  #
  # Loaded on-demand (not auto-required by lib/rble.rb).
  # Use: require 'rble/company_ids'
  #
  # Source: Bluetooth SIG Assigned Numbers
  # https://www.bluetooth.com/specifications/assigned-numbers/
  #
  # @example Resolve a company ID
  #   RBLE::CompanyIdentifiers.resolve(0x004C) # => "Apple"
  module CompanyIdentifiers
    # Curated subset of ~80 common BLE device/chipset manufacturers.
    # Keys are 16-bit Company ID integers, values are short display names.
    COMPANIES = {
      0x0000 => "Ericsson",
      0x0001 => "Nokia",
      0x0002 => "Intel",
      0x0004 => "Toshiba",
      0x0006 => "Microsoft",
      0x0008 => "Motorola",
      0x000A => "Qualcomm",
      0x000D => "Texas Instruments",
      0x000F => "Broadcom",
      0x0022 => "NEC",
      0x0025 => "NXP",
      0x0030 => "ST Microelectronics",
      0x0034 => "Renesas",
      0x003A => "Panasonic",
      0x003C => "BlackBerry",
      0x0040 => "Seiko Epson",
      0x0043 => "Parrot",
      0x0046 => "MediaTek",
      0x0047 => "Bluegiga",
      0x0048 => "Marvell",
      0x004C => "Apple",
      0x004E => "Avago",
      0x0055 => "Plantronics",
      0x0057 => "Harman",
      0x0058 => "Vizio",
      0x0059 => "Nordic Semiconductor",
      0x005D => "Realtek",
      0x0065 => "HP",
      0x006B => "Polar",
      0x0075 => "Samsung",
      0x0076 => "Creative",
      0x0078 => "Nike",
      0x0087 => "Garmin",
      0x0094 => "Airoha",
      0x00C3 => "Adidas",
      0x00C4 => "LG Electronics",
      0x00E0 => "Google",
      0x0131 => "Cypress Semiconductor",
      0x0171 => "Amazon",
      0x018E => "Google",
      0x01AB => "Meta",
      0x01DA => "Logitech",
      0x01DD => "Philips",
      0x01D1 => "August Home",
      0x01FC => "Wahoo Fitness",
      0x027D => "Huawei",
      0x02E5 => "Espressif",
      0x02FF => "Silicon Labs",
      0x038F => "Xiaomi",
      0x03C1 => "Ember Technologies",
      0x03FF => "Withings",
      0x040F => "OnePlus",
      0x0499 => "Ruuvi Innovations",
      0x05A7 => "Sonos",
      0x060F => "Signify",
      0x067C => "Tile",
      0x0768 => "Peloton",
      0x07D0 => "Tuya",
      0x07D6 => "Ecobee",
      0x079A => "Roku",
    }.freeze

    # Resolve a company identifier to a human-readable name.
    #
    # @param company_id [Integer] 16-bit Bluetooth SIG Company Identifier
    # @return [String, nil] Company name, or nil if unknown
    def self.resolve(company_id)
      COMPANIES[company_id]
    end
  end
end
