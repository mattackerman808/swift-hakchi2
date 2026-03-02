import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "FlashService")

/// Handles the complete flash/install/uninstall workflows.
/// After FEL memboot, the console boots with the RNDIS USB gadget.
/// We communicate via user-space RNDIS + TCP/IP + SSH (same as upstream Windows client).
actor FlashService {
    private let felService: FELService
    private weak var deviceManager: DeviceManager?

    init(felService: FELService, deviceManager: DeviceManager) {
        self.felService = felService
        self.deviceManager = deviceManager
    }

    // MARK: - Install Hakchi

    /// Full install workflow:
    /// 1. FEL: InitDram + memboot (cmdline: hakchi-shell → RNDIS gadget)
    /// 2. Wait for RNDIS device + SSH connection
    /// 3. Dump stock kernel backup
    /// 4. Grow data partition if needed (kexec reboot + reconnect)
    /// 5. Write install config flags
    /// 6. Transfer base hmods + hakchi.hmod
    /// 7. Boot hakchi (installs + reboots)
    func installHakchi(
        fes1: Data, uboot: Data, bootImg: Data,
        baseHmods: Data, hakchiHmod: Data,
        backupSettings: BackupSettings,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        // Step 1: FEL memboot
        logger.info("Step 1: FEL memboot")
        progress("Initializing DRAM...", 0.05)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)
        logger.info("FEL memboot complete")

        // Step 2: Wait for RNDIS device + SSH connection
        logger.info("Step 2: Waiting for RNDIS/SSH")
        progress("Waiting for console to boot...", 0.10)
        var shell = try await waitForSSH(timeout: 90)
        logger.info("SSH connected")

        // Step 3: Dump stock kernel (backup) — MANDATORY before any modifications
        if backupSettings.enabled {
            progress("Backing up stock kernel...", 0.15)
            let backupPath = try await dumpStockKernel(shell: shell, saveDirectory: backupSettings.directory)
            progress("Kernel backup verified: \(backupPath.lastPathComponent)", 0.20)
            logger.info("Kernel backup saved and verified: \(backupPath.path)")
        } else {
            logger.warning("Kernel backup SKIPPED by user")
            progress("Skipping kernel backup (user choice)...", 0.20)
        }

        // Step 4: Grow data partition (if needed)
        progress("Checking data partition...", 0.25)
        let grew = try await growDataPartition(shell: shell)

        if grew {
            // Partition table changed — must reboot for it to take effect.
            // Upload boot.img → kexec → RNDIS reconnects.
            logger.info("Partition grew — kexec rebooting for partition table to take effect")
            progress("Uploading boot image for reboot...", 0.28)
            try await shell.upload(data: bootImg, to: "/tmp/boot.img")

            progress("Rebooting after partition resize...", 0.30)
            logger.info("Executing kexec memboot from shell")
            // memboot loads the kernel via kexec and reboots.
            // Connection will drop during kexec -e.
            _ = try? await shell.execute(
                "source /hakchi/script/base && memboot /tmp/boot.img hakchi-memboot hakchi-shell",
                timeout: 10000
            )
            await shell.disconnect()

            // Wait for RNDIS/SSH to come back after kexec reboot
            progress("Waiting for console to reboot...", 0.35)
            shell = try await waitForSSH(timeout: 120)
            logger.info("SSH reconnected after grow kexec reboot")
        }

        try await continueInstall(shell: shell, baseHmods: baseHmods,
                                   hakchiHmod: hakchiHmod, bootImg: bootImg,
                                   progress: progress, startProgress: 0.45)
    }

    private func continueInstall(
        shell: SSHService,
        baseHmods: Data, hakchiHmod: Data, bootImg: Data,
        progress: @Sendable (String, Double) -> Void,
        startProgress: Double
    ) async throws {
        // Step 5: Handle install config
        progress("Configuring installation...", startProgress)
        logger.info("Step 5: Writing install config")
        let configResult = try await shell.execute(
            "echo \"cf_install=y\" >> /hakchi/config && echo \"cf_update=y\" >> /hakchi/config"
        )
        logger.info("Config write: exit=\(configResult.exitCode), stderr='\(configResult.stderr)'")

        let mkdirResult = try await shell.execute("mkdir -p /hakchi/transfer/")
        logger.info("mkdir: exit=\(mkdirResult.exitCode)")

        // Verify config was written
        let configCheck = try await shell.execute("cat /hakchi/config")
        logger.info("Config contents:\n\(configCheck.stdout)")
        guard configCheck.stdout.contains("cf_install=y") else {
            throw FlashError.commandFailed("Config flags not written: \(configCheck.stdout)")
        }

        // Step 6: Transfer base hmods (exclude hakchi.hmod — transferred separately)
        progress("Transferring base modules...", startProgress + 0.10)
        logger.info("Step 6: Transferring base hmods (\(baseHmods.count) bytes)")
        try await shell.uploadTar(data: baseHmods, to: "/hakchi/transfer",
                                   extraArgs: "--exclude='./hakchi.hmod'")

        // Verify transfer
        let lsResult1 = try await shell.execute("ls -la /hakchi/transfer/")
        logger.info("After base hmods transfer:\n\(lsResult1.stdout)")

        // Step 7: Transfer hakchi.hmod (stock — no patching needed for RNDIS)
        progress("Transferring hakchi module...", startProgress + 0.15)
        try await shell.upload(data: hakchiHmod, to: "/hakchi/transfer/hakchi.hmod")

        // Step 8: Run boot command (installs everything + reboots)
        progress("Installing and rebooting...", startProgress + 0.30)
        print("[INSTALL] Running boot command")
        let bootResult = try await shell.execute("boot", timeout: 300000)

        print("[INSTALL] Boot exit=\(bootResult.exitCode), stdout=\(bootResult.stdoutData.count) bytes")
        if !bootResult.stderr.isEmpty {
            print("[INSTALL] Boot stderr: \(bootResult.stderr)")
        }

        if bootResult.stdout.contains("flash md5 mismatch!") {
            await shell.disconnect()
            throw FlashError.flashMismatch(bootResult.stdout)
        }

        // Disconnect SSH to release the RNDIS USB handle before the console
        // reboots. Without this, DeviceManager's auto-reconnect fails because
        // rndis_open() can't claim the device while the old handle exists.
        await shell.disconnect()

        progress("Installation complete!", 1.0)
        print("[INSTALL] Install complete")
    }

    // MARK: - Uninstall Hakchi

    func uninstallHakchi(
        fes1: Data, uboot: Data, bootImg: Data,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        progress("Booting recovery...", 0.1)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)

        progress("Waiting for console...", 0.3)
        let shell = try await waitForSSH(timeout: 90)

        progress("Uninstalling hakchi...", 0.5)
        _ = try await shell.execute("hakchi mount_base")
        _ = try await shell.execute("hakchi mod_uninstall")
        _ = try await shell.execute("hakchi umount_base")

        progress("Rebooting...", 0.8)
        _ = try? await shell.execute("reboot")
        await shell.disconnect()

        progress("Uninstall complete!", 1.0)
    }

    // MARK: - Factory Reset

    func factoryReset(
        fes1: Data, uboot: Data, bootImg: Data,
        kernelImage: Data?,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        progress("Booting recovery...", 0.05)
        try await felService.memboot(fes1Data: fes1, ubootData: uboot, bootImgData: bootImg)

        progress("Waiting for console...", 0.15)
        let shell = try await waitForSSH(timeout: 90)

        // Step 1: Get the stock kernel — try console backup first, fall back to user file
        progress("Retrieving stock kernel...", 0.25)
        var stockKernel: Data?

        // Try getting backup from the console's backup2 partition
        if let result = try? await shell.execute("hakchi getBackup2", timeout: 60000),
           result.succeeded,
           result.stdoutData.count > 1024,
           Self.verifyKernelBackup(result.stdoutData) {
            stockKernel = result.stdoutData
            logger.info("Got stock kernel from console backup2 (\(result.stdoutData.count) bytes)")
        }

        // Fall back to user-provided kernel image
        if stockKernel == nil, let kernelImage, Self.verifyKernelBackup(kernelImage) {
            stockKernel = kernelImage
            logger.info("Using user-provided kernel image (\(kernelImage.count) bytes)")
        }

        guard let stockKernel else {
            await shell.disconnect()
            throw FlashError.commandFailed("No valid stock kernel image available")
        }

        // Step 2: Upload and flash the stock kernel
        progress("Uploading stock kernel...", 0.35)
        try await shell.upload(data: stockKernel, to: "/kernel.img")

        progress("Validating kernel...", 0.45)
        let checkResult = try await shell.execute("sntool check /kernel.img")
        logger.info("sntool check: exit=\(checkResult.exitCode) out='\(checkResult.stdout)'")

        let patchResult = try await shell.execute("sntool kernel /kernel.img")
        logger.info("sntool kernel: exit=\(patchResult.exitCode) out='\(patchResult.stdout)'")

        progress("Flashing stock kernel...", 0.55)
        let flashResult = try await shell.execute("hakchi flashBoot2 /kernel.img", timeout: 60000)
        logger.info("flashBoot2: exit=\(flashResult.exitCode) out='\(flashResult.stdout)'")
        if !flashResult.succeeded {
            logger.error("flashBoot2 failed: \(flashResult.stderr)")
        }

        // Step 3: Uninstall hakchi
        progress("Removing hakchi...", 0.65)
        _ = try await shell.execute("hakchi mount_base")
        _ = try await shell.execute("hakchi mod_uninstall reset")
        _ = try await shell.execute("hakchi umount_base")

        // Step 4: Reboot
        progress("Rebooting...", 0.85)
        _ = try? await shell.execute("sync; umount -ar; reboot -f")
        await shell.disconnect()

        progress("Factory reset complete!", 1.0)
    }

    // MARK: - Dump Stock Kernel (standalone)

    func dumpStockKernel(
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        let shell = SSHService()
        do {
            try await shell.connect()
        } catch {
            throw FlashError.notConnected
        }

        progress("Reading stock kernel...", 0.3)
        let backupPath = try await dumpStockKernel(shell: shell)
        await shell.disconnect()
        progress("Kernel backup saved to \(backupPath.lastPathComponent)!", 1.0)
    }

    // MARK: - Helpers

    /// Wait for RNDIS device to appear and SSH to connect after memboot.
    /// After FEL exec, the device goes through three phases:
    /// 1. FEL device disappears (kernel takes over)
    /// 2. RNDIS gadget (0x04E8:0x6863) appears
    /// 3. SSH starts accepting connections
    private func waitForSSH(timeout: TimeInterval) async throws -> SSHService {
        logger.info("Waiting for RNDIS/SSH (timeout: \(timeout)s)")
        let deadline = Date().addingTimeInterval(timeout)

        // Phase 1: Wait for FEL device to disappear (kernel handoff)
        logger.info("Phase 1: Waiting for FEL device to disappear")
        let disappearDeadline = Date().addingTimeInterval(15)
        while Date() < disappearDeadline {
            if !SSHService.deviceExists() {
                logger.info("RNDIS device not yet present (FEL still up or transitioning)")
            }
            // Wait for FEL to go away (different VID/PID won't match RNDIS check)
            try await Task.sleep(for: .milliseconds(500))
            if SSHService.deviceExists() {
                break // RNDIS appeared
            }
        }

        // Phase 2: Wait for RNDIS device to appear
        logger.info("Phase 2: Waiting for RNDIS USB device")
        while Date() < deadline {
            if SSHService.deviceExists() {
                logger.info("RNDIS device appeared, waiting for boot to complete...")
                // Wait for the console to fully boot the ramdisk, start inetd + dropbear
                try await Task.sleep(for: .seconds(5))
                break
            }
            try await Task.sleep(for: .seconds(1))
        }

        guard Date() < deadline else {
            logger.error("Timed out waiting for RNDIS device")
            throw FlashError.timeout
        }

        // Phase 3: Try SSH connections until one succeeds
        logger.info("Phase 3: Connecting via SSH over RNDIS")
        while Date() < deadline {
            let shell = SSHService()
            do {
                try await shell.connect()
                // Give the shell a moment to be ready after SSH auth
                try await Task.sleep(for: .milliseconds(500))
                let result = try await shell.execute("echo ready", timeout: 15000)
                if result.succeeded {
                    logger.info("SSH verified with test command")
                    return shell
                }
                logger.warning("SSH test command failed: exit=\(result.exitCode)")
                await shell.disconnect()
            } catch {
                logger.warning("SSH connect attempt failed: \(error.localizedDescription)")
                await shell.disconnect()
            }
            try await Task.sleep(for: .seconds(3))
        }

        logger.error("Timed out waiting for SSH connection")
        throw FlashError.timeout
    }

    /// Dump the stock kernel to disk. Returns the path where it was saved.
    @discardableResult
    private func dumpStockKernel(shell: SSHService, saveDirectory: URL? = nil) async throws -> URL {
        let dumpDir = saveDirectory ?? AppConfig.shared.dumpDirectory
        try FileManager.default.createDirectory(at: dumpDir, withIntermediateDirectories: true)
        let backupPath = dumpDir.appendingPathComponent("kernel_backup.img")

        // Skip if a valid backup already exists
        if FileManager.default.fileExists(atPath: backupPath.path) {
            if let existingData = try? Data(contentsOf: backupPath),
               Self.verifyKernelBackup(existingData) {
                logger.info("Valid kernel backup already exists (\(existingData.count) bytes), skipping")
                return backupPath
            }
            logger.warning("Existing backup is invalid, re-dumping")
            try? FileManager.default.removeItem(at: backupPath)
        }

        // Try hakchi getBackup2 first
        if let result = try? await shell.execute("hakchi getBackup2", timeout: 60000),
           result.succeeded,
           result.stdoutData.count > 1024 {
            if Self.verifyKernelBackup(result.stdoutData) {
                try result.stdoutData.write(to: backupPath)
                logger.info("Stock kernel backed up via getBackup2 (\(result.stdoutData.count) bytes)")
                try verifyWrittenBackup(at: backupPath, expectedSize: result.stdoutData.count)
                return backupPath
            }
        }

        // Fallback: read from NAND
        if let result = try? await shell.execute("sunxi-flash read_boot2 30", timeout: 60000),
           result.succeeded,
           result.stdoutData.count > 1024 {
            if Self.verifyKernelBackup(result.stdoutData) {
                try result.stdoutData.write(to: backupPath)
                logger.info("Stock kernel backed up via sunxi-flash (\(result.stdoutData.count) bytes)")
                try verifyWrittenBackup(at: backupPath, expectedSize: result.stdoutData.count)
                return backupPath
            }
        }

        logger.error("Failed to dump stock kernel")
        throw FlashError.backupFailed
    }

    private static func verifyKernelBackup(_ data: Data) -> Bool {
        guard data.count > 65536 else { return false }
        guard data.count < 16 * 1024 * 1024 else { return false }

        let magic = Data("ANDROID!".utf8)
        if data.prefix(magic.count) == magic { return true }

        let header = data.prefix(16)
        let allZero = header.allSatisfy { $0 == 0 }
        let allFF = header.allSatisfy { $0 == 0xFF }
        return !(allZero || allFF)
    }

    private func verifyWrittenBackup(at path: URL, expectedSize: Int) throws {
        let written = try Data(contentsOf: path)
        guard written.count == expectedSize else {
            try? FileManager.default.removeItem(at: path)
            throw FlashError.backupVerificationFailed(expected: expectedSize, actual: written.count)
        }
    }

    private func growDataPartition(shell: SSHService) async throws -> Bool {
        let mdCheck = try await shell.execute("sntool ismd")
        if mdCheck.exitCode == 0 {
            logger.info("MD partitioning detected — skipping grow")
            return false
        }

        let partResult = try await shell.execute("sunxi-part")
        guard partResult.stdout.contains("UDISK") else {
            logger.info("No UDISK partition found — skipping grow")
            return false
        }
        let growResult = try await shell.execute("sunxi-part grow")
        return growResult.succeeded
    }
}

enum FlashError: Error, LocalizedError {
    case notConnected
    case timeout
    case flashMismatch(String)
    case commandFailed(String)
    case backupFailed
    case backupVerificationFailed(expected: Int, actual: Int)

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
        case .backupFailed:
            return "Failed to backup stock kernel. Install aborted — your console has not been modified."
        case .backupVerificationFailed(let expected, let actual):
            return "Kernel backup verification failed: expected \(expected) bytes but got \(actual) on disk. Install aborted."
        }
    }
}
