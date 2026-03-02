import SwiftUI
import AppKit
import Combine
import os
import UniformTypeIdentifiers

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "AppState")

/// Flash/task operation types
enum FlashOperation: Equatable {
    case installHakchi
    case uninstallHakchi
    case factoryReset
    case memboot
    case membootOriginal
    case dumpStockKernel
    case processHmods

    /// Whether this operation requires the console to be in FEL mode
    var requiresFEL: Bool {
        switch self {
        case .installHakchi, .uninstallHakchi, .factoryReset, .memboot:
            return true
        default:
            return false
        }
    }
}

/// Global application state, shared across the app via @EnvironmentObject
@MainActor
final class AppState: ObservableObject {
    // MARK: - Services
    let deviceManager = DeviceManager()
    let gameManager = GameManagerService()
    let taskRunner = TaskRunner()
    let payloads = PayloadService.shared

    // MARK: - UI State
    @Published var selectedGame: Game?
    @Published var searchText = ""
    @Published var showModHub = false
    @Published var showFoldersManager = false
    @Published var showScraper = false
    @Published var showTaskProgress = false
    @Published var showWaitingForDevice = false
    @Published var showInstallConfig = false

    // MARK: - Flash state
    @Published var pendingFlashOperation: FlashOperation?
    var pendingBackupSettings: BackupSettings?
    var pendingKernelImage: Data?

    private var cancellables = Set<AnyCancellable>()

    init() {
        // Forward objectWillChange from nested ObservableObjects
        deviceManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        gameManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        taskRunner.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)

