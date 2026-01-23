import Foundation

/// RBLEHelper - macOS CoreBluetooth bridge for rble gem
///
/// Communication protocol:
/// - Reads JSON requests from stdin (one per line)
/// - Writes JSON responses to stdout (one per line)
/// - Async events (device_discovered, state_changed) written to stdout as JSON lines
/// - All non-JSON output goes to stderr

// MARK: - Global State

/// Shared BLE manager instance
let bleManager = BLEManager()

// MARK: - Output Functions

/// Write a response to stdout as a single JSON line (thread-safe)
func writeResponse(_ response: Response) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [] // Compact output, no pretty printing
    do {
        let jsonData = try encoder.encode(response)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        }
    } catch {
        // If encoding fails, write a minimal error response
        fputs("{\"id\":-1,\"error\":{\"code\":-32603,\"message\":\"Internal error: failed to encode response\"}}\n", stdout)
        fflush(stdout)
    }
}

/// Write an event to stdout as a single JSON line (thread-safe)
func writeEvent(_ event: Event) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [] // Compact output, no pretty printing
    do {
        let jsonData = try encoder.encode(event)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
            fflush(stdout)
        }
    } catch {
        fputs("{\"method\":\"error\",\"params\":{\"message\":\"Failed to encode event\"}}\n", stdout)
        fflush(stdout)
    }
}

/// Create an error response for parse errors (no valid request ID available)
func createParseErrorResponse() -> Response {
    return Response.error(
        id: -1,
        code: ErrorCode.parseError,
        message: "Parse error: invalid JSON"
    )
}

// MARK: - Request Handlers

/// Handle a parsed request and return a response
/// For sync methods, returns a Response directly
/// For async methods, returns nil and calls writeResponse when complete
func handleRequest(_ request: Request) -> Response? {
    switch request.method {
    case "adapters":
        handleAdapters(request)
        return nil // Response sent asynchronously after state check
    case "scan_start":
        handleScanStart(request)
        return nil // Response sent asynchronously
    case "scan_stop":
        return handleScanStop(request)
    case "connect":
        handleConnect(request)
        return nil // Response sent asynchronously
    case "disconnect":
        handleDisconnect(request)
        return nil // Response sent asynchronously
    case "discover_services":
        handleDiscoverServices(request)
        return nil // Response sent asynchronously
    case "read_characteristic":
        handleReadCharacteristic(request)
        return nil // Response sent asynchronously
    case "write_characteristic":
        handleWriteCharacteristic(request)
        return nil // Response sent asynchronously
    case "subscribe":
        handleSubscribe(request)
        return nil // Response sent asynchronously
    case "unsubscribe":
        return handleUnsubscribe(request)
    default:
        return Response.error(
            id: request.id,
            code: ErrorCode.methodNotFound,
            message: "Method not found: \(request.method)"
        )
    }
}

/// Handle the "adapters" method - returns Bluetooth adapter state
/// macOS has a single logical Bluetooth adapter
/// Waits briefly for CoreBluetooth to determine state if currently unknown
func handleAdapters(_ request: Request) {
    // Wait for state to be determined (not unknown/resetting)
    bleManager.waitForStateKnown(timeout: 2) { _ in
        let state = bleManager.getState()
        let powered = state == "powered_on"

        let adapter: [String: Any] = [
            "name": "default",
            "powered": powered,
            "state": state
        ]

        writeResponse(Response.success(
            id: request.id,
            result: ["adapters": AnyCodable([adapter])]
        ))
    }
}

/// Handle the "scan_start" method - begins BLE scanning
/// Optional params:
///   - service_uuids: Array of service UUID strings to filter by
///   - allow_duplicates: Boolean to receive repeated advertisements
func handleScanStart(_ request: Request) {
    // Extract optional parameters
    let serviceUUIDs = request.params?["service_uuids"]?.value as? [String]
    let allowDuplicates = request.params?["allow_duplicates"]?.value as? Bool ?? false

    // Wait for Bluetooth to be powered on (CoreBluetooth needs time to initialize)
    bleManager.waitForPoweredOn(timeout: 5) { ready in
        if ready {
            do {
                try bleManager.startScan(serviceUUIDs: serviceUUIDs, allowDuplicates: allowDuplicates)
                writeResponse(Response.success(
                    id: request.id,
                    result: ["status": AnyCodable("started")]
                ))
            } catch BLEError.notPoweredOn {
                writeResponse(Response.error(
                    id: request.id,
                    code: BLEErrorCode.notPoweredOn,
                    message: "Bluetooth not powered on",
                    data: ["platform_error": "CBManagerState.poweredOff"]
                ))
            } catch {
                writeResponse(Response.error(
                    id: request.id,
                    code: ErrorCode.internalError,
                    message: error.localizedDescription
                ))
            }
        } else {
            writeResponse(Response.error(
                id: request.id,
                code: BLEErrorCode.notPoweredOn,
                message: "Bluetooth not powered on",
                data: ["platform_error": "CBManagerState.poweredOff"]
            ))
        }
    }
}

