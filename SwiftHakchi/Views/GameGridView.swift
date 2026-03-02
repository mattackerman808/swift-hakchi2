import SwiftUI

/// Top-left panel: scrollable grid of game cover art tiles
struct GameGridView: View {
    @EnvironmentObject var appState: AppState
    @Binding var isDraggingFromExplorer: Bool
    @Binding var selectionSource: SelectionSource
    @State private var gameToDelete: Game?

    /// Only custom (non-stock) games in the explorer
    private var customGames: [Game] {
        appState.filteredGames.filter { !$0.isStock }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 8) {
                Text("Games Explorer")
                    .font(.headline)

                TextField("Search", text: $appState.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)

                Spacer()

                Button {
                    Task { await appState.importFromConsole() }
                } label: {
                    Label("Import from Console", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(ActionButtonStyle(compact: true))
                .disabled(!appState.deviceManager.isConnected)
                .help("Import custom games from the connected console")

                Button {
                    appState.addROMs()
                } label: {
                    Label("Add ROMs", systemImage: "plus.rectangle.on.folder")
                }
                .buttonStyle(ActionButtonStyle(compact: true))
                .help("Import ROM files from your Mac")
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 6)

            Divider()

            // Grid — always 3 columns, cards scale to fill
            GeometryReader { geo in
                let columns = 3
                let hPadding: CGFloat = 16 * 2
                let spacing: CGFloat = 12
                let totalSpacing = spacing * CGFloat(columns - 1) + hPadding
                let cardSize = max(60, (geo.size.width - totalSpacing) / CGFloat(columns))

                ScrollView {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: spacing), count: columns),
                        spacing: 16
                    ) {
                        ForEach(customGames) { game in
                            GameCardView(
                                game: game,
                                isActive: game == appState.selectedGame && selectionSource == .explorer,
                                isOnBar: game.isSelected,
                                cardSize: cardSize
                            )
                            .onTapGesture {
                                appState.selectedGame = game
                                selectionSource = .explorer
                            }
                            .onDrag {
                                isDraggingFromExplorer = true
                                return NSItemProvider(object: game.id as NSString)
                            }
                            .contextMenu {
                                if game.source == .local {
                                    Button("Delete Game...") {
                                        gameToDelete = game
                                    }
                                }
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .overlay {
                if customGames.isEmpty {
                    ContentUnavailableView {
                        Label("No Games", systemImage: "gamecontroller")
                    } description: {
                        Text("Import ROM files to get started.")
                    } actions: {
                        Button {
                            appState.addROMs()
                        } label: {
                            Label("Add ROMs", systemImage: "plus.rectangle.on.folder")
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .alert("Delete Game", isPresented: Binding(
            get: { gameToDelete != nil },
            set: { if !$0 { gameToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let game = gameToDelete {
                    if appState.selectedGame?.id == game.id {
                        appState.selectedGame = nil
                    }
                    appState.gameManager.deleteGame(game)
                    gameToDelete = nil
                }
            }
            Button("Cancel", role: .cancel) {
                gameToDelete = nil
            }
        } message: {
            Text("Are you sure you want to delete \"\(gameToDelete?.name ?? "")\"? This removes the imported copy from the app library. Your original ROM file is not affected.")
        }
    }
}
