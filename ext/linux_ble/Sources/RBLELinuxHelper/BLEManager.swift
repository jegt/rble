#if os(Linux)
import Foundation
import Bluetooth
import BluetoothLinux
import BluetoothGATT
import GATT

// MARK: - Type Aliases

/// GATTCentral type using BluetoothLinux's HostController and L2CAP socket
/// Must fully qualify BluetoothLinux.L2CAPSocket to avoid conflict with Bluetooth.L2CAPSocket protocol
typealias LinuxCentral = GATTCentral<HostController, BluetoothLinux.L2CAPSocket.Connection>

/// GATT Service type for Linux backend
typealias LinuxService = GATT.Service<LinuxCentral.Peripheral, UInt16>

/// GATT Characteristic type for Linux backend
typealias LinuxCharacteristic = GATT.Characteristic<LinuxCentral.Peripheral, UInt16>

/// Wrapper to associate a characteristic with its parent service UUID
struct CachedCharacteristic {
    let characteristic: LinuxCharacteristic
    let serviceUUID: String
}

// MARK: - Connection State

/// Tracks an active connection and its monitoring task
struct ConnectionState {
    let peripheral: LinuxCentral.Peripheral
    let monitorTask: Task<Void, Never>
    var intentionalDisconnect: Bool = false  // Flag to distinguish user vs unexpected disconnect
}

// MARK: - BLEManager

/// BluetoothLinux wrapper that manages Bluetooth scanning and device discovery.
/// This class handles all interaction with BluetoothLinux/GATT and emits events via the onEvent callback.
/// Mirrors the macOS CoreBluetooth BLEManager for cross-platform parity.
///
/// @MainActor ensures thread-safe access to mutable state and allows callbacks on main queue.
@MainActor
class BLEManager {
    private var hostController: HostController?
    private var central: LinuxCentral?
    private var scanStream: AsyncCentralScan<LinuxCentral>?
    private var scanTask: Task<Void, Never>?
    private var timeoutWorkItem: DispatchWorkItem?

    private var reportedPeripherals: Set<BluetoothAddress> = []
    private var allowDuplicates = false
    private var filterServiceUUIDs: [String]? = nil

    /// Active connections keyed by BluetoothAddress
    private var connections: [BluetoothAddress: ConnectionState] = [:]

    /// Track connection attempts in progress (address -> timeout workItem)
    private var connectingAddresses: [BluetoothAddress: DispatchWorkItem] = [:]

    /// Discovered services cache per device
    private var discoveredServices: [BluetoothAddress: [LinuxService]] = [:]

    /// Discovered characteristics cache per device (with service UUID association)
    private var discoveredCharacteristics: [BluetoothAddress: [CachedCharacteristic]] = [:]

    /// Active notification tasks, keyed by "address:charHandle"
    private var notificationTasks: [String: Task<Void, Never>] = [:]

    /// Callback to send events to stdout
    var onEvent: ((Event) -> Void)?

    // MARK: - Initialization

    /// Ensure HostController and GATTCentral are initialized
    /// Called lazily on first scan to defer adapter acquisition
    private func ensureInitialized() async throws {
        guard hostController == nil else { return }

        // Find first available controller
        let controllers = await HostController.controllers
        guard let controller = controllers.first else {
            throw LinuxBLEError.adapterNotFound
        }
        hostController = controller

        // Create GATTCentral with L2CAP socket type
        central = LinuxCentral(hostController: controller, socket: BluetoothLinux.L2CAPSocket.Connection.self)
    }

    // MARK: - Public Methods

