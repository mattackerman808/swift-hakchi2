import SwiftUI

@main
struct SwiftHakchiApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
        }
        .commands {
            // Kernel menu
            CommandMenu("Kernel") {
                Button("Install / Repair") {
                    appState.requestFlash(.installHakchi)
                }
                .keyboardShortcut("i", modifiers: [.command, .shift])
                .disabled(!appState.deviceManager.felDevicePresent)

                Button("Uninstall") {
                    appState.requestFlash(.uninstallHakchi)
                }
                .disabled(!appState.deviceManager.isConnected)

                Button("Factory Reset") {
                    appState.requestFlash(.factoryReset)
                }
                .disabled(!appState.deviceManager.isConnected)

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

            // Modules menu
            CommandMenu("Modules") {
                Button("Mod Hub...") {
                    appState.showModHub = true
                }
            }

            // Tools menu
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

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
