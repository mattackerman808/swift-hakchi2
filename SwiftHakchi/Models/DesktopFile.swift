import Foundation

/// Parser/serializer for .desktop files used by the NES/SNES Classic
final class DesktopFile {
    var exec: String = ""
    var bin: String = ""
    var args: [String] = []
    var profilePath: String = ""
    var name: String = ""
    var cePrefix: String = ""
    var iconPath: String = ""
    var iconFilename: String?
    var code: String = ""
    var testId: Int = 0
    var status: String = ""
    var players: Int = 1
    var simultaneous: Bool = false
    var releaseDate: String = "1900-01-01"
    var saveCount: Int = 0
    var sortName: String = ""
    var publisher: String = "UNKNOWN"
    var copyright: String = ""
    var genre: String = ""
    var index: String = ""
    var demoTime: String = ""
    var country: String = ""
    var regionTag: String = ""
    var description: String = ""

    var hasUnsavedChanges: Bool = false

    /// Whether to include SNES-specific fields (Status, MyPlayDemoTime)
    var snesExtraFields: Bool = false

    /// Whether to omit /{code} from Path= line
    var omitProfilePathCode: Bool = false

    init() {}

    /// Load from a .desktop file's contents
    init(data: Data) {
        guard let content = String(data: data, encoding: .utf8) else { return }
        load(from: content)
    }

    init(string: String) {
        load(from: string)
    }

    // MARK: - Parsing

    func load(from content: String) {
        let lines = content.components(separatedBy: .newlines)
        var inDescription = false
        var descriptionLines: [String] = []

        for line in lines {
            if inDescription {
                // Skip the "Text = " marker line
                if descriptionLines.isEmpty && line.trimmingCharacters(in: .whitespaces) == "Text =" {
                    continue
                }
                descriptionLines.append(line)
                continue
            }

            if line.trimmingCharacters(in: .whitespaces) == "[Description]" {
                inDescription = true
                continue
            }

            // Skip section headers
            if line.hasPrefix("[") { continue }

            guard let eqIndex = line.firstIndex(of: "=") else { continue }
            let key = String(line[line.startIndex..<eqIndex]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: eqIndex)...]).trimmingCharacters(in: .whitespaces)

            switch key {
            case "exec":
                exec = value
                parseExec(value)
            case "path":
                let normalized = value.replacingOccurrences(of: "\\", with: "/")
                    .replacingOccurrences(of: "//", with: "/")
                profilePath = (normalized as NSString).deletingLastPathComponent
            case "name":
                name = value
            case "ceprefix":
                cePrefix = value
            case "icon":
                let normalized = value.replacingOccurrences(of: "\\", with: "/")
                // iconPath = grandparent directory
                let parent = (normalized as NSString).deletingLastPathComponent
                iconPath = (parent as NSString).deletingLastPathComponent
                iconFilename = (normalized as NSString).lastPathComponent
            case "code":
                code = value
            case "testid":
                testId = Int(value) ?? 0
            case "status":
                status = value
            case "players":
                players = Int(value) ?? 1
            case "simultaneous":
                simultaneous = (Int(value) ?? 0) != 0
            case "releasedate":
                releaseDate = value
            case "savecount":
                saveCount = Int(value) ?? 0
            case "sortrawtitle":
                sortName = value
            case "sortrawpublisher":
                publisher = value
            case "copyright":
                copyright = value
            case "sortrawgenre":
                genre = value
            case "index":
                index = value
            case "demo_time":
                demoTime = value
            case "country":
                country = value
            case "regiontag":
                regionTag = value
            default:
                break
            }
        }

        // Join description lines
        description = descriptionLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        hasUnsavedChanges = false
    }

    private func parseExec(_ value: String) {
        // Match binary path including any " -rom" suffixes
        guard let match = value.range(of: #"^[^\s]+(?:\s+-rom)*"#, options: .regularExpression) else {
            bin = value
            args = []
            return
        }
        bin = String(value[match])
        let remainder = String(value[match.upperBound...]).trimmingCharacters(in: .whitespaces)
        args = remainder.isEmpty ? [] : remainder.components(separatedBy: " ").filter { !$0.isEmpty }
    }

    // MARK: - Serialization

    func serialize() -> String {
        var lines: [String] = []

        lines.append("[Desktop Entry]")
        lines.append("Type=Application")
        lines.append("Exec=\(exec)")

        if omitProfilePathCode {
            lines.append("Path=\(profilePath)")
        } else {
            lines.append("Path=\(profilePath)/\(code)")
        }

        lines.append("Name=\(name.isEmpty ? code : name)")
        lines.append("CePrefix=\(cePrefix)")
        lines.append("Icon=\(iconPath)/\(code)/\(iconFilename ?? "\(code).png")")

        lines.append("")
        lines.append("[X-CLOVER Game]")
        lines.append("Code=\(code)")
        lines.append("TestID=\(testId)")

        if snesExtraFields {
            lines.append("Status=\(status)")
        }

        lines.append("ID=0")
        lines.append("Players=\(players)")
        lines.append("Simultaneous=\(simultaneous ? 1 : 0)")
        lines.append("ReleaseDate=\(releaseDate)")
        lines.append("SaveCount=\(saveCount)")
        lines.append("SortRawTitle=\(sortName)")
        lines.append("SortRawPublisher=\(publisher.uppercased())")
        lines.append("Copyright=\(copyright)")

        if snesExtraFields {
            lines.append("MyPlayDemoTime=45")
        }

        lines.append("")
        lines.append("[m2engage]")
        lines.append("regionTag=\(regionTag)")
        lines.append("sortRawGenre=\(genre)")
        lines.append("index=\(index)")
        lines.append("demo_time=\(demoTime)")
        lines.append("country=\(country)")

        lines.append("")
        lines.append("[Description]")
        lines.append("Text = ")
        // Normalize line endings
        let descText = description.replacingOccurrences(of: "\r\n", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(descText)

        return lines.joined(separator: "\n") + "\n"
    }

    func toData() -> Data {
        serialize().data(using: .utf8) ?? Data()
    }
}
