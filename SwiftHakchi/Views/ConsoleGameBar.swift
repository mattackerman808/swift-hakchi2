import SwiftUI

/// Which category the console bar is showing
enum BarMode: String, CaseIterable {
    case customGames = "Custom Games"
    case defaultGames = "Default Games"
}

/// Bottom bar showing games selected for install — horizontal scrolling timeline
struct ConsoleGameBar: View {
    @EnvironmentObject var appState: AppState
    @Binding var isDraggingFromExplorer: Bool
    @Binding var selectionSource: SelectionSource
    @State private var isDropTarget = false
    @State private var barMode: BarMode = .customGames

    /// Selected custom games for the Custom tab
    private var customBarGames: [Game] {
        appState.gameManager.games
            .filter { !$0.isStock && $0.isSelected }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// All stock games for the Default tab (both selected and deselected)
    private var defaultBarGames: [Game] {
        appState.gameManager.games
            .filter { $0.isStock }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var displayedGames: [Game] {
        barMode == .defaultGames ? defaultBarGames : customBarGames
    }

    private var selectedCount: Int {
        displayedGames.filter { $0.isSelected }.count
    }

    var body: some View {
        VStack(spacing: 0) {
            // Stronger top border — replaces the thin Divider
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1.5)

            // Header row
            HStack {
                Label("Desired Console Config", systemImage: "arrow.down.circle")
                    .font(.headline)

                ForEach(BarMode.allCases, id: \.self) { mode in
                    Button {
                        barMode = mode
                    } label: {
                        Text(mode.rawValue)
                    }
                    .buttonStyle(ActionButtonStyle(role: barMode == mode ? .primary : .normal, compact: true))
                    .help(mode == .customGames
                          ? "Show your imported games selected for sync"
                          : "Show the console's built-in stock games")
                }

                Spacer()

                Text("\(selectedCount) games")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .overlay {
                Button {
                    Task { await appState.syncGames() }
                } label: {
                    Label("Sync", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(ActionButtonStyle(role: .primary))
                .disabled(!appState.deviceManager.canSync)
                .opacity(appState.deviceManager.canSync ? 1.0 : 0.5)
                .help("Upload selected games to the console")
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)

            // Horizontal scroll of game tiles with pinned drop placeholder
            HStack(spacing: 0) {
                // Pinned drop placeholder on the left — always visible when dragging
                if isDraggingFromExplorer {
                    DropPlaceholderTile()
                        .padding(.leading, 20)
                        .padding(.trailing, 8)
                        .frame(maxHeight: .infinity)
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                        .onDrop(of: [.text], delegate: BarAddDropDelegate(
                            appState: appState,
                            isDropTarget: $isDropTarget,
                            isDraggingFromExplorer: $isDraggingFromExplorer
                        ))
                }

                GeometryReader { scrollGeo in
                    ScrollView(.horizontal, showsIndicators: true) {
                        if displayedGames.isEmpty && !isDraggingFromExplorer {
                            emptyBarContent
                                .frame(width: scrollGeo.size.width, height: scrollGeo.size.height)
                        } else {
                            HStack(spacing: 16) {
                                ForEach(displayedGames) { game in
                                    ConsoleBarTile(
                                        game: game,
                                        isActive: game == appState.selectedGame && selectionSource == .consoleBar,
                                        isDisabled: !game.isSelected
                                    )
                                    .onDrag {
                                        NSItemProvider(object: game.id as NSString)
                                    }
                                    .onTapGesture(count: 2) {
                                        if !game.isSelected {
                                            setSelected(game, true)
                                        }
                                    }
                                    .onTapGesture {
                                        if appState.selectedGame == game && selectionSource == .consoleBar {
                                            appState.selectedGame = nil
                                        } else {
                                            appState.selectedGame = game
                                            selectionSource = .consoleBar
                                        }
                                    }
                                    .contextMenu {
                                        if !game.isSelected && game.isStock {
                                            Button("Re-enable") {
                                                setSelected(game, true)
                                            }
                                        }
                                    }
                                }
                            }
                            .padding(.horizontal, 20)
                            .frame(minHeight: scrollGeo.size.height)
                        }
                    }
                }
            }
            .animation(.easeInOut(duration: 0.2), value: isDraggingFromExplorer)
            .frame(height: 200)
            .onDrop(of: [.text], delegate: BarAddDropDelegate(
                appState: appState,
                isDropTarget: $isDropTarget,
                isDraggingFromExplorer: $isDraggingFromExplorer
            ))
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(
                        isDropTarget ? Color.accentColor : Color.clear,
                        lineWidth: 2.5
                    )
                    .padding(2)
            )
            .background(isDropTarget ? Color.accentColor.opacity(0.08) : Color.clear)
            // Darker, inset tray background
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.5))
            .background(Color.black.opacity(0.15))
            // Inner shadow at the top — 3D inset effect
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [.black.opacity(0.2), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 4)
                .allowsHitTesting(false)
            }
            .animation(.easeInOut(duration: 0.15), value: isDropTarget)
        }
    }

    private var emptyBarContent: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line.compact")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text(barMode == .customGames
                 ? "Drag games here from the explorer above"
                 : "No default games loaded")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func setSelected(_ game: Game, _ value: Bool) {
        if let index = appState.gameManager.games.firstIndex(where: { $0.id == game.id }) {
            appState.gameManager.games[index].isSelected = value
        }
    }

}

/// Dashed placeholder tile shown when dragging a game from the explorer
private struct DropPlaceholderTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
            .foregroundStyle(.secondary)
            .frame(width: 130, height: 130)
            .overlay {
                Image(systemName: "arrow.down")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
    }
}

/// Drop delegate for adding games to the bar — uses .move to avoid the green "+" cursor badge
struct BarAddDropDelegate: DropDelegate {
    let appState: AppState
    @Binding var isDropTarget: Bool
    @Binding var isDraggingFromExplorer: Bool

    func dropEntered(info: DropInfo) {
        isDropTarget = true
    }

    func dropExited(info: DropInfo) {
        isDropTarget = false
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        isDropTarget = false
        isDraggingFromExplorer = false
        for provider in info.itemProviders(for: [.text]) {
            provider.loadObject(ofClass: NSString.self) { object, _ in
                guard let gameId = object as? String else { return }
                Task { @MainActor in
                    if let index = appState.gameManager.games.firstIndex(where: { $0.id == gameId }) {
                        appState.gameManager.games[index].isSelected = true
                    }
                }
            }
        }
        return true
    }
}

/// Small tile for the console bar — compact cover art with name and status badges
private struct ConsoleBarTile: View {
    let game: Game
    let isActive: Bool
    var isDisabled: Bool = false

    private let cardSize: CGFloat = 130

    var body: some View {
        Group {
            // Cover art
            if let coverImage = game.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: cardSize)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: cardSize, height: cardSize)
                    .overlay {
                        Image(systemName: game.isStock ? "star.fill" : "gamecontroller.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }
        }
        .shadow(color: .black.opacity(isActive ? 0.5 : 0.15), radius: isActive ? 8 : 2, y: isActive ? 4 : 1)
        .scaleEffect(isActive ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .frame(width: cardSize)
        .contentShape(Rectangle())
        .opacity(isDisabled ? 0.35 : 1.0)
        .saturation(isDisabled ? 0.3 : 1.0)
    }
}
