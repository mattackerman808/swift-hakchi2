import SwiftUI

/// Right panel: game metadata editor with cover art
struct GameDetailView: View {
    @Binding var game: Game
    @EnvironmentObject var appState: AppState
    @State private var showScraper = false

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Game Details")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataSection
                        .padding()

                    Divider()

                    descriptionSection
                        .padding(.horizontal)

                    Spacer()
                }
            }
        }
        .sheet(isPresented: $showScraper) {
            ScraperView(game: $game)
                .environmentObject(appState)
        }
    }

    // MARK: - Sections

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Name") {
                TextField("Name", text: $game.name)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Publisher") {
                TextField("Publisher", text: $game.publisher)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Release Date") {
                TextField("YYYY-MM-DD", text: $game.releaseDate)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
            }

            HStack(spacing: 20) {
                LabeledContent("Players") {
                    Stepper("\(game.players)", value: $game.players, in: 1...4)
                }

                Toggle("Simultaneous", isOn: $game.simultaneous)
            }

            LabeledContent("Genre") {
                TextField("Genre", text: $game.genre)
                    .textFieldStyle(.roundedBorder)
            }

            LabeledContent("Command Line") {
                TextField("Exec", text: $game.commandLine)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            HStack {
                Text("Code: \(game.code)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if game.source == .local {
                    Button("Search Online...") {
                        showScraper = true
                    }
                    .help("Search TheGamesDB for metadata and cover art")
                }
                if appState.deviceManager.isConnected {
                    Button("Download from Console") {
                        appState.downloadGameFromConsole(game: game)
                    }
                    .help("Save a copy of this game's ROM from the console to your Mac")
                }
                Button("Save") {
                    appState.gameManager.saveGame(game)
                }
                .help("Save changes to this game's metadata")
            }
        }
    }

    private var descriptionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Description")
                .font(.headline)
            TextEditor(text: $game.description)
                .frame(minHeight: 100)
                .font(.body)
                .border(.separator)
        }
    }

}