    /// Start scanning for BLE peripherals
    /// - Parameters:
    ///   - serviceUUIDs: Optional array of service UUID strings to filter by
    ///   - allowDuplicates: If true, receive repeated advertisements from the same device
    ///   - timeout: Optional timeout in seconds after which scanning automatically stops
    /// - Throws: LinuxBLEError if adapter not found or scanning fails
    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool, timeout: TimeInterval?) async throws {
        // Stop any existing scan first
        stopScan()

        try await ensureInitialized()

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        self.allowDuplicates = allowDuplicates
        self.filterServiceUUIDs = serviceUUIDs
        self.reportedPeripherals = []

        // Start scanning - we do our own deduplication for macOS parity
        // Setting filterDuplicates: false at HCI level gives us full control
        let stream = try await central.scan(filterDuplicates: false)
        self.scanStream = stream

        // Create task to consume the async stream
        // Using @MainActor task to ensure safe access to BLEManager state
        scanTask = Task { @MainActor [weak self] in
            do {
                for try await scanData in stream {
                    guard let self = self else { break }

                    // Apply service UUID filter if specified
                    if let filterUUIDs = self.filterServiceUUIDs {
                        let advertised = scanData.advertisementData.serviceUUIDs ?? []
                        let hasMatch = advertised.contains { uuid in
                            filterUUIDs.contains(uuid.rawValue.uppercased())
                        }
                        guard hasMatch else { continue }
                    }

                    // Deduplication when !allowDuplicates
                    // Use peripheral.id (BluetoothAddress) for tracking
                    if !self.allowDuplicates {
                        guard !self.reportedPeripherals.contains(scanData.peripheral.id) else { continue }
                        self.reportedPeripherals.insert(scanData.peripheral.id)
                    }

                    // Convert to event and dispatch via onEvent callback
                    let event = self.scanDataToEvent(scanData)
                    self.onEvent?(event)
                }
            } catch {
                // Scan cancelled or error - expected during stopScan
            }
        }

        // Set up timeout if specified
        if let timeout = timeout, timeout > 0 {
            let workItem = DispatchWorkItem { [weak self] in
                self?.stopScan()
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
            self.timeoutWorkItem = workItem
        }
    }

    /// Stop scanning for BLE peripherals
    func stopScan() {
        // Cancel any pending timeout
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        // Stop the scan stream and task
        scanStream?.stop()
        scanTask?.cancel()
        scanStream = nil
        scanTask = nil
    }

    // MARK: - Connection Methods

    /// Connect to a peripheral by its MAC address
    /// - Parameters:
    ///   - address: The MAC address string (e.g., "AA:BB:CC:DD:EE:FF")
    ///   - timeout: Connection timeout in seconds (default 30)
    /// - Throws: LinuxBLEError if connection fails
    func connect(address: String, timeout: TimeInterval = 30) async throws {
        // Normalize address to uppercase (Pitfall 5 from research)
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress) else {
            throw LinuxBLEError.deviceNotFound(normalizedAddress)
        }

        // Check if already connected (idempotent success)
        if connections[bluetoothAddress] != nil {
            return
        }

        // Check if connection already in progress (Pitfall 3)
        if connectingAddresses[bluetoothAddress] != nil {
            throw LinuxBLEError.alreadyConnecting(normalizedAddress)
        }

        try await ensureInitialized()

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        // Find peripheral in scan cache (Pitfall 1 from research)
        // central.peripherals returns [Peripheral: Bool] where key is peripheral, value is connection status
        let peripherals = await central.peripherals
        guard let peripheral = peripherals.keys.first(where: { $0.id == bluetoothAddress }) else {
            throw LinuxBLEError.deviceNotFound(normalizedAddress)
        }

        // Set up timeout (Pitfall 2 - must cancel on success/failure)
        var timedOut = false
        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            timedOut = true
            self?.connectingAddresses.removeValue(forKey: bluetoothAddress)
            // Note: Cannot cancel in-flight connect, but we'll check timedOut flag
        }
        connectingAddresses[bluetoothAddress] = timeoutWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: timeoutWorkItem)

        do {
            try await central.connect(to: peripheral)

            // Cancel timeout on success
            timeoutWorkItem.cancel()
            connectingAddresses.removeValue(forKey: bluetoothAddress)

            // Check if timed out while connecting
            if timedOut {
                // Disconnect since we told Ruby it timed out
                await central.disconnect(peripheral)
                throw LinuxBLEError.connectionTimeout
            }

            // Start monitoring task for disconnect detection
            let monitorTask = Task { @MainActor [weak self] in
                guard let self = self else { return }
                await self.monitorConnection(peripheral: peripheral, address: bluetoothAddress)
            }

            connections[bluetoothAddress] = ConnectionState(
                peripheral: peripheral,
                monitorTask: monitorTask
            )

            // Emit connected event
            let event = Event(method: "connected", params: [
                "uuid": AnyCodable(normalizedAddress)
            ])
            onEvent?(event)

        } catch let error as LinuxBLEError {
            timeoutWorkItem.cancel()
            connectingAddresses.removeValue(forKey: bluetoothAddress)
            throw error
        } catch {
            timeoutWorkItem.cancel()
            connectingAddresses.removeValue(forKey: bluetoothAddress)
            throw LinuxBLEError.connectionFailed(error)
        }
    }

    /// Disconnect from a connected peripheral
    /// - Parameter address: The MAC address string
    func disconnect(address: String) async throws {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress) else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard var connectionState = connections[bluetoothAddress] else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        // Mark as intentional disconnect (Pitfall 4 from research)
        connectionState.intentionalDisconnect = true
        connections[bluetoothAddress] = connectionState

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        // Cancel monitoring task
        connectionState.monitorTask.cancel()

        // Disconnect from peripheral
        await central.disconnect(connectionState.peripheral)

        // Cancel all subscriptions for this device
        cancelSubscriptions(for: bluetoothAddress)

        // Remove from connections and clear GATT cache
        connections.removeValue(forKey: bluetoothAddress)
        discoveredServices.removeValue(forKey: bluetoothAddress)
        discoveredCharacteristics.removeValue(forKey: bluetoothAddress)

        // Emit disconnected event with user_requested reason
        emitDisconnectEvent(address: normalizedAddress, reason: "user_requested", error: nil)
    }

    // MARK: - GATT Discovery Methods

    /// Discover services and characteristics for a connected device
    /// - Parameter address: The MAC address string
    /// - Throws: LinuxBLEError if not connected or discovery fails
    func discoverServices(address: String) async throws {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress) else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard let connectionState = connections[bluetoothAddress] else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        do {
            // Discover all services
            let services = try await central.discoverServices(for: connectionState.peripheral)
            discoveredServices[bluetoothAddress] = services

            // Discover characteristics for each service, tracking service UUID association
            var allCharacteristics: [CachedCharacteristic] = []
            for service in services {
                let serviceUUID = service.uuid.rawValue.uppercased()
                let characteristics = try await central.discoverCharacteristics(for: service)
                for char in characteristics {
                    allCharacteristics.append(CachedCharacteristic(
                        characteristic: char,
                        serviceUUID: serviceUUID
                    ))
                }
            }
            discoveredCharacteristics[bluetoothAddress] = allCharacteristics

        } catch {
            throw LinuxBLEError.serviceDiscoveryFailed(error)
        }
    }

    /// Get discovered services for a connected device in macOS-compatible format
    /// - Parameter address: The MAC address string
    /// - Returns: Array of service dictionaries with nested characteristics, or nil if not discovered
    func getServices(address: String) -> [[String: Any]]? {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress),
              let services = discoveredServices[bluetoothAddress],
              let cachedChars = discoveredCharacteristics[bluetoothAddress] else {
            return nil
        }

        return services.map { service in
            let serviceUUID = service.uuid.rawValue.uppercased()

            // Find characteristics belonging to this service using cached service UUID
            let serviceCharacteristics = cachedChars.filter { cached in
                cached.serviceUUID == serviceUUID
            }

            let charDicts: [[String: Any]] = serviceCharacteristics.map { cached in
                [
                    "uuid": cached.characteristic.uuid.rawValue.uppercased(),
                    "properties": characteristicPropertiesToFlags(cached.characteristic.properties),
                    "service_uuid": serviceUUID
                ]
            }

            return [
                "uuid": serviceUUID,
                "primary": service.isPrimary,
                "characteristics": charDicts
            ] as [String: Any]
        }
    }

    /// Find a characteristic by service and characteristic UUIDs
    /// - Parameters:
    ///   - address: The MAC address string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    /// - Returns: The characteristic if found, nil otherwise
    func findCharacteristic(address: String, serviceUUID: String, charUUID: String) -> LinuxCharacteristic? {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress),
              let cachedChars = discoveredCharacteristics[bluetoothAddress] else {
            return nil
        }

        let normalizedServiceUUID = normalizeUUID(serviceUUID)
        let normalizedCharUUID = normalizeUUID(charUUID)

        return cachedChars.first { cached in
            normalizeUUID(cached.serviceUUID) == normalizedServiceUUID &&
            normalizeUUID(cached.characteristic.uuid.rawValue) == normalizedCharUUID
        }?.characteristic
    }

    // MARK: - GATT Read/Write Methods

    /// Read a characteristic value
    /// - Parameters:
    ///   - address: The MAC address string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    /// - Returns: The characteristic value as Data
    /// - Throws: LinuxBLEError if not connected, characteristic not found, or read fails
    func readCharacteristic(
        address: String,
        serviceUUID: String,
        charUUID: String
    ) async throws -> Data {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress),
              connections[bluetoothAddress] != nil else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard let characteristic = findCharacteristic(
            address: normalizedAddress,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            throw LinuxBLEError.characteristicNotFound(charUUID)
        }

        // Check that characteristic supports read
        guard characteristic.properties.contains(.read) else {
            throw LinuxBLEError.operationFailed(
                NSError(domain: "BLE", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Characteristic does not support read"
                ])
            )
        }

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        do {
            let data = try await central.readValue(for: characteristic)
            return data
        } catch {
            throw LinuxBLEError.operationFailed(error)
        }
    }

    /// Write a value to a characteristic
    /// - Parameters:
    ///   - address: The MAC address string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    ///   - data: The data to write
    ///   - withResponse: Whether to request a write response from the peripheral
    /// - Throws: LinuxBLEError if not connected, characteristic not found, or write fails
    func writeCharacteristic(
        address: String,
        serviceUUID: String,
        charUUID: String,
        data: Data,
        withResponse: Bool
    ) async throws {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress),
              connections[bluetoothAddress] != nil else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard let characteristic = findCharacteristic(
            address: normalizedAddress,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            throw LinuxBLEError.characteristicNotFound(charUUID)
        }

        // Check that characteristic supports the requested write type
        if withResponse {
            guard characteristic.properties.contains(.write) else {
                throw LinuxBLEError.operationFailed(
                    NSError(domain: "BLE", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Characteristic does not support write with response"
                    ])
                )
            }
        } else {
            guard characteristic.properties.contains(.writeWithoutResponse) else {
                throw LinuxBLEError.operationFailed(
                    NSError(domain: "BLE", code: -1, userInfo: [
                        NSLocalizedDescriptionKey: "Characteristic does not support write without response"
                    ])
                )
            }
        }

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        do {
            try await central.writeValue(data, for: characteristic, withResponse: withResponse)
        } catch {
            throw LinuxBLEError.operationFailed(error)
        }
    }

    // MARK: - Notification Methods

    /// Subscribe to notifications for a characteristic
    /// - Parameters:
    ///   - address: The MAC address string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    /// - Throws: LinuxBLEError if not connected, characteristic not found, or subscribe fails
    func subscribe(
        address: String,
        serviceUUID: String,
        charUUID: String
    ) async throws {
        let normalizedAddress = address.uppercased()

        guard let bluetoothAddress = BluetoothAddress(rawValue: normalizedAddress),
              connections[bluetoothAddress] != nil else {
            throw LinuxBLEError.notConnected(normalizedAddress)
        }

        guard let characteristic = findCharacteristic(
            address: normalizedAddress,
            serviceUUID: serviceUUID,
            charUUID: charUUID
        ) else {
            throw LinuxBLEError.characteristicNotFound(charUUID)
        }

        // Check that characteristic supports notify or indicate
        guard characteristic.properties.contains(.notify) || characteristic.properties.contains(.indicate) else {
            throw LinuxBLEError.operationFailed(
                NSError(domain: "BLE", code: -1, userInfo: [
                    NSLocalizedDescriptionKey: "Characteristic does not support notifications"
                ])
            )
        }

        guard let central = central else {
            throw LinuxBLEError.adapterNotFound
        }

        // Generate key using address and characteristic handle
        let key = "\(normalizedAddress):\(characteristic.id)"

        // If already subscribed, return success (idempotent)
        if notificationTasks[key] != nil {
            return
        }

        // Look up service UUID for the event
        let serviceUUIDStr = serviceUUIDForCharacteristic(address: bluetoothAddress, charHandle: characteristic.id) ?? serviceUUID.uppercased()
        let charUUIDStr = characteristic.uuid.rawValue.uppercased()

        // Start notification stream
        let stream = central.notify(for: characteristic)

        // Create task that iterates the AsyncSequence and emits events
        notificationTasks[key] = Task { @MainActor [weak self] in
            do {
                for try await data in stream {
                    guard let self = self else { break }
                    let event = Event(
                        method: "notification",
                        params: [
                            "device_uuid": AnyCodable(normalizedAddress),
                            "service_uuid": AnyCodable(serviceUUIDStr),
                            "char_uuid": AnyCodable(charUUIDStr),
                            "value": AnyCodable(Array(data).map { Int($0) })
                        ]
                    )
                    self.onEvent?(event)
                }
            } catch {
                // Stream ended (disconnect or unsubscribe) - expected behavior
            }
        }
    }

    /// Unsubscribe from notifications for a characteristic
    /// - Parameters:
    ///   - address: The MAC address string
    ///   - serviceUUID: The service UUID (short or full)
    ///   - charUUID: The characteristic UUID (short or full)
    func unsubscribe(
        address: String,
        serviceUUID: String,
        charUUID: String
    ) {
        let normalizedAddress = address.uppercased()

        guard let _ = BluetoothAddress(rawValue: normalizedAddress),
              let characteristic = findCharacteristic(
                  address: normalizedAddress,
                  serviceUUID: serviceUUID,
                  charUUID: charUUID
              ) else {
            return
        }

        // Generate key using address and characteristic handle
        let key = "\(normalizedAddress):\(characteristic.id)"

        // Cancel the notification task
        notificationTasks[key]?.cancel()
        notificationTasks.removeValue(forKey: key)
    }

    // MARK: - Private Methods

    /// Cancel all notification subscriptions for a device
    /// Called during disconnect to clean up notification tasks
    /// - Parameter address: The device's BluetoothAddress
    private func cancelSubscriptions(for address: BluetoothAddress) {
        let prefix = "\(address.rawValue.uppercased()):"
        for (key, task) in notificationTasks where key.hasPrefix(prefix) {
            task.cancel()
            notificationTasks.removeValue(forKey: key)
        }
    }

    /// Look up the service UUID for a characteristic by its handle
    /// - Parameters:
    ///   - address: The device's BluetoothAddress
    ///   - charHandle: The characteristic handle (UInt16)
    /// - Returns: The service UUID string if found, nil otherwise
    private func serviceUUIDForCharacteristic(address: BluetoothAddress, charHandle: UInt16) -> String? {
        guard let cachedChars = discoveredCharacteristics[address] else {
            return nil
        }
        return cachedChars.first { $0.characteristic.id == charHandle }?.serviceUUID
    }

    /// Normalize a UUID, converting 4-character short UUIDs to full 128-bit format
    /// - Parameter uuid: The UUID string (either 4-char short or full 128-bit)
    /// - Returns: The full 128-bit UUID string in uppercase
    private func normalizeUUID(_ uuid: String) -> String {
        if uuid.count == 4 {
            return "0000\(uuid.uppercased())-0000-1000-8000-00805F9B34FB"
        }
        return uuid.uppercased()
    }

    /// Convert GATTCharacteristicProperties to array of string flags
    /// Matches macOS format exactly for API parity
    private func characteristicPropertiesToFlags(_ properties: GATTCharacteristicProperties) -> [String] {
        var flags: [String] = []
        if properties.contains(.read) { flags.append("read") }
        if properties.contains(.write) { flags.append("write") }
        if properties.contains(.writeWithoutResponse) { flags.append("write-without-response") }
        if properties.contains(.notify) { flags.append("notify") }
        if properties.contains(.indicate) { flags.append("indicate") }
        if properties.contains(.broadcast) { flags.append("broadcast") }
        if properties.contains(.signedWrite) { flags.append("authenticated-signed-writes") }
        if properties.contains(.extendedProperties) { flags.append("extended-properties") }
        return flags
    }

    /// Monitor a connection for unexpected disconnect
    /// This runs in a Task and detects when the connection drops
    private func monitorConnection(peripheral: LinuxCentral.Peripheral, address: BluetoothAddress) async {
        guard let central = central else { return }

        // Poll for connection status
        // GATTCentral doesn't expose a stream for disconnect events,
        // so we check if peripheral is still in connected set
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 100_000_000)  // 100ms

            // Check if still in our connections dict (may have been removed by disconnect())
            guard let connectionState = connections[address] else {
                return  // Already handled by explicit disconnect
            }

            // Check if peripheral still connected via GATTCentral
            // peripherals dict has Bool value indicating connection status
            let peripherals = await central.peripherals
            let stillConnected = peripherals[peripheral] ?? false

            if !stillConnected {
                // Unexpected disconnect detected - cancel subscriptions and clear state
                cancelSubscriptions(for: address)
                connections.removeValue(forKey: address)
                discoveredServices.removeValue(forKey: address)
                discoveredCharacteristics.removeValue(forKey: address)

                let reason = connectionState.intentionalDisconnect ? "user_requested" : "link_loss"
                emitDisconnectEvent(address: address.rawValue.uppercased(), reason: reason, error: nil)
                return
            }
        }
    }

    /// Emit a disconnected event
    private func emitDisconnectEvent(address: String, reason: String, error: String?) {
        var params: [String: AnyCodable] = [
            "uuid": AnyCodable(address),
            "reason": AnyCodable(reason)
        ]
        if let error = error {
            params["error"] = AnyCodable(error)
        }
        let event = Event(method: "disconnected", params: params)
        onEvent?(event)
    }

    // MARK: - Scan Data Conversion

    /// Convert BluetoothLinux ScanData to Event matching macOS format exactly
    /// - Parameter scanData: The scan data from BluetoothLinux
    /// - Returns: Event with method "device_discovered" and matching params
    private func scanDataToEvent(_ scanData: ScanData<LinuxCentral.Peripheral, LinuxCentral.Advertisement>) -> Event {
        var params: [String: AnyCodable] = [
            // Use BluetoothAddress as device ID
            // Linux uses MAC address format (XX:XX:XX:XX:XX:XX), not UUID like macOS
            // Uppercase for consistency with macOS UUID format
            // peripheral.id is BluetoothAddress, .rawValue gives the "XX:XX:XX:XX:XX:XX" string
            "uuid": AnyCodable(scanData.peripheral.id.rawValue.uppercased()),
            "rssi": AnyCodable(Int(scanData.rssi))
        ]

        let adv = scanData.advertisementData

        // Local name - from GAPCompleteLocalName or GAPShortLocalName
        if let name = adv.localName {
            params["name"] = AnyCodable(name)
        }

        // Service UUIDs - convert to uppercase string array for consistency
        if let serviceUUIDs = adv.serviceUUIDs, !serviceUUIDs.isEmpty {
            params["service_uuids"] = AnyCodable(serviceUUIDs.map { $0.rawValue.uppercased() })
        }

        // Manufacturer data - must match macOS format exactly
        // macOS: { "company_id": Int, "data": [Int] }
        if let mfgData = adv.manufacturerData {
            params["manufacturer_data"] = AnyCodable([
                "company_id": Int(mfgData.companyIdentifier.rawValue),
                "data": Array(mfgData.additionalData).map { Int($0) }
            ])
        }

        // Service data - map of service UUID -> data bytes
        // macOS: { "UUID": [Int] }
        if let serviceData = adv.serviceData, !serviceData.isEmpty {
            var sdDict: [String: [Int]] = [:]
            for (uuid, data) in serviceData {
                sdDict[uuid.rawValue.uppercased()] = Array(data).map { Int($0) }
            }
            params["service_data"] = AnyCodable(sdDict)
        }

        // Tx power level if advertised
        if let txPower = adv.txPowerLevel {
            params["tx_power"] = AnyCodable(Int(txPower))
        }

        // Connectable status - from ScanData, not AdvertisementData
        params["connectable"] = AnyCodable(scanData.isConnectable)

        return Event(method: "device_discovered", params: params)
    }
}

