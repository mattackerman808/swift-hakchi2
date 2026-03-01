import SwiftUI
import Combine

/// Flash/task operation types
enum FlashOperation {
    case installHakchi
    case uninstallHakchi
    case factoryReset
    case memboot
    case membootOriginal
    case dumpStockKernel
    case processHmods
}

/// Global application state, shared across the app via @EnvironmentObject
@MainActor
final class AppState: ObservableObject {
    // MARK: - Services
    let deviceManager = DeviceManager()
    let gameManager = GameManagerService()
    let taskRunner = TaskRunner()

    // MARK: - UI State
    @Published var selectedGame: Game?
    @Published var searchText = ""
    @Published var showModHub = false
    @Published var showFoldersManager = false
    @Published var showScraper = false
    @Published var showTaskProgress = false
    @Published var showWaitingForDevice = false

    // MARK: - Flash state
    @Published var pendingFlashOperation: FlashOperation?

    private var cancellables = Set<AnyCancellable>()

    init() {
        deviceManager.start()
    }

    // MARK: - Actions

    func requestFlash(_ operation: FlashOperation) {
        pendingFlashOperation = operation
        showTaskProgress = true
    }

    func rebootConsole() async {
        guard deviceManager.isConnected else { return }
        _ = try? await deviceManager.sshService?.execute("reboot")
    }

    func shutdownConsole() async {
        guard deviceManager.isConnected else { return }
        _ = try? await deviceManager.sshService?.execute("poweroff")
    }

    func syncGames() async {
        guard deviceManager.isConnected else { return }
        showTaskProgress = true
        // GameSyncService will handle the actual sync
    }

    // MARK: - Filtered games

    var filteredGames: [Game] {
        if searchText.isEmpty {
            return gameManager.games
        }
        return gameManager.games.filter { game in
            game.name.localizedCaseInsensitiveContains(searchText)
        }
    }
}
