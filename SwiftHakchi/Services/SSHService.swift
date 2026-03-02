import Foundation
import USBBridge
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "SSH")

/// SSH connection errors
enum SSHError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case commandFailed(command: String, exitCode: Int, stderr: String)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Not connected to console via SSH"
        case .connectionFailed(let msg):
            return "SSH connection failed: \(msg)"
        case .commandFailed(let cmd, let code, let stderr):
            return "Command '\(cmd)' failed (exit \(code)): \(stderr)"
        case .transferFailed(let msg):
            return "File transfer failed: \(msg)"
        }
    }
}

/// Result of an SSH command execution — mirrors ClovershellResult for drop-in replacement
struct SSHResult {
    let stdout: String
    let stderr: String
    let stdoutData: Data
    let exitCode: Int

    var succeeded: Bool { exitCode == 0 }
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// SSH service using user-space RNDIS networking (no kernel driver needed).
/// Drop-in replacement for ClovershellService — same API shape.
///
/// Architecture: SSHService → ssh_bridge.c → libssh2 → tcpip.c → rndis.c → USB
actor SSHService {
    // ssh_session_t* is opaque from C
    private var session: OpaquePointer?

    var isConnected: Bool { session != nil }

    /// Open SSH connection via RNDIS to the console.
    /// Performs: USB open → RNDIS init → ARP → TCP connect → SSH handshake → auth
    func connect() throws {
        guard session == nil else { return }

        logger.info("Opening SSH session via RNDIS")
        let s = ssh_session_open(
            UInt16(RNDIS_VID), UInt16(RNDIS_PID),
            HOST_IP_STR, CONSOLE_IP_STR
        )
        guard let s else {
            logger.error("SSH session open failed")
            throw SSHError.connectionFailed("RNDIS/SSH connection failed")
        }
        session = s
        logger.info("SSH session established")
    }

    /// Close the SSH session and all underlying connections.
    func disconnect() {
        guard let s = session else { return }
        logger.info("Closing SSH session")
        ssh_session_close(s)
        session = nil
    }

    /// Execute a command on the console via SSH.
    func execute(_ command: String, timeout: Int = 30000) throws -> SSHResult {
        guard let s = session else {
            throw SSHError.notConnected
        }

        logger.info("Exec: \(command)")

        var result = ssh_exec_result_t()
        let ret = ssh_exec(s, command, &result, Int32(timeout))

        defer { ssh_result_free(&result) }

        guard ret == 0 else {
            logger.error("Exec failed with code \(ret)")
            throw SSHError.connectionFailed("SSH exec failed: \(ret)")
        }

        // Preserve raw binary data (for kernel dumps etc.)
        let stdoutData: Data
        if result.stdout_buf != nil && result.stdout_len > 0 {
            stdoutData = Data(bytes: result.stdout_buf, count: Int(result.stdout_len))
        } else {
            stdoutData = Data()
        }

        let stdout = String(data: stdoutData, encoding: .utf8)
            ?? String(stdoutData.prefix(min(stdoutData.count, 4096)).map {
                $0 < 0x80 ? Character(UnicodeScalar($0)) : "?"
            })
        let stderr = result.stderr_buf != nil
            ? String(cString: result.stderr_buf)
            : ""

        logger.info("Exec result: exit=\(result.exit_code), stdout=\(stdoutData.count) bytes")

        return SSHResult(
            stdout: stdout,
            stderr: stderr,
            stdoutData: stdoutData,
            exitCode: Int(result.exit_code)
        )
    }

    /// Upload data to a remote path via stdin pipe (cat > path)
    func upload(data: Data, to remotePath: String, timeout: Int = 60000) throws {
        guard let s = session else {
            throw SSHError.notConnected
        }

        logger.info("Upload \(data.count) bytes to \(remotePath)")

        let command = "cat > \"\(remotePath)\""
        var result = ssh_exec_result_t()

        let ret = data.withUnsafeBytes { dataPtr -> Int32 in
            guard let baseAddr = dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return ssh_exec_stdin(s, command, baseAddr, UInt32(data.count),
                                   &result, Int32(timeout))
        }

        defer { ssh_result_free(&result) }

        guard ret == 0 && result.exit_code == 0 else {
            let stderr = result.stderr_buf != nil ? String(cString: result.stderr_buf) : ""
            logger.error("Upload failed: ret=\(ret), exit=\(result.exit_code), stderr=\(stderr)")
            throw SSHError.transferFailed(stderr)
        }

        logger.info("Upload complete")
    }

    /// Upload tar data and extract on console
    func uploadTar(data: Data, to directory: String, extraArgs: String = "",
                    timeout: Int = 120000) throws {
        guard let s = session else {
            throw SSHError.notConnected
        }

        logger.info("Upload tar \(data.count) bytes to \(directory)")

        let command = extraArgs.isEmpty
            ? "tar -xvC \"\(directory)\""
            : "tar -xvC \"\(directory)\" \(extraArgs)"
        var result = ssh_exec_result_t()

        let ret = data.withUnsafeBytes { dataPtr -> Int32 in
            guard let baseAddr = dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return ssh_exec_stdin(s, command, baseAddr, UInt32(data.count),
                                   &result, Int32(timeout))
        }

        defer { ssh_result_free(&result) }

        let stderr = result.stderr_buf != nil ? String(cString: result.stderr_buf) : ""

        guard ret == 0 else {
            logger.error("Tar upload failed: ret=\(ret), stderr=\(stderr)")
            throw SSHError.transferFailed("SSH error \(ret): \(stderr)")
        }

        guard result.exit_code == 0 else {
            logger.error("Tar extraction failed: exit=\(result.exit_code), stderr=\(stderr)")
            throw SSHError.transferFailed("tar exit \(result.exit_code): \(stderr)")
        }

        logger.info("Tar upload complete")
    }

    /// Check if an RNDIS device is present on USB
    nonisolated static func deviceExists() -> Bool {
        return ssh_device_exists()
    }
}
