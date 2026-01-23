import Foundation

/// RBLELinuxHelper - BluetoothLinux bridge for rble gem
///
/// Communication protocol:
/// - Reads JSON requests from stdin (one per line)
/// - Writes JSON responses to stdout (one per line)
/// - Async events (device_discovered, state_changed) written to stdout as JSON lines
/// - All non-JSON output goes to stderr

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
    case "ping":
        // Simple ping/pong for testing the protocol
        return Response.success(
            id: request.id,
            result: ["pong": AnyCodable(true)]
        )
    default:
        // All other methods return method_not_found for now
        // Phase 7+ will add real BLE handlers
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
    // Disable stdout buffering for immediate output
    setbuf(stdout, nil)

    // Validate prerequisites BEFORE entering the stdin read loop
    // This ensures errors are reported immediately on startup
    validatePrerequisites()

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

    // Run main RunLoop for async callbacks
    // This keeps the process alive and allows future BLE async operations
    RunLoop.main.run()
}

// Run the main loop
main()
