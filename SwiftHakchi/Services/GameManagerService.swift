import Foundation
import CoreGraphics
import ImageIO
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameManager")

/// Manages the local game library — loading, saving, importing ROMs
@MainActor
final class GameManagerService: ObservableObject {
    @Published var games: [Game] = []
    @Published var isLoading: Bool = false

    private let config = AppConfig.shared

    /// Load games from the local games directory, plus cached stock games from the last known device.
    func loadGames() {
        isLoading = true
        defer { isLoading = false }

        let gamesDir = config.gamesDirectory
        var loadedGames: [Game] = []

        if FileManager.default.fileExists(atPath: gamesDir.path),
           let contents = try? FileManager.default.contentsOfDirectory(
               at: gamesDir, includingPropertiesForKeys: nil
           ) {
            for dir in contents where dir.hasDirectoryPath {
                let desktopPath = dir
                    .appendingPathComponent(dir.lastPathComponent)
                    .appendingPathExtension("desktop")

                guard FileManager.default.fileExists(atPath: desktopPath.path),
                      let data = try? Data(contentsOf: desktopPath)
                else { continue }

                let desktop = DesktopFile(data: data)
                if desktop.code.isEmpty {
                    desktop.code = dir.lastPathComponent
                }

                let game = Game(
                    desktopFile: desktop,
                    consoleType: config.lastConsoleType,
                    basePath: gamesDir.path,
                    source: .local
                )
                loadedGames.append(game)
            }
        }

        // Apply cached installed status to local games — instant, no SSH
        let cachedInstalled = Set(config.installedGameCodes)
        if !cachedInstalled.isEmpty {
            for i in loadedGames.indices where loadedGames[i].source == .local {
                loadedGames[i].isOnConsole = cachedInstalled.contains(loadedGames[i].id)
            }
        }

        // Load cached stock games from the last known device — instant, no SSH
        let localIds = Set(loadedGames.map { $0.id })
        let lastDeviceId = config.lastDeviceId
        if !lastDeviceId.isEmpty, let cache = StockGameCache.load(deviceId: lastDeviceId) {
            let cachedGames = cache.toGames().filter { !localIds.contains($0.id) }
            loadedGames.append(contentsOf: cachedGames)
            logger.info("Loaded \(cachedGames.count) cached stock games for device \(lastDeviceId)")
        }

        // Merge with any existing console-pulled games still in memory
        let consoleGames = games.filter { $0.source == .stock || $0.source == .console }
        let allIds = Set(loadedGames.map { $0.id })
        let nonConflicting = consoleGames.filter { !allIds.contains($0.id) }
        loadedGames.append(contentsOf: nonConflicting)

        games = loadedGames.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }

        // Apply cached covers immediately
        applyCachedCovers()
    }

    // MARK: - Pull games from console

    /// Pull the game list from a connected console via SSH.
    /// Stock games may already be loaded from cache at launch — this verifies and updates.
    /// User-installed games are always pulled fresh.
    func pullGamesFromConsole(shell: SSHService, consoleType: ConsoleType, deviceId: String) async {
        isLoading = true
        defer { isLoading = false }

        // Remember this device for instant cache load on next launch
        if !deviceId.isEmpty && config.lastDeviceId != deviceId {
            config.lastDeviceId = deviceId
            config.lastConsoleType = consoleType
            config.save()
            logger.info("Saved device ID \(deviceId) for next launch")
        }

        var pulledGames: [Game] = []

        // 1. Stock games — use cache if available, otherwise pull over SSH
        if let cache = StockGameCache.load(deviceId: deviceId) {
            pulledGames.append(contentsOf: cache.toGames())
        } else {
            let stockPath = consoleType.originalGamesPath
            let stockResults = await pullDesktopFiles(
                shell: shell, basePath: stockPath, consoleType: consoleType, source: .stock
            )
            pulledGames.append(contentsOf: stockResults.games)

            // Cache for next time
            if !stockResults.games.isEmpty {
                let cache = StockGameCache(
                    deviceId: deviceId,
                    consoleType: consoleType,
                    cachedAt: Date(),
                    games: stockResults.raw.map {
                        StockGameCache.CachedGame(code: $0.code, desktopContent: $0.content)
                    }
                )
                cache.save()
            }
        }

        // 2. User-installed games — always pull fresh
        let userGamesPath = await resolveUserGamesPath(shell: shell)
        if let userGamesPath {
            let userResults = await pullDesktopFiles(
                shell: shell, basePath: userGamesPath, consoleType: consoleType, source: .console
            )
            pulledGames.append(contentsOf: userResults.games)
        }

        // 3. Check which games are installed on the console (.storage directory)
        let installedCodes = await getInstalledGameCodes(shell: shell, consoleType: consoleType)

        // Cache installed codes for instant status on next launch
        config.installedGameCodes = Array(installedCodes)
        config.save()

        // 4. Merge with local games (local takes priority on conflicts)
        var localGames = games.filter { $0.source == .local }
        for i in localGames.indices {
            localGames[i].isOnConsole = installedCodes.contains(localGames[i].id)
        }

        let localIds = Set(localGames.map { $0.id })
        let nonConflicting = pulledGames.filter { !localIds.contains($0.id) }

        var merged = localGames + nonConflicting
        merged.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        games = merged

        // 5. Apply locally cached cover art immediately (no SSH needed)
        applyCachedCovers()

        // 6. Download any missing covers from console in the background
        Task { @MainActor in
            await self.pullCoverArtFromConsole(shell: shell, consoleType: consoleType)
        }
    }

    /// Set cover art paths from locally cached files — instant, no network.
    private func applyCachedCovers() {
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cacheDir.path) else { return }

        for i in games.indices {
            guard games[i].coverArtPath == nil || games[i].coverImage == nil else { continue }
            let localCover = cacheDir.appendingPathComponent("\(games[i].code).png")
            if FileManager.default.fileExists(atPath: localCover.path) {
                games[i].coverArtPath = localCover.path
            }
        }
    }

    /// Download cover art for stock/console games directly from the console via SSH.
    /// Only downloads for games that don't already have a cover (e.g. from TGDB).
    /// Covers are resized to console dimensions and cached locally.
    private func pullCoverArtFromConsole(shell: SSHService, consoleType: ConsoleType) async {
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        for i in games.indices {
            let game = games[i]
            guard game.source == .stock || game.source == .console else { continue }

            let localCover = cacheDir.appendingPathComponent("\(game.code).png")

            // Skip if already has a cover (from TGDB download or previous cache)
            if FileManager.default.fileExists(atPath: localCover.path) {
                if games[i].coverArtPath == nil {
                    games[i].coverArtPath = localCover.path
                }
                continue
            }
            // Also skip if cover exists elsewhere (e.g. game directory)
            if let path = game.coverArtPath, FileManager.default.fileExists(atPath: path) {
                continue
            }

            // Determine remote path — stock games are under the original games path
            let basePath: String
            if game.source == .stock {
                basePath = consoleType.originalGamesPath
            } else {
                basePath = (await resolveUserGamesPath(shell: shell)) ?? "/var/lib/hakchi/games"
            }

            let remotePath = "\(basePath)/\(game.code)/\(game.code).png"

            // Download via base64 encoding (safe for binary over SSH text channel)
            guard let result = try? await shell.execute("base64 \"\(remotePath)\" 2>/dev/null"),
                  result.succeeded else {
                continue
            }

            let base64Str = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !base64Str.isEmpty,
                  let imageData = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                  !imageData.isEmpty else {
                continue
            }

            // Save original image (sync service handles resizing at upload time)
            try? imageData.write(to: localCover)
            games[i].coverArtPath = localCover.path
            ImageCache.shared.evict(localCover.path)
            logger.info("Cover from console: \(game.code) (\(imageData.count) bytes)")
        }
    }

    /// Raw desktop file data from a console pull (code + content pairs)
    struct PullResult {
        struct RawEntry {
            let code: String
            let content: String
        }
        let games: [Game]
        let raw: [RawEntry]
    }

    /// Pull .desktop files from a directory on the console
    private func pullDesktopFiles(
        shell: SSHService, basePath: String, consoleType: ConsoleType, source: GameSource
    ) async -> PullResult {
        var games: [Game] = []
        var rawEntries: [PullResult.RawEntry] = []

        // List game directories
        guard let result = try? await shell.execute("ls -1 \(basePath)/ 2>/dev/null"),
              result.succeeded else {
            return PullResult(games: [], raw: [])
        }

        let dirs = result.output.components(separatedBy: .newlines).filter {
            !$0.isEmpty && !$0.hasPrefix("CLV-S-") // Skip folder navigation entries
        }

        for dir in dirs {
            let dirPath = "\(basePath)/\(dir)"

            // Find .desktop file — could be dir/dir.desktop or dir/*.desktop
            let desktopContent: String?
            if let r = try? await shell.execute("cat \"\(dirPath)/\(dir).desktop\" 2>/dev/null"),
               r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else if let r = try? await shell.execute(
                "cat \"\(dirPath)\"/*.desktop 2>/dev/null | head -200"
            ), r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else {
                continue
            }

            guard let content = desktopContent else { continue }

            let game = Game(
                code: dir,
                desktopContent: content,
                consoleType: consoleType,
                source: source
            )
            games.append(game)
            rawEntries.append(PullResult.RawEntry(code: dir, content: content))
        }

        return PullResult(games: games, raw: rawEntries)
    }

    /// List CLV codes in .storage on the console — these are the currently installed custom games.
    func getInstalledGameCodes(shell: SSHService, consoleType: ConsoleType) async -> Set<String> {
        let storagePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage"
        guard let result = try? await shell.execute("ls -1 \"\(storagePath)/\" 2>/dev/null"),
              result.succeeded else {
            return []
        }
        let codes = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("CLV-") }
        return Set(codes)
    }

    /// Resolve the user games path from the console config
    func resolveUserGamesPath(shell: SSHService) async -> String? {
        // Try reading from config
        if let result = try? await shell.execute(
            "grep cfg_gamepath /etc/preinit.d/p0000_config 2>/dev/null | sed \"s/.*='\\(.*\\)'/\\1/\""
        ), result.succeeded, !result.output.isEmpty {
            return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Default
        return "/var/lib/hakchi/games"
    }

    // MARK: - Refresh installed status

    /// Re-check which games are installed on the console and update the green checkmarks.
    func refreshInstalledStatus(shell: SSHService, consoleType: ConsoleType) async {
        let installedCodes = await getInstalledGameCodes(shell: shell, consoleType: consoleType)

        for i in games.indices {
            if games[i].source == .local {
                games[i].isOnConsole = installedCodes.contains(games[i].id)
            }
        }

        // Cache for next launch
        config.installedGameCodes = Array(installedCodes)
        config.save()
    }

    // MARK: - Import games from console

    /// Find the .storage path on the console using multiple strategies.
    /// Returns nil if no .storage directory can be found.
    private func findStoragePath(shell: SSHService, consoleType: ConsoleType) async -> String? {
        // Strategy 1: syncCode-based path (standard Hakchi2-CE layout)
        let syncCodePath = "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage"
        if let r = try? await shell.execute("[ -d \"\(syncCodePath)\" ] && echo yes"),
           r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" {
            logger.info("Found .storage via syncCode: \(syncCodePath)")
            return syncCodePath
        }

        // Strategy 2: resolve user games path from console config + .storage
        if let userPath = await resolveUserGamesPath(shell: shell) {
            let userStoragePath = "\(userPath)/.storage"
            if let r = try? await shell.execute("[ -d \"\(userStoragePath)\" ] && echo yes"),
               r.output.trimmingCharacters(in: .whitespacesAndNewlines) == "yes" {
                logger.info("Found .storage via userGamesPath: \(userStoragePath)")
                return userStoragePath
            }
        }

        // Strategy 3: search for .storage directories under /var/lib/hakchi/games
        if let r = try? await shell.execute(
            "find /var/lib/hakchi/games -maxdepth 2 -name .storage -type d 2>/dev/null | head -1"
        ), r.succeeded {
            let found = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !found.isEmpty {
                logger.info("Found .storage via find: \(found)")
                return found
            }
        }

        logger.warning("No .storage directory found on console")
        return nil
    }

    /// List CLV codes from a .storage path on the console.
    private func listStorageCodes(shell: SSHService, storagePath: String) async -> Set<String> {
        guard let result = try? await shell.execute("ls -1 \"\(storagePath)/\" 2>/dev/null"),
              result.succeeded else {
            return []
        }
        let codes = result.output.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("CLV-") }
        return Set(codes)
    }

    /// Import custom games from the console into the local library.
    /// Downloads ROMs, cover art, and .desktop files for each console game
    /// not already present locally.
    func importGamesFromConsole(
        shell: SSHService,
        consoleType: ConsoleType,
        progress: @escaping (String, Double) -> Void
    ) async -> Int {
        progress("Finding games on console...", 0.0)

        // Discover the .storage path on the console
        let storagePath = await findStoragePath(shell: shell, consoleType: consoleType)

        let localIds = Set(games.filter { $0.source == .local }.map { $0.id })

        // Collect import candidates from multiple sources:
        var candidateCodes = Set<String>()

        // 1. Console-source games already in the array (discovered during connect)
        let consoleGameCodes = Set(
            games.filter { $0.source == .console && !localIds.contains($0.id) }.map { $0.id }
        )
        candidateCodes.formUnion(consoleGameCodes)

        // 2. Codes from .storage/ directory listing
        if let storagePath {
            let storageCodes = await listStorageCodes(shell: shell, storagePath: storagePath)
            candidateCodes.formUnion(storageCodes)
        }

        // 3. Codes from getInstalledGameCodes (uses syncCode path — may overlap with #2)
        let installedCodes = await getInstalledGameCodes(shell: shell, consoleType: consoleType)
        candidateCodes.formUnion(installedCodes)

        let allCandidates = candidateCodes.subtracting(localIds).sorted()
        logger.info("Import: candidates=\(allCandidates.count) console=\(consoleGameCodes.count) storage=\(storagePath ?? "nil") installed=\(installedCodes.count) local=\(localIds.count)")

        guard !allCandidates.isEmpty else {
            progress("No new games to import", 1.0)
            return 0
        }

        // Use discovered storage path, fall back to syncCode-based path
        let effectiveStoragePath = storagePath ?? "/var/lib/hakchi/games/\(consoleType.syncCode)/.storage"

        let gamesDir = config.gamesDirectory
        try? FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)

        var imported = 0
        for (index, code) in allCandidates.enumerated() {
            let fraction = Double(index) / Double(allCandidates.count)
            progress("Importing \(code) (\(index + 1)/\(allCandidates.count))...", fraction)

            let remotePath = "\(effectiveStoragePath)/\(code)"

            // 1. Read .desktop file — search multiple locations
            //    Some console layouts put .desktop in .storage/{code}/, others in 000/{code}/ or 001/{code}/
            let desktopContent: String?
            if let r = try? await shell.execute(
                "cat \"\(remotePath)/\(code).desktop\" 2>/dev/null"
            ), r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else if let r = try? await shell.execute(
                "cat \"\(remotePath)\"/*.desktop 2>/dev/null | head -200"
            ), r.succeeded, !r.output.isEmpty {
                desktopContent = r.output
            } else if let r = try? await shell.execute(
                "find \"\(effectiveStoragePath)/..\" -path \"*/\(code)/*.desktop\" -maxdepth 3 2>/dev/null | head -1"
            ), r.succeeded, !r.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Found .desktop elsewhere — read it
                let desktopFile = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if let r2 = try? await shell.execute("cat \"\(desktopFile)\" 2>/dev/null"),
                   r2.succeeded, !r2.output.isEmpty {
                    desktopContent = r2.output
                } else {
                    desktopContent = nil
                }
            } else {
                // Log what's actually in the directory to help debug
                let diag = try? await shell.execute("ls -la \"\(remotePath)/\" 2>&1")
                logger.warning("No .desktop for \(code) at \(remotePath). Contents: \(diag?.output ?? "ls failed")")
                continue
            }

            guard let content = desktopContent else { continue }

            // 2. List files to find ROM — check .storage/{code}/ and parent directories
            var files: [String] = []
            if let listResult = try? await shell.execute(
                "ls -1 \"\(remotePath)/\" 2>/dev/null"
            ), listResult.succeeded {
                files = listResult.output.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty && !$0.hasPrefix(".") }
            }

            var romFilename: String?
            for filename in files {
                if filename.hasSuffix(".png") || filename.hasSuffix(".jpg") { continue }
                if filename.hasSuffix(".desktop") { continue }
                romFilename = filename
                break
            }

            // 3. Create local game directory
            let gameDir = gamesDir.appendingPathComponent(code)
            try? FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

            // 4. Save .desktop file
            let desktopPath = gameDir.appendingPathComponent("\(code).desktop")
            try? content.data(using: .utf8)?.write(to: desktopPath)

            // 5. Download ROM via base64 encoding
            if let romFile = romFilename {
                progress("Downloading ROM for \(code)...", fraction + 0.3 / Double(allCandidates.count))
                if let romResult = try? await shell.execute(
                    "base64 \"\(remotePath)/\(romFile)\" 2>/dev/null"
                ), romResult.succeeded {
                    let base64Str = romResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !base64Str.isEmpty,
                       let romData = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                       !romData.isEmpty {
                        let romDest = gameDir.appendingPathComponent(romFile)
                        try? romData.write(to: romDest)
                        logger.info("Downloaded ROM: \(romFile) (\(romData.count) bytes)")
                    }
                }
            }

            // 6. Download cover PNG via base64
            progress("Downloading cover for \(code)...", fraction + 0.6 / Double(allCandidates.count))
            let coverDest = gameDir.appendingPathComponent("\(code).png")
            if let coverResult = try? await shell.execute(
                "base64 \"\(remotePath)/\(code).png\" 2>/dev/null"
            ), coverResult.succeeded {
                let base64Str = coverResult.output.trimmingCharacters(in: .whitespacesAndNewlines)
                if !base64Str.isEmpty,
                   let imageData = Data(base64Encoded: base64Str, options: .ignoreUnknownCharacters),
                   !imageData.isEmpty {
                    try? imageData.write(to: coverDest)
                }
            }

            // 7. Create local Game, replacing any .console entry
            let desktop = DesktopFile(string: content)
            if desktop.code.isEmpty { desktop.code = code }
            var game = Game(
                desktopFile: desktop,
                consoleType: consoleType,
                basePath: gamesDir.path,
                source: .local
            )
            game.isSelected = true
            game.isOnConsole = true

            // Remove the old .console entry if it exists, replace with .local
            games.removeAll { $0.id == code && $0.source != .local }
            games.append(game)
            imported += 1

            logger.info("Imported game from console: \(code) (\(game.name))")
        }

        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        progress("Imported \(imported) game(s)", 1.0)
        return imported
    }

    // MARK: - Clear console games

    /// Remove user-installed console games on disconnect, but keep stock games from cache
    func clearConsoleGames() {
        games.removeAll { $0.source == .console }
    }

    // MARK: - Import ROMs

    /// Import ROM files via file picker results
    func importROMs(urls: [URL], consoleType: ConsoleType) {
        let gamesDir = config.gamesDirectory
        try? FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)

        for url in urls {
            // Compute CRC32 (with header stripping) for deterministic code + DB lookup
            let romCrc = CRC32.romChecksum(file: url)
            let code = generateCode(for: consoleType, crc32: romCrc)

            // Skip if this game is already imported (same deterministic code)
            if games.contains(where: { $0.id == code }) {
                logger.info("Skipping duplicate ROM: \(url.lastPathComponent) (code \(code))")
                continue
            }

            let gameDir = gamesDir.appendingPathComponent(code)
            try? FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

            // Copy ROM
            let romDest = gameDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: romDest)

            // Create .desktop file
            let desktop = DesktopFile()
            desktop.code = code
            // Try auto-matching via bundled game database (CRC32 lookup)
            var coverUrl: String?
            if let dbEntry = GameDatabase.shared.lookup(romURL: url), !dbEntry.name.isEmpty {
                desktop.name = dbEntry.name
                desktop.publisher = dbEntry.publisher ?? "UNKNOWN"
                desktop.releaseDate = dbEntry.releaseDate ?? "1990-01-01"
                desktop.players = dbEntry.players ?? 1
                coverUrl = dbEntry.coverUrl
                logger.info("Auto-matched ROM: \(dbEntry.name)")
            } else {
                desktop.name = cleanTitle(url.deletingPathExtension().lastPathComponent)
                desktop.releaseDate = "1990-01-01"
                desktop.publisher = "UNKNOWN"
                desktop.players = 1
                // Still grab cover URL even without full metadata (romfiles.xml match)
                if let dbEntry = GameDatabase.shared.lookup(romURL: url) {
                    coverUrl = dbEntry.coverUrl
                }
            }
            desktop.exec = defaultExec(for: consoleType, rom: url.lastPathComponent, code: code)
            desktop.profilePath = "/var/saves"
            desktop.iconPath = "/var/games"
            desktop.iconFilename = "\(code).png"
            desktop.snesExtraFields = consoleType.isSNES

            let desktopPath = gameDir
                .appendingPathComponent(code)
                .appendingPathExtension("desktop")
            try? desktop.toData().write(to: desktopPath)

            let game = Game(
                desktopFile: desktop,
                consoleType: consoleType,
                basePath: gamesDir.path,
                source: .local
            )
            games.append(game)

            // Download cover art in background if available
            if let artUrl = coverUrl {
                downloadCoverArt(urlString: artUrl, gameCode: code, gameDir: gameDir)
            }

            // Enrich from TGDB if API key is configured
            if !config.theGamesDbApiKey.isEmpty,
               let tgdbId = GameDatabase.shared.tgdbId(forROM: url) {
                let gameIndex = games.count - 1
                enrichSingleGame(at: gameIndex, tgdbId: tgdbId, apiKey: config.theGamesDbApiKey)
            }
        }

        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Delete Games

    /// Delete a local game from the library (removes files from disk)
    func deleteGame(_ game: Game) {
        guard game.source == .local else { return }

        let gameDir = config.gamesDirectory.appendingPathComponent(game.code)
        try? FileManager.default.removeItem(at: gameDir)
        games.removeAll { $0.id == game.id }
        logger.info("Deleted game: \(game.code) (\(game.name))")
    }

    /// Delete multiple local games
    func deleteGames(_ gamesToDelete: [Game]) {
        for game in gamesToDelete {
            deleteGame(game)
        }
    }

    // MARK: - Purge Cover Art

    /// Delete all cached cover art and cover PNGs inside local game directories,
    /// then re-trigger downloads from the game database.
    func purgeCoverArt() {
        let fm = FileManager.default

        // 1. Delete covers cache directory (stock/console game covers)
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.removeItem(at: cacheDir)
            logger.info("Purged covers cache directory")
        }

        // 2. Delete cover PNGs inside each local game directory
        let gamesDir = config.gamesDirectory
        for game in games where game.source == .local {
            let coverPath = gamesDir
                .appendingPathComponent(game.code)
                .appendingPathComponent("\(game.code).png")
            if fm.fileExists(atPath: coverPath.path) {
                try? fm.removeItem(at: coverPath)
            }
        }

        // 3. Clear all cached images from memory
        ImageCache.shared.purgeAll()

        // 4. Clear coverArtPath on all games so the UI shows placeholders
        for i in games.indices {
            games[i].coverArtPath = nil
        }

        logger.info("Purged all cover art, re-downloading...")

        // 5. Re-trigger downloads
        matchExistingGames()
    }

    // MARK: - Purge All Local Data

    /// Delete all imported games, cached covers, and downloaded data.
    /// Stock/console games from the device are kept in memory but their cached covers are cleared.
    func purgeAllLocalData() {
        let fm = FileManager.default

        // 1. Delete entire games directory (all imported ROMs + .desktop files + covers)
        let gamesDir = config.gamesDirectory
        if fm.fileExists(atPath: gamesDir.path) {
            try? fm.removeItem(at: gamesDir)
            logger.info("Purged games directory")
        }

        // 2. Delete covers cache directory
        let cacheDir = AppConfig.configDirectory
            .appendingPathComponent("covers", isDirectory: true)
        if fm.fileExists(atPath: cacheDir.path) {
            try? fm.removeItem(at: cacheDir)
            logger.info("Purged covers cache directory")
        }

        // 3. Delete data cache directory
        let dataDir = config.dataDirectory
        if fm.fileExists(atPath: dataDir.path) {
            try? fm.removeItem(at: dataDir)
            logger.info("Purged data directory")
        }

        // 4. Clear image cache
        ImageCache.shared.purgeAll()

        // 5. Remove local games from the list, keep stock/console games
        games.removeAll { $0.source == .local }
        for i in games.indices {
            games[i].coverArtPath = nil
        }

        // 6. Clear cached installed codes since local games are gone
        config.installedGameCodes = []
        config.save()

        logger.info("Purged all local data")
    }

    // MARK: - Match existing games against database

    /// Scan all games and match against the bundled game database.
    /// - Local games: CRC32 match → update metadata + download cover art
    /// - Stock/console games: name match → download cover art from TGDB CDN
    func matchExistingGames() {
        let gamesDir = config.gamesDirectory
        let db = GameDatabase.shared
        var updated = false

        for i in games.indices {
            let game = games[i]

            if game.source == .local {
                // Local games: CRC32 match for metadata + cover
                let gameDir = gamesDir.appendingPathComponent(game.code)
                guard let romURL = findROMFile(in: gameDir) else { continue }
                guard let dbEntry = db.lookup(romURL: romURL) else { continue }

                if game.publisher == "UNKNOWN" || game.publisher.isEmpty {
                    games[i].name = dbEntry.name
                    games[i].publisher = dbEntry.publisher ?? "UNKNOWN"
                    games[i].releaseDate = dbEntry.releaseDate ?? game.releaseDate
                    games[i].players = dbEntry.players ?? game.players
                    saveGame(games[i])
                    updated = true
                }

                if let artUrl = dbEntry.coverUrl {
                    downloadCoverArt(urlString: artUrl, gameCode: game.code, gameDir: gameDir)
                }
                logger.info("Matched local game: \(game.code) → \(dbEntry.name)")

            } else {
                // Stock/console games: match by name for cover art
                // Skip if already has a non-square cover (square covers are old resized ones — re-download)
                if let path = game.coverArtPath, FileManager.default.fileExists(atPath: path),
                   !isCoverSquare(path: path) {
                    continue
                }

                guard let artUrl = db.coverURL(forName: game.name) else { continue }

                let cacheDir = AppConfig.configDirectory
                    .appendingPathComponent("covers", isDirectory: true)
                try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)

                downloadCoverArt(urlString: artUrl, gameCode: game.code, gameDir: cacheDir)
                logger.info("Matched stock game cover: \(game.name)")
            }
        }

        if updated {
            games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        }
    }

    /// Check if an existing cover image is square (old resized cover that should be re-downloaded)
    private func isCoverSquare(path: String) -> Bool {
        guard let source = CGImageSourceCreateWithData(
            (try? Data(contentsOf: URL(fileURLWithPath: path))) as CFData? ?? Data() as CFData, nil
        ), let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else {
            return false
        }
        return width == height
    }

    /// Find the ROM file inside a game directory (skips .desktop and .png files)
    private func findROMFile(in directory: URL) -> URL? {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return nil }

        let romExtensions: Set<String> = ["nes", "sfc", "smc", "fds", "md", "bin", "zip", "gb", "gbc", "gba", "n64", "z64"]
        return contents.first { url in
            !url.hasDirectoryPath && romExtensions.contains(url.pathExtension.lowercased())
        }
    }

    /// Save a game's .desktop file back to disk
    func saveGame(_ game: Game) {
        guard game.source == .local else { return } // only save local games

        let gamesDir = config.gamesDirectory
        let gameDir = gamesDir.appendingPathComponent(game.code)
        let desktopPath = gameDir
            .appendingPathComponent(game.code)
            .appendingPathExtension("desktop")

        let desktop = DesktopFile()
        desktop.code = game.code
        desktop.name = game.name
        desktop.sortName = game.sortName
        desktop.publisher = game.publisher
        desktop.copyright = game.copyright
        desktop.genre = game.genre
        desktop.releaseDate = game.releaseDate
        desktop.players = game.players
        desktop.simultaneous = game.simultaneous
        desktop.description = game.description
        desktop.exec = game.commandLine
        desktop.saveCount = game.saveCount
        desktop.testId = game.testId
        desktop.snesExtraFields = game.consoleType.isSNES
        desktop.profilePath = "/var/saves"
        desktop.iconPath = "/var/games"
        desktop.iconFilename = "\(game.code).png"

        try? desktop.toData().write(to: desktopPath)
    }

    // MARK: - Title Cleanup

    /// Clean a ROM filename into a presentable game title
    private func cleanTitle(_ filename: String) -> String {
        var title = filename

        // 1. Remove bracketed/parenthesized tags: [USA], [!], (Rev A), (U), etc.
        title = title.replacingOccurrences(
            of: #"\s*[\[\(][^\]\)]*[\]\)]"#,
            with: "",
            options: .regularExpression
        )

        // 2. Replace _ and - with spaces
        title = title.replacingOccurrences(of: "_", with: " ")
        title = title.replacingOccurrences(of: "-", with: " ")

        // 3. Collapse multiple spaces and trim
        title = title.replacingOccurrences(
            of: #"\s{2,}"#, with: " ", options: .regularExpression
        ).trimmingCharacters(in: .whitespaces)

        // 4. Title-case with special handling
        let romanNumerals: Set<String> = ["II", "III", "IV", "VI", "VII", "VIII", "IX", "XI", "XII"]
        let smallWords: Set<String> = ["a", "an", "the", "and", "or", "of", "in", "on", "at", "to", "for", "is", "by"]

        let words = title.components(separatedBy: " ")
        let titleCased = words.enumerated().map { index, word -> String in
            let upper = word.uppercased()
            if romanNumerals.contains(upper) {
                return upper
            }
            if index > 0 && smallWords.contains(word.lowercased()) {
                return word.lowercased()
            }
            if word.isEmpty { return word }
            return word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }

        return titleCased.joined(separator: " ")
    }

    // MARK: - Helpers

    /// Generate a deterministic CLV code from a CRC32, matching Hakchi2-CE's algorithm.
    /// Falls back to random if no CRC is available.
    private func generateCode(for consoleType: ConsoleType, crc32: UInt32? = nil) -> String {
        let prefixChar: Character
        switch consoleType {
        case .nes, .famicom: prefixChar = "H"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump: prefixChar = "U"
        default: prefixChar = "P"
        }

        let suffix: String
        if let crc = crc32 {
            // Deterministic: derive 5 letters from CRC32 bits (matches Hakchi2-CE)
            let c0 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + (crc % 26))!)
            let c1 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 5) % 26))!)
            let c2 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 10) % 26))!)
            let c3 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 15) % 26))!)
            let c4 = Character(UnicodeScalar(UInt32(Character("A").asciiValue!) + ((crc >> 20) % 26))!)
            suffix = String([c0, c1, c2, c3, c4])
        } else {
            // Fallback: random
            let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
            suffix = (0..<5).map { _ in String(chars.randomElement()!) }.joined()
        }

        return "CLV-\(prefixChar)-\(suffix)"
    }

    private func defaultExec(for consoleType: ConsoleType, rom: String, code: String) -> String {
        switch consoleType {
        case .nes, .famicom:
            return "/bin/clover-kachikachi-wr /var/games/\(code)/\(rom) --volume 75 --rollback-snapshot-period 720"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump:
            return "/bin/clover-canoe-shvc-wr -rom /var/games/\(code)/\(rom) --volume 75 --rollback-snapshot-period 720"
        default:
            return "/bin/\(rom)"
        }
    }

    // MARK: - TGDB Library Enrichment

    /// Enrich the entire game library with metadata from TheGamesDB.
    /// Fills in descriptions, genres, and better cover art for all games.
    /// Local games: CRC32 → TGDB ID lookup via romfiles.xml.
    /// Stock/console games: name-based search on TGDB.
    func enrichLibraryFromTGDB(apiKey: String, progress: @escaping (String, Double) -> Void) async {
        let db = GameDatabase.shared
        let scraper = ScraperService()
        let gamesDir = config.gamesDirectory

        // 0. Validate API key first
        progress("Validating API key...", 0.0)
        do {
            let allowance = try await scraper.validateApiKey(apiKey)
            logger.info("API key valid, \(allowance) requests remaining this month")
        } catch {
            progress("Invalid API key: \(error.localizedDescription)", 1.0)
            return
        }

        // 1. Collect TGDB IDs for local games via CRC32 lookup
        progress("Scanning library for TGDB matches...", 0.02)
        var idToGameIndices: [Int: [Int]] = [:]
        var nameSearchIndices: [Int] = []  // games that need name-based search

        for i in games.indices {
            let game = games[i]

            if game.source == .local {
                // Local game — find ROM file, compute CRC32, look up TGDB ID
                let gameDir = gamesDir.appendingPathComponent(game.code)
                if let romURL = findROMFile(in: gameDir),
                   let tgdbId = db.tgdbId(forROM: romURL) {
                    idToGameIndices[tgdbId, default: []].append(i)
                } else {
                    nameSearchIndices.append(i)
                }
            } else {
                // Stock/console game — no ROM on disk, use name search
                nameSearchIndices.append(i)
            }
        }

        let crcMatchCount = idToGameIndices.values.flatMap { $0 }.count
        logger.info("Enrichment: \(crcMatchCount) CRC matches, \(nameSearchIndices.count) need name search")
        progress("Found \(crcMatchCount) CRC matches, \(nameSearchIndices.count) for name search...", 0.05)

        // 2. Batch fetch metadata for CRC-matched games
        var gameInfoMap: [Int: ScraperService.GameInfo] = [:]
        let allIds = Array(idToGameIndices.keys)
        if !allIds.isEmpty {
            progress("Fetching metadata for \(allIds.count) matched games...", 0.1)
            do {
                gameInfoMap = try await scraper.fetchGamesByIds(ids: allIds, apiKey: apiKey) { fraction in
                    progress("Fetching metadata (\(Int(fraction * 100))%)...", 0.1 + fraction * 0.3)
                }
            } catch {
                logger.error("TGDB batch fetch failed: \(error.localizedDescription)")
                progress("Fetch failed: \(error.localizedDescription)", 1.0)
                return
            }
        }

        // 3. Name-based search for stock/unmatched games (one at a time, with rate limiting)
        var nameMatchMap: [Int: ScraperService.GameInfo] = [:]  // gameIndex → info
        if !nameSearchIndices.isEmpty {
            let platformId = ScraperService.platformId(for: config.lastConsoleType)
            for (searchIdx, gameIdx) in nameSearchIndices.enumerated() {
                let game = games[gameIdx]
                let fraction = 0.4 + 0.4 * Double(searchIdx) / Double(nameSearchIndices.count)
                progress("Searching: \(game.name)...", fraction)

                do {
                    let results = try await scraper.searchGames(
                        name: game.name, apiKey: apiKey, platform: platformId
                    )
                    // Take the first result — it's the best match
                    if let best = results.first {
                        // Fetch full details including boxart for this game
                        if let detailed = try? await scraper.fetchGamesByIds(
                            ids: [best.id], apiKey: apiKey
                        ), let info = detailed[best.id] {
                            nameMatchMap[gameIdx] = info
                        }
                    }
                } catch {
                    logger.warning("Name search failed for \(game.name): \(error.localizedDescription)")
                }
            }
        }

        // 4. Apply metadata from CRC-matched games
        progress("Applying metadata...", 0.85)
        var updatedCount = 0

        for (tgdbId, indices) in idToGameIndices {
            guard let info = gameInfoMap[tgdbId] else { continue }
            for i in indices {
                if applyEnrichment(at: i, from: info, gamesDir: gamesDir) {
                    updatedCount += 1
                }
            }
        }

        // 5. Apply metadata from name-searched games
        for (gameIdx, info) in nameMatchMap {
            if applyEnrichment(at: gameIdx, from: info, gamesDir: gamesDir) {
                updatedCount += 1
            }
        }

        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        progress("Enrichment complete — \(updatedCount) game(s) updated", 1.0)
        logger.info("Enrichment complete: \(updatedCount) games updated (\(gameInfoMap.count) CRC results, \(nameMatchMap.count) name results)")
    }

    /// Apply TGDB metadata to a game at the given index.
    /// Returns true if any field was updated.
    private func applyEnrichment(at i: Int, from info: ScraperService.GameInfo, gamesDir: URL) -> Bool {
        guard i < games.count else { return false }
        var changed = false

        // Fill description if empty
        if games[i].description.isEmpty, let overview = info.overview, !overview.isEmpty {
            games[i].description = overview
            changed = true
        }

        // Fill publisher if default — also update name (was filename-derived)
        if games[i].publisher == "UNKNOWN" || games[i].publisher.isEmpty {
            games[i].name = info.title
            changed = true
        }

        // Fill genre if empty
        if games[i].genre.isEmpty, let genres = info.genres, !genres.isEmpty {
            games[i].genre = genres.joined(separator: ", ")
            changed = true
        }

        // Fill release date if default
        if games[i].releaseDate == "1990-01-01" || games[i].releaseDate == "1900-01-01",
           let date = info.releaseDate, !date.isEmpty {
            games[i].releaseDate = date
            changed = true
        }

        // Fill players if default
        if games[i].players == 1, let players = info.players, players > 1 {
            games[i].players = players
            changed = true
        }

        if changed && games[i].source == .local {
            saveGame(games[i])
        }

        // Download better cover art if available
        if let artURL = info.boxartFrontURL {
            let coverDir: URL
            if games[i].source == .local {
                coverDir = gamesDir.appendingPathComponent(games[i].code)
            } else {
                coverDir = AppConfig.configDirectory.appendingPathComponent("covers", isDirectory: true)
                try? FileManager.default.createDirectory(at: coverDir, withIntermediateDirectories: true)
            }

            let hasCover = games[i].coverArtPath != nil
                && FileManager.default.fileExists(atPath: games[i].coverArtPath!)
            if !hasCover || isCoverSquare(path: games[i].coverArtPath ?? "") {
                downloadCoverArt(urlString: artURL, gameCode: games[i].code, gameDir: coverDir)
            }
        }

        return changed
    }

    /// Enrich a single game from TGDB by its known TGDB ID.
    /// Used during ROM import when the API key is configured.
    func enrichSingleGame(at index: Int, tgdbId: Int, apiKey: String) {
        Task {
            let scraper = ScraperService()
            guard let results = try? await scraper.fetchGamesByIds(ids: [tgdbId], apiKey: apiKey),
                  let info = results[tgdbId] else { return }

            if applyEnrichment(at: index, from: info, gamesDir: config.gamesDirectory) {
                games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
            }
        }
    }

    /// Download cover art from a URL and save the original full-res image.
    /// For TGDB CDN URLs, tries multiple suffix variants (-1.jpg, -1.png, -2.jpg, -2.png)
    /// since the exact filename varies per game.
    /// The sync service handles resizing to console dimensions at upload time.
    private func downloadCoverArt(urlString: String, gameCode: String, gameDir: URL) {
        let coverPath = gameDir.appendingPathComponent("\(gameCode).png")

        // Build list of URLs to try
        var urls: [URL] = []
        if let url = URL(string: urlString) {
            urls.append(url)
        }

        // For TGDB CDN URLs ending in -1.jpg, also try -1.png, -2.jpg, -2.png
        let tgdbPrefix = "https://cdn.thegamesdb.net/images/original/boxart/front/"
        if urlString.hasPrefix(tgdbPrefix) && urlString.hasSuffix("-1.jpg") {
            let base = String(urlString.dropLast(6)) // strip "-1.jpg"
            for suffix in ["-1.png", "-2.jpg", "-2.png"] {
                if let url = URL(string: "\(base)\(suffix)") {
                    urls.append(url)
                }
            }
        }

        guard !urls.isEmpty else { return }

        Task.detached(priority: .utility) { [urls] in
            for url in urls {
                do {
                    var request = URLRequest(url: url)
                    request.setValue("SwiftHakchi/1.0", forHTTPHeaderField: "User-Agent")
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard let httpResponse = response as? HTTPURLResponse,
                          httpResponse.statusCode == 200,
                          !data.isEmpty else {
                        continue // try next URL
                    }

                    // Save original full-res image (sync service handles resizing at upload time)
                    try data.write(to: coverPath)
                    logger.info("Cover art for \(gameCode): \(data.count) bytes")

                    ImageCache.shared.evict(coverPath.path)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        if let index = self.games.firstIndex(where: { $0.id == gameCode }) {
                            self.games[index].coverArtPath = coverPath.path
                        }
                    }
                    return // success, stop trying
                } catch {
                    continue // try next URL
                }
            }
            logger.warning("Cover art download failed for \(gameCode): all URLs returned errors")
        }
    }

}

// MARK: - Image Resizing

/// Resize image data to the given dimensions, outputting PNG.
/// Handles both PNG and JPEG input. Returns original data if resize fails.
func resizeCoverArt(data: Data, width: Int, height: Int) -> Data {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
          let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        return data
    }

    // Skip if already at or below target size
    if cgImage.width <= width && cgImage.height <= height {
        // Still re-encode as PNG if input might be JPEG
        let output = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            output as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return data }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { return data }
        return output as Data
    }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        return data
    }

    context.interpolationQuality = .high
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

    guard let resized = context.makeImage() else { return data }

    let output = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
        output as CFMutableData, "public.png" as CFString, 1, nil
    ) else { return data }
    CGImageDestinationAddImage(dest, resized, nil)
    guard CGImageDestinationFinalize(dest) else { return data }
    return output as Data
}
