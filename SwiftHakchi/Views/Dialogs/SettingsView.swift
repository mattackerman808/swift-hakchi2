import SwiftUI

/// Settings window (macOS Settings scene)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            consoleTab
                .tabItem {
                    Label("Console", systemImage: "gamecontroller")
                }

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }
        }
        .frame(width: 450, height: 300)
        .onChange(of: config.lastConsoleType) { _, _ in config.save() }
        .onChange(of: config.separateGameStorage) { _, _ in config.save() }
        .onChange(of: config.forceNetwork) { _, _ in config.save() }
        .onChange(of: config.uploadCompressed) { _, _ in config.save() }
        .onChange(of: config.maxGameSize) { _, _ in config.save() }
    }

    private var generalTab: some View {
        Form {
            Toggle("Force network mode (SSH)", isOn: $config.forceNetwork)
            Toggle("Upload games compressed", isOn: $config.uploadCompressed)
        }
        .padding()
    }

    private var consoleTab: some View {
        Form {
            Picker("Default Console Type", selection: $config.lastConsoleType) {
                ForEach(ConsoleType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }
        }
        .padding()
    }

    private var storageTab: some View {
        Form {
            Toggle("Separate game storage per console", isOn: $config.separateGameStorage)

            LabeledContent("Max game size (MB)") {
                TextField("MB", value: $config.maxGameSize, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            LabeledContent("Games folder") {
                Text(config.gamesDirectory.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding()
    }
}
