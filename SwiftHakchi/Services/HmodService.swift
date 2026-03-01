import Foundation

/// Manages hmod installation/uninstallation on the console
actor HmodService {
    private let ssh: SSHService

    init(ssh: SSHService) {
        self.ssh = ssh
    }

    /// Get list of installed hmods
    func installedHmods() async throws -> [String] {
        let result = try await ssh.execute("ls /var/lib/hakchi/hmod/installed/ 2>/dev/null")
        guard result.succeeded else { return [] }
        return result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }

    /// Transfer an hmod file to the console
    func transferHmod(data: Data, name: String) async throws {
        _ = try await ssh.execute("mkdir -p /hakchi/transfer")
        try await ssh.upload(data: data, to: "/hakchi/transfer/\(name)")
    }

    /// Transfer a tar of hmods to the console
    func transferHmods(tarData: Data) async throws {
        _ = try await ssh.execute("mkdir -p /hakchi/transfer")
        try await ssh.uploadTar(data: tarData, to: "/hakchi/transfer")
    }

    /// Install transferred hmods
    func installTransferred() async throws {
        let result = try await ssh.execute("hakchi pack_install")
        guard result.succeeded else {
            throw SSHError.commandFailed(command: "hakchi pack_install",
                                         exitCode: result.exitCode,
                                         stderr: result.stderr)
        }
    }

    /// Uninstall specific hmods
    func uninstallHmods(_ names: [String]) async throws {
        for name in names {
            _ = try await ssh.execute("hakchi pack_uninstall \(name)")
        }
    }
}
