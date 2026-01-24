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

        // Remove from connections
        connections.removeValue(forKey: bluetoothAddress)

        // Emit disconnected event with user_requested reason
        emitDisconnectEvent(address: normalizedAddress, reason: "user_requested", error: nil)
    }

    // MARK: - Private Methods

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
                // Unexpected disconnect detected
                connections.removeValue(forKey: address)

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
    case deviceNotFound(String)      // Device address not in scan cache
    case connectionFailed(Error)     // GATTCentral.connect failed
    case connectionTimeout           // Connection attempt timed out
    case alreadyConnecting(String)   // Connection already in progress for this address
    case notConnected(String)        // Disconnect called but not connected

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
