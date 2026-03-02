import Foundation

/// Console types supported by hakchi
enum ConsoleType: String, Codable, CaseIterable, Identifiable {
    case nes = "nes"
    case famicom = "hvc"
    case snesUsa = "snes-usa"
    case snesEur = "snes-eur"
    case superFamicom = "shvc"
    case superFamicomShonenJump = "snes-shonen"
    case megaDrive = "md"
    case unknown = "unknown"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nes: return "NES Classic"
        case .famicom: return "Famicom Mini"
        case .snesUsa: return "SNES Classic (USA)"
        case .snesEur: return "SNES Classic (EUR)"
        case .superFamicom: return "Super Famicom Mini"
        case .superFamicomShonenJump: return "Super Famicom (Shonen Jump)"
        case .megaDrive: return "Mega Drive Mini"
        case .unknown: return "Unknown Console"
        }
    }

    var isSNES: Bool {
        switch self {
        case .snesUsa, .snesEur, .superFamicom, .superFamicomShonenJump:
            return true
        default:
            return false
        }
    }

    var isNES: Bool {
        self == .nes || self == .famicom
    }

    /// Default cover art dimensions
    var coverWidth: Int {
        isNES ? 204 : 228
    }

    var coverHeight: Int {
        204
    }

    /// Path to original games on the console
    var originalGamesPath: String {
        switch self {
        case .nes, .famicom:
            return "/usr/share/games/nes/kachikachi"
        default:
            return "/usr/share/games"
        }
    }

    /// Map system_code strings to ConsoleType
    static func fromSystemCode(_ code: String) -> ConsoleType {
        let mapping: [String: ConsoleType] = [
            "clv-nes": .nes,
            "clv-hvc": .famicom,
            "clv-snes-usa": .snesUsa,
            "clv-snes-eur": .snesEur,
            "clv-shvc": .superFamicom,
            "clv-snes-shonen": .superFamicomShonenJump,
            "clv-md": .megaDrive,
            // sftype-sfregion format (or bare sftype when region is empty)
            "nes": .nes,
            "nes-usa": .nes,
            "nes-eur": .nes,
            "nes-jpn": .famicom,
            "hvc-jpn": .famicom,
            "snes-usa": .snesUsa,
            "snes-eur": .snesEur,
            "shvc-jpn": .superFamicom,
            "md-usa": .megaDrive,
            "md-eur": .megaDrive,
            "md-jpn": .megaDrive,
        ]
        return mapping[code.lowercased()] ?? .unknown
    }

    /// System code string for this console type
    var systemCode: String {
        switch self {
        case .nes: return "clv-nes"
        case .famicom: return "clv-hvc"
        case .snesUsa: return "clv-snes-usa"
        case .snesEur: return "clv-snes-eur"
        case .superFamicom: return "clv-shvc"
        case .superFamicomShonenJump: return "clv-snes-shonen"
        case .megaDrive: return "clv-md"
        case .unknown: return "unknown"
        }
    }

    /// Sync subdirectory name (used in /var/lib/hakchi/games/{syncCode}/)
    var syncCode: String {
        switch self {
        case .nes: return "nes-usa"
        case .famicom: return "nes-jpn"
        case .snesUsa: return "snes-usa"
        case .snesEur: return "snes-eur"
        case .superFamicom: return "snes-jpn"
        case .superFamicomShonenJump: return "hvcj-jpn"
        case .megaDrive: return "md-usa"
        case .unknown: return "unknown"
        }
    }
}
