import SwiftUI

/// Modal sheet shown while waiting for FEL device connection.
/// Displays instructions for entering FEL mode and auto-dismisses
/// when the device is detected (handled by AppState subscriber).
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

            Text("Connect your console in FEL mode to continue.")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("How to enter FEL mode:")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    step(number: 1, text: "Unplug the console from USB to remove power")
                    step(number: 2, text: "Make sure the console's power switch is ON")
                    step(number: 3, text: "Hold the RESET button on the console")
                    step(number: 4, text: "While holding RESET, plug in the USB cable to your Mac")
                    step(number: 5, text: "Keep holding RESET for 3 seconds, then release")
                }
                .padding(4)
            }

            if appState.deviceManager.felDevicePresent {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Text("Console detected!")
                        .fontWeight(.medium)
                }
                .transition(.opacity)
            }

            Button("Cancel") {
                appState.cancelWaitingForDevice()
            }
        }
        .padding(30)
        .frame(minWidth: 400)
        .animation(.easeInOut, value: appState.deviceManager.felDevicePresent)
    }

    private func step(number: Int, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "\(number).circle.fill")
                .foregroundColor(.accentColor)
                .font(.title3)
            Text(text)
                .font(.callout)
        }
    }
}
