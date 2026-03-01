import SwiftUI

/// Left sidebar: searchable, selectable game list with checkboxes
struct GameListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        List(selection: $appState.selectedGame) {
            ForEach(appState.filteredGames) { game in
                GameListRow(game: game, isSelected: game.isSelected) {
                    toggleSelection(game)
                }
                .tag(game)
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if appState.filteredGames.isEmpty {
                ContentUnavailableView {
                    Label("No Games", systemImage: "gamecontroller")
                } description: {
                    Text("Add games using File > Add Games or the + button.")
                }
            }
        }
    }

    private func toggleSelection(_ game: Game) {
        if let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) {
            appState.gameManager.games[index].isSelected.toggle()
        }
    }
}

/// Single row in the game list
struct GameListRow: View {
    let game: Game
    let isSelected: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button {
                onToggle()
            } label: {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? .blue : .secondary)
            }
            .buttonStyle(.plain)

            if let coverImage = game.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 32, height: 32)
                    .cornerRadius(4)
            } else {
                Image(systemName: "gamecontroller.fill")
                    .frame(width: 32, height: 32)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(game.name)
                    .lineLimit(1)
                Text(game.publisher)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
