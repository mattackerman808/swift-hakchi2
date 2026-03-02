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

/// Errors during game download from console
enum DownloadError: LocalizedError {
    case notFound(String)
    case noFiles(String)

    var errorDescription: String? {
        switch self {
        case .notFound(let code): return "Could not find game \(code) on the console."
        case .noFiles(let code): return "No downloadable files found for \(code)."
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
    @Published var showScraper = false
    @Published var showModuleManager = false
    @Published var showHelp = false
    @Published var showTaskProgress = false
    @Published var showWaitingForDevice = false
    @Published var showInstallConfig = false
    @Published var statusMessage: String?
    @Published var showSyncConfirmation = false
    @Published var showDeleteConfirmation = false
    var syncRemovedCount = 0

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

        // When API key is changed (not on initial load), auto-enrich library
        AppConfig.shared.$theGamesDbApiKey
            .removeDuplicates()
            .dropFirst()
            .filter { !$0.isEmpty }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.enrichLibrary()
            }
            .store(in: &cancellables)

        deviceManager.start()
    }

    // MARK: - Library Enrichment

    /// Enrich the game library with metadata from TheGamesDB
    func enrichLibrary() {
        let apiKey = AppConfig.shared.theGamesDbApiKey
        guard !apiKey.isEmpty else { return }
        showTaskProgress = true
        taskRunner.run(name: "Enriching library from TheGamesDB") { [weak self] runner in
            guard let self else { return }
            await self.gameManager.enrichLibraryFromTGDB(apiKey: apiKey) { status, fraction in
                runner.updateProgress(status: status, fraction: fraction)
            }
        }
    }

    // MARK: - Console connection

