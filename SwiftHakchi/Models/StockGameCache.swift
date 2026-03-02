import Foundation

/// Cached stock game data for a specific console, keyed by device ID
struct StockGameCache: Codable {
    let deviceId: String
    let consoleType: ConsoleType
    let cachedAt: Date
    let games: [CachedGame]

    var isExpired: Bool {
        Date().timeIntervalSince(cachedAt) > 7 * 24 * 3600
    }

    struct CachedGame: Codable {
        let code: String
        let desktopContent: String
    }

    // MARK: - Persistence

    private static var cacheDirectory: URL {
        AppConfig.configDirectory.appendingPathComponent("cache", isDirectory: true)
    }

    private static func cacheFile(for deviceId: String) -> URL {
        let safeId = deviceId.replacingOccurrences(of: "/", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cacheDirectory.appendingPathComponent("stock_games_\(safeId).json")
    }

    /// Load cached stock games for a device, or nil if expired/missing
    static func load(deviceId: String) -> StockGameCache? {
        let file = cacheFile(for: deviceId)
        guard FileManager.default.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file)
        else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let cache = try? decoder.decode(StockGameCache.self, from: data),
              !cache.isExpired
        else {
            return nil
        }
        return cache
    }

    /// Save stock games to the cache
    func save() {
        let dir = Self.cacheDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.cacheFile(for: deviceId))
        }
    }

    /// Convert cached games back to Game objects
    func toGames() -> [Game] {
        games.map { cached in
            Game(
                code: cached.code,
                desktopContent: cached.desktopContent,
                consoleType: consoleType,
                source: .stock
            )
        }
    }
}
