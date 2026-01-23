import Foundation

// MARK: - Daemon Error Types

/// Errors that can occur during BlueZ daemon conflict detection
enum DaemonError: Error {
    /// BlueZ bluetooth.service is currently active
    case bluetoothServiceActive
    /// Cannot check daemon status (includes reason)
    case cannotCheckDaemon(reason: String)
}

// MARK: - Public API

/// Check that the BlueZ Bluetooth daemon is not running.
///
/// BluetoothLinux requires exclusive access to the Bluetooth adapter.
/// If bluetoothd (BlueZ daemon) is running, it will conflict with
/// our direct HCI access.
///
/// On non-systemd systems (or if systemctl is not available), this
/// check is skipped - the user may be managing the daemon differently.
///
/// - Throws: `DaemonError.bluetoothServiceActive` if bluetooth.service is running
func checkBlueZDaemon() throws {
    let systemctlPath = "/usr/bin/systemctl"

    // Check if systemctl exists (non-systemd systems won't have it)
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: systemctlPath) else {
        // Not a systemd system - skip this check
        // User may be managing daemon manually or using different init system
        return
    }

    // Run: systemctl is-active --quiet bluetooth.service
    // Exit code 0 = active, non-zero = inactive or not found
    let process = Process()
    process.executableURL = URL(fileURLWithPath: systemctlPath)
    process.arguments = ["is-active", "--quiet", "bluetooth.service"]

    // Suppress stdout/stderr - we only care about exit code
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
        process.waitUntilExit()

        if process.terminationStatus == 0 {
            // Service is active - this is a conflict
            throw DaemonError.bluetoothServiceActive
        }
        // Non-zero exit = service not active (good)
    } catch let error as DaemonError {
        // Re-throw our errors
        throw error
    } catch {
        // Process failed to run - skip check rather than blocking user
        // This could happen if systemctl exists but has permission issues
        return
    }
}

/// Format a daemon error into a JSON-RPC Response suitable for Ruby.
///
/// - Parameter error: The daemon error to format
/// - Returns: A Response with actionable error message
func formatDaemonError(_ error: DaemonError) -> Response {
    switch error {
    case .bluetoothServiceActive:
        let message = """
            BlueZ Bluetooth daemon is running.

            The BluetoothLinux backend requires exclusive access to the Bluetooth adapter.
            BlueZ daemon (bluetoothd) must be stopped first.

            To stop temporarily:
              sudo systemctl stop bluetooth

            To disable permanently:
              sudo systemctl disable bluetooth

            Note: Other Bluetooth applications using BlueZ will not work while stopped.
            """

        return Response.error(
            id: 0,
            code: LinuxErrorCode.daemonConflict,
            message: message
        )

    case .cannotCheckDaemon(let reason):
        return Response.error(
            id: 0,
            code: LinuxErrorCode.daemonConflict,
            message: "Cannot check BlueZ daemon status: \(reason)"
        )
    }
}
