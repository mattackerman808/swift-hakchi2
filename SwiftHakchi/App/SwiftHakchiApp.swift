import SwiftUI
import AppKit

@main
struct SwiftHakchiApp: App {
    @StateObject private var appState = AppState()

    init() {
        // When running via `swift run` (not from a .app bundle), macOS treats
        // the process as a background/CLI tool — no dock icon, no menu bar.
        // Setting .regular makes it behave as a normal GUI app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            KernelCommands(appState: appState)
            ModulesCommands(appState: appState)
            ToolsCommands(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// Each Commands struct is a standalone SwiftUI Commands conformance
// that takes an @ObservedObject so menu items update reactively.

struct KernelCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Kernel") {
            Button("Install / Repair") {
                appState.requestFlash(.installHakchi)
            }
            .keyboardShortcut("i", modifiers: [.command, .shift])
            .disabled(!appState.deviceManager.felDevicePresent)

            Button("Uninstall") {
                appState.requestFlash(.uninstallHakchi)
            }

            Button("Factory Reset") {
                appState.requestFlash(.factoryReset)
            }

            Divider()

            Button("Flash Custom Kernel") {
                appState.requestFlash(.memboot)
            }
            .keyboardShortcut("k", modifiers: [.command, .shift])
            .disabled(!appState.deviceManager.felDevicePresent)

            Divider()

            Button("Reboot") {
                Task { await appState.rebootConsole() }
            }
            .disabled(!appState.deviceManager.isConnected)

            Button("Shutdown") {
                Task { await appState.shutdownConsole() }
            }
            .disabled(!appState.deviceManager.isConnected)
        }
    }
}

struct ModulesCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Modules") {
            Button("Mod Hub...") {
                appState.showModHub = true
            }
        }
    }
}

struct ToolsCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Tools") {
            Button("Folders Manager...") {
                appState.showFoldersManager = true
            }

            Button("Scraper...") {
                appState.showScraper = true
            }

            Divider()

            Button("Dump Stock Kernel") {
                appState.requestFlash(.dumpStockKernel)
            }
            .disabled(!appState.deviceManager.isConnected)
        }
    }
}
