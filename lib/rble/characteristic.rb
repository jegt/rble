# frozen_string_literal: true

module RBLE
  # Immutable representation of a GATT characteristic
  #
  # @!attribute uuid [String] Characteristic UUID (128-bit format)
  # @!attribute flags [Array<String>] Capability flags: "read", "write", "write-without-response", "notify", "indicate"
  # @!attribute service_uuid [String] Parent service UUID
  Characteristic = Data.define(:uuid, :flags, :service_uuid) do
    def initialize(uuid:, flags: [], service_uuid: nil)
      super
    end

    # Get short UUID for standard characteristics
    def short_uuid
      if uuid =~ /^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/i
        Regexp.last_match(1).downcase
      else
        uuid
      end
    end

    # Check if characteristic supports reading
    def readable?
      flags.include?('read')
    end

    # Check if characteristic supports writing with response
    def writable?
      flags.include?('write')
    end

    # Check if characteristic supports writing without response
    def writable_without_response?
      flags.include?('write-without-response')
    end

    # Check if characteristic supports notifications
    def notifiable?
      flags.include?('notify')
    end

    # Check if characteristic supports indications
    def indicatable?
      flags.include?('indicate')
    end

    # Check if characteristic supports any form of subscription
    def subscribable?
      notifiable? || indicatable?
    end
  end
end
