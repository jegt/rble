import Foundation

/// RBLELinuxHelper - BluetoothLinux bridge for rble gem
///
/// Communication protocol:
/// - Reads JSON requests from stdin (one per line)
/// - Writes JSON responses to stdout (one per line)
/// - Async events (device_discovered, state_changed) written to stdout as JSON lines
/// - All non-JSON output goes to stderr

// MARK: - Output Functions

/// Write data to stdout with proper flushing
private func writeToStdout(_ string: String) {
    if let data = (string + "\n").data(using: .utf8) {
        FileHandle.standardOutput.write(data)
    }
}

/// Write a response to stdout as a single JSON line (thread-safe)
func writeResponse(_ response: Response) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [] // Compact output, no pretty printing
    do {
        let jsonData = try encoder.encode(response)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            writeToStdout(jsonString)
        }
    } catch {
        // If encoding fails, write a minimal error response
        writeToStdout("{\"id\":-1,\"error\":{\"code\":-32603,\"message\":\"Internal error: failed to encode response\"}}")
    }
}

/// Write an event to stdout as a single JSON line (thread-safe)
func writeEvent(_ event: Event) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [] // Compact output, no pretty printing
    do {
        let jsonData = try encoder.encode(event)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            writeToStdout(jsonString)
        }
    } catch {
        writeToStdout("{\"method\":\"error\",\"params\":{\"message\":\"Failed to encode event\"}}")
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

// MARK: - Error Mapping

/// Map LinuxBLEError to JSON-RPC error code and message
func mapLinuxBLEError(_ error: LinuxBLEError) -> (code: Int, message: String) {
    switch error {
    case .adapterNotFound:
        return (BLEErrorCode.adapterNotFound, "No Bluetooth adapter found. Ensure a Bluetooth adapter is connected.")
    case .notPoweredOn:
        return (BLEErrorCode.notPoweredOn, "Bluetooth adapter is not powered on")
    case .scanningFailed(let underlying):
        return (BLEErrorCode.operationFailed, "Scanning failed: \(underlying)")
    }
}

// MARK: - Request Handlers

/// Handle a parsed request and return a response
/// For sync methods, returns a Response directly
/// For async methods, returns nil and calls writeResponse when complete
func handleRequest(_ request: Request, bleManager: BLEManager) -> Response? {
    switch request.method {
    case "ping":
        // Simple ping/pong for testing the protocol
        return Response.success(
            id: request.id,
            result: ["pong": AnyCodable(true)]
        )

    case "start_scan":
        // Extract parameters
        let serviceUUIDs = (request.params?["service_uuids"]?.value as? [Any])?.compactMap { $0 as? String }
        let allowDuplicates = (request.params?["allow_duplicates"]?.value as? Bool) ?? false
        // Extract timeout parameter (in seconds, as Double/TimeInterval)
        let timeout = request.params?["timeout"]?.value as? Double

        // Dispatch async scan
        Task {
            do {
                try await bleManager.startScan(serviceUUIDs: serviceUUIDs, allowDuplicates: allowDuplicates, timeout: timeout)
                DispatchQueue.main.async {
                    writeResponse(Response.success(id: request.id, result: ["scanning": AnyCodable(true)]))
                }
            } catch let error as LinuxBLEError {
                DispatchQueue.main.async {
                    let (code, message) = mapLinuxBLEError(error)
                    writeResponse(Response.error(id: request.id, code: code, message: message))
                }
            } catch {
                DispatchQueue.main.async {
                    writeResponse(Response.error(id: request.id, code: BLEErrorCode.operationFailed, message: "Scan failed: \(error)"))
                }
            }
        }
        return nil  // Response written async

    case "stop_scan":
        Task {
            await bleManager.stopScan()
            DispatchQueue.main.async {
                writeResponse(Response.success(id: request.id, result: ["stopped": AnyCodable(true)]))
            }
        }
        return nil  // Response written async

    default:
        return Response.error(
            id: request.id,
            code: ErrorCode.methodNotFound,
            message: "Method not found: \(request.method)"
        )
    }
}

// MARK: - Prerequisite Validation

/// Validate that all prerequisites are met for BLE operations on Linux.
///
/// This function performs fail-fast validation:
/// 1. Checks for required Linux capabilities (CAP_NET_RAW, CAP_NET_ADMIN)
/// 2. Checks that BlueZ daemon is not running (would conflict with direct HCI access)
///
/// If validation fails, writes a JSON error response to stdout and exits.
/// This ensures Ruby gets a parseable error rather than cryptic socket errors later.
func validatePrerequisites() {
    #if os(Linux)
    // Check Linux capabilities
    do {
        try checkCapabilities()
    } catch let error as PermissionError {
        writeResponse(formatPermissionError(error))
        exit(1)
    } catch {
        writeResponse(Response.error(
            id: 0,
            code: LinuxErrorCode.missingCapabilities,
            message: "Unexpected error checking capabilities: \(error)"
        ))
        exit(1)
    }

    // Check BlueZ daemon is not running
    do {
        try checkBlueZDaemon()
    } catch let error as DaemonError {
        writeResponse(formatDaemonError(error))
        exit(1)
    } catch {
        writeResponse(Response.error(
            id: 0,
            code: LinuxErrorCode.daemonConflict,
            message: "Unexpected error checking daemon: \(error)"
        ))
        exit(1)
    }
    #endif
    // On macOS, skip validation (for development)
}

// MARK: - Main Entry Point

func main() {
    // Note: FileHandle.standardOutput used in writeToStdout handles buffering appropriately

    // Validate prerequisites BEFORE entering the stdin read loop
    // This ensures errors are reported immediately on startup
    validatePrerequisites()

    // Create BLE manager and wire event callback
    let bleManager = BLEManager()
    bleManager.onEvent = { event in
        writeEvent(event)
    }

    let decoder = JSONDecoder()

    // Read stdin on a background queue so the main RunLoop can process async callbacks
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

                // Handle request on main queue for thread safety
                DispatchQueue.main.async {
                    if let response = handleRequest(request, bleManager: bleManager) {
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

    // Run main RunLoop for async callbacks
    // This keeps the process alive and allows future BLE async operations
    RunLoop.main.run()
}

// Run the main loop
main()
