import Foundation
import USBBridge
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "Clovershell")

/// Result of a Clovershell command execution
struct ClovershellResult {
    let stdout: String
    let stderr: String
    let stdoutData: Data  // Raw binary stdout (not corrupted by String conversion)
    let exitCode: Int

    var succeeded: Bool { exitCode == 0 }
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// Clovershell USB shell service for communicating with the console after memboot.
/// Uses the custom Clovershell USB protocol (same VID/PID as FEL, different framing).
actor ClovershellService {
    // clovershell_conn_t* is opaque — Swift imports as OpaquePointer
    private var conn: OpaquePointer?

    var isConnected: Bool { conn != nil }

    /// Open connection to Clovershell device
    func connect() throws {
        guard conn == nil else { return }

        logger.info("Opening Clovershell connection")
        let c = clovershell_open()
        guard c != nil else {
            logger.error("Failed to open Clovershell device")
            throw ClovershellError.connectionFailed
        }
        conn = c
        logger.info("Clovershell connected")
    }

    /// Close the connection
    func disconnect() {
        guard let c = conn else { return }
        logger.info("Closing Clovershell connection")
        clovershell_close(c)
        conn = nil
    }

    /// Execute a command on the console
    func execute(_ command: String, timeout: Int = 30000) throws -> ClovershellResult {
        guard let c = conn else {
            throw ClovershellError.notConnected
        }

        logger.info("Exec: \(command)")

        var result = clovershell_exec_result_t()
        let ret = clovershell_exec(c, command, &result, Int32(timeout))

        defer { clovershell_result_free(&result) }

        guard ret == 0 else {
            logger.error("Exec failed with code \(ret)")
            throw ClovershellError.execFailed(ret)
        }

        // Preserve raw binary data (for kernel dumps etc.)
        let stdoutData: Data
        if result.stdout_buf != nil && result.stdout_len > 0 {
            stdoutData = Data(bytes: result.stdout_buf, count: Int(result.stdout_len))
        } else {
            stdoutData = Data()
        }

        // String versions for text commands (safe for null bytes in binary)
        let stdout = String(data: stdoutData, encoding: .utf8)
            ?? String(stdoutData.prefix(min(stdoutData.count, 4096)).map { $0 < 0x80 ? Character(UnicodeScalar($0)) : "?" })
        let stderr = result.stderr_buf != nil
            ? String(cString: result.stderr_buf)
            : ""

        logger.info("Exec result: exit=\(result.exit_code), stdout=\(stdoutData.count) bytes")

        return ClovershellResult(
            stdout: stdout,
            stderr: stderr,
            stdoutData: stdoutData,
            exitCode: Int(result.exit_code)
        )
    }

    /// Upload data to a remote path via stdin pipe (cat > path)
    func upload(data: Data, to remotePath: String, timeout: Int = 60000) throws {
        guard let c = conn else {
            throw ClovershellError.notConnected
        }

        logger.info("Upload \(data.count) bytes to \(remotePath)")

        let command = "cat > \"\(remotePath)\""
        var result = clovershell_exec_result_t()

        let ret = data.withUnsafeBytes { dataPtr -> Int32 in
            guard let baseAddr = dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return clovershell_exec_stdin(
                c, command,
                baseAddr, Int32(data.count),
                &result, Int32(timeout)
            )
        }

        defer { clovershell_result_free(&result) }

        guard ret == 0 && result.exit_code == 0 else {
            let stderr = result.stderr_buf != nil ? String(cString: result.stderr_buf) : ""
            logger.error("Upload failed: ret=\(ret), exit=\(result.exit_code), stderr=\(stderr)")
            throw ClovershellError.transferFailed(stderr)
        }

        logger.info("Upload complete")
    }

    /// Upload tar data and extract on console
    func uploadTar(data: Data, to directory: String, extraArgs: String = "", timeout: Int = 120000) throws {
        guard let c = conn else {
            throw ClovershellError.notConnected
        }

        logger.info("Upload tar \(data.count) bytes to \(directory)")

        let command = extraArgs.isEmpty
            ? "tar -xvC \"\(directory)\""
            : "tar -xvC \"\(directory)\" \(extraArgs)"
        var result = clovershell_exec_result_t()

        let ret = data.withUnsafeBytes { dataPtr -> Int32 in
            guard let baseAddr = dataPtr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return -1
            }
            return clovershell_exec_stdin(
                c, command,
                baseAddr, Int32(data.count),
                &result, Int32(timeout)
            )
        }

        defer { clovershell_result_free(&result) }

        let stderr = result.stderr_buf != nil ? String(cString: result.stderr_buf) : ""

        guard ret == 0 else {
            logger.error("Tar upload failed: ret=\(ret), stderr=\(stderr)")
            throw ClovershellError.transferFailed("clovershell error \(ret): \(stderr)")
        }

        guard result.exit_code == 0 else {
            logger.error("Tar extraction failed: exit=\(result.exit_code), stderr=\(stderr)")
            throw ClovershellError.transferFailed("tar exit \(result.exit_code): \(stderr)")
        }

        logger.info("Tar upload complete")
    }

    /// Check if a Clovershell device is present on USB
    nonisolated static func deviceExists() -> Bool {
        return clovershell_device_exists()
    }
}

enum ClovershellError: Error, LocalizedError {
    case connectionFailed
    case notConnected
    case execFailed(Int32)
    case transferFailed(String)

    var errorDescription: String? {
        switch self {
        case .connectionFailed:
            return "Failed to connect to console via Clovershell USB"
        case .notConnected:
            return "Not connected to console"
        case .execFailed(let code):
            return "Command execution failed (code: \(code))"
        case .transferFailed(let msg):
            return "File transfer failed: \(msg)"
        }
    }
}
