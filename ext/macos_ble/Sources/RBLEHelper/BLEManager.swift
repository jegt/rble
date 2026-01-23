import Foundation
import CoreBluetooth

// MARK: - BLEManager

/// CoreBluetooth wrapper that manages Bluetooth scanning and device discovery.
/// This class handles all interaction with CoreBluetooth and emits events via the onEvent callback.
class BLEManager: NSObject, CBCentralManagerDelegate {
    private var centralManager: CBCentralManager!
    private var isScanning = false
    private var allowDuplicates = false
    private var serviceUUIDs: [CBUUID]?

    /// Callback to send events to stdout
    var onEvent: ((Event) -> Void)?

    override init() {
        super.init()
        // Create manager on main queue for delegate callbacks
        // nil queue = main queue, which is required for proper delegate callback handling
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public Methods

    /// Start scanning for BLE peripherals
    /// - Parameters:
    ///   - serviceUUIDs: Optional array of service UUID strings to filter by
    ///   - allowDuplicates: If true, receive repeated advertisements from the same device
    /// - Throws: BLEError.notPoweredOn if Bluetooth is not enabled
    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool) throws {
        guard centralManager.state == .poweredOn else {
            throw BLEError.notPoweredOn
        }

        self.allowDuplicates = allowDuplicates
        self.serviceUUIDs = serviceUUIDs?.map { CBUUID(string: $0) }

        var options: [String: Any] = [:]
        if allowDuplicates {
            options[CBCentralManagerScanOptionAllowDuplicatesKey] = true
        }

        centralManager.scanForPeripherals(
            withServices: self.serviceUUIDs,
            options: options
        )
        isScanning = true
    }

    /// Stop scanning for BLE peripherals
    func stopScan() {
        centralManager.stopScan()
        isScanning = false
    }

    /// Get current Bluetooth adapter state as a string
    /// - Returns: String representation of the Bluetooth state
    func getState() -> String {
        switch centralManager.state {
        case .unknown: return "unknown"
        case .resetting: return "resetting"
        case .unsupported: return "unsupported"
        case .unauthorized: return "unauthorized"
        case .poweredOff: return "powered_off"
        case .poweredOn: return "powered_on"
        @unknown default: return "unknown"
        }
    }

    /// Check if Bluetooth is currently powered on
    var isPoweredOn: Bool {
        return centralManager.state == .poweredOn
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let event = Event(
            method: "state_changed",
            params: ["state": AnyCodable(getState())]
        )
        onEvent?(event)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Build device info dictionary
        var params: [String: AnyCodable] = [
            "uuid": AnyCodable(peripheral.identifier.uuidString),
            "rssi": AnyCodable(RSSI.intValue)
        ]

        // Add device name if available (from peripheral or advertisement data)
        if let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String {
            params["name"] = AnyCodable(name)
        }

        // Parse advertised service UUIDs
        if let advertServiceUUIDs = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            params["service_uuids"] = AnyCodable(advertServiceUUIDs.map { $0.uuidString })
        }

        // Parse manufacturer data
        // First 2 bytes are company ID (little-endian), rest is payload
        if let mfgData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            if mfgData.count >= 2 {
                let companyId = UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8)
                let dataBytes = Array(mfgData.dropFirst(2))
                params["manufacturer_data"] = AnyCodable([
                    "company_id": companyId,
                    "data": dataBytes
                ])
            }
        }

        // Parse service data (map of service UUID -> data bytes)
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var sdDict: [String: [UInt8]] = [:]
            for (uuid, data) in serviceData {
                sdDict[uuid.uuidString] = Array(data)
            }
            params["service_data"] = AnyCodable(sdDict)
        }

        // Tx power level if advertised
        if let txPower = advertisementData[CBAdvertisementDataTxPowerLevelKey] as? NSNumber {
            params["tx_power"] = AnyCodable(txPower.intValue)
        }

        // Connectable status if available
        if let connectable = advertisementData[CBAdvertisementDataIsConnectable] as? NSNumber {
            params["connectable"] = AnyCodable(connectable.boolValue)
        }

        let event = Event(method: "device_discovered", params: params)
        onEvent?(event)
    }
}

// MARK: - BLE Errors

/// Errors specific to BLE operations
enum BLEError: Error {
    case notPoweredOn
    case notConnected
    case timeout
    case invalidUUID(String)

    var localizedDescription: String {
        switch self {
        case .notPoweredOn:
            return "Bluetooth not powered on"
        case .notConnected:
            return "Not connected to device"
        case .timeout:
            return "Operation timed out"
        case .invalidUUID(let uuid):
            return "Invalid UUID: \(uuid)"
        }
    }
}

// MARK: - BLE Error Codes (for JSON-RPC responses)

/// Application-specific error codes (outside JSON-RPC reserved range)
enum BLEErrorCode {
    static let notPoweredOn = -1
    static let notConnected = -2
    static let timeout = -3
    static let invalidUUID = -4
    static let operationFailed = -5
}
