# frozen_string_literal: true

require 'dbus'

module RBLE
  module BlueZ
    # D-Bus object implementing the org.bluez.Agent1 interface for BLE pairing.
    #
    # BlueZ invokes Agent1 methods during pairing to handle security prompts
    # (PIN entry, passkey confirmation, authorization). This class exports those
    # methods on the system bus so BlueZ can call back into the Ruby process.
    #
    # @example
    #   agent = PairingAgent.new(io_handler: handler, force: false)
    #   bus.object_server.export(agent)
    #
    class PairingAgent < DBus::Object
      AGENT_INTERFACE = 'org.bluez.Agent1'
      AGENT_PATH = '/org/rble/agent'

      # @param io_handler [#display, #prompt, #confirm] IO handler for user interaction
      # @param force [Boolean] Skip interactive prompts (auto-accept)
      def initialize(io_handler:, force: false)
        super(AGENT_PATH)
        @io_handler = io_handler
        @force = force
      end

      dbus_interface AGENT_INTERFACE do
        # Called when the agent is unregistered
        dbus_method :Release do
          # no-op
        end

        # Request a PIN code from the user
        # @param device [String] D-Bus object path of the device
        # @return [String] PIN code
        dbus_method :RequestPinCode, 'in device:o, out pincode:s' do |device|
          if @force
            @io_handler.display("Auto-accepting PIN for #{device_label(device)}")
            ['0000']
          else
            pin = @io_handler.prompt("Enter PIN for #{device_label(device)}: ")
            [pin.to_s.strip]
          end
        end

        # Display a PIN code to the user
        # @param device [String] D-Bus object path of the device
        # @param pincode [String] PIN code to display
        dbus_method :DisplayPinCode, 'in device:o, in pincode:s' do |device, pincode|
          @io_handler.display("PIN for #{device_label(device)}: #{pincode}")
        end

        # Request a passkey (numeric) from the user
        # @param device [String] D-Bus object path of the device
        # @return [Integer] Passkey (0-999999)
        dbus_method :RequestPasskey, 'in device:o, out passkey:u' do |device|
          if @force
            @io_handler.display("Auto-accepting passkey for #{device_label(device)}")
            [0]
          else
            input = @io_handler.prompt("Enter passkey (0-999999) for #{device_label(device)}: ")
            passkey = input.to_s.strip.to_i
            passkey = passkey.clamp(0, 999_999)
            [passkey]
          end
        end

        # Display a passkey with the number of digits entered so far
        # @param device [String] D-Bus object path of the device
        # @param passkey [Integer] Passkey being entered
        # @param entered [Integer] Number of digits entered
        dbus_method :DisplayPasskey, 'in device:o, in passkey:u, in entered:q' do |device, passkey, entered|
          @io_handler.display("Passkey for #{device_label(device)}: #{format('%06d', passkey)} (#{entered} digits entered)")
        end

        # Request confirmation of a passkey
        # @param device [String] D-Bus object path of the device
        # @param passkey [Integer] Passkey to confirm
        dbus_method :RequestConfirmation, 'in device:o, in passkey:u' do |device, passkey|
          if @force
            @io_handler.display("Auto-confirming passkey #{format('%06d', passkey)} for #{device_label(device)}")
          else
            accepted = @io_handler.confirm("Confirm passkey #{format('%06d', passkey)} for #{device_label(device)}? [Y/n] ")
            unless accepted
              raise DBus.error('org.bluez.Error.Rejected'), "Passkey rejected by user for #{device_label(device)}"
            end
          end
        end

        # Request authorization for the device
        # @param device [String] D-Bus object path of the device
        dbus_method :RequestAuthorization, 'in device:o' do |device|
          if @force
            @io_handler.display("Auto-authorizing #{device_label(device)}")
          else
            accepted = @io_handler.confirm("Authorize #{device_label(device)}? [Y/n] ")
            unless accepted
              raise DBus.error('org.bluez.Error.Rejected'), "Authorization rejected by user for #{device_label(device)}"
            end
          end
        end

        # Authorize a service (auto-authorize, no prompt needed)
        # @param device [String] D-Bus object path of the device
        # @param uuid [String] Service UUID
        dbus_method :AuthorizeService, 'in device:o, in uuid:s' do |device, uuid|
          @io_handler.display("Authorizing service #{uuid} for #{device_label(device)}")
        end

        # Called when a pairing request is cancelled
        dbus_method :Cancel do
          @io_handler.display('Pairing cancelled')
        end
      end

      private

      # Extract a human-readable label from a D-Bus device path
      # @param device_path [String] D-Bus object path like /org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF
      # @return [String] MAC address or the raw path
      def device_label(device_path)
        if device_path =~ /dev_([0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2}_[0-9A-F]{2})/i
          ::Regexp.last_match(1).tr('_', ':')
        else
          device_path
        end
      end
    end
  end
end
