import Foundation

/// SNES Game Genie code encoder/decoder
enum GameGenieSNES {
    private static let alphabet = "DF346789BCRTXYZ0"

    /// Decode a SNES Game Genie code (format: XXXX-XXXX)
    static func decode(_ code: String) -> (address: UInt32, value: UInt8)? {
        let clean = code.uppercased().replacingOccurrences(of: "-", with: "")
        guard clean.count == 8 else { return nil }

        var n = [UInt8]()
        for char in clean {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            n.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: idx)))
        }

        let value = (n[0] << 4) | n[1]
        let p0: UInt32 = UInt32(n[2]) << 20
        let p1: UInt32 = UInt32(n[3]) << 16
        let p2: UInt32 = UInt32(n[4]) << 12
        let p3: UInt32 = UInt32(n[5]) << 8
        let p4: UInt32 = UInt32(n[6]) << 4
        let p5: UInt32 = UInt32(n[7])
        var address: UInt32 = p0 | p1 | p2 | p3 | p4 | p5

        // Unscramble address
        let bit0: UInt32 = (address >> 1) & 1
        let bit1: UInt32 = (address >> 0) & 1
        let bit2: UInt32 = (address >> 3) & 1
        let bit3: UInt32 = (address >> 2) & 1
        let unscrambled: UInt32 = (bit3 << 3) | (bit2 << 2) | (bit1 << 1) | bit0
        address = (address & 0xFFFFF0) | unscrambled

        return (address, value)
    }

    /// Encode address + value to a SNES Game Genie code
    static func encode(address: UInt32, value: UInt8) -> String {
        let chars = Array(alphabet)

        // Scramble address
        let bit0 = (address >> 0) & 1
        let bit1 = (address >> 1) & 1
        let bit2 = (address >> 2) & 1
        let bit3 = (address >> 3) & 1
        let scrambleBits: UInt32 = (bit2 << 3) | (bit3 << 2) | (bit0 << 1) | bit1
        let scrambled: UInt32 = (address & 0xFFFFF0) | scrambleBits

        var n = [UInt8](repeating: 0, count: 8)
        n[0] = value >> 4
        n[1] = value & 0x0F
        n[2] = UInt8((scrambled >> 20) & 0xF)
        n[3] = UInt8((scrambled >> 16) & 0xF)
        n[4] = UInt8((scrambled >> 12) & 0xF)
        n[5] = UInt8((scrambled >> 8) & 0xF)
        n[6] = UInt8((scrambled >> 4) & 0xF)
        n[7] = UInt8(scrambled & 0xF)

        let encoded = String(n.map { chars[Int($0)] })
        return "\(encoded.prefix(4))-\(encoded.suffix(4))"
    }
}
