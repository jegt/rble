# frozen_string_literal: true

require 'dbus'
require_relative 'async_call'
require_relative 'async_introspection'

module RBLE
  module BlueZ
    # Provides async GATT operations using AsyncCall + AsyncIntrospection patterns.
    # Use this to perform GATT read/write/notify operations without blocking the event loop.
    #
    # This module is part of the v0.4.0 async architecture. It builds on AsyncCall
    # and AsyncIntrospection to provide non-blocking GATT operations.
    #
    # Including class must:
    # - Include AsyncCall module (provides async_call method)
    # - Include AsyncIntrospection module (provides async_introspect method)
    # - Have @service attribute pointing to D-Bus service
    #
    # @example
    #   include AsyncCall
    #   include AsyncIntrospection
    #   include AsyncGattOperations
    #
    #   value = async_read_value("/org/bluez/hci0/.../char0011")
    #   async_write_value("/org/bluez/hci0/.../char0011", [0x01, 0x02])
    #   async_start_notify("/org/bluez/hci0/.../char0011")
    #   async_stop_notify("/org/bluez/hci0/.../char0011")
    #
    module AsyncGattOperations
      # Stub - will be implemented in GREEN phase
    end
  end
end