/// Handle the "scan_stop" method - stops BLE scanning
func handleScanStop(_ request: Request) -> Response {
    bleManager.stopScan()
    return Response.success(
        id: request.id,
        result: ["status": AnyCodable("stopped")]
    )
}

// MARK: - Async Request Handlers (Connection and Service Discovery)

/// Handle the "connect" method - connects to a peripheral
/// Required params:
///   - uuid: The peripheral's UUID string (must have been discovered first)
/// Optional params:
///   - timeout: Connection timeout in seconds (default: 30)
func handleConnect(_ request: Request) {
    guard let uuid = request.params?["uuid"]?.value as? String else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required param: uuid"
        ))
        return
    }

    let timeout = request.params?["timeout"]?.value as? Int ?? 30

    // Track timeout
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        writeResponse(Response.error(
            id: request.id,
            code: BLEErrorCode.timeout,
            message: "Connection timeout"
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

    bleManager.connect(uuid: uuid) { result in
        // Cancel timeout if we got a result
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        switch result {
        case .success:
            writeResponse(Response.success(
                id: request.id,
                result: ["status": AnyCodable("connected")]
            ))
        case .failure(let error):
            let code: Int
            if let bleError = error as? BLEError {
                switch bleError {
                case .deviceNotFound: code = BLEErrorCode.deviceNotFound
                case .notPoweredOn: code = BLEErrorCode.notPoweredOn
                case .connectionFailed: code = BLEErrorCode.connectionFailed
                default: code = BLEErrorCode.operationFailed
                }
            } else {
                code = BLEErrorCode.operationFailed
            }
            writeResponse(Response.error(
                id: request.id,
                code: code,
                message: error.localizedDescription
            ))
        }
    }
}

/// Handle the "disconnect" method - disconnects from a peripheral
/// Required params:
///   - uuid: The peripheral's UUID string
func handleDisconnect(_ request: Request) {
    guard let uuid = request.params?["uuid"]?.value as? String else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required param: uuid"
        ))
        return
    }

    // Disconnect with a short timeout (5 seconds)
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        // Even if timeout, respond with disconnected since we initiated the disconnect
        writeResponse(Response.success(
            id: request.id,
            result: ["status": AnyCodable("disconnected")]
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5), execute: timeoutWorkItem)

    bleManager.disconnect(uuid: uuid) {
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        writeResponse(Response.success(
            id: request.id,
            result: ["status": AnyCodable("disconnected")]
        ))
    }
}

