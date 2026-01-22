# frozen_string_literal: true

require 'dbus'

module RBLE
  module BlueZ
    BLUEZ_SERVICE = 'org.bluez'
    ADAPTER_INTERFACE = 'org.bluez.Adapter1'
    DEVICE_INTERFACE = 'org.bluez.Device1'
    PROPERTIES_INTERFACE = 'org.freedesktop.DBus.Properties'
    OBJECT_MANAGER_INTERFACE = 'org.freedesktop.DBus.ObjectManager'
  end
end

require_relative 'bluez/dbus_connection'
require_relative 'bluez/adapter'
require_relative 'bluez/event_loop'
