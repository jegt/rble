import Foundation

// MARK: - Permission Error Types

/// Errors that can occur during Linux capability validation
enum PermissionError: Error {
    /// Cannot read /proc/self/status file
    case cannotReadCapabilities
    /// Cannot parse CapEff line from /proc/self/status
    case cannotParseCapabilities
    /// One or more required capabilities are missing
    case missingCapabilities(hasNetRaw: Bool, hasNetAdmin: Bool)
}

// MARK: - Capability Bit Masks

/// Linux capability bit masks (from include/uapi/linux/capability.h)
/// CapEff is a hex value where each bit represents a capability
private let CAP_NET_ADMIN_MASK: UInt64 = 0x1000  // Bit 12 (1 << 12)
private let CAP_NET_RAW_MASK: UInt64 = 0x2000    // Bit 13 (1 << 13)

// MARK: - Public API

/// Check that the process has the required Linux capabilities for BLE access.
///
/// BluetoothLinux requires:
/// - CAP_NET_RAW: For raw socket access to HCI device
/// - CAP_NET_ADMIN: For configuring network interfaces
///
/// - Throws: `PermissionError` if capabilities cannot be read or are missing
func checkCapabilities() throws {
    // Read /proc/self/status to get effective capabilities
    let statusPath = "/proc/self/status"

    guard let statusContents = try? String(contentsOfFile: statusPath, encoding: .utf8) else {
        throw PermissionError.cannotReadCapabilities
    }

    // Find the CapEff line (effective capabilities)
    // Format: "CapEff:\t0000000000003000"
    var capEffValue: UInt64?
    for line in statusContents.split(separator: "\n") {
        if line.hasPrefix("CapEff:") {
            // Extract hex value after the tab
            let parts = line.split(separator: "\t")
            if parts.count >= 2 {
                let hexString = String(parts[1])
                capEffValue = UInt64(hexString, radix: 16)
            }
            break
        }
    }

    guard let capabilities = capEffValue else {
        throw PermissionError.cannotParseCapabilities
    }

    // Check for required capabilities
    let hasNetRaw = (capabilities & CAP_NET_RAW_MASK) != 0
    let hasNetAdmin = (capabilities & CAP_NET_ADMIN_MASK) != 0

    if !hasNetRaw || !hasNetAdmin {
        throw PermissionError.missingCapabilities(hasNetRaw: hasNetRaw, hasNetAdmin: hasNetAdmin)
    }
}

/// Format a permission error into a JSON-RPC Response suitable for Ruby.
///
/// - Parameter error: The permission error to format
/// - Returns: A Response with actionable error message
func formatPermissionError(_ error: PermissionError) -> Response {
    let binaryPath = CommandLine.arguments[0]

    switch error {
    case .cannotReadCapabilities:
        return Response.error(
            id: 0,
            code: LinuxErrorCode.missingCapabilities,
            message: "Cannot read /proc/self/status to check Linux capabilities."
        )

    case .cannotParseCapabilities:
        return Response.error(
            id: 0,
            code: LinuxErrorCode.missingCapabilities,
            message: "Cannot parse CapEff from /proc/self/status."
        )

    case .missingCapabilities(let hasNetRaw, let hasNetAdmin):
        var missingCaps: [String] = []
        if !hasNetRaw { missingCaps.append("CAP_NET_RAW") }
        if !hasNetAdmin { missingCaps.append("CAP_NET_ADMIN") }

        let message = """
            Missing Linux capabilities: \(missingCaps.joined(separator: ", "))

            Option 1 - Run with sudo:
              sudo your_ruby_script.rb

            Option 2 - Grant capabilities to helper binary:
              sudo setcap 'cap_net_raw,cap_net_admin=eip' \(binaryPath)

            After setting capabilities, run without sudo.
            """

        return Response.error(
            id: 0,
            code: LinuxErrorCode.missingCapabilities,
            message: message
        )
    }
}
