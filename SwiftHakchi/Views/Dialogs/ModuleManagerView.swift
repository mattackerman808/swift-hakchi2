import SwiftUI
import AppKit

/// Module (hmod) manager — install, uninstall, and browse modules
struct ModuleManagerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appState: AppState

    @State private var selectedTab = 0
    @State private var installedModules: [HmodPackage] = []
    @State private var selectedModules: Set<String> = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var isInstalling = false
    @State private var isUninstalling = false

    // Browse tab state
    @State private var remoteModules: [ModRepositoryService.RemoteModule] = []
    @State private var isFetchingRemote = false
    @State private var browseError: String?
    @State private var selectedCategory: String = "All"
    @State private var installingModuleId: String?

    private let repoService = ModRepositoryService()

    private var categories: [String] {
        var cats = Set(remoteModules.map { $0.category })
        cats.insert("All")
        return ["All"] + cats.filter { $0 != "All" }.sorted()
    }

    private var filteredRemoteModules: [ModRepositoryService.RemoteModule] {
        if selectedCategory == "All" { return remoteModules }
        return remoteModules.filter { $0.category == selectedCategory }
    }

    private var installedIds: Set<String> {
        Set(installedModules.map { $0.id })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Module Manager")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Tabs
            Picker("", selection: $selectedTab) {
                Text("Installed").tag(0)
                Text("Browse").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            // Tab content
            if selectedTab == 0 {
                installedTab
            } else {
                browseTab
            }

            Divider()

            // Bottom actions
            HStack {
                Button("Install from File...") {
                    installFromFile()
                }
                .disabled(!appState.deviceManager.isConnected || isInstalling)

                Spacer()

                if selectedTab == 0 {
                    Button("Uninstall Selected") {
                        uninstallSelected()
                    }
                    .disabled(selectedModules.isEmpty || !appState.deviceManager.isConnected || isUninstalling)
                }
            }
            .padding()
        }
        .frame(width: 550, height: 500)
        .onAppear { loadInstalledModules() }
    }

    // MARK: - Installed Tab

    private var installedTab: some View {
        Group {
            if isLoading {
                ProgressView("Loading installed modules...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if installedModules.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "shippingbox")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("No modules installed")
                        .foregroundStyle(.secondary)
                    if !appState.deviceManager.isConnected {
                        Text("Connect a console to view installed modules.")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(installedModules, selection: $selectedModules) { mod in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.name)
                                .font(.body.weight(.medium))
                            if !mod.version.isEmpty {
                                Text("v\(mod.version)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if !mod.category.isEmpty {
                                Text(mod.category)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .tag(mod.id)
                }
                .listStyle(.inset)
            }

            if let error = errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.horizontal)
            }
        }
    }

    // MARK: - Browse Tab

    private var browseTab: some View {
        VStack(spacing: 0) {
            if isFetchingRemote {
                ProgressView("Fetching modules...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if remoteModules.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "globe")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text("Browse community modules")
                        .font(.headline)
                    Button("Load Repository") {
                        fetchRemoteModules()
                    }
                    if let error = browseError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Category filter
                HStack {
                    Text("Category:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("", selection: $selectedCategory) {
                        ForEach(categories, id: \.self) { cat in
                            Text(cat).tag(cat)
                        }
                    }
                    .frame(width: 150)
                    Spacer()
                    Text("\(filteredRemoteModules.count) modules")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal)
                .padding(.vertical, 4)

                List(filteredRemoteModules) { mod in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mod.name)
                                .font(.body.weight(.medium))
                            Text(mod.category)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()

                        if installedIds.contains(mod.id) {
                            Text("Installed")
                                .font(.caption)
                                .foregroundStyle(.green)
                        } else if installingModuleId == mod.id {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Button("Install") {
                                installRemoteModule(mod)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(!appState.deviceManager.isConnected)
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    // MARK: - Actions

    private func loadInstalledModules() {
        guard appState.deviceManager.isConnected, let shell = appState.deviceManager.sshService else {
            installedModules = []
            return
        }

        isLoading = true
        errorMessage = nil

        Task {
            let hmodService = HmodService(ssh: shell)
            do {
                let names = try await hmodService.installedHmods()
                await MainActor.run {
                    installedModules = names.map { name in
                        HmodPackage(id: name, name: name, isInstalled: true)
                    }
                    isLoading = false
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Failed to load: \(error.localizedDescription)"
                    isLoading = false
                }
            }
        }
    }

    private func fetchRemoteModules() {
        let repoURLs = AppConfig.shared.modRepositoryURLs
        guard let firstURL = repoURLs.first else {
            browseError = "No repository URLs configured."
            return
        }

        isFetchingRemote = true
        browseError = nil

        Task {
            do {
                let modules = try await repoService.fetchModules(from: firstURL)
                await MainActor.run {
                    remoteModules = modules
                    isFetchingRemote = false
                }
            } catch {
                await MainActor.run {
                    browseError = error.localizedDescription
                    isFetchingRemote = false
                }
            }
        }
    }

    private func installRemoteModule(_ mod: ModRepositoryService.RemoteModule) {
        guard let shell = appState.deviceManager.sshService else { return }

        installingModuleId = mod.id
        errorMessage = nil

        Task {
            do {
                let data = try await repoService.downloadModule(from: mod.downloadURL)
                let hmodService = HmodService(ssh: shell)
                try await hmodService.transferHmod(data: data, name: mod.id)
                try await hmodService.installTransferred()

                await MainActor.run {
                    installingModuleId = nil
                    loadInstalledModules()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Install failed: \(error.localizedDescription)"
                    installingModuleId = nil
                }
            }
        }
    }

    private func installFromFile() {
        let panel = NSOpenPanel()
        panel.title = "Select Module to Install"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.data, .folder]

        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        guard let shell = appState.deviceManager.sshService else { return }

        isInstalling = true
        errorMessage = nil

        Task {
            let hmodService = HmodService(ssh: shell)
            do {
                for url in panel.urls {
                    let name = url.lastPathComponent
                    if url.hasDirectoryPath {
                        let tarData = try tarDirectory(url)
                        try await hmodService.transferHmods(tarData: tarData)
                    } else {
                        let data = try Data(contentsOf: url)
                        try await hmodService.transferHmod(data: data, name: name)
                    }
                }
                try await hmodService.installTransferred()

                await MainActor.run {
                    isInstalling = false
                    loadInstalledModules()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Install failed: \(error.localizedDescription)"
                    isInstalling = false
                }
            }
        }
    }

    private func uninstallSelected() {
        guard let shell = appState.deviceManager.sshService else { return }
        let toUninstall = Array(selectedModules)

        isUninstalling = true
        errorMessage = nil

        Task {
            let hmodService = HmodService(ssh: shell)
            do {
                try await hmodService.uninstallHmods(toUninstall)
                await MainActor.run {
                    selectedModules = []
                    isUninstalling = false
                    loadInstalledModules()
                }
            } catch {
                await MainActor.run {
                    errorMessage = "Uninstall failed: \(error.localizedDescription)"
                    isUninstalling = false
                }
            }
        }
    }

    private func tarDirectory(_ url: URL) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-cf", "-", "-C", url.deletingLastPathComponent().path, url.lastPathComponent]

        let pipe = Pipe()
        process.standardOutput = pipe

        try process.run()
        process.waitUntilExit()

        return pipe.fileHandleForReading.readDataToEndOfFile()
    }
}
