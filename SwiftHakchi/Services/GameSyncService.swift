import Foundation

/// Syncs games to the console via SSH tar streaming
actor GameSyncService {
    private let ssh: SSHService
    private let consoleType: ConsoleType

    init(ssh: SSHService, consoleType: ConsoleType) {
        self.ssh = ssh
        self.consoleType = consoleType
    }

    /// Sync selected games to the console
    func syncGames(
        games: [Game],
        gameSyncPath: String,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        let selectedGames = games.filter { $0.isSelected }
        guard !selectedGames.isEmpty else { return }

        // Clean existing games
        progress("Preparing console...", 0.05)
        _ = try await ssh.execute("hakchi mount_base")
        _ = try await ssh.execute("rm -rf \(gameSyncPath)/CLV-*")

        let total = Double(selectedGames.count)

        for (index, game) in selectedGames.enumerated() {
            let fraction = Double(index) / total
            progress("Uploading \(game.name)...", 0.1 + fraction * 0.8)

            // Build tar of the game directory
            let gameDir = URL(fileURLWithPath: game.romPath)
            guard FileManager.default.fileExists(atPath: gameDir.path) else { continue }

            // Use system tar to create archive
            let tarProcess = Process()
            tarProcess.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            tarProcess.arguments = ["-cf", "-", "-C", gameDir.deletingLastPathComponent().path, gameDir.lastPathComponent]

            let pipe = Pipe()
            tarProcess.standardOutput = pipe

            try tarProcess.run()
            tarProcess.waitUntilExit()

            let tarData = pipe.fileHandleForReading.readDataToEndOfFile()
            guard !tarData.isEmpty else { continue }

            // Stream tar to console
            try await ssh.uploadTar(data: tarData, to: gameSyncPath)
        }

        // Sync and unmount
        progress("Finalizing...", 0.95)
        _ = try await ssh.execute("sync")
        _ = try await ssh.execute("hakchi umount_base")

        progress("Sync complete!", 1.0)
    }
}