    private func onConsoleConnected() async {
        guard let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        let deviceId = deviceManager.uniqueId

        statusMessage = "Refreshing console status..."
        await gameManager.pullGamesFromConsole(shell: shell, consoleType: consoleType, deviceId: deviceId)
        gameManager.matchExistingGames()
        statusMessage = nil
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

    // MARK: - Download from Console

    /// Download a game's ROM files from the console to a user-chosen directory.
    func downloadGameFromConsole(game: Game) {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        let code = game.code

        // Determine remote path
        let remotePath: String
        if game.source == .stock {
            remotePath = "\(consoleType.originalGamesPath)/\(code)"
        } else {
            remotePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage/\(code)"
        }

        // Sanitize game name for use as filename
        let safeName = game.name
            .replacingOccurrences(of: #"[/:\\]"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        // Show save panel — user picks destination folder
        let panel = NSOpenPanel()
        panel.title = "Save Game ROM"
        panel.message = "Choose where to save \(game.name)"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Save Here"

        panel.begin { [weak self] response in
            guard let self else { return }
            Task { @MainActor in
                guard response == .OK, let destURL = panel.url else { return }

                self.showTaskProgress = true

                self.taskRunner.run(name: "Downloading \(game.name)") { runner in
                    runner.updateProgress(status: "Finding ROM on console...", fraction: 0.1)

                    // List remote files — find the ROM (skip .desktop, .png, .jpg, directories)
                    guard let listResult = try? await shell.execute("ls -1 \"\(remotePath)/\" 2>/dev/null"),
                          listResult.succeeded else {
                        throw DownloadError.notFound(code)
                    }

                    let files = listResult.output.components(separatedBy: .newlines)
                        .filter { !$0.isEmpty && !$0.hasPrefix(".") }

                    var romFile: String?
                    for filename in files {
                        if filename.hasSuffix(".png") || filename.hasSuffix(".jpg") { continue }
                        if filename.hasSuffix(".desktop") { continue }
                        let isDir = try? await shell.execute("[ -d \"\(remotePath)/\(filename)\" ] && echo yes")
                        if isDir?.output != "yes" {
                            romFile = filename
                            break
                        }
                    }

                    guard let romFilename = romFile else {
                        throw DownloadError.noFiles(code)
                    }

                    // Use game title with the ROM's file extension
                    let ext = (romFilename as NSString).pathExtension
                    let localName = ext.isEmpty ? safeName : "\(safeName).\(ext)"
                    let localFile = destURL.appendingPathComponent(localName)

                    runner.updateProgress(status: "Downloading \(localName)...", fraction: 0.2)

                    guard let result = try? await shell.execute(
                        "base64 \"\(remotePath)/\(romFilename)\" 2>/dev/null"
                    ), result.succeeded else {
                        throw DownloadError.noFiles(code)
                    }

                    let base64Str = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !base64Str.isEmpty,
                          let data = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                          !data.isEmpty else {
                        throw DownloadError.noFiles(code)
                    }

                    try data.write(to: localFile)

                    runner.updateProgress(
                        status: "Saved \(localName)",
                        fraction: 1.0
                    )
                }
            }
        }
    }

    func syncGames() async {
        guard deviceManager.isConnected, deviceManager.sshService != nil else { return }

        // Safety check: count games on console that would be removed by this sync
        let installedCodes = Set(AppConfig.shared.installedGameCodes)
        let selectedLocalCodes = Set(
            gameManager.games.filter { $0.source == .local && $0.isSelected }.map { $0.id }
        )
        let removedCount = installedCodes.subtracting(selectedLocalCodes).count
        if removedCount > 0 {
            syncRemovedCount = removedCount
            showSyncConfirmation = true
            return
        }

        performSync()
    }

    /// Actually run the sync (called directly or after user confirms)
    func confirmSync() {
        showSyncConfirmation = false
        performSync()
    }

    private func performSync() {
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

            // Refresh installed status after sync completes
            runner.updateProgress(status: "Verifying installed games...", fraction: 0.95)
            await self.gameManager.refreshInstalledStatus(shell: shell, consoleType: consoleType)
        }
    }

    // MARK: - Import from Console

    /// Import custom games from the console into the local library
    func importFromConsole() async {
        guard deviceManager.isConnected, let shell = deviceManager.sshService else { return }
        let consoleType = deviceManager.consoleType
        showTaskProgress = true

        taskRunner.run(name: "Importing games from console") { [weak self] runner in
            guard let self else { return }
            let count = await self.gameManager.importGamesFromConsole(
                shell: shell,
                consoleType: consoleType
            ) { status, progress in
                runner.updateProgress(status: status, fraction: progress)
            }
            runner.updateProgress(
                status: count > 0 ? "Imported \(count) game(s)" : "No new games to import",
                fraction: 1.0
            )
        }
    }

    // MARK: - Game navigation

    func selectNextGame() {
        let games = filteredGames.filter { !$0.isStock }
        guard !games.isEmpty else { return }
        if let current = selectedGame, let idx = games.firstIndex(of: current) {
            let next = games.index(after: idx)
            selectedGame = next < games.endIndex ? games[next] : games[games.startIndex]
        } else {
            selectedGame = games.first
        }
    }

    func selectPreviousGame() {
        let games = filteredGames.filter { !$0.isStock }
        guard !games.isEmpty else { return }
        if let current = selectedGame, let idx = games.firstIndex(of: current) {
            if idx > games.startIndex {
                selectedGame = games[games.index(before: idx)]
            } else {
                selectedGame = games.last
            }
        } else {
            selectedGame = games.last
        }
    }

    // MARK: - Game actions

    func deleteSelectedGame() {
        guard let game = selectedGame, game.source == .local else { return }
        showDeleteConfirmation = true
    }

    func confirmDeleteSelectedGame() {
        guard let game = selectedGame else { return }
        gameManager.deleteGame(game)
        selectedGame = nil
        showDeleteConfirmation = false
    }

    func selectAllGamesForSync() {
        for i in gameManager.games.indices {
            if !gameManager.games[i].isStock {
                gameManager.games[i].isSelected = true
            }
        }
    }

    // MARK: - ROM import

    func addROMs() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "nes")!,
            .init(filenameExtension: "sfc")!,
            .init(filenameExtension: "smc")!,
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "zip")!,
        ]
        guard panel.runModal() == .OK else { return }
        gameManager.importROMs(
            urls: panel.urls,
            consoleType: deviceManager.consoleType
        )
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
