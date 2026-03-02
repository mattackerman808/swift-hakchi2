import Foundation
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "ModRepository")

/// Fetches and manages remote hmod repositories (e.g., KMFD Mod Hub)
actor ModRepositoryService {
    /// A remote module available for download
    struct RemoteModule: Identifiable, Hashable {
        let id: String  // filename
        let name: String
        let downloadURL: URL
        let category: String
        let fileSize: String?

        static func == (lhs: RemoteModule, rhs: RemoteModule) -> Bool { lhs.id == rhs.id }
        func hash(into hasher: inout Hasher) { hasher.combine(id) }
    }

    /// Fetch available modules from a repository URL.
    /// Parses HTML directory listings for .hmod files.
    func fetchModules(from repositoryURL: String) async throws -> [RemoteModule] {
        guard let url = URL(string: repositoryURL) else {
            throw ModRepositoryError.invalidURL
        }

        logger.info("Fetching module list from \(repositoryURL)")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModRepositoryError.fetchFailed
        }

        guard let html = String(data: data, encoding: .utf8) else {
            throw ModRepositoryError.parseFailed
        }

        return parseDirectoryListing(html: html, baseURL: url)
    }

    /// Download a module from its URL
    func downloadModule(from url: URL) async throws -> Data {
        logger.info("Downloading module: \(url.lastPathComponent)")
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ModRepositoryError.downloadFailed
        }

        return data
    }

    // MARK: - HTML Parsing

    /// Parse an Apache/nginx-style directory listing for .hmod links
    private func parseDirectoryListing(html: String, baseURL: URL) -> [RemoteModule] {
        var modules: [RemoteModule] = []

        // Match href="something.hmod" or href="something.hmod/"
        let pattern = #"href="([^"]*\.hmod/?)"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else {
            return []
        }

        let nsHtml = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHtml.length))

        for match in matches {
            guard match.numberOfRanges >= 2 else { continue }
            let hrefRange = match.range(at: 1)
            var href = nsHtml.substring(with: hrefRange)

            // Clean trailing slash
            if href.hasSuffix("/") { href = String(href.dropLast()) }

            let filename = (href as NSString).lastPathComponent
            let name = cleanModuleName(filename)
            let category = categorizeModule(name: name, filename: filename)

            let downloadURL: URL
            if href.hasPrefix("http") {
                guard let url = URL(string: href) else { continue }
                downloadURL = url
            } else {
                downloadURL = baseURL.appendingPathComponent(href)
            }

            let mod = RemoteModule(
                id: filename,
                name: name,
                downloadURL: downloadURL,
                category: category,
                fileSize: nil
            )
            modules.append(mod)
        }

        // De-duplicate
        var seen = Set<String>()
        modules = modules.filter { seen.insert($0.id).inserted }

        return modules.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Clean an hmod filename into a display name
    private func cleanModuleName(_ filename: String) -> String {
        var name = filename
        // Remove .hmod extension
        if name.hasSuffix(".hmod") {
            name = String(name.dropLast(5))
        }
        // Replace underscores and hyphens
        name = name.replacingOccurrences(of: "_", with: " ")
        // Title case the first letter
        if let first = name.first {
            name = first.uppercased() + name.dropFirst()
        }
        return name
    }

    /// Categorize a module based on naming conventions
    private func categorizeModule(name: String, filename: String) -> String {
        let lower = filename.lowercased()
        if lower.contains("retroarch") || lower.contains("_ra_") { return "Emulators" }
        if lower.contains("core") { return "Cores" }
        if lower.contains("bios") { return "BIOS" }
        if lower.contains("font") || lower.contains("theme") { return "Themes" }
        if lower.contains("xtreme") || lower.contains("performance") { return "Performance" }
        return "Utilities"
    }
}

enum ModRepositoryError: LocalizedError {
    case invalidURL
    case fetchFailed
    case parseFailed
    case downloadFailed

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid repository URL"
        case .fetchFailed: return "Failed to fetch module list"
        case .parseFailed: return "Failed to parse module listing"
        case .downloadFailed: return "Failed to download module"
        }
    }
}
