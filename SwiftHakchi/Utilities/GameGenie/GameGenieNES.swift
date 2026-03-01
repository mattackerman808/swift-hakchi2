import Foundation

/// NES Game Genie code encoder/decoder
enum GameGenieNES {
    private static let alphabet = "APZLGITYEOXUKSVN"

    /// Decode a Game Genie code to address + value + compare
    static func decode(_ code: String) -> (address: UInt16, value: UInt8, compare: UInt8?)? {
        let code = code.uppercased()
        guard code.count == 6 || code.count == 8 else { return nil }

        var n = [UInt8]()
        for char in code {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            n.append(UInt8(alphabet.distance(from: alphabet.startIndex, to: idx)))
        }

        if code.count == 6 {
            let v0: UInt8 = (n[0] & 8) << 4
            let v1: UInt8 = (n[1] & 7) << 4
            let v2: UInt8 = n[0] & 7
            let v3: UInt8 = n[5] & 8
            let value: UInt8 = v0 | v1 | v2 | v3

            let a0: UInt16 = (UInt16(n[4]) & 8) << 12
            let a1: UInt16 = (UInt16(n[3]) & 7) << 12
            let a2: UInt16 = (UInt16(n[2]) & 8) << 8
            let a3: UInt16 = (UInt16(n[5]) & 7) << 8
            let a4: UInt16 = (UInt16(n[4]) & 7) << 4
            let a5: UInt16 = UInt16(n[3]) & 8
            let a6: UInt16 = UInt16(n[2]) & 7
            let address: UInt16 = (a0 | a1 | a2 | a3 | a4 | a5 | a6) | 0x8000
            return (address, value, nil)
        } else {
            let v0: UInt8 = (n[0] & 8) << 4
            let v1: UInt8 = (n[1] & 7) << 4
            let v2: UInt8 = n[0] & 7
            let v3: UInt8 = n[7] & 8
            let value: UInt8 = v0 | v1 | v2 | v3

            let a0: UInt16 = (UInt16(n[4]) & 8) << 12
            let a1: UInt16 = (UInt16(n[3]) & 7) << 12
            let a2: UInt16 = (UInt16(n[2]) & 8) << 8
            let a3: UInt16 = (UInt16(n[5]) & 7) << 8
            let a4: UInt16 = (UInt16(n[4]) & 7) << 4
            let a5: UInt16 = UInt16(n[3]) & 8
            let a6: UInt16 = UInt16(n[2]) & 7
            let address: UInt16 = (a0 | a1 | a2 | a3 | a4 | a5 | a6) | 0x8000

            let c0: UInt8 = (n[6] & 8) << 4
            let c1: UInt8 = (n[7] & 7) << 4
            let c2: UInt8 = n[6] & 7
            let c3: UInt8 = n[5] & 8
            let compare: UInt8 = c0 | c1 | c2 | c3
            return (address, value, compare)
        }
    }

    /// Encode address + value (+ optional compare) to a Game Genie code
    static func encode(address: UInt16, value: UInt8, compare: UInt8? = nil) -> String {
        let chars = Array(alphabet)
        let addr = address & 0x7FFF

        if let compare = compare {
            var n = [UInt8](repeating: 0, count: 8)
            n[0] = ((value >> 4) & 8) | (value & 7)
            n[1] = (value >> 4) & 7
            n[2] = UInt8((addr >> 8) & 8) | UInt8(addr & 7)
            n[3] = UInt8(addr & 8) | UInt8((addr >> 12) & 7)
            n[4] = UInt8((addr >> 12) & 8) | UInt8((addr >> 4) & 7)
            n[5] = ((compare >> 4) & 8) | UInt8((addr >> 8) & 7)
            n[6] = (compare & 8) | (compare & 7)
            n[7] = (value & 8) | ((compare >> 4) & 7)
            return String(n.map { chars[Int($0)] })
        } else {
            var n = [UInt8](repeating: 0, count: 6)
            n[0] = ((value >> 4) & 8) | (value & 7)
            n[1] = (value >> 4) & 7
            n[2] = UInt8((addr >> 8) & 8) | UInt8(addr & 7)
            n[3] = UInt8(addr & 8) | UInt8((addr >> 12) & 7)
            n[4] = UInt8((addr >> 12) & 8) | UInt8((addr >> 4) & 7)
            n[5] = (value & 8) | UInt8((addr >> 8) & 7)
            return String(n.map { chars[Int($0)] })
        }
    }
}
