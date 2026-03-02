import SwiftUI

/// Which panel last selected a game
enum SelectionSource {
    case explorer, consoleBar
}

/// Main app window with sidebar game list + detail view
struct ContentView: View {
    @EnvironmentObject var appState: AppState
    /// Fraction of the total width used by the left (explorer) panel, 0.0–1.0
    @State private var splitFraction: CGFloat = 0.50
    @State private var poofLocation: CGPoint = .zero
    @State private var showPoof = false
    @State private var dragOverRemove = false
    @State private var dragLocation: CGPoint = .zero
    @State private var dragLabelText: String = "Remove"
    @State private var isDraggingFromExplorer = false
    /// Tracks which panel last selected a game, so only that panel shows the lift
    @State private var selectionSource: SelectionSource = .explorer

    var body: some View {
        VStack(spacing: 0) {
            // Action bar with common task buttons
            ActionBarView()

            Divider()

            // Top: explorer + detail with a draggable divider
            GeometryReader { geo in
                let minLeft: CGFloat = 300
                let minRight: CGFloat = 300
                let totalWidth = geo.size.width
                let leftWidth = max(minLeft, min(totalWidth - minRight, totalWidth * splitFraction))

                HStack(spacing: 0) {
                    GameGridView(isDraggingFromExplorer: $isDraggingFromExplorer, selectionSource: $selectionSource)
                        .frame(width: leftWidth)

                    // Draggable divider
                    Rectangle()
                        .fill(Color.gray.opacity(0.2))
                        .frame(width: 5)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside {
                                NSCursor.resizeLeftRight.push()
                            } else {
                                NSCursor.pop()
                            }
                        }
                        .gesture(
                            DragGesture(minimumDistance: 1)
                                .onChanged { value in
                                    let newLeft = leftWidth + value.location.x - value.startLocation.x
                                    splitFraction = max(minLeft / totalWidth, min(1 - minRight / totalWidth, newLeft / totalWidth))
                                }
                        )

                    detailPanel
                        .frame(maxWidth: .infinity)
                }
                // Drop zone — deselects games dragged off the bar
                .onDrop(of: [.text], delegate: PoofDropDelegate(
                    appState: appState,
                    poofLocation: $poofLocation,
                    showPoof: $showPoof,
                    dragOverRemove: $dragOverRemove,
                    dragLocation: $dragLocation,
                    dragLabelText: $dragLabelText,
                    isDraggingFromExplorer: $isDraggingFromExplorer
                ))
                // Dim the explorer + detail when dragging a game off the bar
                .overlay {
                    if dragOverRemove {
                        Color.black.opacity(0.3)
                            .allowsHitTesting(false)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: dragOverRemove)
                // "Remove" / "Hide" speech bubble — follows the dragged icon, clamped to stay visible
                .overlay {
                    if dragOverRemove {
                        let bubbleX = min(max(60, dragLocation.x), geo.size.width - 60)
                        let bubbleY = max(25, dragLocation.y - 110)
                        DockBubbleLabel(text: dragLabelText)
                            .fixedSize()
                            .position(x: bubbleX, y: bubbleY)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.15), value: dragOverRemove)
                // Poof animation on drop
                .overlay {
                    if showPoof {
                        Image(systemName: "cloud")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary)
                            .position(poofLocation)
                            .transition(.asymmetric(
                                insertion: .scale(scale: 0.5).combined(with: .opacity),
                                removal: .scale(scale: 1.8).combined(with: .opacity)
                            ))
                    }
                }
                .animation(.easeOut(duration: 0.35), value: showPoof)
            }

            // Bottom: console game bar
            ConsoleGameBar(isDraggingFromExplorer: $isDraggingFromExplorer, selectionSource: $selectionSource)

            // Status bar
            Divider()
            StatusBarView()
        }
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
        .sheet(isPresented: $appState.showScraper) {
            if let game = appState.selectedGame {
                ScraperView(game: binding(for: game))
                    .environmentObject(appState)
            } else {
                VStack(spacing: 12) {
                    Text("No game selected")
                        .font(.headline)
                    Text("Select a game first, then open the scraper.")
                        .foregroundStyle(.secondary)
                    Button("Close") { appState.showScraper = false }
                }
                .padding(40)
                .frame(minWidth: 300)
            }
        }
        .sheet(isPresented: $appState.showModuleManager) {
            ModuleManagerView()
                .environmentObject(appState)
        }
        .sheet(isPresented: $appState.showHelp) {
            HelpView()
        }
        .alert("Delete Game", isPresented: $appState.showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                appState.confirmDeleteSelectedGame()
            }
            Button("Cancel", role: .cancel) {
                appState.showDeleteConfirmation = false
            }
        } message: {
            Text("Are you sure you want to delete \"\(appState.selectedGame?.name ?? "")\"? This removes the imported copy from the app library. Your original ROM file is not affected.")
        }
        .alert(
            "Remove Games from Console?",
            isPresented: $appState.showSyncConfirmation
        ) {
            Button("Import First") {
                Task { await appState.importFromConsole() }
            }
            Button("Sync Anyway", role: .destructive) {
                appState.confirmSync()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove \(appState.syncRemovedCount) game(s) from the console that aren't in your local library. You can import them first to keep a local copy.")
        }
        .onAppear {
            appState.gameManager.loadGames()
            appState.gameManager.matchExistingGames()
        }
    }

    /// Always the same view type so HSplitView keeps the divider stable
    @ViewBuilder
    private var detailPanel: some View {
        if let game = appState.selectedGame {
            GameDetailView(game: binding(for: game))
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "info.square")
                .font(.system(size: 48))
                .foregroundStyle(.quaternary)
            Text("Click a game card to see its details")
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

/// Drop delegate that deselects games dragged off the console bar with a poof animation.
/// Shows a Dock-style "Remove"/"Hide" speech bubble while hovering.
struct PoofDropDelegate: DropDelegate {
    let appState: AppState
    @Binding var poofLocation: CGPoint
    @Binding var showPoof: Bool
    @Binding var dragOverRemove: Bool
    @Binding var dragLocation: CGPoint
    @Binding var dragLabelText: String
    @Binding var isDraggingFromExplorer: Bool

    func dropEntered(info: DropInfo) {
        // Resolve the game to pick the right label
        for provider in info.itemProviders(for: [.text]) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let gameId = object as? String else { return }
                Task { @MainActor in
                    if let game = appState.gameManager.games.first(where: { $0.id == gameId }) {
                        dragLabelText = game.isStock ? "Hide" : "Remove"
                    }
                }
            }
        }
        dragLocation = info.location
        dragOverRemove = true
    }

    func dropExited(info: DropInfo) {
        dragOverRemove = false
        isDraggingFromExplorer = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        dragLocation = info.location
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        dragOverRemove = false
        isDraggingFromExplorer = false
        poofLocation = info.location
        showPoof = true

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showPoof = false
        }

        for provider in info.itemProviders(for: [.text]) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let gameId = object as? String else { return }
                Task { @MainActor in
                    if let index = appState.gameManager.games.firstIndex(where: { $0.id == gameId }) {
                        appState.gameManager.games[index].isSelected = false
                    }
                }
            }
        }
        return true
    }
}