/// Handle the "discover_services" method - discovers services and characteristics
/// Required params:
///   - uuid: The peripheral's UUID string (must be connected)
/// Optional params:
///   - timeout: Discovery timeout in seconds (default: 30)
func handleDiscoverServices(_ request: Request) {
    guard let uuid = request.params?["uuid"]?.value as? String else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required param: uuid"
        ))
        return
    }

    let timeout = request.params?["timeout"]?.value as? Int ?? 30

    // Track timeout
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        writeResponse(Response.error(
            id: request.id,
            code: BLEErrorCode.timeout,
            message: "Service discovery timeout"
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

    bleManager.discoverServices(uuid: uuid) { result in
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        switch result {
        case .success:
            if let services = bleManager.getServices(uuid: uuid) {
                writeResponse(Response.success(
                    id: request.id,
                    result: ["services": AnyCodable(services)]
                ))
            } else {
                writeResponse(Response.error(
                    id: request.id,
                    code: BLEErrorCode.serviceDiscoveryFailed,
                    message: "No services found"
                ))
            }
        case .failure(let error):
            let code: Int
            if let bleError = error as? BLEError {
                switch bleError {
                case .notConnected: code = BLEErrorCode.notConnected
                case .serviceDiscoveryFailed: code = BLEErrorCode.serviceDiscoveryFailed
                default: code = BLEErrorCode.operationFailed
                }
            } else {
                code = BLEErrorCode.operationFailed
            }
            writeResponse(Response.error(
                id: request.id,
                code: code,
                message: error.localizedDescription
            ))
        }
    }
}

// MARK: - GATT Operation Handlers

/// Handle the "read_characteristic" method - reads a characteristic value
/// Required params:
///   - device_uuid: The peripheral's UUID string
///   - service_uuid: The service UUID (short or full)
///   - char_uuid: The characteristic UUID (short or full)
/// Optional params:
///   - timeout: Read timeout in seconds (default: 30)
func handleReadCharacteristic(_ request: Request) {
    guard let deviceUUID = request.params?["device_uuid"]?.value as? String,
          let serviceUUID = request.params?["service_uuid"]?.value as? String,
          let charUUID = request.params?["char_uuid"]?.value as? String else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required params: device_uuid, service_uuid, char_uuid"
        ))
        return
    }

    let timeout = request.params?["timeout"]?.value as? Int ?? 30

    // Track timeout
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        writeResponse(Response.error(
            id: request.id,
            code: BLEErrorCode.timeout,
            message: "Read timeout"
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

    bleManager.readCharacteristic(
        deviceUUID: deviceUUID,
        serviceUUID: serviceUUID,
        charUUID: charUUID
    ) { result in
        // Cancel timeout if we got a result
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        switch result {
        case .success(let data):
            writeResponse(Response.success(
                id: request.id,
                result: ["value": AnyCodable(Array(data).map { Int($0) })]
            ))
        case .failure(let error):
            let code: Int
            if let bleError = error as? BLEError {
                switch bleError {
                case .notConnected: code = BLEErrorCode.notConnected
                case .characteristicNotFound: code = BLEErrorCode.characteristicNotFound
                default: code = BLEErrorCode.operationFailed
                }
            } else {
                code = BLEErrorCode.operationFailed
            }
            writeResponse(Response.error(
                id: request.id,
                code: code,
                message: error.localizedDescription
            ))
        }
    }
}

/// Handle the "write_characteristic" method - writes a value to a characteristic
/// Required params:
///   - device_uuid: The peripheral's UUID string
///   - service_uuid: The service UUID (short or full)
///   - char_uuid: The characteristic UUID (short or full)
///   - value: Array of bytes to write
/// Optional params:
///   - response: Whether to request write confirmation (default: true)
///   - timeout: Write timeout in seconds (default: 30)
func handleWriteCharacteristic(_ request: Request) {
    guard let deviceUUID = request.params?["device_uuid"]?.value as? String,
          let serviceUUID = request.params?["service_uuid"]?.value as? String,
          let charUUID = request.params?["char_uuid"]?.value as? String,
          let valueArray = request.params?["value"]?.value as? [Int] else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required params: device_uuid, service_uuid, char_uuid, value"
        ))
        return
    }

    let withResponse = request.params?["response"]?.value as? Bool ?? true
    let data = Data(valueArray.map { UInt8(clamping: $0) })
    let timeout = request.params?["timeout"]?.value as? Int ?? 30

    // Track timeout
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        writeResponse(Response.error(
            id: request.id,
            code: BLEErrorCode.timeout,
            message: "Write timeout"
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

    bleManager.writeCharacteristic(
        deviceUUID: deviceUUID,
        serviceUUID: serviceUUID,
        charUUID: charUUID,
        data: data,
        withResponse: withResponse
    ) { result in
        // Cancel timeout if we got a result
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        switch result {
        case .success:
            writeResponse(Response.success(
                id: request.id,
                result: ["status": AnyCodable("written")]
            ))
        case .failure(let error):
            let code: Int
            if let bleError = error as? BLEError {
                switch bleError {
                case .notConnected: code = BLEErrorCode.notConnected
                case .characteristicNotFound: code = BLEErrorCode.characteristicNotFound
                default: code = BLEErrorCode.operationFailed
                }
            } else {
                code = BLEErrorCode.operationFailed
            }
            writeResponse(Response.error(
                id: request.id,
                code: code,
                message: error.localizedDescription
            ))
        }
    }
}

/// Handle the "subscribe" method - subscribes to characteristic notifications
/// Required params:
///   - device_uuid: The peripheral's UUID string
///   - service_uuid: The service UUID (short or full)
///   - char_uuid: The characteristic UUID (short or full)
/// Optional params:
///   - timeout: Subscribe timeout in seconds (default: 30)
func handleSubscribe(_ request: Request) {
    guard let deviceUUID = request.params?["device_uuid"]?.value as? String,
          let serviceUUID = request.params?["service_uuid"]?.value as? String,
          let charUUID = request.params?["char_uuid"]?.value as? String else {
        writeResponse(Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required params: device_uuid, service_uuid, char_uuid"
        ))
        return
    }

    let timeout = request.params?["timeout"]?.value as? Int ?? 30

    // Track timeout
    var timedOut = false
    let timeoutWorkItem = DispatchWorkItem {
        timedOut = true
        writeResponse(Response.error(
            id: request.id,
            code: BLEErrorCode.timeout,
            message: "Subscribe timeout"
        ))
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(timeout), execute: timeoutWorkItem)

    bleManager.subscribe(
        deviceUUID: deviceUUID,
        serviceUUID: serviceUUID,
        charUUID: charUUID
    ) { result in
        // Cancel timeout if we got a result
        timeoutWorkItem.cancel()
        guard !timedOut else { return }

        switch result {
        case .success:
            writeResponse(Response.success(
                id: request.id,
                result: ["status": AnyCodable("subscribed")]
            ))
        case .failure(let error):
            let code: Int
            if let bleError = error as? BLEError {
                switch bleError {
                case .notConnected: code = BLEErrorCode.notConnected
                case .characteristicNotFound: code = BLEErrorCode.characteristicNotFound
                default: code = BLEErrorCode.operationFailed
                }
            } else {
                code = BLEErrorCode.operationFailed
            }
            writeResponse(Response.error(
                id: request.id,
                code: code,
                message: error.localizedDescription
            ))
        }
    }
}

