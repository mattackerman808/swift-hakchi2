import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ScraperService")

/// Game metadata scraping — bundled DB lookup + TheGamesDB API search
actor ScraperService {
    private let baseURL = "https://api.thegamesdb.net/v1.1"

    // MARK: - Search Result

    struct SearchResult: Identifiable {
        let id: Int
        let title: String
        let releaseDate: String?
        let platform: String?
        let overview: String?
        let players: Int?
        let publisher: String?
        let genre: String?
        let boxartURL: String?
    }

    // MARK: - API Response Types

    private struct GamesResponse: Codable {
        let data: GamesData
        struct GamesData: Codable {
            let games: [APIGame]
        }
    }

    private struct APIGame: Codable {
        let id: Int
        let game_title: String
        let release_date: String?
        let platform: Int?
        let overview: String?
        let players: Int?
        let developers: [Int]?
        let publishers: [Int]?
        let genres: [Int]?
    }

    private struct ImageResponse: Codable {
        let data: ImageData
        struct ImageData: Codable {
            let base_url: BaseUrl
            let images: [String: [GameImage]]
            struct BaseUrl: Codable {
                let original: String
            }
            struct GameImage: Codable {
                let filename: String
                let type: String
                let side: String?
            }
        }
    }

    // MARK: - Platform IDs (TheGamesDB)

    static let platformNES = 7
    static let platformSNES = 6
    static let platformFamicom = 39
    static let platformSuperFamicom = 48

    static func platformId(for consoleType: ConsoleType) -> Int? {
        switch consoleType {
        case .nes: return platformNES
        case .famicom: return platformFamicom
        case .snesUsa, .snesEur: return platformSNES
        case .superFamicom, .superFamicomShonenJump: return platformSuperFamicom
        default: return nil
        }
    }

    // MARK: - API Key Validation

    /// Validate an API key by making a lightweight probe call.
    /// Returns the remaining monthly allowance, or throws on failure.
    func validateApiKey(_ apiKey: String) async throws -> Int {
        guard !apiKey.isEmpty else { throw ScraperError.noApiKey }

        // Minimal call: fetch one known game with no extra fields
        var components = URLComponents(string: "https://api.thegamesdb.net/v1/Games/ByGameID")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "id", value: "1"),
        ]

        guard let url = components.url else { throw ScraperError.invalidURL }

        let (data, _) = try await URLSession.shared.data(from: url)

        struct ProbeResponse: Codable {
            let code: Int?
            let status: String?
            let remaining_monthly_allowance: Int?
        }

        let response = try JSONDecoder().decode(ProbeResponse.self, from: data)
        guard response.status == "Success" else {
            throw ScraperError.invalidApiKey
        }

        return response.remaining_monthly_allowance ?? 0
    }

    // MARK: - Search

    /// Search TheGamesDB for games by name
    func searchGames(name: String, apiKey: String, platform: Int? = nil) async throws -> [SearchResult] {
        guard !apiKey.isEmpty else {
            throw ScraperError.noApiKey
        }

        var components = URLComponents(string: "\(baseURL)/Games/ByGameName")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "name", value: name),
        ]
        if let platform {
            components.queryItems?.append(URLQueryItem(name: "filter[platform]", value: "\(platform)"))
        }

        guard let url = components.url else {
            throw ScraperError.invalidURL
        }

        logger.info("Searching TheGamesDB: \(name)")
        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(GamesResponse.self, from: data)

        return response.data.games.map { game in
            SearchResult(
                id: game.id,
                title: game.game_title,
                releaseDate: game.release_date,
                platform: nil,
                overview: game.overview,
                players: game.players,
                publisher: nil,
                genre: nil,
                boxartURL: nil
            )
        }
    }

    /// Download box art for a game from TheGamesDB
    func downloadBoxArt(gameId: Int, apiKey: String) async throws -> Data? {
        guard !apiKey.isEmpty else { return nil }

        var components = URLComponents(string: "\(baseURL)/Games/Images")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "games_id", value: "\(gameId)"),
        ]

        guard let url = components.url else { return nil }

        let (data, _) = try await URLSession.shared.data(from: url)
        let imgResp = try JSONDecoder().decode(ImageResponse.self, from: data)
        let baseUrl = imgResp.data.base_url.original

        guard let images = imgResp.data.images["\(gameId)"] else { return nil }

        // Prefer front boxart
        let boxart = images.first(where: { $0.type == "boxart" && $0.side == "front" })
            ?? images.first(where: { $0.type == "boxart" })

        guard let art = boxart else { return nil }

        let imageURL = URL(string: baseUrl + art.filename)!
        logger.info("Downloading boxart: \(imageURL.absoluteString)")
        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        return imageData
    }

    /// Download cover art from a direct URL
    func downloadCoverArt(from urlString: String) async throws -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let (data, _) = try await URLSession.shared.data(from: url)
        return data
    }

    // MARK: - Batch Fetch by ID

    /// Metadata returned from a batch TGDB fetch
    struct GameInfo {
        let id: Int
        let title: String
        let overview: String?
        let releaseDate: String?
        let players: Int?
        let genres: [String]?
        let publishers: [String]?
        let boxartFrontURL: String?
    }

    /// Response type for `/Games/ByGameID`
    private struct GamesByIdResponse: Codable {
        let data: ResponseData
        let include: IncludeData?
        struct ResponseData: Codable {
            let games: [APIGame]
        }
        struct IncludeData: Codable {
            let boxart: BoxartInclude?
        }
        /// Inline boxart from `include=boxart` — uses `data` key (not `images`)
        struct BoxartInclude: Codable {
            let base_url: BaseUrlMeta
            let data: [String: [ImageResponse.ImageData.GameImage]]
        }
        struct BaseUrlMeta: Codable {
            let original: String
        }
    }

    /// Fetch game metadata by TGDB IDs in batches of up to 20.
    /// Returns a dictionary of TGDB ID → GameInfo.
    func fetchGamesByIds(
        ids: [Int],
        apiKey: String,
        progress: ((Double) -> Void)? = nil
    ) async throws -> [Int: GameInfo] {
        guard !apiKey.isEmpty else { throw ScraperError.noApiKey }
        guard !ids.isEmpty else { return [:] }

        var results: [Int: GameInfo] = [:]
        let batchSize = 20
        let batches = stride(from: 0, to: ids.count, by: batchSize).map {
            Array(ids[$0..<min($0 + batchSize, ids.count)])
        }

        for (batchIndex, batch) in batches.enumerated() {
            let idList = batch.map { String($0) }.joined(separator: ",")

            // ByGameID only exists on v1 (not v1.1)
            var components = URLComponents(string: "https://api.thegamesdb.net/v1/Games/ByGameID")!
            components.queryItems = [
                URLQueryItem(name: "apikey", value: apiKey),
                URLQueryItem(name: "id", value: idList),
                URLQueryItem(name: "fields", value: "players,publishers,genres,overview"),
                URLQueryItem(name: "include", value: "boxart"),
            ]

            guard let url = components.url else { continue }

            logger.info("Batch fetch \(batchIndex + 1)/\(batches.count): \(batch.count) IDs")
            let (data, _) = try await URLSession.shared.data(from: url)
            let response: GamesByIdResponse
            do {
                response = try JSONDecoder().decode(GamesByIdResponse.self, from: data)
            } catch {
                let preview = String(data: data.prefix(500), encoding: .utf8) ?? "non-utf8"
                logger.error("TGDB decode failed: \(error). Response preview: \(preview)")
                throw error
            }

            // Parse boxart base URL and per-game images
            let baseUrl = response.include?.boxart?.base_url.original
            let imageMap = response.include?.boxart?.data ?? [:]

            for game in response.data.games {
                // Find front boxart URL for this game
                var boxartURL: String?
                if let base = baseUrl, let images = imageMap["\(game.id)"] {
                    if let front = images.first(where: { $0.type == "boxart" && $0.side == "front" }) {
                        boxartURL = base + front.filename
                    }
                }

                results[game.id] = GameInfo(
                    id: game.id,
                    title: game.game_title,
                    overview: game.overview,
                    releaseDate: game.release_date,
                    players: game.players,
                    genres: game.genres?.map { String($0) },
                    publishers: game.publishers?.map { String($0) },
                    boxartFrontURL: boxartURL
                )
            }

            progress?(Double(batchIndex + 1) / Double(batches.count))
        }

        logger.info("Batch fetch complete: \(results.count) games resolved from \(ids.count) IDs")
        return results
    }
}

enum ScraperError: LocalizedError {
    case invalidURL
    case noResults
    case downloadFailed
    case noApiKey
    case invalidApiKey

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid URL"
        case .noResults: return "No results found"
        case .downloadFailed: return "Download failed"
        case .noApiKey: return "No API key configured. Add your TheGamesDB API key in Settings."
        case .invalidApiKey: return "API key is not valid. Check your TheGamesDB API key in Settings."
        }
    }
}
