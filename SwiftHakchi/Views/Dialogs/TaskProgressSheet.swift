import SwiftUI

/// Modal sheet showing task progress with cancel button
struct TaskProgressSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            if appState.taskRunner.isRunning {
                ProgressView(value: appState.taskRunner.progress) {
                    Text(appState.taskRunner.currentTask)
                }
                .progressViewStyle(.linear)

                if appState.taskRunner.canCancel {
                    Button("Cancel") {
                        appState.taskRunner.cancel()
                        dismiss()
                    }
                }
            } else if let error = appState.taskRunner.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.red)

                Text("Error")
                    .font(.headline)

                Text(error.localizedDescription)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                Image(systemName: "checkmark.circle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.green)

                Text("Complete")
                    .font(.headline)

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(minWidth: 350)
    }
}
