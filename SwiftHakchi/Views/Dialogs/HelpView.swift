import SwiftUI

/// In-app help window with sidebar navigation and scrollable content sections
struct HelpView: View {
    @Environment(\.dismiss) private var dismiss

    enum Section: String, CaseIterable, Identifiable {
        case gettingStarted = "Getting Started"
        case flashing = "Flashing the Console"
        case managingGames = "Managing Games"
        case syncing = "Syncing Games"
        case modules = "Modules (hmods)"
        case settings = "Settings"
        case troubleshooting = "Troubleshooting"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .gettingStarted: return "star"
            case .flashing: return "cpu"
            case .managingGames: return "gamecontroller"
            case .syncing: return "arrow.triangle.2.circlepath"
            case .modules: return "shippingbox"
            case .settings: return "gearshape"
            case .troubleshooting: return "wrench.and.screwdriver"
            }
        }
    }

    @State private var selectedSection: Section = .gettingStarted

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Swift Hakchi2 Help")
                    .font(.title2.bold())
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Sidebar + content
            HStack(spacing: 0) {
                // Sidebar
                List(Section.allCases, selection: $selectedSection) { section in
                    Label(section.rawValue, systemImage: section.icon)
                        .tag(section)
                }
                .listStyle(.sidebar)
                .frame(width: 200)

                Divider()

                // Content
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sectionContent(selectedSection)
                    }
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .frame(width: 650, height: 500)
    }

    // MARK: - Section content

    @ViewBuilder
    private func sectionContent(_ section: Section) -> some View {
        switch section {
        case .gettingStarted: gettingStartedContent
        case .flashing: flashingContent
        case .managingGames: managingGamesContent
        case .syncing: syncingContent
        case .modules: modulesContent
        case .settings: settingsContent
        case .troubleshooting: troubleshootingContent
        }
    }

    // MARK: - Getting Started

    private var gettingStartedContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Getting Started")

            bodyText("Swift Hakchi2 is a native macOS tool for modding Nintendo NES Classic Mini and SNES Classic Mini consoles. It lets you install a custom kernel, import your own game ROMs, and sync them to your console over USB.")

            heading("Requirements")
            bulletList([
                "macOS 14 (Sonoma) or later",
                "A USB-A cable (or USB-C adapter) to connect your console",
                "An NES Classic Mini or SNES Classic Mini console",
            ])

            heading("Window Layout")
            bodyText("The main window is organized into four areas from top to bottom:")
            numberedList([
                "Action Bar \u{2014} Buttons for Install Kernel, Connect, Memboot, and Reboot across the top",
                "Games Explorer \u{2014} Your ROM library as a grid of cover art cards on the left, with an editable detail panel on the right",
                "Console Game Bar \u{2014} The tray along the bottom labeled \"Desired Console Config\" showing which games will be on your console",
                "Status Bar \u{2014} Connection status and game counts at the very bottom",
            ])

            heading("Basic Workflow")
            numberedList([
                "Flash \u{2014} Click \"Install Kernel\" in the action bar to install the custom kernel",
                "Import \u{2014} Click \"Add ROMs\" in the Games Explorer to import your ROM files",
                "Select \u{2014} Drag game cards from the explorer down into the Console Game Bar",
                "Sync \u{2014} Click \"Sync\" in the Console Game Bar to upload games to the console",
                "Play \u{2014} Unplug USB, power on, and enjoy your games",
            ])
        }
    }

    // MARK: - Flashing the Console

    private var flashingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Flashing the Console")

            bodyText("Flashing installs a custom kernel on your console that enables loading additional games. The process is safe and reversible \u{2014} you can always restore the stock kernel.")

            heading("Install Kernel")
            bodyText("Click the \"Install Kernel\" button in the action bar at the top of the window. A configuration dialog will appear where you can choose to back up the stock kernel before flashing. If the console isn't in FEL mode yet, the app will show instructions and wait for you to connect it.")

            heading("Entering FEL Mode")
            bodyText("The console must be in FEL (bootloader) mode for flashing. The app shows these steps automatically when needed:")
            numberedList([
                "Unplug the console from USB to remove power",
                "Make sure the console's power switch is ON",
                "Hold the RESET button on the console",
                "While holding RESET, plug in the USB cable to your Mac",
                "Keep holding RESET for 3 seconds, then release",
            ])
            bodyText("When the console is detected, the status bar at the bottom shows an orange dot and \"FEL Device Detected\".")

            heading("Connect / Disconnect")
            bodyText("After the custom kernel is installed, power cycle the console and it will boot into the custom firmware. Click the \"Connect\" button in the action bar. When connected, the button turns green and shows \"Disconnect\". The status bar shows a green dot and the console type.")

            heading("Memboot")
            bodyText("Click the \"Memboot\" button in the action bar to boot the custom kernel temporarily without writing it to flash. The console reverts to stock on the next power cycle. Useful for testing.")

            heading("Reboot")
            bodyText("Click the \"Reboot\" button in the action bar to restart the console. Only available while connected.")

            heading("Other Kernel Operations")
            bodyText("Additional operations are available in the Kernel menu:")
            bulletList([
                "Uninstall \u{2014} Removes the custom kernel and restores stock",
                "Factory Reset \u{2014} Full restore using a kernel backup file you select",
                "Shutdown \u{2014} Powers off the console",
            ])
        }
    }

    // MARK: - Managing Games

    private var managingGamesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Managing Games")

            heading("Adding ROMs")
            bodyText("Click the \"Add ROMs\" button in the top-right of the Games Explorer. Select one or more ROM files from your Mac. Supported formats:")
            bulletList([
                ".nes \u{2014} NES / Famicom ROMs",
                ".sfc, .smc \u{2014} SNES / Super Famicom ROMs",
                ".md, .bin \u{2014} Sega Genesis / Mega Drive ROMs",
                ".zip \u{2014} Compressed ROM archives",
            ])

            heading("Importing from Console")
            bodyText("If your console already has custom games installed, click the \"Import from Console\" button in the Games Explorer header (only available while connected). This copies games from the console into your local library.")

            heading("Auto-Matching")
            bodyText("When you import a ROM, the app calculates its CRC32 checksum and looks it up in a built-in game database. If a match is found, the game name, publisher, release date, and cover art are filled in automatically.")

            heading("Editing Game Details")
            bodyText("Click any game card in the explorer to select it. The detail panel on the right shows editable fields:")
            bulletList([
                "Name, Publisher, Genre \u{2014} Text fields for game metadata",
                "Release Date \u{2014} In YYYY-MM-DD format",
                "Players \u{2014} Number of players (1\u{2013}4) with a Simultaneous toggle",
                "Command Line \u{2014} The launch command (advanced, usually auto-configured)",
                "Description \u{2014} Free-text description of the game",
            ])
            bodyText("Click \"Save\" in the detail panel to save your changes.")

            heading("Scraper")
            bodyText("For games that weren't auto-matched, select a game and click \"Search Online...\" in the detail panel. This opens the Scraper, which searches TheGamesDB for matching titles. Select the correct result and click \"Apply\" to import the metadata and cover art. Requires a TheGamesDB API key (see Settings).")

            heading("Downloading ROMs from Console")
            bodyText("To save a copy of a game's ROM from the console to your Mac, select the game and click \"Download from Console\" in the detail panel. You'll be prompted to choose a save location.")

            heading("Deleting Games")
            bodyText("Right-click a game card in the explorer and choose \"Delete Game...\" to remove it from your library. This only removes the imported copy \u{2014} your original ROM file is not affected.")
        }
    }

    // MARK: - Syncing Games

    private var syncingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Syncing Games")

            bodyText("The Console Game Bar at the bottom of the window shows exactly which games will be on your console after the next sync. Think of it as a staging area \u{2014} arrange the games you want, then sync to apply.")

            heading("Adding Games to the Console Bar")
            bodyText("Drag game cards from the Games Explorer and drop them onto the Console Game Bar at the bottom. A dashed drop target appears when you start dragging. You can also double-click a game in the bar to re-enable it if it was hidden.")

            heading("Removing Games from the Console Bar")
            bodyText("Drag a game card off the Console Game Bar and drop it anywhere in the explorer area above. A \"Remove\" label follows your cursor (or \"Hide\" for stock games), and the game is deselected with a poof animation.")

            heading("Custom Games vs Default Games")
            bodyText("The Console Game Bar has two tabs:")
            bulletList([
                "Custom Games \u{2014} Your imported ROMs that you've dragged to the bar",
                "Default Games \u{2014} The console's built-in stock games",
            ])
            bodyText("Stock games can be hidden by dragging them off the bar, or re-enabled by right-clicking and choosing \"Re-enable\".")

            heading("Syncing")
            bodyText("Click the \"Sync\" button in the center of the Console Game Bar header. The app compresses the selected ROMs, uploads them to the console via USB, and rebuilds the console's game menu. The console must be connected (green status).")

            heading("Storage Limits")
            bodyText("The console has approximately 300 MB of usable storage. You can set a maximum game size in Settings to skip oversized ROMs during sync.")

            heading("Safety")
            bodyText("If syncing would remove games already on the console that aren't in your current selection, the app warns you and offers to import them first so you don't lose anything.")
        }
    }

    // MARK: - Modules (hmods)

    private var modulesContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Modules (hmods)")

            bodyText("Modules (also called hmods) are add-on packages that extend your console's capabilities \u{2014} RetroArch cores for additional emulators, themes, and other enhancements.")

            heading("Opening the Module Manager")
            bodyText("Open the Module Manager from the Modules menu or press Cmd+Shift+M.")

            heading("Browsing & Installing")
            numberedList([
                "Switch to the \"Browse\" tab",
                "Click \"Load Repository\" to fetch the list of available modules",
                "Use the category filter to narrow results",
                "Click \"Install\" next to the module you want",
            ])
            bodyText("You can also install a module from a local .hmod file using the \"Install from File...\" button.")

            heading("Viewing Installed Modules")
            bodyText("The \"Installed\" tab shows all modules currently on your console (the console must be connected). Each entry shows the module name, version, and category.")

            heading("Removing Modules")
            bodyText("In the \"Installed\" tab, select one or more modules, then click \"Uninstall Selected\".")
        }
    }

    // MARK: - Settings

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Settings")

            bodyText("Open Settings from the Swift Hakchi2 menu or press Cmd+,. Settings are organized into three tabs.")

            heading("Console Tab")
            bulletList([
                "Default Console Type \u{2014} Choose NES Classic, SNES Classic, Famicom Mini, or Super Famicom Mini to match your hardware",
                "TheGamesDB API Key \u{2014} Enter your free API key from thegamesdb.net to enable the Scraper and library enrichment",
                "Enrich Library Now \u{2014} Fetches descriptions, genres, and cover art from TheGamesDB for all games in your library at once",
            ])

            heading("Storage Tab")
            bulletList([
                "Upload games compressed \u{2014} Compress ROMs during sync to save console storage",
                "Separate game storage per console \u{2014} Keep game files separate for each console type",
                "Max game size (MB) \u{2014} Skip ROMs larger than this limit during sync",
                "Games folder \u{2014} Shows the path where your imported game library is stored",
            ])

            heading("Advanced Tab")
            bulletList([
                "Purge All Cover Art \u{2014} Deletes all cached cover images and re-downloads them from the game database. Useful if artwork appears corrupted.",
                "Purge All Imported Games \u{2014} Removes all imported ROMs, cached data, and cover art from the library. Built-in console games are not affected, and your original ROM files on disk are not deleted.",
            ])
        }
    }

    // MARK: - Troubleshooting

    private var troubleshootingContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionTitle("Troubleshooting")

            troubleItem(
                problem: "Console not detected after connecting USB",
                solution: "Check the USB cable and try a different port. Make sure the console is powered on. If the console is playing its demo reel, press a button on the controller to exit it first. Click the \"Connect\" button in the action bar to retry. The status bar at the bottom shows a green dot when connected."
            )

            troubleItem(
                problem: "FEL device not found when trying to flash",
                solution: "Make sure the console is off, then hold RESET before plugging in USB. Keep holding for 3 seconds, then release. The status bar should show an orange dot and \"FEL Device Detected\". If it doesn't appear, try a different USB cable or port."
            )

            troubleItem(
                problem: "Sync fails or stalls",
                solution: "Make sure the console is connected (green status). Check the console has enough free storage \u{2014} try syncing fewer games. Make sure the console is running the custom kernel, not stock. Click \"Reboot\" in the action bar and reconnect."
            )

            troubleItem(
                problem: "Missing or corrupted cover art",
                solution: "Select the game and click \"Search Online...\" in the detail panel to search for artwork via the Scraper. You can also go to Settings \u{2192} Advanced and click \"Purge & Re-download...\" to re-fetch all cover art."
            )

            troubleItem(
                problem: "Games don't appear on the console after sync",
                solution: "Reboot the console \u{2014} click \"Reboot\" in the action bar, or unplug power and reconnect. The console rebuilds its game menu on boot."
            )

            troubleItem(
                problem: "App won't launch",
                solution: "Swift Hakchi2 requires macOS 14 (Sonoma) or later. Check your macOS version in Apple menu \u{2192} About This Mac."
            )
        }
    }

    // MARK: - Reusable components

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.title3.bold())
            .padding(.bottom, 4)
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.headline)
            .padding(.top, 4)
    }

    private func bodyText(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.secondary)
    }

    private func bulletList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(items, id: \.self) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\u{2022}")
                        .foregroundStyle(.secondary)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func numberedList(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                HStack(alignment: .top, spacing: 8) {
                    Text("\(index + 1).")
                        .foregroundStyle(.secondary)
                        .frame(width: 20, alignment: .trailing)
                    Text(item)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.leading, 8)
    }

    private func troubleItem(problem: String, solution: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(problem)
                .font(.headline)
            Text(solution)
                .font(.body)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary))
    }
}
