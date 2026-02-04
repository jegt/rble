# frozen_string_literal: true

require "spec_helper"
require "rble/backend/corebluetooth"

RSpec.describe RBLE::Backend::CoreBluetooth, "error mapping" do
  # Use allocate to skip initialize (avoids subprocess startup)
  subject(:backend) { described_class.allocate }

  def error_response(message, platform_error: nil)
    error = { 'message' => message }
    error['data'] = { 'platform_error' => platform_error } if platform_error
    { error: error }
  end

  def handle(response)
    backend.send(:handle_response_error, response)
  end

  describe "#handle_response_error" do
    it "raises BluetoothOffError for 'not powered on'" do
      expect { handle(error_response("not powered on")) }
        .to raise_error(RBLE::BluetoothOffError)
    end

    it "raises PermissionError for 'unauthorized'" do
      expect { handle(error_response("Unauthorized access")) }
        .to raise_error(RBLE::PermissionError)
    end

    it "raises NotConnectedError for 'not connected'" do
      expect { handle(error_response("Device not connected")) }
        .to raise_error(RBLE::NotConnectedError)
    end

    it "raises DeviceNotFoundError for 'device not found'" do
      expect { handle(error_response("device not found")) }
        .to raise_error(RBLE::DeviceNotFoundError)
    end

    it "raises DeviceNotFoundError for 'no peripheral'" do
      expect { handle(error_response("no peripheral with that UUID")) }
        .to raise_error(RBLE::DeviceNotFoundError)
    end

    it "raises DeviceNotFoundError for 'unknown device'" do
      expect { handle(error_response("unknown device identifier")) }
        .to raise_error(RBLE::DeviceNotFoundError)
    end

    it "raises ConnectionFailed for 'connection failed'" do
      expect { handle(error_response("connection failed")) }
        .to raise_error(RBLE::ConnectionFailed)
    end

    it "raises ConnectionFailed for 'connection refused'" do
      expect { handle(error_response("connection refused by device")) }
        .to raise_error(RBLE::ConnectionFailed)
    end

    it "raises ConnectionTimeoutError for 'connection timeout'" do
      expect { handle(error_response("connection timeout")) }
        .to raise_error(RBLE::ConnectionTimeoutError)
    end

    it "raises ConnectionTimeoutError for 'timed out'" do
      expect { handle(error_response("operation timed out")) }
        .to raise_error(RBLE::ConnectionTimeoutError)
    end

    it "raises ServiceDiscoveryError for 'service discovery failed'" do
      expect { handle(error_response("service discovery failed")) }
        .to raise_error(RBLE::ServiceDiscoveryError)
    end

    it "raises ServiceDiscoveryError for 'discover fail'" do
      expect { handle(error_response("failed to discover services")) }
        .to raise_error(RBLE::ServiceDiscoveryError)
    end

    it "raises CharacteristicNotFoundError for 'characteristic not found'" do
      expect { handle(error_response("characteristic not found")) }
        .to raise_error(RBLE::CharacteristicNotFoundError)
    end

    it "raises generic RBLE::Error for unknown messages" do
      expect { handle(error_response("something unexpected")) }
        .to raise_error(RBLE::Error, "something unexpected")
    end

    it "includes platform_error in message" do
      expect { handle(error_response("not connected", platform_error: "CBError 7")) }
        .to raise_error(RBLE::NotConnectedError, /CBError 7/)
    end
  end

  describe "#translate_error" do
    def translate(message)
      error = StandardError.new(message)
      backend.send(:translate_error, error)
    end

    it "raises NotConnectedError for 'not connected'" do
      expect { translate("not connected") }
        .to raise_error(RBLE::NotConnectedError)
    end

    it "raises CharacteristicNotFoundError for 'characteristic not found'" do
      expect { translate("characteristic not found") }
        .to raise_error(RBLE::CharacteristicNotFoundError)
    end

    it "raises ConnectionTimeoutError for 'timeout'" do
      expect { translate("operation timeout") }
        .to raise_error(RBLE::ConnectionTimeoutError)
    end

    it "returns message string for unknown errors" do
      result = translate("some unknown error")
      expect(result).to eq("some unknown error")
    end
  end
end
