import SwiftUI

/// Modal sheet showing task progress with cancel button
struct TaskProgressSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            if appState.taskRunner.isRunning {
                // Running state
                Text(appState.taskRunner.currentTask)
                    .font(.headline)

                ProgressView(value: appState.taskRunner.progress)
                    .progressViewStyle(.linear)

                Text(String(format: "%.0f%%", appState.taskRunner.progress * 100))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if appState.taskRunner.canCancel {
                    Button("Cancel") {
                        appState.taskRunner.cancel()
                        dismiss()
                    }
                }
            } else if let error = appState.taskRunner.error {
                // Error state
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.red)

                Text("Error")
                    .font(.headline)

                ScrollView {
                    Text(error.localizedDescription)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 150)

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            } else {
                // Success state
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36))
                    .foregroundStyle(.green)

                Text("Complete")
                    .font(.headline)

                Text(appState.taskRunner.currentTask)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("OK") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(minWidth: 400)
    }
}
