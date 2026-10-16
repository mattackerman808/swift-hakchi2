import Foundation
import SWCompression

/// Converts SNES ROMs (.sfc/.smc, optionally zipped) to the .sfrom container
/// that the stock emulator (canoe) requires.
///
/// Ported from Hakchi2-CE (hakchi_gui/Apps/SnesGame.cs, GPL-3.0): header
/// layouts, LoROM/HiROM detection and the known preset IDs.
enum SfromConverter {
    struct Result {
        let data: Data
        /// True if the cartridge has battery-backed SRAM
        let hasSaveRam: Bool
        let title: String
    }

    private enum RomType: UInt8 {
        case loRom = 0x14
        case hiRom = 0x15
    }

    private struct RomHeader {
        let title: String
        let romMakeup: UInt8
        let romType: UInt8
        let sramSize: UInt8
        let checksumComplement: UInt16
        let checksum: UInt16
    }

    private static let romExtensions: Set<String> = ["sfc", "smc", "fig", "swc"]
    private static let sfxTypes: Set<UInt8> = [0x13, 0x14, 0x15, 0x1a]
    private static let dsp1Types: Set<UInt8> = [0x03, 0x05]
    private static let sa1Types: Set<UInt8> = [0x34, 0x35]

    /// Preset IDs for games canoe has tuned settings for, keyed by internal ROM title
    private static let knownPresets: [String: UInt16] = [
        "SUPER MARIOWORLD": 0x1011,
        "F-ZERO": 0x1018,
        "SUPER MARIO KART": 0x10BD,
        "Super Metroid": 0x1040,
        "EARTH BOUND": 0x1070,
        "Kirby's Dream Course": 0x1058,
        "DONKEY KONG COUNTRY": 0x1077,
        "KIRBY SUPER DELUXE": 0x109F,
        "Super Punch-Out!!": 0x10A9,
        "MEGAMAN X": 0x1109,
        "SUPER GHOULS'N GHOST": 0x1003,
        "Street Fighter2 Turb": 0x1065,
        "SUPER MARIO RPG": 0x109E,
        "FINAL FANTASY 3": 0x10DC,
        "SUPER CASTLEVANIA 4": 0x1030,
        "CONTRA3 THE ALIEN WA": 0x1036,
        "STAR FOX": 0x1242,
        "STARFOX2": 0x123C,
        "SHVC FIREEMBLEM": 0x102B,
        "SUPER DONKEY KONG": 0x1023,
        "ROCKMAN X": 0x110A,
        "CHOHMAKAIMURA": 0x1004,
        "SeikenDensetsu 2": 0x10B2,
        "FINAL FANTASY 6": 0x10DD,
        "CONTRA SPIRITS": 0x1037,
        "ganbare goemon": 0x1048,
        "SUPER FORMATION SOCC": 0x1240,
        "YOSSY'S ISLAND": 0x1243,
        "FINAL FIGHT": 0x100E,
        "DIDDY'S KONG QUEST": 0x105D,
        "BREATH OF FIRE 2": 0x1068,
        "FINAL FIGHT 2": 0x10E1,
        "MEGAMAN X2": 0x1117,
        "FINAL FIGHT 3": 0x10E3,
        "GENGHIS KHAN 2": 0x10C4,
        "CASTLEVANIA DRACULA": 0x1131,
        "STREET FIGHTER ALPHA": 0x10DF,
        "MEGAMAN 7": 0x113A,
        "MEGAMAN X3": 0x113D,
        "Breath of Fire": 0x1144,
    ]

    /// Whether a ROM file with this extension can be converted
    static func canConvert(fileExtension: String) -> Bool {
        let ext = fileExtension.lowercased()
        return ext == "zip" || romExtensions.contains(ext)
    }

