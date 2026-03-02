# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Swift Hakchi2 is a native macOS rewrite of Hakchi2 CE — a tool for modding Nintendo mini consoles (NES/SNES Classic). It handles custom kernel installation, game management, and console communication over USB. Built with Swift/SwiftUI and a C-based USB protocol layer.

## Build & Run

```bash
./run.sh              # Build, create .app bundle, and launch
swift build           # Build only (debug)
swift build -c release  # Release build
```

Requires macOS 14.0+ (Sonoma) and Swift 5.9+. No test target or linter is configured.

## Architecture

### Target Dependency Chain (Package.swift)

```
MbedCrypto (vendored C) → LibSSH2 (vendored C) → USBBridge (C) → SwiftHakchi (Swift executable)
                                                                    ↳ SWCompression (SPM dep)
```

### Swift Layer (`SwiftHakchi/`)

**MVVM-style with actor-based services and Swift structured concurrency.**

- **AppState** (`App/AppState.swift`) — `@MainActor ObservableObject`, the central coordinator. Owns all services, manages UI state, orchestrates flash/sync workflows. Injected into views via `@EnvironmentObject`.
- **Services** (`Services/`) — Actor-isolated business logic using `async/await`. Key services:
  - `DeviceManager` — USB device lifecycle: detects FEL and RNDIS devices via `USBMonitor`, establishes SSH connections, probes console info
  - `SSHService` / `FELService` — Thin Swift wrappers around C functions in USBBridge
  - `FlashService` — Install/uninstall/factory-reset workflows (memboot → SSH → upload payloads → reboot)
  - `GameManagerService` — Local game library + console game pulling + ROM import
  - `GameSyncService` — Syncs selected games to console over SSH (matching hakchi2-CE directory layout)
  - `PayloadService` — Loads bundled binary resources (fes1.bin, uboot, boot.img, hmods)
  - `TaskRunner` — Progress tracking for async operations
- **Models** (`Models/`) — `Game`, `ConsoleType`, `DesktopFile` (parser/serializer for .desktop files), `AppConfig` (persistent settings as Codable JSON), `HmodPackage`
- **Views** (`Views/`) — SwiftUI. `ContentView` is the main layout; dialogs in `Views/Dialogs/`

Services publish state changes via Combine, forwarded through `AppState` to views.

### C Layer (`USBBridge/`)

Implements the full USB communication stack using macOS IOKit:

```
usb_device.c  — IOKit USB device open/close, bulk I/O, control transfers
fel_protocol.c — Allwinner FEL bootloader protocol (DRAM init, memboot, memory read/write)
rndis.c        — RNDIS USB gadget protocol (CDC Ethernet over USB)
tcpip.c        — Minimal user-space TCP/IP stack (ARP, IP, TCP) over RNDIS
ssh_bridge.c   — LibSSH2 session over the user-space TCP stack (exec, upload via stdin)
clovershell.c  — Legacy Clovershell USB protocol (alternative to RNDIS/SSH)
```

### Console Communication Flow

1. **FEL phase** — Console in bootloader mode (USB VID `0x1F3A`). FEL protocol initializes DRAM, uploads and boots a custom kernel with RNDIS gadget enabled.
2. **RNDIS/SSH phase** — Console appears as RNDIS USB device (VID `0x04E8`). User-space TCP/IP stack runs over RNDIS. SSH sessions execute shell commands and upload files. Host IP: `169.254.13.38`, Console IP: `169.254.13.37`.

### Data Storage

```
~/Library/Application Support/SwiftHakchi/
├── config.json       # AppConfig (console type, preferences)
├── games/            # Local game library ({CLV-code}/{CLV-code}.desktop + ROM + art)
├── data/             # Cached downloads
└── dump/             # Stock kernel backups
```

### Console Game Layout (on device)

```
/var/lib/hakchi/games/{syncCode}/
├── .storage/{code}/  # Actual game files
├── 000/              # Main menu folder (stock games + "More games")
└── 001/              # User-imported games
```

## Conventions

- Logging uses `os.Logger` with subsystem `"com.swifthakchi.app"` and per-service categories
- Error types are service-scoped: `SSHError`, `FELError`, `FlashError`, `PayloadError`, etc.
- Game codes follow console-specific prefixes: `CLV-H-` (NES/Famicom), `CLV-U-` (SNES), `CLV-P-` (others)
- Binary payloads are SPM bundle resources in `SwiftHakchi/Resources/`
- The app requires USB entitlements — it accesses IOKit directly for device I/O
