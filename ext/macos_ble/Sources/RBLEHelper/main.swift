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
func handleRequest(_ request: Request) -> Response {
    switch request.method {
    case "adapters":
        return handleAdapters(request)
    case "scan_start":
        return handleScanStart(request)
    case "scan_stop":
        return handleScanStop(request)
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
func handleAdapters(_ request: Request) -> Response {
    let state = bleManager.getState()
    let powered = state == "powered_on"

    let adapter: [String: Any] = [
        "name": "default",
        "powered": powered,
        "state": state
    ]

    return Response.success(
        id: request.id,
        result: ["adapters": AnyCodable([adapter])]
    )
}

/// Handle the "scan_start" method - begins BLE scanning
/// Optional params:
///   - service_uuids: Array of service UUID strings to filter by
///   - allow_duplicates: Boolean to receive repeated advertisements
func handleScanStart(_ request: Request) -> Response {
    do {
        // Extract optional parameters
        let serviceUUIDs = request.params?["service_uuids"]?.value as? [String]
        let allowDuplicates = request.params?["allow_duplicates"]?.value as? Bool ?? false

        try bleManager.startScan(serviceUUIDs: serviceUUIDs, allowDuplicates: allowDuplicates)

        return Response.success(
            id: request.id,
            result: ["status": AnyCodable("started")]
        )
    } catch BLEError.notPoweredOn {
        return Response.error(
            id: request.id,
            code: BLEErrorCode.notPoweredOn,
            message: "Bluetooth not powered on",
            data: ["platform_error": "CBManagerState.poweredOff"]
        )
    } catch {
        return Response.error(
            id: request.id,
            code: ErrorCode.internalError,
            message: error.localizedDescription
        )
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
                    let response = handleRequest(request)
                    writeResponse(response)
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
