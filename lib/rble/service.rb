# frozen_string_literal: true

module RBLE
  # Immutable representation of a GATT service
  #
  # @!attribute uuid [String] Service UUID (128-bit format: "0000180d-0000-1000-8000-00805f9b34fb")
  # @!attribute primary [Boolean] True if primary service, false if secondary
  # @!attribute characteristics [Array<Characteristic>] Characteristics in this service
  Service = Data.define(:uuid, :primary, :characteristics) do
    def initialize(uuid:, primary: true, characteristics: [])
      super
    end

    # Get short UUID for standard services (e.g., "180d" from full UUID)
    def short_uuid
      if uuid =~ /^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/i
        Regexp.last_match(1).downcase
      else
        uuid
      end
    end

    # Find a characteristic by UUID (supports short UUID like "2a37")
    # @param char_uuid [String] UUID to find
    # @return [Characteristic, nil]
    def characteristic(char_uuid)
      normalized = normalize_uuid(char_uuid)
      characteristics.find { |c| c.uuid.downcase == normalized || c.short_uuid == char_uuid.downcase }
    end

    private

    def normalize_uuid(short_uuid)
      if short_uuid.length == 4
        "0000#{short_uuid.downcase}-0000-1000-8000-00805f9b34fb"
      else
        short_uuid.downcase
      end
    end
  end
end