// MARK: - Linux BLE Errors

/// Errors specific to Linux BLE operations
enum LinuxBLEError: Error {
    case adapterNotFound
    case notPoweredOn
    case scanningFailed(Error)
    case deviceNotFound(String)           // Device address not in scan cache
    case connectionFailed(Error)          // GATTCentral.connect failed
    case connectionTimeout                // Connection attempt timed out
    case alreadyConnecting(String)        // Connection already in progress for this address
    case notConnected(String)             // Disconnect called but not connected
    case serviceDiscoveryFailed(Error)    // Service/characteristic discovery failed
    case characteristicNotFound(String)   // Characteristic UUID not in cache
    case operationFailed(Error)           // GATT read/write operation failed

    var localizedDescription: String {
        switch self {
        case .adapterNotFound:
            return "No Bluetooth adapter found"
        case .notPoweredOn:
            return "Bluetooth not powered on"
        case .scanningFailed(let error):
            return "Scanning failed: \(error)"
        case .deviceNotFound(let address):
            return "Device not found: \(address)"
        case .connectionFailed(let error):
            return "Connection failed: \(error)"
        case .connectionTimeout:
            return "Connection timeout"
        case .alreadyConnecting(let address):
            return "Already connecting to: \(address)"
        case .notConnected(let address):
            return "Not connected to: \(address)"
        case .serviceDiscoveryFailed(let error):
            return "Service discovery failed: \(error)"
        case .characteristicNotFound(let uuid):
            return "Characteristic not found: \(uuid)"
        case .operationFailed(let error):
            return "Operation failed: \(error)"
        }
    }
}

#else
// MARK: - macOS Stub (for development/compilation)

import Foundation

/// Stub BLEManager for macOS development
/// Allows compilation on macOS but operations are no-ops
class BLEManager {
    var onEvent: ((Event) -> Void)?

    func startScan(serviceUUIDs: [String]?, allowDuplicates: Bool, timeout: TimeInterval?) async throws {
        // No-op on macOS - real implementation requires BluetoothLinux
    }

    func stopScan() {
        // No-op on macOS
    }

    func connect(address: String, timeout: TimeInterval = 30) async throws {
        // No-op on macOS
    }

    func disconnect(address: String) async throws {
        // No-op on macOS
    }
}

enum LinuxBLEError: Error {
    case adapterNotFound
    case notPoweredOn
    case scanningFailed(Error)
    case deviceNotFound(String)
    case connectionFailed(Error)
    case connectionTimeout
    case alreadyConnecting(String)
    case notConnected(String)
}

#endif
