import SwiftUI

/// Right panel: game metadata editor with cover art
struct GameDetailView: View {
    @Binding var game: Game
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // Header with cover art
                HStack(alignment: .top, spacing: 20) {
                    coverArtSection
                    metadataSection
                }
                .padding()

                Divider()

                // Description
                descriptionSection
                    .padding(.horizontal)

                Spacer()
            }
        }
        .frame(minWidth: 400)
    }

    // MARK: - Sections

    private var coverArtSection: some View {
        VStack {
            if let coverImage = game.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: CGFloat(game.consoleType.coverWidth),
                           height: CGFloat(game.consoleType.coverHeight))
                    .cornerRadius(8)
                    .shadow(radius: 2)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: CGFloat(game.consoleType.coverWidth),
                           height: CGFloat(game.consoleType.coverHeight))
                    .overlay {
                        Image(systemName: "photo")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                    }
            }

            Button("Change Cover...") {
                changeCoverArt()
            }
            .buttonStyle(.link)
        }
    }

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
                Button("Save") {
                    appState.gameManager.saveGame(game)
                }
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

    // MARK: - Actions

    private func changeCoverArt() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        // Copy to game directory
        if let data = try? Data(contentsOf: url) {
            let destPath = URL(fileURLWithPath: game.romPath)
                .appendingPathComponent("\(game.code).png")
            try? data.write(to: destPath)
            game.coverArtPath = destPath.path
        }
    }
}
