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
    private var reportedPeripherals: Set<String> = [] // Track already-reported UUIDs when !allowDuplicates

    // Peripheral tracking
    private var discoveredPeripherals: [String: CBPeripheral] = [:] // UUID -> peripheral
    private var connectedPeripherals: [String: CBPeripheral] = [:]
    private var pendingConnections: [String: (Result<Void, Error>) -> Void] = [:] // UUID -> completion
    private var pendingDisconnects: [String: () -> Void] = [:]

    // Service discovery tracking
    private var pendingServiceDiscovery: [String: (Result<Void, Error>) -> Void] = [:]
    private var pendingCharacteristicDiscovery: [String: Int] = [:] // UUID -> remaining services

    // GATT operation tracking
    private var pendingReads: [String: (Result<Data, Error>) -> Void] = [:] // deviceUUID:charUUID -> completion
    private var pendingWrites: [String: (Result<Void, Error>) -> Void] = [:]
    private var subscriptions: Set<String> = [] // deviceUUID:charUUID

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
        self.reportedPeripherals = [] // Reset for new scan

        let options: [String: Any] = [
            CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates
        ]

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

    /// Callback for state changes (used for waitForPoweredOn)
    private var stateChangeCallback: ((CBManagerState) -> Void)?

    /// Wait for Bluetooth to be powered on
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds
    ///   - completion: Called with true if powered on, false if timeout or not available
    func waitForPoweredOn(timeout: Int = 5, completion: @escaping (Bool) -> Void) {
        // Already powered on?
        if centralManager.state == .poweredOn {
            completion(true)
            return
        }

        // Already in a terminal non-powered state?
        if centralManager.state == .unsupported ||
           centralManager.state == .unauthorized ||
           centralManager.state == .poweredOff {
            completion(false)
            return
        }

        // Wait for state change
        var completed = false
        let timeoutWorkItem = DispatchWorkItem {
            if !completed {
                completed = true
                self.stateChangeCallback = nil
                completion(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

        stateChangeCallback = { newState in
            if !completed {
                if newState == .poweredOn {
                    completed = true
                    timeoutWorkItem.cancel()
                    self.stateChangeCallback = nil
                    completion(true)
                } else if newState == .unsupported || newState == .unauthorized || newState == .poweredOff {
                    completed = true
                    timeoutWorkItem.cancel()
                    self.stateChangeCallback = nil
                    completion(false)
                }
                // For .unknown or .resetting, keep waiting
            }
        }
    }

    /// Wait for Bluetooth state to be determined (not unknown or resetting)
    /// - Parameters:
    ///   - timeout: Maximum time to wait in seconds
    ///   - completion: Called with true if state is now known, false if timeout
    func waitForStateKnown(timeout: Int = 2, completion: @escaping (Bool) -> Void) {
        // Already in a known state?
        let state = centralManager.state
        if state != .unknown && state != .resetting {
            completion(true)
            return
        }

        // Wait for state change
        var completed = false
        let timeoutWorkItem = DispatchWorkItem {
            if !completed {
                completed = true
                self.stateChangeCallback = nil
                completion(false)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

        stateChangeCallback = { newState in
            if !completed && newState != .unknown && newState != .resetting {
                completed = true
                timeoutWorkItem.cancel()
                self.stateChangeCallback = nil
                completion(true)
            }
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        // Notify any waiters
        stateChangeCallback?(central.state)

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
        let uuid = peripheral.identifier.uuidString.uppercased()

        // Store discovered peripheral for later connection
        discoveredPeripherals[uuid] = peripheral

        // When allowDuplicates is false, only report each peripheral once
        if !allowDuplicates {
            if reportedPeripherals.contains(uuid) {
                return // Already reported this peripheral
            }
            reportedPeripherals.insert(uuid)
        }

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
                let companyId = Int(UInt16(mfgData[0]) | (UInt16(mfgData[1]) << 8))
                let dataBytes = Array(mfgData.dropFirst(2)).map { Int($0) }
                params["manufacturer_data"] = AnyCodable([
                    "company_id": companyId,
                    "data": dataBytes
                ])
            }
        }

        // Parse service data (map of service UUID -> data bytes)
        if let serviceData = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var sdDict: [String: [Int]] = [:]
            for (uuid, data) in serviceData {
                sdDict[uuid.uuidString] = Array(data).map { Int($0) }
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

    // MARK: - CBCentralManagerDelegate - Connection

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let uuid = peripheral.identifier.uuidString.uppercased()
        connectedPeripherals[uuid] = peripheral
        peripheral.delegate = self

        // Notify pending connection
        if let completion = pendingConnections.removeValue(forKey: uuid) {
            completion(.success(()))
        }

        // Emit event
        let event = Event(method: "connected", params: ["uuid": AnyCodable(uuid)])
        onEvent?(event)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let uuid = peripheral.identifier.uuidString.uppercased()
        if let completion = pendingConnections.removeValue(forKey: uuid) {
            completion(.failure(error ?? BLEError.connectionFailed))
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let uuid = peripheral.identifier.uuidString.uppercased()
        connectedPeripherals.removeValue(forKey: uuid)

        // Map error to reason
        let reason = mapDisconnectReason(error)

        if let completion = pendingDisconnects.removeValue(forKey: uuid) {
            completion()
        }

        let event = Event(method: "disconnected", params: [
            "uuid": AnyCodable(uuid),
            "reason": AnyCodable(reason),
            "error": AnyCodable(error?.localizedDescription as Any)
        ])
        onEvent?(event)
    }

    // MARK: - Disconnect Reason Mapping

    /// Map CoreBluetooth error to disconnect reason string
    /// - Parameter error: The error from didDisconnectPeripheral
    /// - Returns: String reason for disconnect event
    private func mapDisconnectReason(_ error: Error?) -> String {
        guard let error = error else {
            return "user_requested"
        }

        if let cbError = error as? CBError {
            switch cbError.code {
            case .connectionTimeout:
                return "timeout"
            case .peripheralDisconnected:
                return "remote_disconnect"
            case .connectionFailed:
                return "connection_failed"
            default:
                return "unknown"
            }
        }

        // Check for NSError with CoreBluetooth domain
        let nsError = error as NSError
        if nsError.domain == CBErrorDomain {
            switch nsError.code {
            case 6:  // CBErrorConnectionTimeout
                return "timeout"
            case 7:  // CBErrorPeripheralDisconnected
                return "remote_disconnect"
            default:
                return "unknown"
            }
        }

        // Generic error - likely link loss
        return "link_loss"
    }

    // MARK: - Connection Methods

    /// Connect to a peripheral by UUID
    /// - Parameters:
    ///   - uuid: The peripheral's UUID string
    ///   - completion: Callback with success/failure result
    func connect(uuid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        // Normalize UUID to uppercase for consistent lookup
        let normalizedUUID = uuid.uppercased()

        guard let peripheral = discoveredPeripherals[normalizedUUID] else {
            completion(.failure(BLEError.deviceNotFound))
            return
        }

        guard centralManager.state == .poweredOn else {
            completion(.failure(BLEError.notPoweredOn))
            return
        }

        pendingConnections[normalizedUUID] = completion
        centralManager.connect(peripheral, options: nil)
    }

    /// Disconnect from a peripheral
    /// - Parameters:
    ///   - uuid: The peripheral's UUID string
    ///   - completion: Callback when disconnection completes
    func disconnect(uuid: String, completion: @escaping () -> Void) {
        let normalizedUUID = uuid.uppercased()
        guard let peripheral = connectedPeripherals[normalizedUUID] else {
            completion()
            return
        }

        pendingDisconnects[normalizedUUID] = completion
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// Check if a peripheral is connected
    /// - Parameter uuid: The peripheral's UUID string
    /// - Returns: True if connected
    func isConnected(uuid: String) -> Bool {
        return connectedPeripherals[uuid.uppercased()] != nil
    }

    // MARK: - GATT Operations

    /// Normalize a UUID, converting 4-character short UUIDs to full 128-bit format
    /// - Parameter uuid: The UUID string (either 4-char short or full 128-bit)
    /// - Returns: The full 128-bit UUID string
    private func normalizeUUID(_ uuid: String) -> String {
        if uuid.count == 4 {
            return "0000\(uuid.uppercased())-0000-1000-8000-00805F9B34FB"
        }
        return uuid.uppercased()
    }

    /// Find a characteristic by device, service, and characteristic UUIDs
    /// - Parameters:
    ///   - deviceUUID: The peripheral's UUID string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    /// - Returns: The CBCharacteristic if found, nil otherwise
    func findCharacteristic(deviceUUID: String, serviceUUID: String, charUUID: String) -> CBCharacteristic? {
        let normalizedDeviceUUID = deviceUUID.uppercased()
        guard let peripheral = connectedPeripherals[normalizedDeviceUUID],
              let services = peripheral.services else {
            return nil
        }

        // Find service (support both full and short UUID)
        // Normalize both input UUID and CoreBluetooth UUID to full form for comparison
        let normalizedServiceUUID = normalizeUUID(serviceUUID)
        guard let service = services.first(where: {
            normalizeUUID($0.uuid.uuidString) == normalizedServiceUUID
        }) else {
            return nil
        }

        // Find characteristic
        // Normalize both input UUID and CoreBluetooth UUID to full form for comparison
        let normalizedCharUUID = normalizeUUID(charUUID)
        return service.characteristics?.first(where: {
            normalizeUUID($0.uuid.uuidString) == normalizedCharUUID
        })
    }

    /// Read a characteristic value
    /// - Parameters:
    ///   - deviceUUID: The peripheral's UUID string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    ///   - completion: Callback with the read data or error
    func readCharacteristic(
        deviceUUID: String,
        serviceUUID: String,
        charUUID: String,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        let normalizedDeviceUUID = deviceUUID.uppercased()
        guard let peripheral = connectedPeripherals[normalizedDeviceUUID] else {
            completion(.failure(BLEError.notConnected))
            return
        }

        guard let characteristic = findCharacteristic(
            deviceUUID: deviceUUID,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }

        let key = "\(normalizedDeviceUUID):\(characteristic.uuid.uuidString.uppercased())"
        pendingReads[key] = completion
        peripheral.readValue(for: characteristic)
    }

    /// Write a value to a characteristic
    /// - Parameters:
    ///   - deviceUUID: The peripheral's UUID string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    ///   - data: The data to write
    ///   - withResponse: Whether to request a write response from the peripheral
    ///   - completion: Callback with success or error
    func writeCharacteristic(
        deviceUUID: String,
        serviceUUID: String,
        charUUID: String,
        data: Data,
        withResponse: Bool,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let normalizedDeviceUUID = deviceUUID.uppercased()
        guard let peripheral = connectedPeripherals[normalizedDeviceUUID] else {
            completion(.failure(BLEError.notConnected))
            return
        }

        guard let characteristic = findCharacteristic(
            deviceUUID: deviceUUID,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }

        let writeType: CBCharacteristicWriteType = withResponse ? .withResponse : .withoutResponse

        if withResponse {
            let key = "\(normalizedDeviceUUID):\(characteristic.uuid.uuidString.uppercased())"
            pendingWrites[key] = completion
        }

        peripheral.writeValue(data, for: characteristic, type: writeType)

        if !withResponse {
            // No response expected, complete immediately
            completion(.success(()))
        }
    }

    /// Subscribe to notifications for a characteristic
    /// - Parameters:
    ///   - deviceUUID: The peripheral's UUID string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    ///   - completion: Callback when subscription is confirmed or fails
    func subscribe(
        deviceUUID: String,
        serviceUUID: String,
        charUUID: String,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let normalizedDeviceUUID = deviceUUID.uppercased()
        guard let peripheral = connectedPeripherals[normalizedDeviceUUID] else {
            completion(.failure(BLEError.notConnected))
            return
        }

        guard let characteristic = findCharacteristic(
            deviceUUID: deviceUUID,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            completion(.failure(BLEError.characteristicNotFound))
            return
        }

        let key = "\(normalizedDeviceUUID):\(characteristic.uuid.uuidString.uppercased())"
        subscriptions.insert(key)

        // setNotifyValue completion comes via didUpdateNotificationState
        pendingWrites[key] = completion
        peripheral.setNotifyValue(true, for: characteristic)
    }

    /// Unsubscribe from notifications for a characteristic
    /// - Parameters:
    ///   - deviceUUID: The peripheral's UUID string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    func unsubscribe(
        deviceUUID: String,
        serviceUUID: String,
        charUUID: String
    ) {
        let normalizedDeviceUUID = deviceUUID.uppercased()
        guard let peripheral = connectedPeripherals[normalizedDeviceUUID],
              let characteristic = findCharacteristic(
                  deviceUUID: deviceUUID,
                  serviceUUID: serviceUUID,
                  charUUID: charUUID
              ) else {
            return
        }

        let key = "\(normalizedDeviceUUID):\(characteristic.uuid.uuidString.uppercased())"
        subscriptions.remove(key)
        peripheral.setNotifyValue(false, for: characteristic)
    }

    // MARK: - Service Discovery Methods

    /// Discover services for a connected peripheral
    /// - Parameters:
    ///   - uuid: The peripheral's UUID string
    ///   - completion: Callback with success/failure result
    func discoverServices(uuid: String, completion: @escaping (Result<Void, Error>) -> Void) {
        let normalizedUUID = uuid.uppercased()
        guard let peripheral = connectedPeripherals[normalizedUUID] else {
            completion(.failure(BLEError.notConnected))
            return
        }

        pendingServiceDiscovery[normalizedUUID] = completion
        peripheral.discoverServices(nil) // Discover all services
    }

    /// Get discovered services and characteristics for a connected peripheral
    /// - Parameter uuid: The peripheral's UUID string
    /// - Returns: Array of service dictionaries with nested characteristics, or nil if not found
    func getServices(uuid: String) -> [[String: Any]]? {
        let normalizedUUID = uuid.uppercased()
        guard let peripheral = connectedPeripherals[normalizedUUID],
              let services = peripheral.services else {
            return nil
        }

        return services.map { service in
            var serviceDict: [String: Any] = [
                "uuid": service.uuid.uuidString,
                "primary": service.isPrimary
            ]

            let characteristics: [[String: Any]] = (service.characteristics ?? []).map { char in
                [
                    "uuid": char.uuid.uuidString,
                    "properties": characteristicPropertiesToFlags(char.properties),
                    "service_uuid": service.uuid.uuidString
                ]
            }
            serviceDict["characteristics"] = characteristics

            return serviceDict
        }
    }

    /// Convert CBCharacteristicProperties to array of string flags
    private func characteristicPropertiesToFlags(_ properties: CBCharacteristicProperties) -> [String] {
        var flags: [String] = []
        if properties.contains(.read) { flags.append("read") }
        if properties.contains(.write) { flags.append("write") }
        if properties.contains(.writeWithoutResponse) { flags.append("write-without-response") }
        if properties.contains(.notify) { flags.append("notify") }
        if properties.contains(.indicate) { flags.append("indicate") }
        if properties.contains(.broadcast) { flags.append("broadcast") }
        if properties.contains(.authenticatedSignedWrites) { flags.append("authenticated-signed-writes") }
        if properties.contains(.extendedProperties) { flags.append("extended-properties") }
        return flags
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let uuid = peripheral.identifier.uuidString.uppercased()

        if let error = error {
            if let completion = pendingServiceDiscovery.removeValue(forKey: uuid) {
                completion(.failure(error))
            }
            return
        }

        // Discover characteristics for each service
        guard let services = peripheral.services, !services.isEmpty else {
            // No services found, complete immediately
            if let completion = pendingServiceDiscovery.removeValue(forKey: uuid) {
                completion(.success(()))
            }
            return
        }

        pendingCharacteristicDiscovery[uuid] = services.count

        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let uuid = peripheral.identifier.uuidString.uppercased()

        // Decrement pending count
        if var remaining = pendingCharacteristicDiscovery[uuid] {
            remaining -= 1
            pendingCharacteristicDiscovery[uuid] = remaining

            // All services discovered?
            if remaining == 0 {
                pendingCharacteristicDiscovery.removeValue(forKey: uuid)
                if let completion = pendingServiceDiscovery.removeValue(forKey: uuid) {
                    completion(.success(()))
                }
            }
        }
    }

    // MARK: - GATT Operation Callbacks

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let deviceUUID = peripheral.identifier.uuidString.uppercased()
        let charUUID = characteristic.uuid.uuidString.uppercased()
        let key = "\(deviceUUID):\(charUUID)"

        // Check if this is a read response
        if let completion = pendingReads.removeValue(forKey: key) {
            if let error = error {
                completion(.failure(error))
            } else if let value = characteristic.value {
                completion(.success(value))
            } else {
                completion(.success(Data()))
            }
            return
        }

        // Otherwise it's a notification
        if subscriptions.contains(key) {
            let value = characteristic.value ?? Data()
            let event = Event(
                method: "notification",
                params: [
                    "device_uuid": AnyCodable(deviceUUID),
                    "service_uuid": AnyCodable(characteristic.service?.uuid.uuidString.uppercased() ?? ""),
                    "char_uuid": AnyCodable(charUUID),
                    "value": AnyCodable(Array(value).map { Int($0) })
                ]
            )
            onEvent?(event)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        let key = "\(peripheral.identifier.uuidString.uppercased()):\(characteristic.uuid.uuidString.uppercased())"
        if let completion = pendingWrites.removeValue(forKey: key) {
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let key = "\(peripheral.identifier.uuidString.uppercased()):\(characteristic.uuid.uuidString.uppercased())"
        if let completion = pendingWrites.removeValue(forKey: key) {
            if let error = error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }
}

// MARK: - BLE Errors

/// Errors specific to BLE operations
enum BLEError: Error {
    case notPoweredOn
    case notConnected
    case timeout
    case invalidUUID(String)
    case deviceNotFound
    case connectionFailed
    case serviceDiscoveryFailed
    case characteristicNotFound

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
        case .deviceNotFound:
            return "Device not found (must scan first)"
        case .connectionFailed:
            return "Connection failed"
        case .serviceDiscoveryFailed:
            return "Service discovery failed"
        case .characteristicNotFound:
            return "Characteristic not found"
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
    static let deviceNotFound = -6
    static let connectionFailed = -7
    static let serviceDiscoveryFailed = -8
    static let characteristicNotFound = -9
}
