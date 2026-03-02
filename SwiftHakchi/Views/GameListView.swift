import SwiftUI

/// Left sidebar: searchable, selectable game list with checkboxes
struct GameListView: View {
    @EnvironmentObject var appState: AppState

    private var stockGames: [Game] {
        appState.filteredGames.filter { $0.source == .stock }
    }

    private var customGames: [Game] {
        appState.filteredGames.filter { $0.source != .stock }
    }

    var body: some View {
        List(selection: $appState.selectedGame) {
            if !stockGames.isEmpty {
                Section("Built-in Games") {
                    ForEach(stockGames) { game in
                        GameListRow(game: game) {
                            toggleSelection(game)
                        }
                        .tag(game)
                    }
                }
            }

            if !customGames.isEmpty {
                Section("Custom Games") {
                    ForEach(customGames) { game in
                        GameListRow(game: game) {
                            toggleSelection(game)
                        }
                        .tag(game)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if appState.filteredGames.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "gamecontroller")
                } description: {
                    if appState.deviceManager.isConnected {
                        Text("No games found on the console.")
                    } else {
                        Text("Connect a console or add ROM files to get started.")
                    }
                }
            }
        }
    }

    private func toggleSelection(_ game: Game) {
        guard !game.isStock else { return } // stock games can't be deselected
        if let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) {
            appState.gameManager.games[index].isSelected.toggle()
        }
    }
}

/// Single row in the game list
struct GameListRow: View {
    let game: Game
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            // Checkbox / lock icon
            if game.isStock {
                Image(systemName: "lock.fill")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                    .help("Built-in game (always on console)")
            } else {
                Button {
                    onToggle()
                } label: {
                    Image(systemName: game.isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(game.isSelected ? .blue : .secondary)
                }
                .buttonStyle(.plain)
                .frame(width: 16)
            }

            // Cover art thumbnail
            if let coverImage = game.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(.quaternary)
                    Image(systemName: game.isStock ? "star.fill" : "gamecontroller.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(width: 32, height: 32)
            }

            // Name + publisher
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(game.name)
                        .lineLimit(1)
                    if game.source == .console {
                        Image(systemName: "externaldrive.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Installed on console")
                    }
                }
                Text(game.publisher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .opacity(game.isStock ? 0.7 : 1.0)
    }
}
