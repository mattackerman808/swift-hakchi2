import Foundation

/// SSH connection errors
enum SSHError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case commandFailed(command: String, exitCode: Int32, stderr: String)
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

/// SSH result from a command execution
struct SSHResult {
    let stdout: String
    let stderr: String
    let exitCode: Int32

    var succeeded: Bool { exitCode == 0 }
    var output: String { stdout.trimmingCharacters(in: .whitespacesAndNewlines) }
}

/// SSH service for communicating with the console post-boot.
/// Uses Process to shell out to ssh command for now — NMSSH integration later.
actor SSHService {
    private var host: String?
    private var port: Int = 22
    private let username = "root"

    var isConnected: Bool { host != nil }

    func connect(host: String, port: Int = 22) async throws {
        self.host = host
        self.port = port

        // Verify connectivity
        let result = try await execute("echo connected")
        guard result.succeeded else {
            self.host = nil
            throw SSHError.connectionFailed("Failed to verify SSH connection")
        }
    }

    func disconnect() {
        host = nil
    }

    /// Execute a command on the console via SSH
    func execute(_ command: String) async throws -> SSHResult {
        guard let host = host else {
            throw SSHError.notConnected
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=5",
            "-o", "LogLevel=ERROR",
            "-p", "\(port)",
            "\(username)@\(host)",
            command
        ]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()

        return SSHResult(
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? "",
            exitCode: process.terminationStatus
        )
    }

    /// Upload data to a remote path via stdin pipe
    func upload(data: Data, to remotePath: String) async throws {
        guard let host = host else {
            throw SSHError.notConnected
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
            "-p", "\(port)",
            "\(username)@\(host)",
            "cat > \"\(remotePath)\""
        ]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        try process.run()

        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw SSHError.transferFailed(stderr)
        }
    }

    /// Upload a file and make it executable
    func uploadExecutable(data: Data, to remotePath: String) async throws {
        try await upload(data: data, to: remotePath)
        let result = try await execute("chmod +x \"\(remotePath)\"")
        guard result.succeeded else {
            throw SSHError.commandFailed(command: "chmod", exitCode: result.exitCode, stderr: result.stderr)
        }
    }

    /// Stream a tar archive to the console and extract it
    func uploadTar(data: Data, to directory: String) async throws {
        guard let host = host else {
            throw SSHError.notConnected
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "StrictHostKeyChecking=no",
            "-o", "UserKnownHostsFile=/dev/null",
            "-o", "ConnectTimeout=10",
            "-o", "LogLevel=ERROR",
            "-p", "\(port)",
            "\(username)@\(host)",
            "tar -xvC \"\(directory)\""
        ]

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe

        try process.run()

        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                                encoding: .utf8) ?? ""
            throw SSHError.transferFailed(stderr)
        }
    }
}
