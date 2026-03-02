# Swift Hakchi2

A native macOS application for modding Nintendo mini consoles, built with Swift and SwiftUI. This is a ground-up rewrite of [Hakchi2 CE](https://github.com/TeamShinkansen/Hakchi2-CE) targeting macOS.

## Supported Consoles

- NES Classic / Famicom Mini
- SNES Classic (USA / EUR) / Super Famicom Mini

## Features

- **Custom Kernel Install** — Flash a custom kernel to enable homebrew, or uninstall/factory reset
- **Game Management** — Import ROMs, auto-match metadata via CRC32, edit game details
- **Drag-and-Drop Sync** — Drag games into the Console Game Bar, click Sync to upload over USB
- **Module Manager** — Browse, install, and manage hakchi modules (hmods) from an online repository
- **Scraper** — Search TheGamesDB for cover art, descriptions, and metadata
- **Stock Kernel Backup** — Back up and restore the original kernel

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+
- USB-A cable (or USB-C adapter) to connect to the console

## Installation

Download the latest `.zip` from [Releases](https://github.com/mattackerman808/swift-hakchi2/releases), extract it, and double-click **Swift Hakchi2.app**.

Because the app is not signed with an Apple Developer certificate, macOS will block it on first launch. To allow it:

1. Open **System Settings > Privacy & Security**
2. Scroll down to **Security**
3. Click **Open Anyway** next to the message about Swift Hakchi2, or change the **Allow applications from** setting to include the app

Alternatively, right-click the app and choose **Open** to bypass the warning once.

## Building

Clone the repository and run:

```bash
./run.sh
```

This builds the project, assembles a `.app` bundle, and launches it. For build-only:

```bash
swift build              # Debug
swift build -c release   # Release
```

## Usage

### Window Layout

The main window is organized top to bottom:

1. **Action Bar** — Buttons for **Install Kernel**, **Connect/Disconnect**, **Memboot**, and **Reboot**
2. **Games Explorer** — Your ROM library displayed as a grid of cover art cards (left), with an editable detail panel (right). The header has **Add ROMs** and **Import from Console** buttons, plus a search field.
3. **Console Game Bar** — A tray along the bottom labeled "Desired Console Config" that shows which games will be on your console after the next sync. Has **Custom Games** and **Default Games** tabs, and a centered **Sync** button.
4. **Status Bar** — Connection indicator (green = connected, orange = FEL mode, red = disconnected), console type, and game counts.

### Flashing the Console

1. Click **Install Kernel** in the action bar
2. Choose whether to back up the stock kernel (recommended for first-time setup)
3. If the console isn't in FEL mode, the app shows instructions and waits:
   - Power off the console and unplug USB
   - Hold the **RESET** button on the console
   - While holding RESET, plug in the USB cable
   - Release after 3 seconds
4. The app flashes the custom kernel automatically once the console is detected

Additional kernel operations are in the **Kernel** menu: Uninstall, Factory Reset, and Shutdown.

### Managing Games

- **Add ROMs** — Click "Add ROMs" in the Games Explorer header. Supported formats: `.nes`, `.sfc`, `.smc`, `.md`, `.bin`, `.zip`
- **Import from Console** — Click "Import from Console" to copy existing custom games from a connected console into your library
- **Auto-matching** — Imported ROMs are matched by CRC32 against a built-in database to fill in name, publisher, release date, and cover art
- **Edit details** — Click any game card to select it. The detail panel shows editable fields for name, publisher, genre, release date, players, command line, and description. Click "Save" to persist changes.
- **Scraper** — Select a game and click "Search Online..." in the detail panel to search TheGamesDB for metadata and cover art. Requires an API key (see Settings).
- **Delete** — Right-click a game card and choose "Delete Game..." to remove it from the library (your original ROM file is not affected)

### Syncing Games to the Console

1. **Drag** game cards from the Games Explorer down into the Console Game Bar
2. The Console Game Bar shows your desired configuration — Custom Games tab for your imports, Default Games tab for stock titles
3. To remove a game, drag it off the Console Game Bar back up into the explorer area (a "Remove" label follows your cursor and a poof animation plays on drop)
4. Stock games can be hidden by dragging them off, or re-enabled via right-click → "Re-enable"
5. Click the **Sync** button in the Console Game Bar to upload everything to the console

The console has approximately 300 MB of usable storage. If syncing would remove games already on the console, the app warns you and offers to import them first.

### Modules (hmods)

Open the **Module Manager** from the Modules menu (Cmd+Shift+M):

- **Browse tab** — Click "Load Repository" to fetch available modules, then click "Install" next to any module. You can also use "Install from File..." for local `.hmod` files.
- **Installed tab** — View modules on the console, select any to uninstall with "Uninstall Selected"

### Settings

Open from the Swift Hakchi2 menu (Cmd+,):

- **Console tab** — Default console type (NES/SNES/Famicom/Super Famicom), TheGamesDB API key, and "Enrich Library Now" button to bulk-fetch metadata
- **Storage tab** — Upload games compressed, separate game storage per console, max game size (MB), and games folder path
- **Advanced tab** — Purge all cover art (re-downloads from database), purge all imported games (clears library, does not delete original ROM files)

## How It Works

The app communicates with the console through two USB protocols:

1. **FEL Mode** — When the console is in its Allwinner bootloader, the app uses the FEL protocol to initialize DRAM and boot a custom kernel image. The user enters FEL mode by holding Reset while powering on.

2. **RNDIS/SSH** — After memboot, the console exposes a USB RNDIS network gadget. The app runs a user-space TCP/IP stack over this link and opens an SSH session to execute commands and transfer files — no network drivers or kernel extensions required.

## Project Structure

```
SwiftHakchi/          Swift application
├── App/              Entry point and AppState (global coordinator)
├── Models/           Data models (Game, ConsoleType, DesktopFile, AppConfig)
├── Services/         Actor-based business logic (device, flash, games, SSH, FEL)
├── Views/            SwiftUI interface
├── Utilities/        Helpers (TarWriter, CRC32, Game Genie codecs)
└── Resources/        Binary payloads (fes1.bin, hakchi.hmod, basehmods.tar)

USBBridge/            C library — USB and network protocol stack
├── src/              IOKit USB, FEL, RNDIS, TCP/IP, SSH bridge, Clovershell
└── include/          Public headers consumed by Swift

vendor/               Vendored C dependencies
├── mbedtls/          MBedTLS (cryptography, used by libssh2)
└── libssh2/          LibSSH2 (SSH protocol)
```

## License

This project is not affiliated with Nintendo. Use at your own risk.
