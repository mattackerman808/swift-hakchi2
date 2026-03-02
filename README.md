# Swift Hakchi2

A native macOS application for modding Nintendo mini consoles, built with Swift and SwiftUI. This is a ground-up rewrite of [Hakchi2 CE](https://github.com/TeamShinkansen/Hakchi2-CE) targeting macOS.

## Supported Consoles

- NES Classic / Famicom Mini
- SNES Classic (USA / EUR) / Super Famicom Mini
- Mega Drive Mini

## Features

- **Custom Kernel Install** — Flash a custom kernel to enable homebrew, or uninstall/factory reset
- **Game Management** — Import ROMs, manage box art, edit game metadata
- **Game Sync** — Sync your game library to the console over USB
- **Mod Hub** — Install and manage hakchi modules (hmods)
- **Folders Manager** — Organize games into console menu folders
- **Box Art Scraper** — Download cover art from TheGamesDB
- **Game Genie** — NES and SNES cheat code support
- **Stock Kernel Backup** — Dump and restore the original kernel

## Requirements

- macOS 14.0 (Sonoma) or later
- Swift 5.9+
- USB connection to a supported console

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
