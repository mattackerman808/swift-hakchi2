import Foundation

/// Simple POSIX tar archive builder for streaming files to the console
struct TarWriter {
    private var data = Data()

    /// Add a file entry to the tar archive
    mutating func addFile(name: String, contents: Data, mode: UInt32 = 0o100644) {
        var header = Data(count: 512)

        // Name (0-99)
        writeString(&header, offset: 0, value: name, maxLen: 100)

        // Mode (100-107)
        writeOctal(&header, offset: 100, value: mode, width: 8)

        // UID (108-115) - root
        writeOctal(&header, offset: 108, value: 0, width: 8)

        // GID (116-123) - root
        writeOctal(&header, offset: 116, value: 0, width: 8)

        // Size (124-135)
        writeOctal(&header, offset: 124, value: UInt32(contents.count), width: 12)

        // Mtime (136-147)
        writeOctal(&header, offset: 136, value: UInt32(Date().timeIntervalSince1970), width: 12)

        // Typeflag (156)
        header[156] = 0x30  // '0' = regular file

        // USTAR magic (257-262)
        writeString(&header, offset: 257, value: "ustar", maxLen: 6)

        // USTAR version (263-264)
        header[263] = 0x30  // '0'
        header[264] = 0x30  // '0'

        // Checksum (148-155) - calculated over header with checksum field as spaces
        for i in 148..<156 { header[i] = 0x20 }  // spaces
        var checksum: UInt32 = 0
        for byte in header { checksum += UInt32(byte) }
        writeOctal(&header, offset: 148, value: checksum, width: 7)
        header[155] = 0x20  // trailing space

        data.append(header)
        data.append(contents)

        // Pad to 512-byte boundary
        let remainder = contents.count % 512
        if remainder > 0 {
            data.append(Data(count: 512 - remainder))
        }
    }

    /// Add a directory entry
    mutating func addDirectory(name: String, mode: UInt32 = 0o040755) {
        let dirName = name.hasSuffix("/") ? name : name + "/"
        var header = Data(count: 512)

        writeString(&header, offset: 0, value: dirName, maxLen: 100)
        writeOctal(&header, offset: 100, value: mode, width: 8)
        writeOctal(&header, offset: 108, value: 0, width: 8)
        writeOctal(&header, offset: 116, value: 0, width: 8)
        writeOctal(&header, offset: 124, value: 0, width: 12)
        writeOctal(&header, offset: 136, value: UInt32(Date().timeIntervalSince1970), width: 12)
        header[156] = 0x35  // '5' = directory

        writeString(&header, offset: 257, value: "ustar", maxLen: 6)
        header[263] = 0x30
        header[264] = 0x30

        for i in 148..<156 { header[i] = 0x20 }
        var checksum: UInt32 = 0
        for byte in header { checksum += UInt32(byte) }
        writeOctal(&header, offset: 148, value: checksum, width: 7)
        header[155] = 0x20

        data.append(header)
    }

    /// Finalize the archive (adds end-of-archive marker)
    mutating func finalize() -> Data {
        // Two 512-byte zero blocks
        data.append(Data(count: 1024))
        return data
    }

    // MARK: - Helpers

    private func writeString(_ data: inout Data, offset: Int, value: String, maxLen: Int) {
        let bytes = Array(value.utf8.prefix(maxLen))
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
    }

    private func writeOctal(_ data: inout Data, offset: Int, value: UInt32, width: Int) {
        let str = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, width - 1 - str.count)) + str
        let bytes = Array(padded.utf8.prefix(width - 1))
        for (i, byte) in bytes.enumerated() {
            data[offset + i] = byte
        }
        data[offset + width - 1] = 0  // null terminator
    }
}
