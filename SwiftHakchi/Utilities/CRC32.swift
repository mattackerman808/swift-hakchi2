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
}