    /// Convert a ROM file's contents to .sfrom. Returns nil if the data isn't
    /// a recognizable SNES ROM (the caller should upload the file unchanged).
    static func convert(fileData: Data, fileExtension: String) -> Result? {
        var rom: [UInt8]
        if fileExtension.lowercased() == "zip" {
            guard let entries = try? ZipContainer.open(container: fileData),
                  let entry = entries.first(where: {
                      romExtensions.contains(($0.info.name as NSString).pathExtension.lowercased())
                  }),
                  let data = entry.data else { return nil }
            rom = [UInt8](data)
        } else {
            rom = [UInt8](fileData)
        }

        // Remove 512-byte copier header
        if rom.count % 1024 != 0 {
            guard rom.count > 512 else { return nil }
            rom.removeFirst(512)
        }
        guard rom.count >= 0x10000 else { return nil }

        guard let (header, romType) = detectHeader(rom) else { return nil }

        var chip: UInt8 = 0
        if sfxTypes.contains(header.romType) { chip = 0x0C } // Super FX

        var presetId: UInt16 = 0
        if let known = knownPresets[header.title] {
            presetId = known
        } else {
            if dsp1Types.contains(header.romType) { presetId = 0x10BD } // Mario Kart preset, DSP-1
            if sa1Types.contains(header.romType) { presetId = 0x109C }  // Super Mario RPG preset, SA-1
        }

        let headerSize: UInt32 = 48
        let romSize = UInt32(rom.count)
        let romEnd = headerSize + romSize
        let fileSize = romEnd + headerSize

        var out = [UInt8]()
        out.reserveCapacity(Int(fileSize))

        // Header 1 (48 bytes)
        appendLE(&out, UInt32(0x00000100))
        appendLE(&out, fileSize)
        appendLE(&out, UInt32(0x00000030))
        appendLE(&out, romEnd)             // ROM end
        appendLE(&out, fileSize)           // footer start
        appendLE(&out, romEnd)             // header 2 offset
        appendLE(&out, fileSize)           // header 3 offset
        appendLE(&out, UInt32(0))
        appendLE(&out, romEnd + 27)        // flags offset
        out.append(contentsOf: Array("WUP-XXXX".utf8))
        appendLE(&out, UInt32(0))

        out.append(contentsOf: rom)

        // Header 2 (48 bytes, packed)
        out.append(60)                     // FPS
        appendLE(&out, romSize)
        appendLE(&out, UInt32(0))          // PCM size
        appendLE(&out, UInt32(0))          // footer size
        appendLE(&out, presetId)
        out.append(2)                      // max controllers
        out.append(0x5A)                   // volume
        out.append(romType.rawValue)
        appendLE(&out, UInt32(chip))
        out.append(contentsOf: [UInt8](repeating: 0, count: 5))
        appendLE(&out, UInt32(1))
        appendLE(&out, UInt32(1))
        out.append(contentsOf: [UInt8](repeating: 0, count: 13))

        guard out.count == Int(fileSize) else { return nil }
        return Result(data: Data(out), hasSaveRam: header.sramSize > 0, title: header.title)
    }

    // MARK: - ROM header detection

    private static func readHeader(_ rom: [UInt8], at pos: Int) -> RomHeader? {
        guard rom.count >= pos + 32 else { return nil }
        let titleBytes = Array(rom[pos..<pos + 21])
        var title = ""
        if !titleBytes.contains(0), !titleBytes.contains(0xFF), titleBytes[0] != 0x20 {
            var trimmed = titleBytes
            while let last = trimmed.last, last == 0x20 { trimmed.removeLast() }
            title = String(decoding: trimmed.map { $0 < 0x80 ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
        }
        return RomHeader(
            title: title,
            romMakeup: rom[pos + 21],
            romType: rom[pos + 22],
            sramSize: rom[pos + 24],
            checksumComplement: UInt16(rom[pos + 28]) | UInt16(rom[pos + 29]) << 8,
            checksum: UInt16(rom[pos + 30]) | UInt16(rom[pos + 31]) << 8
        )
    }

    private static func detectHeader(_ rom: [UInt8]) -> (RomHeader, RomType)? {
        guard let lo = readHeader(rom, at: 0x7FC0), let hi = readHeader(rom, at: 0xFFC0) else { return nil }

        let loSumOK = (lo.checksum ^ 0xFFFF) == lo.checksumComplement
        let hiSumOK = (hi.checksum ^ 0xFFFF) == hi.checksumComplement
        let loZero = lo.checksum == 0 || lo.checksumComplement == 0
        let hiZero = hi.checksum == 0 || hi.checksumComplement == 0

        let type: RomType
        if loSumOK && (!hiSumOK || hiZero) {
            type = .loRom
        } else if (!loSumOK || loZero) && hiSumOK {
            type = .hiRom
        } else if lo.title == hi.title && (lo.romMakeup & 1) == 0 {
            type = .loRom
        } else if lo.title == hi.title && (hi.romMakeup & 1) == 1 {
            type = .hiRom
        } else {
            let loPrintable = lo.title.utf8.allSatisfy { $0 >= 31 && $0 <= 127 }
            let hiPrintable = hi.title.utf8.allSatisfy { $0 >= 31 && $0 <= 127 }
            if loPrintable && !hiPrintable {
                type = .loRom
            } else if !loPrintable && hiPrintable {
                type = .hiRom
            } else if !lo.title.isEmpty && hi.title.isEmpty {
                type = .loRom
            } else if lo.title.isEmpty && !hi.title.isEmpty {
                type = .hiRom
            } else {
                return nil
            }
        }
        return (type == .loRom ? lo : hi, type)
    }

    private static func appendLE<T: FixedWidthInteger>(_ out: inout [UInt8], _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { out.append(contentsOf: $0) }
    }
}
