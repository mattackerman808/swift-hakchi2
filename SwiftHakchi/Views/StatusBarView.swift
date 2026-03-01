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

            // Console type
            if appState.deviceManager.consoleType != .unknown {
                Text(appState.deviceManager.consoleType.displayName)
                    .font(.caption)

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

            Spacer()

            // Game count
            let selectedCount = appState.gameManager.games.filter { $0.isSelected }.count
            let totalCount = appState.gameManager.games.count
            Text("\(selectedCount)/\(totalCount) games selected")
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
            return "Connected"
        } else if appState.deviceManager.felDevicePresent {
            return "FEL Device Detected"
        }
        return "Disconnected"
    }
}
