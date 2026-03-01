import Foundation

/// Game metadata scraping from TheGamesDB API
actor ScraperService {
    private let baseURL = "https://api.thegamesdb.net/v1.1"
    private let apiKey: String

    init(apiKey: String = "") {
        self.apiKey = apiKey
    }

    struct GameSearchResult: Codable, Identifiable {
        let id: Int
        let gameTitle: String
        let releaseDate: String?
        let platform: Int?
        let overview: String?
        let players: Int?

        enum CodingKeys: String, CodingKey {
            case id
            case gameTitle = "game_title"
            case releaseDate = "release_date"
            case platform
            case overview
            case players
        }
    }

    private struct SearchResponse: Codable {
        let data: SearchData
        struct SearchData: Codable {
            let games: [GameSearchResult]
        }
    }

    /// Search for games by name
    func searchGames(name: String, platform: Int? = nil) async throws -> [GameSearchResult] {
        var components = URLComponents(string: "\(baseURL)/Games/ByGameName")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "name", value: name),
        ]
        if let platform = platform {
            components.queryItems?.append(URLQueryItem(name: "filter[platform]", value: "\(platform)"))
        }

        guard let url = components.url else {
            throw ScraperError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        let response = try JSONDecoder().decode(SearchResponse.self, from: data)
        return response.data.games
    }

    /// Download box art image for a game
    func downloadBoxArt(gameId: Int) async throws -> Data? {
        var components = URLComponents(string: "\(baseURL)/Games/Images")!
        components.queryItems = [
            URLQueryItem(name: "apikey", value: apiKey),
            URLQueryItem(name: "games_id", value: "\(gameId)"),
        ]

        guard let url = components.url else { return nil }

        let (data, _) = try await URLSession.shared.data(from: url)

        // Parse image URL from response and download
        struct ImageResponse: Codable {
            let data: ImageData
            struct ImageData: Codable {
                let baseUrl: BaseUrl
                let images: [String: [GameImage]]
                struct BaseUrl: Codable {
                    let original: String
                }
                struct GameImage: Codable {
                    let filename: String
                    let type: String
                }
            }
        }

        let imgResp = try JSONDecoder().decode(ImageResponse.self, from: data)
        let baseUrl = imgResp.data.baseUrl.original

        guard let images = imgResp.data.images["\(gameId)"],
              let boxart = images.first(where: { $0.type == "boxart" })
        else { return nil }

        let imageURL = URL(string: baseUrl + boxart.filename)!
        let (imageData, _) = try await URLSession.shared.data(from: imageURL)
        return imageData
    }
}

enum ScraperError: Error {
    case invalidURL
    case noResults
    case downloadFailed
}
