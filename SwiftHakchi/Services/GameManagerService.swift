import Foundation

/// Manages the local game library — loading, saving, importing ROMs
@MainActor
final class GameManagerService: ObservableObject {
    @Published var games: [Game] = []
    @Published var isLoading: Bool = false

    private let config = AppConfig.shared

    /// Load games from the local games directory
    func loadGames() {
        isLoading = true
        defer { isLoading = false }

        let gamesDir = config.gamesDirectory
        guard FileManager.default.fileExists(atPath: gamesDir.path) else {
            games = []
            return
        }

        var loadedGames: [Game] = []

        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: gamesDir, includingPropertiesForKeys: nil
        ) else {
            games = []
            return
        }

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

        // Merge with existing games (preserve console-pulled games)
        let consoleGames = games.filter { $0.source == .stock || $0.source == .console }
        let localIds = Set(loadedGames.map { $0.id })
        let nonConflicting = consoleGames.filter { !localIds.contains($0.id) }
        loadedGames.append(contentsOf: nonConflicting)

        games = loadedGames.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    // MARK: - Pull games from console

    /// Pull the game list from a connected console via SSH.
    /// Reads stock games (squashfs) and user-installed games (/var/games).
    func pullGamesFromConsole(shell: SSHService, consoleType: ConsoleType) async {
        isLoading = true
        defer { isLoading = false }

        var pulledGames: [Game] = []

        // 1. Stock games — read .desktop files from the original games path
        let stockPath = consoleType.originalGamesPath
        let stockGames = await pullDesktopFiles(
            shell: shell, basePath: stockPath, consoleType: consoleType, source: .stock
        )
        pulledGames.append(contentsOf: stockGames)

        // 2. User-installed games — read from /var/games or cfg_gamepath
        let userGamesPath = await resolveUserGamesPath(shell: shell)
        if let userGamesPath {
            let userGames = await pullDesktopFiles(
                shell: shell, basePath: userGamesPath, consoleType: consoleType, source: .console
            )
            pulledGames.append(contentsOf: userGames)
        }

        // 3. Merge with local games (local takes priority on conflicts)
        let localGames = games.filter { $0.source == .local }
        let localIds = Set(localGames.map { $0.id })
        let nonConflicting = pulledGames.filter { !localIds.contains($0.id) }

        var merged = localGames + nonConflicting
        merged.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
        games = merged
    }

    /// Pull .desktop files from a directory on the console
    private func pullDesktopFiles(
        shell: SSHService, basePath: String, consoleType: ConsoleType, source: GameSource
    ) async -> [Game] {
        var games: [Game] = []

        // List game directories
        guard let result = try? await shell.execute("ls -1 \(basePath)/ 2>/dev/null"),
              result.succeeded else {
            return []
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
        }

        return games
    }

    /// Resolve the user games path from the console config
    private func resolveUserGamesPath(shell: SSHService) async -> String? {
        // Try reading from config
        if let result = try? await shell.execute(
            "grep cfg_gamepath /etc/preinit.d/p0000_config 2>/dev/null | sed \"s/.*='\\(.*\\)'/\\1/\""
        ), result.succeeded, !result.output.isEmpty {
            return result.output
        }
        // Default
        return "/var/lib/hakchi/games"
    }

    // MARK: - Clear console games

    /// Remove all console-sourced games (called on disconnect)
    func clearConsoleGames() {
        games.removeAll { $0.source == .stock || $0.source == .console }
    }

    // MARK: - Import ROMs

    /// Import ROM files via file picker results
    func importROMs(urls: [URL], consoleType: ConsoleType) {
        let gamesDir = config.gamesDirectory
        try? FileManager.default.createDirectory(at: gamesDir, withIntermediateDirectories: true)

        for url in urls {
            let code = generateCode(for: consoleType)
            let gameDir = gamesDir.appendingPathComponent(code)
            try? FileManager.default.createDirectory(at: gameDir, withIntermediateDirectories: true)

            // Copy ROM
            let romDest = gameDir.appendingPathComponent(url.lastPathComponent)
            try? FileManager.default.copyItem(at: url, to: romDest)

            // Create .desktop file
            let desktop = DesktopFile()
            desktop.code = code
            desktop.name = url.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "-", with: " ")
            desktop.exec = defaultExec(for: consoleType, rom: url.lastPathComponent, code: code)
            desktop.profilePath = "/var/saves"
            desktop.iconPath = "/var/games"
            desktop.iconFilename = "\(code).png"
            desktop.releaseDate = "1990-01-01"
            desktop.publisher = "UNKNOWN"
            desktop.players = 1
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
        }

        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
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

    // MARK: - Helpers

    private func generateCode(for consoleType: ConsoleType) -> String {
        let prefix: String
        switch consoleType {
        case .nes, .famicom: prefix = "CLV-H"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump: prefix = "CLV-U"
        default: prefix = "CLV-P"
        }
        let chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let random = (0..<5).map { _ in
            String(chars.randomElement()!)
        }.joined()
        return "\(prefix)-\(random)"
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
}
