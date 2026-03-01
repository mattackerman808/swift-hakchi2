import Foundation
import AppKit

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

    // Derived
    var code: String { id }

    /// Default cover art image (lazy loaded)
    var coverImage: NSImage? {
        guard let path = coverArtPath else { return nil }
        return NSImage(contentsOfFile: path)
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
    init(desktopFile: DesktopFile, consoleType: ConsoleType, basePath: String) {
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
        self.isSelected = true

        // Derive paths from basePath + code
        let gamePath = (basePath as NSString).appendingPathComponent(desktopFile.code)
        self.romPath = gamePath
        if let iconFilename = desktopFile.iconFilename {
            self.coverArtPath = (gamePath as NSString).appendingPathComponent(iconFilename)
        } else {
            self.coverArtPath = nil
        }
    }
}
