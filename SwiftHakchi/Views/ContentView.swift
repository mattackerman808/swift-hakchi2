import SwiftUI

/// Main app window with sidebar game list + detail view
struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // Action bar with common task buttons
            ActionBarView()

            Divider()

            // Main split view
            NavigationSplitView {
                GameListView()
            } detail: {
                if let game = appState.selectedGame {
                    GameDetailView(game: binding(for: game))
                } else {
                    emptyState
                }
            }
            .navigationSplitViewColumnWidth(min: 250, ideal: 300)

            // Status bar
            Divider()
            StatusBarView()
        }
        .searchable(text: $appState.searchText, prompt: "Search games")
        .sheet(isPresented: $appState.showInstallConfig) {
            InstallConfigSheet()
                .environmentObject(appState)
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

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Select a game or add ROMs to get started")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

/// Toolbar-style action bar with prominent buttons for common tasks
struct ActionBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Install Kernel — the primary action
            Button {
                appState.requestFlash(.installHakchi)
            } label: {
                Label("Install Kernel", systemImage: "cpu")
            }
            .buttonStyle(ActionButtonStyle(role: .primary))
            .help("Install or repair custom kernel on the console")

            Button {
                addGames()
            } label: {
                Label("Add Games", systemImage: "plus.rectangle.on.folder")
            }
            .buttonStyle(ActionButtonStyle())
            .help("Import ROM files")

            Button {
                Task { await appState.syncGames() }
            } label: {
                Label("Sync Games", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!appState.deviceManager.canSync)
            .help("Upload selected games to the console")

            Spacer()

            // Secondary actions
            Button {
                appState.requestFlash(.memboot)
            } label: {
                Label("Memboot", systemImage: "bolt")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .help("Boot custom kernel without installing")

            Button {
                Task { await appState.rebootConsole() }
            } label: {
                Label("Reboot", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ActionButtonStyle(compact: true))
            .disabled(!appState.deviceManager.isConnected)
            .help("Reboot the console")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
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
}

/// Custom button style for the action bar
struct ActionButtonStyle: ButtonStyle {
    enum Role { case primary, normal }

    var role: Role = .normal
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption : .callout)
            .fontWeight(role == .primary ? .semibold : .regular)
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(role == .primary ? .white : .primary)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(role == .primary ? Color.accentColor : Color.clear)
            )
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.separator, lineWidth: role == .primary ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
