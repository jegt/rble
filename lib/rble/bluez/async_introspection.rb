# frozen_string_literal: true

require 'dbus'
require 'securerandom'
require_relative 'async_call'

module RBLE
  module BlueZ
    # Provides async D-Bus introspection with caching.
    # Use this to introspect D-Bus objects without blocking the event loop.
    #
    # This module builds on AsyncCall to provide async introspection and
    # GetManagedObjects calls. Results are cached for session lifetime.
    #
    # @example
    #   include AsyncCall
    #   include AsyncIntrospection
    #
    #   proxy = async_introspect("/org/bluez/hci0/dev_AA_BB_CC_DD_EE_FF")
    #   managed = async_get_managed_objects
    #
    module AsyncIntrospection
      # Stub - tests should fail
    end
  end
end