        // When device connects/disconnects, pull or clear console games
        deviceManager.$isConnected
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected in
                guard let self else { return }
                if connected {
                    Task { await self.onConsoleConnected() }
                } else {
                    self.gameManager.clearConsoleGames()
                }
            }
            .store(in: &cancellables)

        // When FEL device appears and we have a pending operation, start it
        deviceManager.$felDevicePresent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] present in
                guard let self, present, let operation = self.pendingFlashOperation else { return }
                guard self.showWaitingForDevice else { return }
                logger.info("FEL device detected, starting pending operation")
                self.showWaitingForDevice = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    self.startFlashOperation(operation)
                }
            }
            .store(in: &cancellables)

        deviceManager.start()
    }

    // MARK: - Console connection

    private func onConsoleConnected() async {
        guard let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        await gameManager.pullGamesFromConsole(shell: shell, consoleType: consoleType)
    }

    // MARK: - Flash operations

    /// Request a flash operation. For install, shows config sheet first.
    /// If FEL is required but not present, shows the waiting dialog.
    func requestFlash(_ operation: FlashOperation) {
        logger.info("Flash requested: \(String(describing: operation))")
        pendingFlashOperation = operation

        // Suppress auto-connect immediately — we need the USB device for FEL
        if operation.requiresFEL {
            deviceManager.suppressAutoConnect = true
        }

        // Install gets a config sheet first (backup settings)
        if operation == .installHakchi {
            showInstallConfig = true
            return
        }

        // Factory reset needs a stock kernel image to flash back
        if operation == .factoryReset {
            pickKernelImage { [weak self] kernelData in
                guard let self else { return }
                self.pendingKernelImage = kernelData

                if !self.deviceManager.felDevicePresent {
                    logger.info("FEL device not present, showing waiting dialog")
                    self.showWaitingForDevice = true
                    return
                }
                self.startFlashOperation(operation)
            }
            return
        }

        if operation.requiresFEL && !deviceManager.felDevicePresent {
            logger.info("FEL device not present, showing waiting dialog")
            showWaitingForDevice = true
            return
        }

        startFlashOperation(operation)
    }

    /// Called when user confirms install from the config sheet
    func confirmInstall(backupSettings: BackupSettings) {
        logger.info("Install confirmed, backup: \(backupSettings.enabled)")
        pendingBackupSettings = backupSettings
        showInstallConfig = false

        guard let operation = pendingFlashOperation else { return }
        if operation.requiresFEL && !deviceManager.felDevicePresent {
            logger.info("FEL device not present, showing waiting dialog")
            showWaitingForDevice = true
            return
        }

        startFlashOperation(operation)
    }

    /// Called when user cancels the install config sheet
    func cancelInstallConfig() {
        logger.info("User cancelled install config")
        pendingFlashOperation = nil
        pendingBackupSettings = nil
        showInstallConfig = false
        deviceManager.suppressAutoConnect = false
    }

    /// Called when user cancels the waiting dialog
    func cancelWaitingForDevice() {
        logger.info("User cancelled waiting for device")
        pendingFlashOperation = nil
        pendingBackupSettings = nil
        pendingKernelImage = nil
        showWaitingForDevice = false
        deviceManager.suppressAutoConnect = false
    }

    /// Show a file picker for the stock kernel image.
    /// Defaults to the dump directory where we save backups.
    private func pickKernelImage(completion: @escaping (Data?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select Stock Kernel Backup"
        panel.message = "Choose the kernel_backup.img file saved during install"
        panel.allowedContentTypes = [.data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = AppConfig.shared.dumpDirectory

        panel.begin { response in
            Task { @MainActor in
                guard response == .OK, let url = panel.url else {
                    logger.info("User cancelled kernel image picker")
                    self.pendingFlashOperation = nil
                    self.deviceManager.suppressAutoConnect = false
                    return
                }

                guard let data = try? Data(contentsOf: url) else {
                    logger.error("Failed to read kernel image from \(url.path)")
                    self.pendingFlashOperation = nil
                    self.deviceManager.suppressAutoConnect = false
                    return
                }

                logger.info("Kernel image selected: \(url.lastPathComponent) (\(data.count) bytes)")
                completion(data)
            }
        }
    }

    /// Actually start the flash operation (FEL device is confirmed present)
    private func startFlashOperation(_ operation: FlashOperation) {
        logger.info("Starting flash operation: \(String(describing: operation))")
        showTaskProgress = true

        // Suppress auto-connect while flash is in progress
        deviceManager.suppressAutoConnect = true

        let flashService = FlashService(
            felService: deviceManager.felService,
            deviceManager: deviceManager
        )

        switch operation {
        case .installHakchi:
            let backupSettings = pendingBackupSettings ?? BackupSettings(enabled: true, directory: nil)
            pendingBackupSettings = nil

            taskRunner.run(name: "Installing custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }

                runner.updateProgress(status: "Loading payloads...", fraction: 0.01)
                let fes1 = try self.payloads.fes1()
                runner.updateProgress(status: "Loading U-Boot...", fraction: 0.02)
                let uboot = try self.payloads.uboot()
                runner.updateProgress(status: "Loading boot image...", fraction: 0.03)
                let bootImg = try self.payloads.bootImg()
                runner.updateProgress(status: "Loading base modules...", fraction: 0.04)
                let baseHmods = try self.payloads.baseHmods()
                let hakchiHmod = try self.payloads.hakchiHmod()
                runner.updateProgress(status: "Payloads loaded, starting FEL...", fraction: 0.05)

                try await flashService.installHakchi(
                    fes1: fes1, uboot: uboot, bootImg: bootImg,
                    baseHmods: baseHmods, hakchiHmod: hakchiHmod,
                    backupSettings: backupSettings
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .uninstallHakchi:
            taskRunner.run(name: "Uninstalling custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try self.payloads.fes1()
                let uboot = try self.payloads.uboot()
                let bootImg = try self.payloads.bootImg()

                try await flashService.uninstallHakchi(
                    fes1: fes1, uboot: uboot, bootImg: bootImg
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .factoryReset:
            let kernelImage = pendingKernelImage
            pendingKernelImage = nil

            taskRunner.run(name: "Factory reset") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try self.payloads.fes1()
                let uboot = try self.payloads.uboot()
                let bootImg = try self.payloads.bootImg()

                try await flashService.factoryReset(
                    fes1: fes1, uboot: uboot, bootImg: bootImg,
                    kernelImage: kernelImage
                ) { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        case .memboot:
            taskRunner.run(name: "Membooting custom kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                let fes1 = try self.payloads.fes1()
                let uboot = try self.payloads.uboot()
                let bootImg = try self.payloads.bootImg()

                runner.updateProgress(status: "Initializing FEL...", fraction: 0.1)
                try await self.deviceManager.felService.memboot(
                    fes1Data: fes1, ubootData: uboot, bootImgData: bootImg
                )
                runner.updateProgress(status: "Memboot complete", fraction: 1.0)
            }

        case .dumpStockKernel:
            taskRunner.run(name: "Dumping stock kernel") { [weak self] runner in
                guard let self else { return }
                defer { Task { @MainActor in self.deviceManager.suppressAutoConnect = false } }
                try await flashService.dumpStockKernel { status, progress in
                    runner.updateProgress(status: status, fraction: progress)
                }
            }

        default:
            deviceManager.suppressAutoConnect = false
            break
        }
    }

    func rebootConsole() async {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        _ = try? await shell.execute("reboot")
    }

    func shutdownConsole() async {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        _ = try? await shell.execute("poweroff")
    }

    func syncGames() async {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        showTaskProgress = true

        taskRunner.run(name: "Syncing games") { [weak self] runner in
            guard let self else { return }
            let syncService = GameSyncService(
                shell: shell,
                consoleType: consoleType
            )
            try await syncService.syncGames(
                games: self.gameManager.games,
                gameSyncPath: "/var/lib/hakchi/games"
            ) { status, progress in
                runner.updateProgress(status: status, fraction: progress)
            }
        }
    }

    // MARK: - Filtered games

    var filteredGames: [Game] {
        if searchText.isEmpty {
            return gameManager.games
        }
        return gameManager.games.filter { game in
            game.name.localizedCaseInsensitiveContains(searchText)
        }
    }
}
