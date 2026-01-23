import Foundation

/// RBLEHelper - macOS CoreBluetooth bridge for rble gem
///
/// Communication protocol:
/// - Reads JSON requests from stdin (one per line)
/// - Writes JSON responses to stdout (one per line)
/// - All non-JSON output goes to stderr

// MARK: - Main Entry Point

/// Disable stdout buffering for immediate output
setbuf(stdout, nil)

/// Handle a parsed request and return a response
func handleRequest(_ request: Request) -> Response {
    // Stub implementation - all methods return "not found" for now
    // CoreBluetooth command handlers will be added in subsequent plans
    return Response.error(
        id: request.id,
        code: ErrorCode.methodNotFound,
        message: "Method not found: \(request.method)"
    )
}

/// Write a response to stdout as a single JSON line
func writeResponse(_ response: Response) {
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [] // Compact output, no pretty printing
        let jsonData = try encoder.encode(response)
        if let jsonString = String(data: jsonData, encoding: .utf8) {
            print(jsonString)
        }
    } catch {
        // If encoding fails, write a minimal error response
        // This should rarely happen since Response is well-defined
        fputs("{\"id\":-1,\"error\":{\"code\":-32603,\"message\":\"Internal error: failed to encode response\"}}\n", stdout)
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

/// Main stdin read loop
func main() {
    let decoder = JSONDecoder()

    while let line = readLine() {
        // Skip empty lines
        guard !line.isEmpty else { continue }

        do {
            // Parse JSON request
            guard let jsonData = line.data(using: .utf8) else {
                writeResponse(createParseErrorResponse())
                continue
            }

            let request = try decoder.decode(Request.self, from: jsonData)

            // Handle the request and write response
            let response = handleRequest(request)
            writeResponse(response)

        } catch {
            // JSON parse error or decoding error
            writeResponse(createParseErrorResponse())
        }
    }

    // stdin closed (EOF) - exit cleanly
    exit(0)
}

// Run the main loop
main()
