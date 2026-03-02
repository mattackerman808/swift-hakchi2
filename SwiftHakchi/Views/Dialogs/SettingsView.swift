import SwiftUI

/// Settings window (macOS Settings scene)
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var config = AppConfig.shared
    @State private var showPurgeConfirm = false
    @State private var showPurgeGamesConfirm = false

    var body: some View {
        TabView {
            consoleTab
                .tabItem {
                    Label("Console", systemImage: "gamecontroller")
                }

            storageTab
                .tabItem {
                    Label("Storage", systemImage: "externaldrive")
                }

            advancedTab
                .tabItem {
                    Label("Advanced", systemImage: "gearshape.2")
                }
        }
        .frame(width: 450, height: 300)
        .onChange(of: config.lastConsoleType) { _, _ in config.save() }
        .onChange(of: config.separateGameStorage) { _, _ in config.save() }
        .onChange(of: config.uploadCompressed) { _, _ in config.save() }
        .onChange(of: config.maxGameSize) { _, _ in config.save() }
        .onChange(of: config.theGamesDbApiKey) { _, _ in config.save() }
    }

    private var consoleTab: some View {
        Form {
            Picker("Default Console Type", selection: $config.lastConsoleType) {
                ForEach(ConsoleType.allCases) { type in
                    Text(type.displayName).tag(type)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("TheGamesDB API Key") {
                    TextField("API Key", text: $config.theGamesDbApiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 250)
                }

                Text("Used for the scraper dialog and to enrich your library with descriptions, genres, and better cover art. Get a free key at [thegamesdb.net/API](https://thegamesdb.net/API).")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Enrich Library Now") {
                    appState.enrichLibrary()
                }
                .disabled(config.theGamesDbApiKey.isEmpty)
                .help("Fetch descriptions, genres, and cover art from TheGamesDB for all games")
            }
        }
        .padding()
    }

    private var storageTab: some View {
        Form {
            Toggle("Upload games compressed", isOn: $config.uploadCompressed)
                .help("Compress ROMs during sync to save storage on the console")

            Toggle("Separate game storage per console", isOn: $config.separateGameStorage)
                .help("Keep game files in separate folders for each console type")

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

    private var advancedTab: some View {
        Form {
            Section("Cover Art") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purge All Cover Art")
                        Text("Deletes all cached cover images and re-downloads them from the game database.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Purge & Re-download...") {
                        showPurgeConfirm = true
                    }
                    .help("Delete all cached cover art and re-download from the game database")
                    .alert("Purge All Cover Art?", isPresented: $showPurgeConfirm) {
                        Button("Purge & Re-download", role: .destructive) {
                            appState.gameManager.purgeCoverArt()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete all cover art images and re-download them. Games without a database match will show placeholder art until new covers are added.")
                    }
                }
            }

            Section("Game Library") {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Purge All Imported Games")
                        Text("Removes all imported ROMs, cached data, and cover art. Built-in console games are not affected. Your original ROM files are not deleted.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Purge Library...") {
                        showPurgeGamesConfirm = true
                    }
                    .help("Remove all imported games, cached data, and cover art from the library")
                    .alert("Purge Game Library?", isPresented: $showPurgeGamesConfirm) {
                        Button("Purge Everything", role: .destructive) {
                            appState.gameManager.purgeAllLocalData()
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This will delete all imported games, cached covers, and downloaded data. Your original ROM files on disk are not affected. You will need to re-import your games.")
                    }
                }
            }
        }
        .padding()
    }
}
