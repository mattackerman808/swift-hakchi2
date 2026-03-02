import SwiftUI

/// Pre-install configuration sheet. Shown before the install starts
/// to let the user choose backup settings.
struct InstallConfigSheet: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var backupKernel = true
    @State private var backupURL: URL = InstallConfigSheet.defaultBackupURL

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "cpu")
                .font(.system(size: 36))
                .foregroundStyle(.tint)

            Text("Install Custom Kernel")
                .font(.headline)

            Text("This will install hakchi on your console. A backup of the stock kernel is recommended so you can restore to factory state later.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: $backupKernel) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Backup stock kernel")
                                .font(.callout)
                                .fontWeight(.medium)
                            Text("Save a copy of the original kernel before modifying the console")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    if backupKernel {
                        HStack {
                            Image(systemName: "folder")
                                .foregroundStyle(.secondary)
                            Text(backupURL.path)
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .foregroundStyle(.primary)
                            Spacer()
                            Button("Change...") {
                                chooseBackupLocation()
                            }
                            .controlSize(.small)
                        }
                        .padding(.leading, 20)
                    }
                }
                .padding(4)
            }

            HStack(spacing: 12) {
                Button("Cancel") {
                    appState.cancelInstallConfig()
                }
                .keyboardShortcut(.cancelAction)

                Button("Install") {
                    let settings = BackupSettings(
                        enabled: backupKernel,
                        directory: backupKernel ? backupURL : nil
                    )
                    appState.confirmInstall(backupSettings: settings)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(30)
        .frame(minWidth: 450)
    }

    private func chooseBackupLocation() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose where to save the kernel backup"
        panel.prompt = "Select Folder"
        panel.directoryURL = backupURL

        if panel.runModal() == .OK, let url = panel.url {
            backupURL = url
        }
    }

    static var defaultBackupURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SwiftHakchi Backups", isDirectory: true)
    }
}

/// Backup configuration passed from the config sheet to the install flow
struct BackupSettings {
    let enabled: Bool
    let directory: URL?
}
