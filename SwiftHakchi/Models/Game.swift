import Foundation
import AppKit

/// Where this game came from
enum GameSource: Hashable {
    case stock          // Built into the console's squashfs
    case console        // User-installed on the console (in /var/games)
    case local          // Imported locally, not yet on console
}

/// Represents a game loaded from a .desktop file
struct Game: Identifiable, Hashable {
    let id: String  // CLV-P-XXXXX code
    var name: String
    var sortName: String
    var publisher: String
    var copyright: String
    var genre: String
    var releaseDate: String
    var players: Int
    var simultaneous: Bool
    var description: String
    var romPath: String  // local path to ROM file
    var coverArtPath: String?  // local path to cover art
    var commandLine: String  // Exec line for .desktop
    var saveCount: Int
    var testId: Int
    var consoleType: ConsoleType
    var isSelected: Bool  // whether to sync this game
    var isOnConsole: Bool = false  // whether this game is currently installed on the console
    var source: GameSource

    var isStock: Bool { source == .stock }

    // Derived
    var code: String { id }

    /// Cover art image, served from an in-memory cache to avoid
    /// repeated disk I/O on every SwiftUI re-render.
    var coverImage: NSImage? {
        guard let path = coverArtPath else { return nil }
        return ImageCache.shared.image(for: path)
    }

    static func == (lhs: Game, rhs: Game) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}

extension Game {
    /// Create a Game from a DesktopFile
    init(desktopFile: DesktopFile, consoleType: ConsoleType, basePath: String, source: GameSource = .local) {
        self.id = desktopFile.code
        self.name = desktopFile.name
        self.sortName = desktopFile.sortName
        self.publisher = desktopFile.publisher
        self.copyright = desktopFile.copyright
        self.genre = desktopFile.genre
        self.releaseDate = desktopFile.releaseDate
        self.players = desktopFile.players
        self.simultaneous = desktopFile.simultaneous
        self.description = desktopFile.description
        self.commandLine = desktopFile.exec
        self.saveCount = desktopFile.saveCount
        self.testId = desktopFile.testId
        self.consoleType = consoleType
        self.isSelected = true  // all games selected by default (stock = included in overlay)
        self.source = source

        let gamePath = (basePath as NSString).appendingPathComponent(desktopFile.code)
        self.romPath = gamePath
        if let iconFilename = desktopFile.iconFilename {
            self.coverArtPath = (gamePath as NSString).appendingPathComponent(iconFilename)
        } else {
            self.coverArtPath = nil
        }
    }

    /// Create a Game from remote .desktop content pulled over SSH
    /// Evict this game's cached cover image so it reloads from disk on next access.
    func invalidateCoverCache() {
        guard let path = coverArtPath else { return }
        ImageCache.shared.evict(path)
    }

    init(code: String, desktopContent: String, consoleType: ConsoleType, source: GameSource) {
        let desktop = DesktopFile(string: desktopContent)
        if desktop.code.isEmpty { desktop.code = code }

        self.id = desktop.code
        self.name = desktop.name.isEmpty ? code : desktop.name
        self.sortName = desktop.sortName
        self.publisher = desktop.publisher
        self.copyright = desktop.copyright
        self.genre = desktop.genre
        self.releaseDate = desktop.releaseDate
        self.players = desktop.players
        self.simultaneous = desktop.simultaneous
        self.description = desktop.description
        self.commandLine = desktop.exec
        self.saveCount = desktop.saveCount
        self.testId = desktop.testId
        self.consoleType = consoleType
        self.isSelected = true  // all games selected by default
        self.isOnConsole = source == .console  // console-pulled games are already installed
        self.source = source
        self.romPath = ""
        self.coverArtPath = nil
    }
}

/// In-memory cache for cover art images, keyed by file path.
/// Prevents repeated disk I/O when SwiftUI re-renders tile views.
final class ImageCache {
    static let shared = ImageCache()

    private let cache = NSCache<NSString, NSImage>()

    private init() {
        cache.countLimit = 500
    }

    func image(for path: String) -> NSImage? {
        let key = path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        guard let img = NSImage(contentsOfFile: path) else { return nil }
        cache.setObject(img, forKey: key)
        return img
    }

    func evict(_ path: String) {
        cache.removeObject(forKey: path as NSString)
    }

    func purgeAll() {
        cache.removeAllObjects()
    }
}
