# frozen_string_literal: true

begin
  require 'dbus'
rescue LoadError
  raise LoadError,
    "The ruby-dbus gem is required for the BlueZ backend on Linux. " \
    "Install it with: gem install ruby-dbus"
end

module RBLE
  module BlueZ
    BLUEZ_SERVICE = 'org.bluez'
    ADAPTER_INTERFACE = 'org.bluez.Adapter1'
    DEVICE_INTERFACE = 'org.bluez.Device1'
    GATT_SERVICE_INTERFACE = 'org.bluez.GattService1'
    GATT_CHARACTERISTIC_INTERFACE = 'org.bluez.GattCharacteristic1'
    GATT_DESCRIPTOR_INTERFACE = 'org.bluez.GattDescriptor1'
    PROPERTIES_INTERFACE = 'org.freedesktop.DBus.Properties'
    OBJECT_MANAGER_INTERFACE = 'org.freedesktop.DBus.ObjectManager'
    AGENT_MANAGER_INTERFACE = 'org.bluez.AgentManager1'
  end
end

require_relative 'bluez/dbus_connection'
require_relative 'bluez/adapter'
require_relative 'bluez/event_loop'
require_relative 'bluez/dbus_session'
require_relative 'bluez/device'
require_relative 'bluez/gatt_service'
require_relative 'bluez/gatt_operation_queue'
require_relative 'bluez/retry_policy'
require_relative 'bluez/pairing_agent'
require_relative 'bluez/pairing_session'