/// Dock-style "Remove" / "Hide" bubble matching macOS Dock appearance:
/// gray rounded pill with a small downward-pointing triangle.
struct DockBubbleLabel: View {
    let text: String

    private let bubbleColor = Color(white: 0.42)

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
                .background(
                    Capsule().fill(bubbleColor)
                )
            // Triangle pointer
            Triangle()
                .fill(bubbleColor)
                .frame(width: 14, height: 8)
        }
        .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
    }
}

/// Downward-pointing triangle for the bubble pointer
private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        Path { p in
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
            p.closeSubpath()
        }
    }
}

/// Toolbar-style action bar with prominent buttons for common tasks
struct ActionBarView: View {
    @EnvironmentObject var appState: AppState
    @State private var isReconnecting = false
    @State private var showReconnectFailed = false

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

            // Connect / Disconnect
            Button {
                if appState.deviceManager.isConnected {
                    appState.deviceManager.manualDisconnect()
                } else {
                    attemptReconnect()
                }
            } label: {
                if isReconnecting {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 16, height: 16)
                } else if appState.deviceManager.isConnected {
                    Label("Disconnect", systemImage: "cable.connector.slash")
                } else {
                    Label("Connect", systemImage: "cable.connector")
                }
            }
            .buttonStyle(ActionButtonStyle(role: appState.deviceManager.isConnected ? .connected : .normal))
            .disabled(isReconnecting)
            .help(appState.deviceManager.isConnected
                  ? "Disconnect from console"
                  : "Connect to console")
            .alert("Connection Failed", isPresented: $showReconnectFailed) {
                Button("OK") {}
            } message: {
                Text("Could not connect to the console.\n\n\u{2022} If demo mode is playing, press a button on the controller to exit it first.\n\u{2022} Try removing the USB cable, waiting a few seconds, and plugging it back in.\n\u{2022} If the console is unresponsive, unplug the power and reconnect it.\n\nThe app will keep trying to connect automatically in the background while the console is plugged in.")
            }

            Button {
                appState.requestFlash(.memboot)
            } label: {
                Label("Memboot", systemImage: "bolt")
            }
            .buttonStyle(ActionButtonStyle())
            .help("Boot custom kernel without installing")

            Button {
                Task { await appState.rebootConsole() }
            } label: {
                Label("Reboot", systemImage: "arrow.clockwise")
            }
            .buttonStyle(ActionButtonStyle())
            .disabled(!appState.deviceManager.isConnected)
            .help("Reboot the console")

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func attemptReconnect() {
        guard !isReconnecting else { return }
        isReconnecting = true
        Task {
            let success = await appState.deviceManager.reconnect()
            isReconnecting = false
            if !success {
                showReconnectFailed = true
            }
        }
    }

}

/// Custom button style for the action bar
struct ActionButtonStyle: ButtonStyle {
    enum Role { case primary, normal, connected }

    var role: Role = .normal
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(compact ? .caption : .callout)
            .fontWeight(role == .primary ? .semibold : .regular)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(role == .primary || role == .connected ? .white : .primary)
            .background(
                Capsule()
                    .fill(role == .primary ? Color.accentColor : role == .connected ? Color.green : Color.clear)
            )
            .background(
                Capsule()
                    .strokeBorder(.separator, lineWidth: role == .primary ? 0 : 1)
            )
            .opacity(configuration.isPressed ? 0.7 : 1.0)
    }
}
