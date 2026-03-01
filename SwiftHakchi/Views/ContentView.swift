import SwiftUI

/// Main app window with sidebar game list + detail view
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationSplitView {
            GameListView()
        } detail: {
            if let game = appState.selectedGame {
                GameDetailView(game: binding(for: game))
            } else {
                Text("Select a game")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationSplitViewColumnWidth(min: 250, ideal: 300)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    addGames()
                } label: {
                    Label("Add Games", systemImage: "plus")
                }

                Button {
                    Task { await appState.syncGames() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!appState.deviceManager.canSync)
            }
        }
        .searchable(text: $appState.searchText, prompt: "Search games")
        .overlay(alignment: .bottom) {
            StatusBarView()
        }
        .sheet(isPresented: $appState.showTaskProgress) {
            TaskProgressSheet()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showWaitingForDevice) {
            WaitingDeviceSheet()
                .environmentObject(appState)
        }
        .onAppear {
            appState.gameManager.loadGames()
        }
    }

    private func addGames() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [
            .init(filenameExtension: "nes")!,
            .init(filenameExtension: "sfc")!,
            .init(filenameExtension: "smc")!,
            .init(filenameExtension: "md")!,
            .init(filenameExtension: "bin")!,
            .init(filenameExtension: "zip")!,
        ]

        guard panel.runModal() == .OK else { return }
        appState.gameManager.importROMs(
            urls: panel.urls,
            consoleType: appState.deviceManager.consoleType
        )
    }

    private func binding(for game: Game) -> Binding<Game> {
        Binding(
            get: {
                appState.gameManager.games.first(where: { $0.id == game.id }) ?? game
            },
            set: { newValue in
                if let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) {
                    appState.gameManager.games[index] = newValue
                }
            }
        )
    }
}
