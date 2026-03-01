import Foundation

/// Handles the complete flash/install/uninstall workflows
actor FlashService {
    private let felService: FELService
    private weak var deviceManager: DeviceManager?

    init(felService: FELService, deviceManager: DeviceManager) {
        self.felService = felService
        self.deviceManager = deviceManager
    }

    // MARK: - Install Hakchi

    /// Full install workflow:
    /// 1. FEL: InitDram + memboot
    /// 2. Wait for SSH
    /// 3. Grow data partition if needed
    /// 4. Write install config flags
    /// 5. Transfer base hmods + hakchi.hmod
    /// 6. Boot hakchi (installs + reboots)
    func installHakchi(
        fes1: Data, uboot: Data, bootImg: Data,
        baseHmods: Data, hakchiHmod: Data,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        // Step 1: FEL memboot
        progress("Initializing DRAM...", 0.05)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)

        // Step 2: Wait for SSH reconnect
        progress("Waiting for console to boot...", 0.15)
        let ssh = try await waitForSSH(timeout: 120)

        // Step 3: Dump stock kernel (backup)
        progress("Backing up stock kernel...", 0.25)
        await dumpStockKernel(ssh: ssh)

        // Step 4: Grow data partition
        progress("Checking data partition...", 0.35)
        let didGrow = try await growDataPartition(ssh: ssh)

        if didGrow {
            // Re-memboot to pick up new partition table
            progress("Rebooting after partition resize...", 0.40)
            _ = try? await ssh.execute("reboot")
            try await Task.sleep(for: .seconds(5))

            // Need to FEL boot again
            try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)
            progress("Waiting for console...", 0.45)
            _ = try await waitForSSH(timeout: 120)
        }

        // Step 5: Handle install config
        progress("Configuring installation...", 0.55)
        try await handleInstall(ssh: ssh)

        // Step 6: Transfer base hmods
        progress("Transferring base modules...", 0.65)
        _ = try await ssh.execute("mkdir -p /hakchi/transfer")
        try await ssh.uploadTar(data: baseHmods, to: "/hakchi/transfer")

        // Step 7: Transfer hakchi.hmod
        progress("Transferring hakchi module...", 0.75)
        try await ssh.upload(data: hakchiHmod, to: "/hakchi/transfer/hakchi.hmod")

        // Step 8: Boot hakchi (installs everything + reboots via kexec)
        progress("Installing and rebooting...", 0.85)
        let bootResult = try await ssh.execute("boot")

        // Check for flash errors
        if bootResult.stdout.contains("flash md5 mismatch!") {
            throw FlashError.flashMismatch(bootResult.stdout)
        }

        // Step 9: Wait for final reconnect
        progress("Waiting for console to reboot...", 0.95)
        _ = try? await waitForSSH(timeout: 120)

        progress("Installation complete!", 1.0)
    }

    // MARK: - Uninstall Hakchi

    func uninstallHakchi(
        fes1: Data, uboot: Data, bootImg: Data,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        progress("Booting recovery...", 0.1)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)

        progress("Waiting for console...", 0.3)
        let ssh = try await waitForSSH(timeout: 120)

        progress("Uninstalling hakchi...", 0.5)
        _ = try await ssh.execute("hakchi mount_base")
        _ = try await ssh.execute("hakchi mod_uninstall")
        _ = try await ssh.execute("hakchi umount_base")

        progress("Rebooting...", 0.8)
        _ = try? await ssh.execute("reboot")

        progress("Uninstall complete!", 1.0)
    }

    // MARK: - Factory Reset

    func factoryReset(
        fes1: Data, uboot: Data, bootImg: Data,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        progress("Booting recovery...", 0.1)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)

        progress("Waiting for console...", 0.3)
        let ssh = try await waitForSSH(timeout: 120)

        progress("Resetting to factory state...", 0.5)
        _ = try await ssh.execute("hakchi mount_base")
        _ = try await ssh.execute("hakchi mod_uninstall reset")
        _ = try await ssh.execute("hakchi umount_base")

        progress("Rebooting...", 0.8)
        _ = try? await ssh.execute("reboot")

        progress("Factory reset complete!", 1.0)
    }

    // MARK: - Dump Stock Kernel

    func dumpStockKernel(
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        let ssh: SSHService
        if let existing = await deviceManager?.sshService {
            ssh = existing
        } else {
            throw FlashError.notConnected
        }

        progress("Reading stock kernel...", 0.3)
        await dumpStockKernel(ssh: ssh)
        progress("Kernel backup complete!", 1.0)
    }

    // MARK: - Helpers

    private func waitForSSH(timeout: TimeInterval) async throws -> SSHService {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            // Check if DeviceManager has established a connection
            if let ssh = await deviceManager?.sshService {
                let result = try? await ssh.execute("echo ready")
                if result?.succeeded == true {
                    return ssh
                }
            }
            try await Task.sleep(for: .seconds(2))
        }
        throw FlashError.timeout
    }

    private func dumpStockKernel(ssh: SSHService) async {
        let dumpDir = AppConfig.shared.dumpDirectory
        try? FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let backupPath = dumpDir.appendingPathComponent("kernel_backup.img")

        // Skip if already backed up
        if FileManager.default.fileExists(atPath: backupPath.path) {
            return
        }

        // Try hakchi getBackup2 first
        if let result = try? await ssh.execute("hakchi getBackup2"),
           result.succeeded,
           let data = result.stdout.data(using: .utf8), !data.isEmpty {
            try? data.write(to: backupPath)
            return
        }

        // Fallback: read from NAND
        if let result = try? await ssh.execute("sunxi-flash read_boot2 30"),
           result.succeeded,
           let data = result.stdout.data(using: .utf8), !data.isEmpty {
            try? data.write(to: backupPath)
        }
    }

    private func growDataPartition(ssh: SSHService) async throws -> Bool {
        let partResult = try await ssh.execute("sunxi-part")
        guard partResult.stdout.contains("UDISK") else {
            return false
        }
        let growResult = try await ssh.execute("sunxi-part grow")
        return growResult.succeeded
    }

    private func handleInstall(ssh: SSHService) async throws {
        _ = try await ssh.execute(
            "echo \"cf_install=y\" >> /hakchi/config && echo \"cf_update=y\" >> /hakchi/config"
        )
        _ = try await ssh.execute("mkdir -p /hakchi/transfer/")
    }
}

enum FlashError: Error, LocalizedError {
    case notConnected
    case timeout
    case flashMismatch(String)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Console is not connected"
        case .timeout:
            return "Timed out waiting for console to respond"
        case .flashMismatch(let detail):
            return "Flash verification failed: \(detail)"
        case .commandFailed(let cmd):
            return "Command failed: \(cmd)"
        }
    }
}