/// Handle the "unsubscribe" method - unsubscribes from characteristic notifications
/// Required params:
///   - device_uuid: The peripheral's UUID string
///   - service_uuid: The service UUID (short or full)
///   - char_uuid: The characteristic UUID (short or full)
func handleUnsubscribe(_ request: Request) -> Response {
    guard let deviceUUID = request.params?["device_uuid"]?.value as? String,
          let serviceUUID = request.params?["service_uuid"]?.value as? String,
          let charUUID = request.params?["char_uuid"]?.value as? String else {
        return Response.error(
            id: request.id,
            code: ErrorCode.invalidParams,
            message: "Missing required params: device_uuid, service_uuid, char_uuid"
        )
    }

    bleManager.unsubscribe(
        deviceUUID: deviceUUID,
        serviceUUID: serviceUUID,
        charUUID: charUUID
    )

    return Response.success(
        id: request.id,
        result: ["status": AnyCodable("unsubscribed")]
    )
}

// MARK: - Main Entry Point

func main() {
    // Disable stdout buffering for immediate output
    setbuf(stdout, nil)

    // Setup event handler to write events to stdout
    // Events are dispatched to main queue for thread safety
    bleManager.onEvent = { event in
        DispatchQueue.main.async {
            writeEvent(event)
        }
    }

    let decoder = JSONDecoder()

    // Read stdin on a background queue so the main RunLoop can process CoreBluetooth callbacks
    DispatchQueue.global(qos: .userInitiated).async {
        while let line = readLine() {
            // Skip empty lines
            guard !line.isEmpty else { continue }

            do {
                // Parse JSON request
                guard let jsonData = line.data(using: .utf8) else {
                    DispatchQueue.main.async {
                        writeResponse(createParseErrorResponse())
                    }
                    continue
                }

                let request = try decoder.decode(Request.self, from: jsonData)

                // Handle request on main queue for thread safety with CoreBluetooth
                DispatchQueue.main.async {
                    if let response = handleRequest(request) {
                        // Sync response - write immediately
                        writeResponse(response)
                    }
                    // Async responses (nil) are written by their handlers
                }

            } catch {
                // JSON parse error or decoding error
                DispatchQueue.main.async {
                    writeResponse(createParseErrorResponse())
                }
            }
        }

        // stdin closed (EOF) - exit cleanly
        exit(0)
    }

    // Run main RunLoop for CoreBluetooth callbacks
    // This keeps the process alive and allows CBCentralManagerDelegate methods to be called
    RunLoop.main.run()
}

// Run the main loop
main()
