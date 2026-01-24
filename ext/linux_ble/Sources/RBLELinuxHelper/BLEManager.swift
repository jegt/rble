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

    // MARK: - Private Methods

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
