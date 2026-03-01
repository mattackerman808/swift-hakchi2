import SwiftUI

/// Modal sheet shown while waiting for FEL device connection
struct WaitingDeviceSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            ProgressView()
                .scaleEffect(1.5)
                .padding()

            Text("Waiting for Console")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                Text("To connect your console in FEL mode:")
                    .font(.subheadline)

                VStack(alignment: .leading, spacing: 4) {
                    Label("Power off the console", systemImage: "1.circle")
                    Label("Hold the RESET button", systemImage: "2.circle")
                    Label("While holding RESET, press POWER", systemImage: "3.circle")
                    Label("Release RESET after 3 seconds", systemImage: "4.circle")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                dismiss()
            }
        }
        .padding(30)
        .frame(minWidth: 350)
        .onChange(of: appState.deviceManager.felDevicePresent) { _, present in
            if present {
                dismiss()
            }
        }
    }
}
