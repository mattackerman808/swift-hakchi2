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
                basePath: gamesDir.path
            )
            loadedGames.append(game)
        }

        games = loadedGames.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

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
            desktop.exec = defaultExec(for: consoleType, rom: url.lastPathComponent)
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

            // Create game entry
            let game = Game(
                desktopFile: desktop,
                consoleType: consoleType,
                basePath: gamesDir.path
            )
            games.append(game)
        }

        games.sort { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Save a game's .desktop file back to disk
    func saveGame(_ game: Game) {
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

    private func defaultExec(for consoleType: ConsoleType, rom: String) -> String {
        switch consoleType {
        case .nes, .famicom:
            return "/bin/clover-kachikachi-wr /usr/share/games/nes/kachikachi/\(rom) --volume 75 --rollback-snapshot-period 720"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump:
            return "/bin/clover-canoe-shvc -rom /usr/share/games/\(rom) --volume 75 --rollback-snapshot-period 720"
        default:
            return "/bin/\(rom)"
        }
    }
}
