import Foundation
import CoreGraphics
import ImageIO
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "GameSync")

/// Syncs games to the console matching the upstream .NET hakchi2-CE layout exactly:
///
///   {syncBase}/.storage/{code}/   — ROM + PNG (actual game files)
///   {syncBase}/000/               — main menu: stock game .desktops + "More games..." folder
///   {syncBase}/001/               — custom games page: game .desktops + "Original games" back button
///   /var/games → {syncBase}/000   — symlink (current page)
///   gamepath bind-mounted with 000/ content
///
/// Stock game dirs in 000/ contain only .desktop + autoplay/pixelart symlinks to squashfs.
/// Custom game .desktop Exec points to absolute .storage path for the ROM.
actor GameSyncService {
    private let shell: SSHService
    private let consoleType: ConsoleType

    private static let nesDefaultArgs = "--guest-overscan-dimensions 0,0,9,3 --initial-fadein-durations 3,2 --volume 75 --enable-armet"
    private static let squashfsBase = "/var/squashfs"

    init(shell: SSHService, consoleType: ConsoleType) {
        self.shell = shell
        self.consoleType = consoleType
    }

    func syncGames(
        games: [Game],
        gameSyncPath: String,
        progress: @Sendable (String, Double) -> Void
    ) async throws {
        let selectedGames = games.filter { $0.isSelected && $0.source == .local }
        let gamePath = consoleType.originalGamesPath
        let syncBase = "\(gameSyncPath)/\(consoleType.syncCode)"
        let storageDir = "\(syncBase)/.storage"
        let page0 = "\(syncBase)/000"
        let page1 = "\(syncBase)/001"
        let squashfsGamePath = "\(Self.squashfsBase)\(gamePath)"

        logger.info("Syncing \(selectedGames.count) custom games, syncBase=\(syncBase)")

        // Step 1: Stop console UI
        progress("Preparing console...", 0.05)
        _ = try? await shell.execute("uistop")

        // Step 2: Unmount any existing bind mount on gamepath
        progress("Unmounting overlay...", 0.08)
        _ = try? await shell.execute("umount \"\(gamePath)\" 2>/dev/null")
        _ = try? await shell.execute("rm -f /var/games")

        // Step 3: Clean and recreate sync directories
        progress("Preparing sync directory...", 0.10)
        _ = try? await shell.execute("rm -rf \"\(syncBase)\"")
        _ = try? await shell.execute("mkdir -p \"\(storageDir)\" \"\(page0)\" \"\(page1)\"")

        // Step 4: Build page 000/ — stock game entries from squashfs
        progress("Building stock game entries...", 0.12)
        try await buildStockGameEntries(page0: page0, squashfsGamePath: squashfsGamePath)

        // Step 5: Create "More games..." folder entry (CLV-S-00001) in page 000/
        progress("Creating folder structure...", 0.18)
        try await createFolderEntry(in: page0)

        // Step 6: Create font symlinks in page 000/
        _ = try? await shell.execute(
            "ln -sf \"\(squashfsGamePath)/copyright.fnt\" \"\(page0)/copyright.fnt\" 2>/dev/null; " +
            "ln -sf /var/lib/hakchi/rootfs/usr/share/fonts/title.fnt \"\(page0)/title.fnt\" 2>/dev/null"
        )

        // Step 7: Upload custom games to .storage/ and page 001/
        if selectedGames.isEmpty {
            logger.info("No custom games to upload")
        } else {
            let total = Double(selectedGames.count)
            for (index, game) in selectedGames.enumerated() {
                let fraction = 0.20 + (Double(index) / total) * 0.55
                progress("Uploading \(game.name)...", fraction)
                try await uploadGame(game: game, storageDir: storageDir, menuDir: page1)
            }
        }

        // Step 8: Create "Original games" back button (CLV-S-00000) in page 001/
        try await createBackButton(in: page1)

        // Step 9: Bind mount page 000/ onto gamepath and create /var/games symlink
        progress("Mounting games...", 0.82)
        _ = try? await shell.execute("mount --bind \"\(page0)\" \"\(gamePath)\"")
        _ = try? await shell.execute("ln -sf \"\(page0)\" /var/games")

        // Step 10: Restart console UI
        progress("Restarting console...", 0.92)
        _ = try? await shell.execute("uistart")

        progress("Sync complete!", 1.0)
        logger.info("Game sync complete")
    }

    // MARK: - Stock Games

    /// Build stock game entries in page 000/ from squashfs.
    /// Each entry has: .desktop + autoplay/pixelart symlinks to squashfs.
    private func buildStockGameEntries(page0: String, squashfsGamePath: String) async throws {
        // Run a console-side script to create all stock game dirs at once.
        // After copying .desktop from squashfs, rewrite Icon= to point to the
        // squashfs path (e.g. /var/squashfs/usr/share/games/...) since the
        // original gamepath will be covered by our bind mount.
        let gamePath = consoleType.originalGamesPath
        let script = """
        sqfs="\(squashfsGamePath)"
        dst="\(page0)"
        gp="\(gamePath)"
        for d in "$sqfs"/CLV-*; do
          [ -d "$d" ] || continue
          code=$(basename "$d")
          mkdir -p "$dst/$code"
          # Copy .desktop file from squashfs
          cp "$d/$code.desktop" "$dst/$code/" 2>/dev/null
          # Rewrite Icon= path to point to squashfs instead of gamepath
          # (gamepath will be covered by bind mount, squashfs still accessible)
          sed -i "s|Icon=$gp|Icon=$sqfs|" "$dst/$code/$code.desktop" 2>/dev/null
          # Symlink autoplay/pixelart directories
          [ -d "$d/autoplay" ] && ln -sf "$d/autoplay" "$dst/$code/autoplay"
          [ -d "$d/pixelart" ] && ln -sf "$d/pixelart" "$dst/$code/pixelart"
        done
        echo "done"
        """
        let result = try? await shell.execute(script)
        logger.info("Stock game entries: \(result?.output ?? "no output")")
    }

    // MARK: - Folder Navigation

    /// Create "More games..." folder entry (CLV-S-00001) in page 000/
    private func createFolderEntry(in page0: String) async throws {
        let code = "CLV-S-00001"
        let desktop = buildFolderDesktop(
            code: code,
            name: "More games...",
            targetPage: 1,
            sortTitle: "\u{042E}more games...",   // Ю prefix (Priority.Rightmost)
            publisher: "ZZZZZZZZZY",
            releaseDate: "8888-88-88"
        )
        let png = Self.generateFolderPNG()
        let smallPng = Self.generateFolderSmallPNG()

        var tar = TarWriter()
        tar.addDirectory(name: "\(code)/")
        tar.addFile(name: "\(code)/\(code).desktop", contents: desktop)
        tar.addFile(name: "\(code)/\(code).png", contents: png)
        tar.addFile(name: "\(code)/\(code)_small.png", contents: smallPng)
        try await shell.uploadTar(data: tar.finalize(), to: page0)
    }

    /// Create "Original games" back button (CLV-S-00000) in page 001/
    private func createBackButton(in page1: String) async throws {
        let code = "CLV-S-00000"
        let desktop = buildFolderDesktop(
            code: code,
            name: "Original games",
            targetPage: 0,
            sortTitle: "\u{042F}original games", // Я prefix (Priority.Back)
            publisher: "ZZZZZZZZZZ",
            releaseDate: "9999-99-99"
        )
        let png = Self.generateBackPNG()
        let smallPng = Self.generateBackSmallPNG()

        var tar = TarWriter()
        tar.addDirectory(name: "\(code)/")
        tar.addFile(name: "\(code)/\(code).desktop", contents: desktop)
        tar.addFile(name: "\(code)/\(code).png", contents: png)
        tar.addFile(name: "\(code)/\(code)_small.png", contents: smallPng)
        try await shell.uploadTar(data: tar.finalize(), to: page1)
    }

    /// Build a folder/back .desktop matching upstream format exactly
    private func buildFolderDesktop(
        code: String, name: String, targetPage: Int,
        sortTitle: String, publisher: String, releaseDate: String
    ) -> Data {
        let desktop = DesktopFile()
        desktop.code = code
        desktop.name = name
        desktop.exec = "/bin/chmenu \(String(format: "%03d", targetPage)) /var/games"
        desktop.profilePath = "/var/saves/FOLDER"
        desktop.omitProfilePathCode = true
        desktop.iconPath = "/var/games"
        desktop.iconFilename = "\(code).png"
        desktop.testId = 777
        desktop.sortName = sortTitle
        desktop.publisher = publisher
        desktop.releaseDate = releaseDate
        desktop.players = 1
        desktop.simultaneous = false
        return desktop.toData()
    }

    // MARK: - Custom Game Upload

    private func uploadGame(game: Game, storageDir: String, menuDir: String) async throws {
        let gameDir = URL(fileURLWithPath: game.romPath)
        guard FileManager.default.fileExists(atPath: gameDir.path),
              let files = try? FileManager.default.contentsOfDirectory(
                  at: gameDir, includingPropertiesForKeys: nil
              ) else {
            logger.warning("Game directory not found: \(gameDir.path)")
            return
        }

        let code = game.code
        let romFile = files.first { f in
            let name = f.lastPathComponent
            return !name.hasSuffix(".desktop") && !name.hasSuffix(".png") && !name.hasPrefix(".")
        }

        let romExt = romFile?.pathExtension ?? "nes"
        let safeRomFilename = "\(code).\(romExt)"
        let romConsolePath = "\(storageDir)/\(code)/\(safeRomFilename)"

        let desktopData = buildGameDesktop(
            localData: files.first { $0.lastPathComponent.hasSuffix(".desktop") }
                .flatMap { try? Data(contentsOf: $0) } ?? Data(),
            game: game,
            romConsolePath: romConsolePath,
            storagePath: "\(storageDir)/\(code)"
        )

        // --- .storage/{code}/ — ROM + PNG ---
        var storageTar = TarWriter()
        storageTar.addDirectory(name: "\(code)/")

        var hasPng = false
        for file in files {
            guard let data = try? Data(contentsOf: file) else { continue }
            let filename = file.lastPathComponent
            if filename.hasSuffix(".desktop") {
                continue
            } else if filename.hasSuffix(".png") {
                hasPng = true
                storageTar.addFile(name: "\(code)/\(filename)", contents: data)
            } else if romFile != nil && filename == romFile!.lastPathComponent {
                storageTar.addFile(name: "\(code)/\(safeRomFilename)", contents: data)
            } else {
                storageTar.addFile(name: "\(code)/\(filename)", contents: data)
            }
        }

        if !hasPng {
            storageTar.addFile(name: "\(code)/\(code).png", contents: Self.generatePlaceholderPNG())
            storageTar.addFile(name: "\(code)/\(code)_small.png", contents: Self.generatePlaceholderPNG())
        }

        try await shell.uploadTar(data: storageTar.finalize(), to: storageDir)

        // --- 001/{code}/ — .desktop only ---
        var menuTar = TarWriter()
        menuTar.addDirectory(name: "\(code)/")
        menuTar.addFile(name: "\(code)/\(code).desktop", contents: desktopData)
        try await shell.uploadTar(data: menuTar.finalize(), to: menuDir)
    }

    private func buildGameDesktop(
        localData: Data, game: Game, romConsolePath: String, storagePath: String
    ) -> Data {
        let desktop: DesktopFile
        if localData.isEmpty {
            desktop = DesktopFile()
            desktop.code = game.code
            desktop.name = game.name
        } else {
            desktop = DesktopFile(data: localData)
        }

        switch consoleType {
        case .nes, .famicom:
            desktop.exec = "/bin/clover-kachikachi-wr \(romConsolePath) \(Self.nesDefaultArgs)"
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump:
            desktop.exec = "/bin/clover-canoe-shvc-wr -rom \(romConsolePath) --volume 100 -rollback-snapshot-period 600"
        default:
            desktop.exec = romConsolePath
        }

        desktop.profilePath = "/var/saves"
        desktop.omitProfilePathCode = false
        // Icon={iconPath}/{code}/{iconFilename} — iconPath is .storage parent
        let storageParent = (storagePath as NSString).deletingLastPathComponent
        desktop.iconPath = storageParent
        desktop.iconFilename = "\(game.code).png"

        return desktop.toData()
    }

    // MARK: - Icon Assets

    /// 204x204 folder icon (from upstream hakchi2-CE folder_images/folder.png)
    private static let folderPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAMwAAADMBAMAAADNDFHBAAAAFVBMVEUAAAC6zNwAAABqgZiPqcXM3e2muMmI6FEdAAAAAXRSTlMAQObYZgAAAQRJREFUeF7s0rENwCAMRNGISdCxQcwEkTMC+6+SMhKycJEiBf8t8Iu74ycAAAAAAABA0aySSajZ7BSZlSKLaK2SSX0Zj8xL0rYZNYt1T023JuP3SPmlDTOS4kz38bBbBycAwlAQRMUOAhYQFhsx/AYE038rHj0FZXMR/kwD77bsWV7rV6gmY1bFuPKlLSSlYrRHHzcCYIoRjBEMjDGdx5QSTQ4DU5c8DAwMDAwMzHNu/FsD433BLAwMDAwMDMz8uYkmGO8L/pSBgYGBgbnbrWMaAAEgCIIXlJAXgxT8S6CkJV9yMwa23e+Z696pzLxzszPTm8kxa0lrJpmdMwWZXwAAAACABwuNRQpX1urdAAAAAElFTkSuQmCC"

    /// 204x204 back-arrow folder icon (from upstream hakchi2-CE folder_images/folder_back.png)
    private static let folderBackPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAMwAAADMBAMAAADNDFHBAAAAFVBMVEUAAAC6zNxqgZgAAACPqcXM3e2muMlbvZH3AAAAAXRSTlMAQObYZgAAAUJJREFUeF7szTENACAQBDASnIABwvn3xv4DjCytgbZPAAAAAKCnWpqH7FHNaG4Oe3aQgjAMRGEY8AQteoAMdV98XkA6HsBi7n8VFYQQk3EMdpf3r8zqA57IgDtILXxvJuPWPB4Za7xuGZwMYFI3zGSy9BrddEGHDIA6M2m8DW7xrpg7Y3ZQu+GX9gqgKwZnjXYWQGZojwwZMnab/nRe/lJ0AZmPJPhMdguQGaWVISPSyJAZpZUhI6kSI2MPU0pk7ONGallnDZk0TFmwb0Eyh+gzZIriKu53mow3j8+QSfMc46vVZ8ikecL78zMyxXFjzBOyZ3nWkKnME7KnfQuSSX35C4eM3dYMGTJkHu3WMQ0AIAwAwSYYIqkHpOBfAiMzHemdgV//KbN2TcvMnZuazL6ZGFkW0S1zZc2MBpkvAAAAAMABQrKSLHruDJ4AAAAASUVORK5CYII="

    /// 40x40 small folder icon (exact bytes from .NET hakchi2-CE sync)
    private static let folderSmallPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAAM0SURBVFhH7ZZbSFNhAMe/HdeyixD0kIkWpUjWEitNI2ZqBUbSjcQKe+ghs4tW3oOsrJZYloWZiklaGnkBLShctU1NU7B5mVOXpc42y6R6qIje/vEt8uEzTme6CcH5we9hsO3/4zucwyFEREREREQocwghLn9xLvvFaUcikYXIA4KHfYM2jq0MDB3XNyhsTB4YMkI4biv7m+lk6ZrgrV9Tb1QhMbscCVfKxqWfk3MeYOOuAz88vFa0eHgu/6eLvOQt7ku81YQQT3ZoUshks0I2Rx60Bh3JKJjg0fOFiFPexrGLxYi7dAdxSn7jM0sQn1kK/9AdA7LZLunsns3Mm7+gLvZsHg6fy8ehM3kTjEnPRbyyGCVP2lHdaERlfS+vFdpeVDUY8ajVhOtldfCUB9xkN4Wy1MdvfXPQpp0/kq7eR8LlezjJmnXXehoFta1oMY7ihcEs2KYeCzrN35FZVAPCzcglhMxmA/hwU4TvHnqu/4j63jHUvTLxqtIN4emrt1C1vbHJRoMZuRVqcE4zQAhZxkbwIY+KSUWb6Ru0XSZoO4d4VbcPWgNt9YXBglvV9X8CvdkIPhYqwiN7aptfQ93x+3Ts7TPdALR6C05k3ICEc7L5BCnp2aWP0WiwTPhze0hPXdVhwQp/BY0rJ4TMYgN44aTOypyyOocGPu2wYNX6zTTQ9scNJ3XOvlmpcVygbgCa7lH4B2+hgUp2/59Ipc6xp3NKf9Z3W/DsLwNTVdtpQqWmG96+ATTwGrsvBG6NYss7ehkme5fy2dQ3ipMX8mjcZ0LIWnZcCLKAkAizIwOTLhXQwGF2WCgzA8O2jar1HxwS2Gz8iLTLxTTQTLfYcSHIVivCux4290Nj52chfQY2GN4jNi2LBn4hhDiz44KQSCTRyZmF1svBjkxFeoNUN/TBbbE3DSwmhDix20LZk6jMd1igq7snDdzOjtpCdEpWEV6+HsPz9kG72aAfRk1T/58T3MeO2kLk8YxcNBo/QaUbhkpH31ymrkY/ggeaHrh6WE/wADtqCzIfv3VX9x4+Bfp2ExWTYhf3x51BUFgEOI77NNlnIEsWIaTJAW5gh0RERERE/jN+AcIQNYTWe2OnAAAAAElFTkSuQmCC"

    /// 40x40 small back-arrow folder icon (exact bytes from .NET hakchi2-CE sync)
    private static let folderBackSmallPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAACgAAAAoCAYAAACM/rhtAAAAAXNSR0IArs4c6QAAAARnQU1BAACxjwv8YQUAAAAJcEhZcwAADsMAAA7DAcdvqGQAAARcSURBVFhH7ZZ7TFNXHMdPL9ihm8mS/TFnZMvEkDk74iYMFlOGOBOMZq+MqItmcROGU9h8IE6BjkklOJBhKW8mCE4sqEAmg0GfFmHR0lIeghu2haJInH9si9l/3+UcA5mnXR9uM1nST/JNc2/P7e/T37nn3EtIgAABAgTwlccJIQvd5Al+4CNHJBLHSaJiHRExa2deil4zl4iY+BlJdNwUEYQN/DWPkqWrYjf8mlHchH0Fp7H3q4a50OP0okasfXf7vdBlK3pDw170mmeXSXqXPB+uJoSE8YUeCrF4fty6xCQm9ElOuUt2fVmBVHk1dufWIPXoSaTKPSctrxZpeXWIXPP2uHjBwiy+nt88+dTTHSkyJXZ+UYaPs5UuSc5SIE1eg9r2fjQbRqHSjXjMWe0ImvSjaOuz4+uGDoRJokr4mr6ydPnK1T0xb7xzb3/ht9h7rB57+OSfYt0ob+lD7+g0Lg1N+hzjsBOWyd+RV3UBRJinIIQs4AU8sVia8J6t23obupEZdFy1e0ynyYYfrv6Mzis/+RXD0CQUZ9UQguaBEPICL+EJyabkDFyx/wbtgB1ai81j1P03mKC/uTTkRGmzblYwnJfwxDPShMThlp4xqM33u+MtdFy3H6JdpnForU58llMMkRDkdwcpWQV1F2EYcrr8OB+91YGG73/Eye8uQ2Oxu3zvLrTrnWYnVkRKqdxpQsh8XsAjQnCIvKihw6ugzuqASm1mK7r8nA69Y7fYbcGP48NuC7MTL69eRwX9326E4JCCEpXGo6DeOsHkUnMr8eGhYuRVt6C6xYD69j5oLXaPU642jUMzOI3I2PVUUM7X90pwcEhKZlHdH7pBJ7rcFNCYbVB19yMttwrJWSVsw07OVjLRFFkZZEoV2ozDbBx/LQ39AyrNIMIjoqjgcb6+LwirpOsn6DTwq5R2ptU4jN1HKrHjsAK7uKcL3dSpaEZhPdtO3HXSeG0ae44oqdwvhJBX+eK+II6K2zjpTpB10GJH5XkDdmQqkCIrvd/BLCU+OnQCSZklTDQpU4GKczq3C4cK7j9aTgUdfGFfeSw6/s1ptfWWW0FWZGQKNa1GJkmn+XDxGRTUXoSsRMVEP8g4jmxFI5tO/tqe0ds4eKyGCk7SWnxxXxC/Ik0YaO25/rf30ZxkixHb0gvxTZsR/ba7rGPndVYUnGpH5okzbDP/6zV0D9QP3UTKwXwqeJcQEsIX9wmRSLQ1Pa+CTQcv9qDkTZQ2aVHapIHGYmMC9DGmHXCgSWNBl+nB8bSjzfprWPxcOBWsIYQE8bV9ZfM+eZlXQRqddcLlHF39ugGHy/lZwUVLwqjgW3xRf9h6IL8Kl8dm2Er0FrWZfo5z5/njG+zJc8F4fbaD7/NF/SHx0xwFDKN30GlyoNNE31z+eTTWKTRqhrEolHVwO1/UH8TLV75WuGXn56BvN5uSD/wr2ZaajZj4jRAE4c7D7oE8+YQQ43+Q1/lCAQIECBDgf8afSt0RpW4ujs4AAAAASUVORK5CYII="

    /// Folder icon PNG data
    private static func generateFolderPNG() -> Data {
        Data(base64Encoded: folderPNGBase64) ?? Data()
    }

    /// Back-arrow folder icon PNG data
    private static func generateBackPNG() -> Data {
        Data(base64Encoded: folderBackPNGBase64) ?? Data()
    }

    /// 40x40 small folder icon
    private static func generateFolderSmallPNG() -> Data {
        Data(base64Encoded: folderSmallPNGBase64) ?? Data()
    }

    /// 40x40 small back-arrow folder icon
    private static func generateBackSmallPNG() -> Data {
        Data(base64Encoded: folderBackSmallPNGBase64) ?? Data()
    }

    /// 40x40 gray placeholder for custom games without icons
    private static func generatePlaceholderPNG() -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 40, height: 40,
            bitsPerComponent: 8, bytesPerRow: 40 * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return Data() }

        context.setFillColor(red: 0.3, green: 0.3, blue: 0.3, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        guard let image = context.makeImage() else { return Data() }

        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, "public.png" as CFString, 1, nil
        ) else { return Data() }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return Data() }
        return data as Data
    }
}
