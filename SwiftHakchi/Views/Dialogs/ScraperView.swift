import SwiftUI

/// Game metadata scraper — search TheGamesDB and apply metadata to a game
struct ScraperView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @Binding var game: Game

    @State private var searchText: String = ""
    @State private var results: [ScraperService.SearchResult] = []
    @State private var selectedResult: ScraperService.SearchResult?
    @State private var isSearching = false
    @State private var errorMessage: String?
    @State private var isApplying = false

    private let scraper = ScraperService()

    init(game: Binding<Game>) {
        self._game = game
        self._searchText = State(initialValue: game.wrappedValue.name)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Game Scraper")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Search bar
            HStack {
                TextField("Search game name...", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }

                Button("Search") { search() }
                    .disabled(searchText.isEmpty || isSearching)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            if isSearching {
                ProgressView("Searching...")
                    .padding()
            }

            if let error = errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }

            // Results list
            List(results, selection: $selectedResult) { result in
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.headline)
                    HStack {
                        if let date = result.releaseDate {
                            Text(date)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let players = result.players {
                            Text("\(players)P")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let overview = result.overview {
                        Text(overview)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                .padding(.vertical, 2)
                .tag(result)
            }
            .listStyle(.inset)

            Divider()

            // Actions
            HStack {
                if let selected = selectedResult {
                    VStack(alignment: .leading) {
                        Text("Selected: \(selected.title)")
                            .font(.caption.bold())
                    }
                }

                Spacer()

                Button("Apply") {
                    applySelected()
                }
                .disabled(selectedResult == nil || isApplying)
                .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 500, height: 450)
    }

    private func search() {
        let apiKey = AppConfig.shared.theGamesDbApiKey
        guard !apiKey.isEmpty else {
            errorMessage = "No API key. Add your TheGamesDB API key in Settings > Console."
            return
        }

        isSearching = true
        errorMessage = nil
        results = []
        selectedResult = nil

        let platform = ScraperService.platformId(for: game.consoleType)

        Task {
            do {
                let searchResults = try await scraper.searchGames(
                    name: searchText, apiKey: apiKey, platform: platform
                )
                await MainActor.run {
                    results = searchResults
                    isSearching = false
                    if searchResults.isEmpty {
                        errorMessage = "No results found for \"\(searchText)\""
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSearching = false
                }
            }
        }
    }

    private func applySelected() {
        guard let result = selectedResult else { return }
        isApplying = true

        game.name = result.title
        if let date = result.releaseDate { game.releaseDate = date }
        if let players = result.players { game.players = players }
        if let publisher = result.publisher { game.publisher = publisher }
        if let genre = result.genre { game.genre = genre }
        if let overview = result.overview { game.description = overview }

        // Download boxart in background
        let apiKey = AppConfig.shared.theGamesDbApiKey
        let gameId = result.id
        let gameCode = game.code

        Task {
            if let artData = try? await scraper.downloadBoxArt(gameId: gameId, apiKey: apiKey) {
                await MainActor.run {
                    saveCoverArt(data: artData, code: gameCode)
                    appState.gameManager.saveGame(game)
                    isApplying = false
                    dismiss()
                }
            } else {
                await MainActor.run {
                    appState.gameManager.saveGame(game)
                    isApplying = false
                    dismiss()
                }
            }
        }
    }

    private func saveCoverArt(data: Data, code: String) {
        let gamesDir = AppConfig.shared.gamesDirectory
        let gameDir = gamesDir.appendingPathComponent(code)
        let coverPath = gameDir.appendingPathComponent("\(code).png")
        try? data.write(to: coverPath)
        game.coverArtPath = coverPath.path
    }
}

extension ScraperService.SearchResult: Hashable {
    static func == (lhs: ScraperService.SearchResult, rhs: ScraperService.SearchResult) -> Bool {
        lhs.id == rhs.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
}
