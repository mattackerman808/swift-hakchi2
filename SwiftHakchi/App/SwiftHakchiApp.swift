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

        // Set the app icon for Dock and About panel
        if let iconURL = Bundle.appBundle.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 800, minHeight: 500)
                .onAppear {
                    // Disable tab bar — removes "Show Tab Bar" from View menu
                    for window in NSApplication.shared.windows {
                        window.tabbingMode = .disallowed
                    }
                }
        }
        .commands {
            AboutCommands()
            FileCommands(appState: appState)
            EditCommands(appState: appState)
            GameCommands(appState: appState)
            KernelCommands(appState: appState)
            ModulesCommands(appState: appState)
            ToolsCommands(appState: appState)
            HelpCommands(appState: appState)
            CommandGroup(replacing: .toolbar) {}
            CommandGroup(replacing: .sidebar) {}
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}

// Each Commands struct is a standalone SwiftUI Commands conformance
// that takes an @ObservedObject so menu items update reactively.

struct FileCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add ROMs...") {
                appState.addROMs()
            }
            .keyboardShortcut("o")

            Button("Import from Console") {
                Task { await appState.importFromConsole() }
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .disabled(!appState.deviceManager.isConnected)

            Divider()

            Button("Sync") {
                Task { await appState.syncGames() }
            }
            .keyboardShortcut("s")
            .disabled(!appState.deviceManager.isConnected)
        }
    }
}

struct EditCommands: Commands {
    @ObservedObject var appState: AppState

    private var canDelete: Bool {
        appState.selectedGame?.source == .local
    }

    var body: some Commands {
        CommandGroup(after: .pasteboard) {
            Divider()

            Button("Delete Game") {
                appState.deleteSelectedGame()
            }
            .keyboardShortcut(.delete)
            .disabled(!canDelete)

            Button("Select All for Sync") {
                appState.selectAllGamesForSync()
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
        }
    }
}

struct GameCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Game") {
            Button("Next Game") {
                appState.selectNextGame()
            }
            .keyboardShortcut(.downArrow, modifiers: [])

            Button("Previous Game") {
                appState.selectPreviousGame()
            }
            .keyboardShortcut(.upArrow, modifiers: [])

            Divider()

            Button("Scraper...") {
                appState.showScraper = true
            }
            .keyboardShortcut("s", modifiers: [.command, .shift])
            .disabled(appState.selectedGame == nil)

            Button("Download from Console") {
                if let game = appState.selectedGame {
                    appState.downloadGameFromConsole(game: game)
                }
            }
            .keyboardShortcut("d")
            .disabled(appState.selectedGame == nil || !appState.deviceManager.isConnected)
        }
    }
}

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
            Button("Module Manager...") {
                appState.showModuleManager = true
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])
        }
    }
}

struct ToolsCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandMenu("Tools") {
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

struct HelpCommands: Commands {
    @ObservedObject var appState: AppState

    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Swift Hakchi2 Help") {
                appState.showHelp = true
            }
            .keyboardShortcut("?")
        }
    }
}

struct AboutCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About Swift Hakchi2") {
                let credits = NSMutableAttributedString()
                let style = NSMutableParagraphStyle()
                style.alignment = .center

                credits.append(NSAttributedString(
                    string: "A native macOS tool for modding Nintendo mini consoles.\n",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                        .paragraphStyle: style,
                    ]
                ))

                let url = URL(string: "https://github.com/mattackerman808/swift-hakchi2")!
                credits.append(NSAttributedString(
                    string: "GitHub",
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .link: url,
                        .paragraphStyle: style,
                    ]
                ))

                NSApplication.shared.orderFrontStandardAboutPanel(options: [
                    .credits: credits,
                ])
            }
        }
    }
}
