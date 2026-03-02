import Foundation
import zlib

/// CRC32 checksum using zlib
enum CRC32 {
    static func checksum(_ data: Data) -> UInt32 {
        data.withUnsafeBytes { ptr in
            guard let baseAddr = ptr.baseAddress else { return 0 }
            return UInt32(zlib.crc32(0, baseAddr.assumingMemoryBound(to: UInt8.self),
                                     uInt(data.count)))
        }
    }

    static func checksum(file url: URL) -> UInt32? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return checksum(data)
    }

    static func checksumHex(_ data: Data) -> String {
        String(format: "%08X", checksum(data))
    }

    /// Compute CRC32 for a ROM file, stripping platform-specific headers first.
    /// This matches No-Intro database values and Hakchi2-CE behavior:
    /// - NES: strips 16-byte iNES header, CRC of PRG+CHR only
    /// - SNES: strips 512-byte copier header if present (size % 1024 != 0)
    /// - Others: CRC of full file
    static func romChecksum(file url: URL) -> UInt32? {
        guard var data = try? Data(contentsOf: url) else { return nil }
        let ext = url.pathExtension.lowercased()

        switch ext {
        case "nes":
            // iNES header is 16 bytes, starts with "NES\x1A"
            if data.count > 16,
               data[0] == 0x4E, data[1] == 0x45, data[2] == 0x53, data[3] == 0x1A {
                data = data.dropFirst(16)
            }

        case "fds":
            // FDS header is 16 bytes, starts with "FDS"
            if data.count > 16,
               data[0] == 0x46, data[1] == 0x44, data[2] == 0x53 {
                data = data.dropFirst(16)
            }

        case "sfc", "smc":
            // SNES copier header is 512 bytes, present when file size % 1024 != 0
            if data.count % 1024 != 0, data.count > 512 {
                data = data.dropFirst(512)
            }

        default:
            break
        }

        return checksum(Data(data))
    }
}
