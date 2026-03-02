import SwiftUI

/// Bottom status bar showing connection state, console type, and game count
struct StatusBarView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        HStack(spacing: 12) {
            // Connection indicator
            HStack(spacing: 4) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.caption)
            }

            Divider()
                .frame(height: 12)

            // Console type + hardware ID
            if appState.deviceManager.consoleType != .unknown {
                Text(appState.deviceManager.consoleType.displayName)
                    .font(.caption)

                if !appState.deviceManager.uniqueId.isEmpty {
                    Text(appState.deviceManager.uniqueId)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 12)
            }

            // FEL indicator
            if appState.deviceManager.felDevicePresent {
                HStack(spacing: 4) {
                    Image(systemName: "bolt.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    Text("FEL")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()
                    .frame(height: 12)
            }

            // Background activity indicator
            if let message = appState.statusMessage {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Divider()
                    .frame(height: 12)
            }

            Spacer()

            // Game counts
            let allGames = appState.gameManager.games
            let stockGames = allGames.filter { $0.source == .stock }
            let selectedStock = stockGames.filter { $0.isSelected }.count
            let customCount = allGames.filter { $0.source != .stock }.count
            let selectedCustom = allGames.filter { $0.isSelected && $0.source != .stock }.count

            if !stockGames.isEmpty {
                Text("\(selectedStock)/\(stockGames.count) built-in")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Divider()
                    .frame(height: 12)
            }

            Text("\(selectedCustom)/\(customCount) custom games selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var statusColor: Color {
        if appState.deviceManager.isConnected {
            return .green
        } else if appState.deviceManager.felDevicePresent {
            return .orange
        }
        return .red
    }

    private var statusText: String {
        if appState.deviceManager.isConnected {
            let name = appState.deviceManager.consoleType.displayName
            return "Connected — \(name)"
        } else if appState.deviceManager.felDevicePresent {
            return "FEL Device Detected"
        }
        return "Disconnected"
    }
}
